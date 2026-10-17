(** Submodules: a definition whose name has a dot in it, `def
    mymod.foo(...)`, is `foo` in the submodule `mymod` of its file, and is
    written `mymod.foo` wherever it is used -- in its own file, and as
    `hello.mymod.foo` or through `from hello import mymod` in another.
    This pass is where a dotted name stops being one: run by
    `module.ml`'s `prepare` before anything else reads a module, it gives
    every dotted name the one plain name it compiles to (`mymod__foo`),
    so the checker, the interpreter and every backend never see a
    submodule. See docs/modules.md, "Submodules".

    It works on tokens: a dotted path naming a definition becomes one
    identifier, and the module is parsed again, which reaches every
    expression, pattern and type at once. An import naming a submodule
    is then rewritten as a `from` line taking its members.

    Data structures:
      Error -- a refusal, with the source position.
      table -- a module's dotted names and the plain names they become.

    Functions:
      flat dotted -- the plain name a dotted one compiles to.
      root name -- the module an import's dotted name reaches.
      module_ name tokens stmts declarations imported -- one module
        rewritten, with its table. *)

open Syntax
open Lexer

exception Error of info * string

(** A module's dotted names, each with the plain name it compiles to. *)
type table = (string * string) list

(** Whether a name starts with a capital: a datatype or a constructor.
    String -> Bool *)
let is_upper name = name <> "" && name.[0] >= 'A' && name.[0] <= 'Z'

(** The parts of a dotted name but the last, and the last.
    String -> ([String], String) *)
let split dotted =
  match List.rev (String.split_on_char '.' dotted) with
  | last :: path -> (List.rev path, last)
  | [] -> ([], dotted)

(** The plain name a dotted one compiles to: the parts joined by `__`,
    with a capital first where the last part has one, and an overloaded
    definition's qualifier kept in front (`mymod.int::abs` is
    `int::mymod__abs`, overloading `mymod.abs`). String -> String *)
let flat dotted =
  let path, last = split dotted in
  match Names.qualifier last with
  | Some q -> q ^ Names.separator ^ String.concat "__" (path @ [ Names.base last ])
  | None ->
      let joined = String.concat "__" (path @ [ last ]) in
      if is_upper last then String.capitalize_ascii joined else joined

(** The module an import's dotted name reaches: its first part.
    String -> String *)
let root name =
  match String.index_opt name '.' with Some i -> String.sub name 0 i | None -> name

(** The part of an import's dotted name after the module, if any.
    String -> String? *)
let path_of name =
  match String.index_opt name '.' with
  | Some i -> Some (String.sub name (i + 1) (String.length name - i - 1))
  | None -> None

(** One span from the start of `a` to the end of `b`. info -> info -> info *)
let combine a b = { a with row2 = b.row2; col2 = b.col2 }

(** Every dotted name a module's top level defines, with where: each
    definition's, and each constructor's of a dotted datatype, which
    lives in the datatype's submodule. [stmt] -> [(String, info)] *)
let defined stmts =
  let rec targets target =
    match target with
    | TargetName (i, name, _) -> [ (name, i) ]
    | TargetTuple (_, parts, _) -> List.concat_map targets parts
  in
  List.concat_map
    (fun statement ->
      match statement with
      | SFunctionDef (i, name, _, _, _, _, _, _, _) | SFunctionSig (i, name, _, _, _) ->
          [ (name, i) ]
      | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) -> targets target
      | SDatatype (i, name, _, constructors, _, _) ->
          let path, _ = split name in
          (name, i)
          :: List.map
               (fun (Constructor (ci, c, _, _)) -> (String.concat "." (path @ [ c ]), ci))
               (if path = [] then [] else constructors)
      | _ -> [])
    stmts
  |> List.filter (fun (name, _) -> String.contains name '.')

(** A module's table from the dotted names it defines: each with its
    plain name, and an overloaded one's base as well, which is what a
    call is written with. [String] -> table *)
