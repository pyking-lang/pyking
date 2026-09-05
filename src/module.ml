(** The module system: one file is one module, and a program is the
    acyclic graph of the modules its main file reaches. Reads and parses
    every module a program needs, puts them in dependency order, and
    settles what each one exports and what each import means, before the
    type checker sees any of them. See
    docs/modules.md for the design and PYKING.md ("Modules") for the
    language.

    This is step 1 of the three the compiler takes over a program of
    several modules: `load` here, then the type checker once per module
    in the order `load` gives, and then `make_sigmap` on each result,
    which is what the next module is checked against.

    Data structures:
      Module_error -- a module-level failure, with the source position.
      t -- one file: its name, path, tokens, statements, the modules it
        imports and the names it exports.
      context -- what a backend is told about the module it is compiling
        beyond its statements.

    Functions:
      load path -- every module the program at path needs, dependencies
        first, parsed, symbolized and with every import resolved.
      read_file path info -- one file, lexed and parsed, and nothing else.
      context units unit -- what a backend needs to know about one
        module of a program beyond its statements.
      make_sigmap stmts tmap -- a module's exported names and their types.
      public_names stmts -- the names a module exports, unchecked.
      check_publics stmts -- the names a module exports, checked.
      resolve_imports module loaded -- one module with every import
        settled.
      module_name path -- the module name a file has.
      module_path directory name -- the file a module name means.
      dirname path / join a b / absolute path -- the path helpers the
        compiler needs, in the shapes Python's os.path gives them.
      sigmaps_for module sigmaps -- the signatures one module needs. *)

open Syntax

(* What a Pyking module is written in. A module name is a file name
   without it, in the directory of the file that imports it -- Pyking
   has no search path (see docs/modules.md, "Finding a module"). *)
let extension = ".pyk"

(** A module-level failure -- a missing module, a cycle, a collision, a
    name that is not exported -- with the source position. *)
exception Module_error of Lexer.info * string

(** One module of a program: its file's stem, which is what another
    module imports it by; the file it was read from; its tokens (kept
    for `--tokens`, which prints every module of the program); its
    statements; the modules it imports, in source order and without
    repeats; the names it exports, and where each was made public; and
    each of those names with the type the checker gave it -- filled in
    after the module is checked, and None until then. *)
type t = {
  name : string;
  path : string;
  tokens : Lexer.token list;
  stmts : stmt list;
  imports : string list;
  publics : (string * Lexer.info) list;
  sigmap : (string * typ) list option;
}

(** What a backend needs to know about the module it is compiling beyond
    its statements -- everything that is true of it only as part of a
    program: the module's own name; whether it is the program's own
    module, the one whose top level is where the program starts; whether
    the program has more than one module at all (a program of one is
    compiled exactly as it was before there were modules); the modules
    the program's own module must run before its own top level, in
    order; and what every module of the program exports and at what
    type, which is how a backend that must know a type for an imported
    name finds one. *)
type context = {
  context_name : string;
  main : bool;
  separate : bool;
  starts : string list;
  sigmaps : (string * (string * typ) list) list;
}

(* --- ordered tables ---
   The Python keeps these in dicts, which remember the order names were
   put in; an association list is the same thing with the order in
   plain sight. *)