let table_of names =
  List.concat_map
    (fun dotted ->
      let path, last = split dotted in
      (dotted, flat dotted)
      ::
      (if Names.is_qualified last then
         let base = String.concat "." (path @ [ Names.base last ]) in
         [ (base, flat base) ]
       else []))
    names

(** Every submodule a table's names are in: each proper prefix, dotted.
    table -> [String] *)
let namespaces table =
  List.sort_uniq compare
    (List.concat_map
       (fun (dotted, _) ->
         let path, _ = split dotted in
         List.mapi (fun k _ -> String.concat "." (List.filteri (fun j _ -> j <= k) path)) path)
       table)

(** What an import makes reachable by a dotted path here: the alias of a
    whole module, or a name standing for a submodule of one. *)
type reach =
  | Whole of string * table * string list
      (* `import hello [as h]`: h.mymod.foo; the module, its table and
         its public names *)
  | Space of string * table * string list * string
      (* `from hello import mymod [as m]`: m.foo; the same, and the
         submodule *)

(** What one import of the first parse reaches, and under which local
    name. `imported` is each imported module's table and public names.
    Raises Error for a submodule the module does not have.
    [(String, (table, [String]))] -> stmt -> [(String, reach)] *)
let reaches imported statement =
  let lookup info name =
    match List.assoc_opt name imported with
    | Some found -> found
    | None -> raise (Error (info, Printf.sprintf "no module '%s' is imported" name))
  in
  match statement with
  | SImport (info, name, local, selected, fields, _) -> (
      let table, publics = lookup info (root name) in
      let module_name = root name in
      let spaces = namespaces table in
      let space_or_none path =
        if List.mem path spaces then Some path
        else None
      in
      match (path_of name, selected) with
      | None, false -> [ (local, Whole (module_name, table, publics)) ]
      | Some path, false ->
          if not (List.mem path spaces) then
            raise
              (Error
                 ( info,
                   Printf.sprintf "module '%s' has no submodule '%s'" (root name) path ));
          let alias = if local = name then snd (split name) else local in
          [ (alias, Space (module_name, table, publics, path)) ]
      | prefix, true ->
          List.filter_map
            (fun (field, alias) ->
              let full = match prefix with Some p -> p ^ "." ^ field | None -> field in
              match space_or_none full with
              | Some path -> Some (alias, Space (module_name, table, publics, path))
              | None -> None)
            fields)
  | _ -> []

(** The tokens with every dotted path that names a definition joined into
    the one identifier it compiles to: one of this module's own
    (`mymod.foo`), one reached through a submodule an import named
    (`m.foo`), or one of an imported module's (`hello.mymod.foo` becomes
    `hello . mymod__foo`). A path is followed only from a name no dot
    comes before, and not on an import line.
    table -> [(String, reach)] -> [token] -> [token] *)
let rewrite own reached tokens =
  let own_roots = List.map root (namespaces own) in
  (* The names after `first`, each `.name` on the row the one before it
     ended on: (name, its span), in order. *)
  let rec chain last tokens =
    match tokens with
    | TokDot dot :: TokIdent (ni, name) :: rest when dot.row1 = last.row2 && ni.row1 = dot.row2 ->
        let more, rest = chain ni rest in
        ((name, ni) :: more, rest)
    | _ -> ([], tokens)
  in
  (* The longest run of the chain's first names whose dotted form, after
     `prefix`, is in `table`: how many, and the dotted name. *)
  let longest table prefix parts =
    let rec try_ k =
      if k = 0 then None
      else
        let taken = List.filteri (fun j _ -> j < k) parts in
        let dotted = String.concat "." (prefix @ List.map fst taken) in
        if List.mem_assoc dotted table then Some (k, dotted) else try_ (k - 1)
    in
    try_ (List.length parts)
  in
  let drop k parts = List.filteri (fun j _ -> j >= k) parts in
  (* Refuses a name of another module that is not public, in the words
     the program wrote it with. *)
  let exported info module_name table publics dotted =
    let plain = List.assoc dotted table in
    (* An overloaded name is exported where any of its definitions is. *)
    if not (List.exists (fun p -> p = plain || Names.base p = plain && Names.is_qualified p) publics)
    then
      raise
        (Error
           ( info,
             Printf.sprintf "module '%s' does not export '%s'" module_name dotted ))
  in
  let rebuild parts =
    List.concat_map (fun (name, ni) -> [ TokDot ni; TokIdent (ni, name) ]) parts
  in
  let span first parts k =
    match List.rev (List.filteri (fun j _ -> j < k) parts) with
    | (_, last) :: _ -> combine first last
    | [] -> first
  in
  let rec go previous tokens =
    match tokens with
    | [] -> []
    | (TokIdent (i, first) as t) :: rest -> (
        let after_dot = match previous with Some (TokDot _) -> true | _ -> false in
        let on_import =
          match previous with Some (TokImport _ | TokFrom _ | TokAs _ | TokComma _) -> true | _ -> false
        in
        let parts, rest' = chain i rest in
        if after_dot || on_import || parts = [] then t :: go (Some t) rest
        else
          match List.assoc_opt first reached with
          | Some (Space (module_name, table, publics, path)) -> (
              match longest table (String.split_on_char '.' path) parts with
              | Some (k, dotted) ->
                  exported (span i parts k) module_name table publics dotted;
                  let local = String.concat "." (first :: List.map fst (List.filteri (fun j _ -> j < k) parts)) in
                  let joined = TokIdent (span i parts k, flat local) in
                  joined :: go (Some joined) (rebuild (drop k parts) @ rest')
              | None ->
                  raise
                    (Error
                       ( span i parts 1,
                         Printf.sprintf "submodule '%s' has no '%s'" path (fst (List.hd parts)) )))
          | Some (Whole (module_name, table, publics)) -> (
              match longest table [] parts with
              | Some (k, dotted) ->
                  exported (span i parts k) module_name table publics dotted;
                  let first_part = snd (List.hd parts) in
                  let joined = TokIdent (span first_part parts k, flat dotted) in
                  let dot = match rest with dot :: _ -> dot | [] -> t in
                  t :: dot :: joined :: go (Some joined) (rebuild (drop k parts) @ rest')
              | None ->
                  (* A path into a submodule the module has, to a name it
                     does not: said here, in the program's own words. *)
                  let spaces = namespaces table in
                  let rec deepest k =
                    if k = 0 then None
                    else
                      let path = String.concat "." (List.map fst (List.filteri (fun j _ -> j < k) parts)) in
                      if List.mem path spaces then Some (k, path) else deepest (k - 1)
                  in
                  (match deepest (List.length parts) with
                  | Some (k, path) when k < List.length parts ->
                      raise
                        (Error
                           ( span (snd (List.hd parts)) parts (k + 1),
                             Printf.sprintf "the submodule '%s' of module '%s' has no '%s'"
                               path module_name (fst (List.nth parts k)) ))
                  | _ -> ());
                  t :: go (Some t) rest)
          | None when List.mem first own_roots -> (
              match longest own [ first ] parts with
              | Some (k, dotted) ->
                  let joined = TokIdent (span i parts k, flat dotted) in
                  joined :: go (Some joined) (rebuild (drop k parts) @ rest')
              | None ->
                  raise
                    (Error
                       ( span i parts 1,
                         Printf.sprintf "'%s.%s' is not defined: the submodule '%s' has no '%s'"
                           first (fst (List.hd parts)) first (fst (List.hd parts)) )))
          | None -> t :: go (Some t) rest)
    | t :: rest -> t :: go (Some t) rest
  in
  go None tokens

(** The `from` fields taking every public member of the submodule `path`
    of a module, each named here under `alias` as it is there under
    `path`. Raises Error where there is none.
    info -> table -> [String] -> String -> String -> String -> [(String, String)] *)
let members info table publics module_name path alias =
  let prefix = path ^ "." in
  let fields =
    List.filter_map
      (fun (dotted, plain) ->
        if String.starts_with ~prefix dotted && List.mem plain publics then
          let rest = String.sub dotted (String.length prefix) (String.length dotted - String.length prefix) in
          Some (plain, flat (alias ^ "." ^ rest))
        else None)
      table
  in
  if fields = [] then
    raise
      (Error
         ( info,
           Printf.sprintf "the submodule '%s' of module '%s' exports nothing" path module_name ));
  fields

(** An import naming a submodule, as the `from` line taking its members:
    `import hello.mymod as m`, `from hello import mymod as m` and `from
    hello.mymod import foo`. Any other import is left as it is.
    [(String, (table, [String]))] -> stmt -> stmt *)
let import_rewritten imported statement =
  match statement with
  | SImport (info, name, local, selected, fields, sym) -> (
      let module_name = root name in
      let table, publics =
        match List.assoc_opt module_name imported with Some found -> found | None -> ([], [])
      in
      let spaces = namespaces table in
      match (path_of name, selected) with
      | None, false -> statement
      | Some path, false ->
          let alias = if local = name then snd (split name) else local in
          SImport (info, module_name, module_name, true,
                   members info table publics module_name path alias, sym)
      | prefix, true ->
          let fields =
            List.concat_map
              (fun (field, alias) ->
                let full = match prefix with Some p -> p ^ "." ^ field | None -> field in
                if List.mem full spaces then members info table publics module_name full alias
                else
                  match prefix with
                  | None -> [ (field, alias) ]
                  | Some p ->
                      if List.mem_assoc full table then [ (flat full, alias) ]
                      else
                        raise
                          (Error
                             ( info,
                               Printf.sprintf "the submodule '%s' of module '%s' has no '%s'" p
                                 module_name field )))
              fields
          in
          SImport (info, module_name, module_name, true, fields, sym))
  | _ -> statement

(** A dotted datatype's constructors given the plain names they compile
    to, the datatype's path in front of each. `dotted` is every dotted
    datatype name the first parse saw. [String] -> stmt -> stmt *)
let constructors_flattened dotted statement =
  match statement with
  | SDatatype (i, name, params, constructors, sym, public) -> (
      match List.find_opt (fun d -> flat d = name) dotted with
      | Some d ->
          let path, _ = split d in
          SDatatype
            ( i,
              name,
              params,
              List.map
                (fun (Constructor (ci, c, fields, csym)) ->
                  Constructor (ci, flat (String.concat "." (path @ [ c ])), fields, csym))
                constructors,
              sym,
              public )
      | None -> statement)
  | _ -> statement

(** A declaration line's dotted name as the plain name it compiles to.
    stmt -> stmt *)
let declaration_flattened statement =
  match statement with
  | SFunctionSig (i, name, t, sym, public) when String.contains name '.' ->
      SFunctionSig (i, flat name, t, sym, public)
  | _ -> statement

(** Refuses binding a name that stands for a submodule here, anywhere in
    the file, and two definitions that compile to one plain name.
    [String] -> [(String, info)] -> [String] -> [stmt] -> () *)
let check_names roots own plain_names stmts =
  let refuse info name =
    raise
      (Error
         ( info,
           Printf.sprintf
             "'%s' names a submodule here, so nothing in this file may also be \
              called '%s'"
             name name ))
  in
  ignore
    (Walk.fold_stmts
       (fun () node ->
         match node with
         | Walk.NExpr _ | Walk.NType _ -> ()
         | Walk.NStmt (SImport (i, _, local, selected, fields, _)) ->
             if (not selected) && List.mem local roots then refuse i local;
             List.iter (fun (_, l) -> if List.mem l roots then refuse i l) fields
         | _ -> (
             match Walk.name_field node with
             | Some name when List.mem name roots -> (
                 match node with
                 | Walk.NStmt s -> refuse (stmt_info s) name
                 | Walk.NParam (Param (i, _, _, _, _)) -> refuse i name
                 | Walk.NPattern p -> refuse (pattern_info p) name
                 | Walk.NTarget t -> refuse (target_info t) name
                 | Walk.NLoopIter (ForIn (i, _, _, _)) -> refuse i name
                 | Walk.NListRest (ListRest (i, _, _)) -> refuse i name
                 | _ -> ())
             | _ -> ()))
       () stmts);
  let seen = Hashtbl.create 16 in
  List.iter
    (fun (dotted, info) ->
      let plain = flat dotted in
      if List.mem plain plain_names then
        raise
          (Error
             ( info,
               Printf.sprintf "'%s' compiles to '%s', which this module also defines" dotted plain ));
      (match Hashtbl.find_opt seen plain with
      | Some other when other <> dotted ->
          raise
            (Error
               ( info,
                 Printf.sprintf "'%s' and '%s' both compile to '%s'" other dotted plain ))
      | _ -> ());
      Hashtbl.replace seen plain dotted)
    own

(** Every name the first parse's top level binds that has no dot.
    [stmt] -> [String] *)
let plain_names stmts =
  List.concat_map
    (fun statement ->
      match statement with
      | SFunctionDef (_, name, _, _, _, _, _, _, _) | SFunctionSig (_, name, _, _, _)
      | SVar (_, name, _, _) ->
          [ name ]
      | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
          let rec names = function
            | TargetName (_, n, _) -> [ n ]
            | TargetTuple (_, parts, _) -> List.concat_map names parts
          in
          names target
      | SDatatype (_, name, _, constructors, _, _) when not (String.contains name '.') ->
          name :: List.map (fun (Constructor (_, c, _, _)) -> c) constructors
      | _ -> [])
    stmts
  |> List.filter (fun n -> not (String.contains n '.'))

(** One module with its submodules gone: every dotted name it defines or
    reaches given the plain name it compiles to, every import naming a
    submodule turned into the `from` line taking its members, and its own
    table. `tokens` and `stmts` are its Pyking half as lexed and as first
    parsed, `declarations` its declaration half, and `imported` each
    module it may import, with its table and public names. `context` is
    what was written before these statements in the same module -- the
    REPL's earlier entries -- whose submodules and imports count here
    too. A module with no dotted name to settle comes back as it was.
    [stmt]? -> [token] -> [stmt] -> [stmt] -> [(String, (table, [String]))] ->
    ([stmt], [stmt], table) *)
let module_ ?(context = []) tokens stmts declarations imported =
  let own = defined (context @ stmts) @ defined declarations in
  let table = table_of (List.map fst own) in
  (* An import of a module with no submodules reaches nothing dotted. *)
  let reached =
    List.filter
      (fun (_, r) -> match r with Whole (_, t, _) | Space (_, t, _, _) -> t <> [])
      (List.concat_map (reaches imported) (context @ stmts))
  in
  let dotted_import =
    List.exists
      (fun s -> match s with SImport (_, name, _, _, _, _) -> String.contains name '.' | _ -> false)
      stmts
  in
  if own = [] && reached = [] && not dotted_import then
    (stmts, declarations, [])
  else
    let reparsed =
      if stmts = [] then [] else if tokens = [] then stmts
      else Parser.parse (rewrite table reached tokens)
    in
    let datatypes =
      List.filter_map
        (fun s ->
          match s with
          | SDatatype (_, name, _, _, _, _) when String.contains name '.' -> Some name
          | _ -> None)
        stmts
    in
    let rewritten =
      List.map (fun s -> constructors_flattened datatypes (import_rewritten imported s)) reparsed
    in
    let declarations = List.map declaration_flattened declarations in
    let roots =
      List.sort_uniq compare
        (List.map root (namespaces table)
        @ List.filter_map
            (fun (alias, r) -> match r with Space _ -> Some alias | Whole _ -> None)
            reached)
    in
    check_names roots
      (defined stmts @ defined declarations)
      (plain_names (context @ stmts) @ plain_names declarations)
      (rewritten @ declarations);
    (rewritten, declarations, table)