(** An association list with `key` set to `value`: the existing entry
    replaced where there is one, and a new entry appended where there is
    not, so the order names arrived in survives.
    string -> 'a -> [(string, 'a)] -> [(string, 'a)] *)
let rec assoc_set key value = function
  | [] -> [ (key, value) ]
  | (k, _) :: rest when k = key -> (key, value) :: rest
  | pair :: rest -> pair :: assoc_set key value rest

(* --- finding a module --- *)

(** The directory part of a path, as Python's os.path.dirname gives it:
    "" for a bare file name, rather than ".". string -> string *)
let dirname path =
  match String.rindex_opt path '/' with
  | None -> ""
  | Some 0 -> "/"
  | Some i -> String.sub path 0 i

(** Two path parts joined, as Python's os.path.join gives it: the
    separator is not added to an empty directory. string -> string ->
    string *)
let join directory name =
  if directory = "" then name
  else if String.length directory > 0
          && directory.[String.length directory - 1] = '/'
  then directory ^ name
  else directory ^ "/" ^ name

(** An absolute, `.`- and `..`-free form of a path, for deciding whether
    two names are the same file and for a command that runs somewhere
    else. string -> string *)
let absolute path =
  let path =
    if Filename.is_relative path then join (Sys.getcwd ()) path else path
  in
  let rec collapse out parts =
    match parts with
    | [] -> List.rev out
    | "" :: rest | "." :: rest -> collapse out rest
    | ".." :: rest -> (
        match out with [] -> collapse [] rest | _ :: up -> collapse up rest)
    | part :: rest -> collapse (part :: out) rest
  in
  "/" ^ String.concat "/" (collapse [] (String.split_on_char '/' path))

(** The module name a file has: its stem. string -> string *)
let module_name path = Filename.remove_extension (Filename.basename path)

(** The file a module name means, in the directory of the file that
    imported it. string -> string -> string *)
let module_path directory name = join directory (name ^ extension)

(* --- reading one module --- *)

(** The contents of a file. string -> string *)
let read_whole_file path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

(** Lexes and parses one file into a module, and nothing else: no module
    it imports is read, and nothing about what it exports is checked.
    `info` is the import that asked for it, for the error a missing file
    raises. What `--no-typechecking` stops at.
    string -> info option -> t *)
let read_file path info =
  let data =
    try read_whole_file path
    with Sys_error _ as error -> (
      match info with
      (* The program's own file: nothing imported it, so there is no
         import to point at and no module error to raise. *)
      | None -> raise error
      | Some info ->
          raise
            (Module_error
               ( info,
                 Printf.sprintf
                   "cannot read module '%s': there is no file '%s'"
                   (module_name path) path )))
  in
  let tokens = Lexer.lexing path (Lexer.chars_of_string data) in
  {
    name = module_name path;
    path;
    tokens;
    stmts = Parser.parse tokens;
    imports = [];
    publics = [];
    sigmap = None;
  }

(** The modules a program imports, in source order and without repeats
    -- two imports of one module are one dependency. [stmt] -> [string] *)
let imported_modules stmts =
  List.fold_left
    (fun names statement ->
      match statement with
      | SImport (_, module_, _, _, _, _) when not (List.mem module_ names) ->
          names @ [ module_ ]
      | _ -> names)
    [] stmts

(* --- what a module exports --- *)

(** Every name the source marked `public`, in order, paired with the
    statement that marked it. A `def` may be marked on its definition or
    on its signature line, so a name can appear twice.
    [stmt] -> [(string, stmt)] *)
let public_names stmts =
  List.filter_map
    (fun statement ->
      match statement with
      | SFunctionDef (_, name, _, _, _, _, true)
      | SFunctionSig (_, name, _, _, true) ->
          Some (name, statement)
      (* The parser refuses `public` on a binding that takes a tuple
         apart, so a public target is always one name. *)
      | SLet (_, TargetName (_, name, _), _, _, _, true)
      | SLetStmt (_, TargetName (_, name, _), _, _, _, true) ->
          Some (name, statement)
      | _ -> None)
    stmts

(** The names an assignment target binds. assign_target -> [string] *)
let rec target_names target =
  match target with
  | TargetName (_, name, _) -> [ name ]
  | TargetTuple (_, elements, _) -> List.concat_map target_names elements

(** Every name the top level of a module binds, paired with the
    statement that binds it, in source order. An import is not one: what
    it binds came from elsewhere, and `check_publics` compares the two.
    [stmt] -> [(string, stmt)] *)
let bound_at_top_level stmts =
  List.concat_map
    (fun statement ->
      match statement with
      | SFunctionDef (_, name, _, _, _, _, _) | SVar (_, name, _, _) ->
          [ (name, statement) ]
      | SLet (_, target, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
          List.map (fun name -> (name, statement)) (target_names target)
      | _ -> [])
    stmts

(** Whether every `public` on `name` belongs to one definition -- a `def`
    and its own signature line, where writing it on either is enough. A
    name given to two `def`s is refused by `Analyses.block_functions` in
    its own words, so it is not refused here.
    string -> [stmt] -> bool *)
let one_definition name stmts =
  List.for_all
    (fun (_, statement) ->
      match statement with
      | SFunctionDef _ | SFunctionSig _ -> true
      | _ -> false)
    (List.filter (fun (n, _) -> n = name) (public_names stmts))

(** The names a module exports, refusing a name exported twice and one
    bound more than once at the top level -- an exported name means one
    thing in its module, so there is one definition for another module
    to reach. [stmt] -> [(string, info)] *)
let check_publics stmts =
  let publics =
    List.fold_left
      (fun publics (name, statement) ->
        match List.assoc_opt name publics with
        | Some (earlier : Lexer.info) when not (one_definition name stmts) ->
            raise
              (Module_error
                 ( stmt_info statement,
                   Printf.sprintf
                     "'%s' is already public in this module (line %d); a \
                      module exports one thing under one name"
                     name earlier.row1 ))
        | Some _ -> publics
        | None -> publics @ [ (name, stmt_info statement) ])
      [] (public_names stmts)
  in
  ignore
    (List.fold_left
       (fun bindings (name, statement) ->
         match List.assoc_opt name bindings with
         | Some (earlier : Lexer.info) when List.mem_assoc name publics ->
             raise
               (Module_error
                  ( stmt_info statement,
                    Printf.sprintf
                      "'%s' is public, and is bound twice at the top level of \
                       this module (already on line %d); an exported name is \
                       bound once, so that another module reaches one \
                       definition"
                      name earlier.row1 ))
         | _ -> assoc_set name (stmt_info statement) bindings)
       [] (bound_at_top_level stmts));
  publics

(* --- resolving what an import means --- *)

(** Why a name a module has is still not one it exports, or "" for a
    name it does not have at all. string -> t -> string *)
let hint name imported =
  if List.exists (fun (bound, _) -> bound = name)
       (bound_at_top_level imported.stmts)
  then
    Printf.sprintf
      ": it is defined in '%s' but not marked 'public', and a module exports \
       nothing by default"
      imported.path
  else ""

(** One import with its fields settled: the module's public names for
    the plain form, and the names the source asked for -- each checked to
    be exported -- for the `from` form. stmt -> t -> stmt *)
let resolved statement imported =
  match statement with
  | SImport (info, module_, local, false, _, sym) ->
      SImport
        ( info,
          module_,
          local,
          false,
          List.map (fun (name, _) -> (name, name)) imported.publics,
          sym )
  | SImport (info, _, _, true, fields, _) ->
      List.iter
        (fun (name, _) ->
          if not (List.mem_assoc name imported.publics) then
            raise
              (Module_error
                 ( info,
                   Printf.sprintf "module '%s' does not export '%s'%s"
                     imported.name name (hint name imported) )))
        fields;
      statement
  | statement -> statement

(** Records that `name` is now in use in `module_`, refusing it if
    something already has it.
    [(string, info option)] -> string -> stmt -> t ->
    [(string, info option)] *)
let claim taken name statement module_ =
  match List.assoc_opt name taken with
  | Some earlier ->
      let where =
        match earlier with
        | None -> "the name of a builtin"
        | Some (info : Lexer.info) ->
            Printf.sprintf "already bound on line %d" info.row1
      in
      raise
        (Module_error
           ( stmt_info statement,
             Printf.sprintf
               "this import brings in '%s', which module '%s' cannot use for \
                it: it is %s. Rename one of them, with 'as' on the import if \
                that is the one to move"
               name module_.name where ))
  | None -> assoc_set name (Some (stmt_info statement)) taken

(** `module_` with every import resolved: a plain import's `fields`
    filled in with the module's public names, a selected one checked
    against them, and every name it brings in checked for a collision
    with the module's own. t -> [(string, t)] -> t *)
let resolve_imports module_ loaded =
  (* What the module already uses: the builtins, which nothing may take
     the name of, and everything its top level binds. *)
  let taken =
    List.fold_left
      (fun taken name -> assoc_set name None taken)
      [] Analyses.builtins
  in
  let taken =
    List.fold_left
      (fun taken (name, statement) ->
        assoc_set name (Some (stmt_info statement)) taken)
      taken
      (bound_at_top_level module_.stmts)
  in
  let _, stmts =
    List.fold_left
      (fun (taken, stmts) statement ->
        match statement with
        | SImport (_, imported_name, local, selected, _, _) ->
            let statement =
              resolved statement (List.assoc imported_name loaded)
            in
            let fields =
              match statement with
              | SImport (_, _, _, _, fields, _) -> fields
              | _ -> []
            in
            let taken =
              if selected then
                List.fold_left
                  (fun taken (_, local) -> claim taken local statement module_)
                  taken fields
              else claim taken local statement module_
            in
            (taken, stmts @ [ statement ])
        | statement -> (taken, stmts @ [ statement ]))
      (taken, []) module_.stmts
  in
  { module_ with stmts }

(* --- the graph --- *)

(** The cycle an import closes, as the ring of modules it runs through.
    string -> [(string, info option)] -> string *)
let cycle_message name stack =
  let held = List.map (fun (module_, _) -> module_) stack in
  let rec from name = function
    | [] -> []
    | x :: rest -> if x = name then x :: rest else from name rest
  in
  let ring = from name held @ [ name ] in
  (match ring with
  | [ a; b ] when a = b -> Printf.sprintf "module '%s' imports itself" name
  | _ ->
      Printf.sprintf "these modules import one another: %s"
        (String.concat " -> " ring))
  ^ ". Pyking has no circular imports: a module is compiled, and run, after \
     everything it imports"

(** Depth-first over the import graph, appending each module to `order`
    after everything it imports. `stack` is the path of imports being
    followed, which is what a cycle is reported from.
    string -> string -> info option -> [(string, t)] -> [string] ->
    [(string, info option)] -> ([(string, t)], [string]) *)
let rec visit name path info parsed order stack =
  if List.exists (fun (held, _) -> held = name) stack then
    (* Only a recursive call has a non-empty stack, and every one of
       those carries the import that asked for the module. *)
    raise (Module_error (Option.get info, cycle_message name stack))
  else if List.mem_assoc name parsed then (parsed, order)
  else
    let module_ = read_file path info in
    let module_ =
      {
        module_ with
        imports = imported_modules module_.stmts;
        publics = check_publics module_.stmts;
      }
    in
    let parsed = parsed @ [ (name, module_) ] in
    (* The importing file's own directory, as it was named rather than
       made absolute: a module is beside the file that imports it (see
       docs/modules.md, "Finding a module"), and an error naming it
       should read the way the command that found it did. *)
    let directory = dirname path in
    let parsed, order =
      List.fold_left
        (fun (parsed, order) statement ->
          match statement with
          | SImport (import_info, imported_name, _, _, _, _) ->
              visit imported_name
                (module_path directory imported_name)
                (Some import_info) parsed order
                (stack @ [ (name, info) ])
          | _ -> (parsed, order))
        (parsed, order) module_.stmts
    in
    (parsed, order @ [ name ])

(** Every module the program in `path` needs, dependencies first and the
    program itself last: read, parsed, symbolized with one numbering
    across the whole program, and with every import resolved. Raises
    Module_error for a missing module or a cycle. string -> [t] *)
let load path =
  let parsed, order = visit (module_name path) path None [] [] [] in
  let _, _, modules =
    List.fold_left
      (fun (highest, loaded, modules) name ->
        let module_ = List.assoc name parsed in
        let module_ =
          { module_ with stmts = Analyses.symbolize ~start:highest module_.stmts }
        in
        let highest = Analyses.highest_sym module_.stmts in
        let module_ = resolve_imports module_ loaded in
        (highest, loaded @ [ (name, module_) ], modules @ [ module_ ]))
      (0, [], []) order
  in
  modules

(* --- what the type checker is given --- *)

(** The context for one module of a program. `units` pairs each module
    with what the checker worked out for it, dependencies first.
    [(t, 'a)] -> t -> context *)
let context units unit =
  let last = fst (List.nth units (List.length units - 1)) in
  let main = unit.name = last.name in
  {
    context_name = unit.name;
    main;
    separate = List.length units > 1;
    starts =
      (if main then
         List.filteri
           (fun i _ -> i < List.length units - 1)
           (List.map (fun (other, _) -> other.name) units)
       else []);
    sigmaps =
      List.map
        (fun (other, _) -> (other.name, Option.value other.sigmap ~default:[]))
        units;
  }

(** A module's exported names and the types the checker worked out for
    them -- what another module is checked against, and all of this
    module that another one can see. Every exported name has one:
    `Typesystem.check_exports` refuses a module that exports a `def` it
    worked out no type for.
    [stmt] -> typ IntMap.t -> [(string, typ)] *)
let make_sigmap stmts tmap =
  let exported = check_publics stmts in
  List.filter_map
    (fun (name, statement) ->
      if List.mem_assoc name exported then
        Some (name, IntMap.find (stmt_sym statement) tmap)
      else None)
    (bound_at_top_level stmts)

(** The signatures needed to check one module: its own imports', out of
    every module checked so far.
    t -> [(string, [(string, typ)])] -> [(string, [(string, typ)])] *)
let sigmaps_for module_ sigmaps =
  List.map (fun name -> (name, List.assoc name sigmaps)) module_.imports
