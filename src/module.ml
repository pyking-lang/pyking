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

    An *external* module is declared in `sys.external.pyk` and
    implemented in the target's own language (`sys.py`, `sys.js`,
    `Sys.java`, ...). The declaration file holds signatures and nothing
    else; the implementation is read by the host toolchain, never by
    this compiler, and is copied beside the program's output so the
    host finds it where it expects to.

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
      module_file directory name -- that file and whether it is a
        declaration of an external module, refusing a name with both.
      class_name stem -- the Java class (and file) name for a stem.
      implementation_name name target -- what an external module's
        implementation file is called on that target.
      implementation_path directory name target info -- that file, checked
        to exist.
      external_signatures stmts -- an external module's declared names
        and their types.
      check_declaration stmts path -- refuses anything but a public
        signature in a declaration file.
      dirname path / join a b / absolute path -- the path helpers the
        compiler needs, in the shapes Python's os.path gives them.
      sigmaps_for module sigmaps -- the signatures one module needs. *)

open Syntax

(* What a Pyking module is written in. A module name is a file name
   without it, in the directory of the file that imports it -- Pyking
   has no search path (see docs/modules.md, "Finding a module"). *)
let extension = ".pyk"

(* An external module's declaration file. `sys.external.pyk` says what
   `sys` offers and at what type; `sys.py`, `sys.js`, `Sys.java` and
   the rest implement it, one per target. Only the declaration is
   Pyking, and only the declaration is read here. *)
let external_extension = ".external.pyk"

(** A module-level failure -- a missing module, a cycle, a collision, a
    name that is not exported -- with the source position. *)
exception Module_error of Lexer.info * string

(** One module of a program: its file's stem, which is what another
    module imports it by; the file it was read from; its tokens (kept
    for `--tokens`, which prints every module of the program); its
    statements; the modules it imports, in source order and without
    repeats; the names it exports, and where each was made public; and
    each of those names with the type the checker gave it -- filled in
    after the module is checked, and None until then; and whether it is
    an external module, declared here and implemented in the target's
    own language. *)
type t = {
  name : string;
  path : string;
  tokens : Lexer.token list;
  stmts : stmt list;
  imports : string list;
  publics : (string * Lexer.info) list;
  sigmap : (string * typ) list option;
  is_external : bool;
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
    name finds one; and which of them are external, since a backend
    reaches one through the host's own source rather than through a file
    this compiler wrote. *)
type context = {
  context_name : string;
  main : bool;
  separate : bool;
  starts : string list;
  sigmaps : (string * (string * typ) list) list;
  externals : string list;
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
let module_name path =
  let stem = Filename.remove_extension (Filename.basename path) in
  (* `sys.external.pyk` is module `sys`: the marker is part of the file
     name, not of the name another module imports it by. *)
  if Filename.extension stem = ".external" then Filename.remove_extension stem
  else stem

(** The file a module name means, in the directory of the file that
    imported it. string -> string -> string *)
let module_path directory name = join directory (name ^ extension)

(** An external module's declaration file, in the same directory.
    string -> string -> string *)
let external_module_path directory name =
  join directory (name ^ external_extension)

(** Whether a path names an external module's declaration.
    string -> bool *)
let is_external_path path =
  Filename.check_suffix path external_extension

(** Where a program's files come from. The compiler reads a directory;
    the browser has none and is handed the sources instead, which is
    what lets `iweb` run a program of several modules in a page (see
    docs/target_js.md, "The interpreted target"). *)
type sources = { exists : string -> bool; contents : string -> string }

(** The contents of a file. string -> string *)
let read_whole_file path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

(** The files on disk: what `pyk` compiles from. sources *)
let disk = { exists = Sys.file_exists; contents = read_whole_file }

(** The file a module name means and whether it declares an external
    module. A name with both files is refused: a module is one thing,
    and which of the two was meant would be a guess.
    string -> string -> info option -> (string, bool) *)
let module_file ?(from = disk) directory name info =
  let plain = module_path directory name in
  let declared = external_module_path directory name in
  match (from.exists declared, from.exists plain) with
  | true, true ->
      let where =
        match info with
        | Some i -> i
        (* The program's own file: no import asked for it, so the
           collision is reported against the file itself. *)
        | None ->
            { Lexer.file = declared; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
      in
      raise
        (Module_error
           ( where,
             Printf.sprintf
               "module '%s' is declared twice: '%s' and '%s'. A module is                 either written in Pyking or implemented for a target, not                 both"
               name declared plain ))
  | true, false -> (declared, true)
  | false, _ -> (plain, false)

(* --- reading one module --- *)

(** Lexes and parses one file into a module, and nothing else: no module
    it imports is read, and nothing about what it exports is checked.
    `info` is the import that asked for it, for the error a missing file
    raises. What `--no-typechecking` stops at.
    string -> info option -> t *)
let read_file ?(from = disk) path info =
  let data =
    try from.contents path
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
    is_external = is_external_path path;
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

(* --- external modules ---

   A declaration file holds signatures and nothing else, so everything
   it exports comes from the implementation and there is no Pyking body
   for this compiler to generate. Mixing the two would need one file to
   be both hand-written and generated (see docs/modules.md, "Why a
   declaration file holds nothing else"). *)

(** An external module's declared names and their types, in source
    order. [stmt] -> [(string, typ)] *)
let external_signatures stmts =
  List.filter_map
    (function
      | SFunctionSig (_, name, type_, _, _) -> Some (name, type_) | _ -> None)
    stmts

(** Refuses a type that cannot cross the boundary between Pyking and a
    target language: a type variable, because a host function is one
    implementation and cannot be polymorphic, and a function anywhere
    inside the signature, because passing a Pyking closure to a host
    would need a calling convention there is none of yet (see
    docs/modules.md, "What may cross the boundary").
    typ -> string -> info -> () *)
let check_boundary_type type_ name info =
  let refuse what =
    raise
      (Module_error
         ( info,
           Printf.sprintf
             "'%s' cannot be declared with %s: an external module is \
              implemented in a target language, and %s does not cross that \
              boundary"
             name what what ))
  in
  let rec walk nested type_ =
    match type_ with
    | TVar _ -> refuse "a type variable"
    | TForall _ -> refuse "a polymorphic type"
    | TFunction (_, params, result, _, _, _) ->
        if nested then refuse "a function type";
        List.iter (walk true) params;
        walk true result
    | TList (_, element, _) -> walk nested element
    | TTuple (_, elements, _) -> List.iter (walk nested) elements
    | _ -> ()
  in
  walk false type_

(** Whether a statement list is a declaration file's -- signatures and
    nothing else, which is what an external module holds. Asked of the
    statements rather than the file name, so a caller that has only the
    program (the interpreter) can tell. [stmt] -> bool *)
let is_declaration stmts =
  stmts <> []
  && List.for_all
       (fun statement ->
         match statement with SFunctionSig _ -> true | _ -> false)
       stmts

(** Refuses anything but a public signature in a declaration file: a
    body there would have to be compiled into the very file the target's
    own implementation already occupies, and a private signature names
    something nothing could reach. [stmt] -> string -> () *)
let check_declaration stmts path =
  List.iter
    (fun statement ->
      match statement with
      | SFunctionSig (info, name, type_, _, true) ->
          check_boundary_type type_ name info
      | SFunctionSig (info, name, _, _, false) ->
          raise
            (Module_error
               ( info,
                 Printf.sprintf
                   "'%s' is declared in '%s' but not marked 'public'. An                     external module is reached only through what it exports,                     so a signature that is not public names nothing"
                   name path ))
      | statement ->
          raise
            (Module_error
               ( stmt_info statement,
                 Printf.sprintf
                   "'%s' declares an external module, so it holds signatures                     and nothing else: what it exports is implemented for each                     target, not here"
                   path )))
    stmts

(** The Java class (and file) name for a stem, e.g. foo_bar -> FooBar.
    Java requires the two to match, so naming the file is naming the
    class. string -> string *)
let class_name stem =
  let is_word c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  in
  let words, current =
    String.fold_left
      (fun (words, current) c ->
        if is_word c then (words, current ^ String.make 1 c)
        else if current = "" then (words, "")
        else (words @ [ current ], ""))
      ([], "") stem
  in
  let words = if current = "" then words else words @ [ current ] in
  let name =
    String.concat ""
      (List.map
         (fun word ->
           String.make 1 (Char.uppercase_ascii word.[0])
           ^ String.sub word 1 (String.length word - 1))
         words)
  in
  let name = if name = "" then "Program" else name in
  if name.[0] >= '0' && name.[0] <= '9' then "_" ^ name else name

(** What an external module's implementation file is called on a target:
    the name the host itself resolves the module by, which is why
    nothing is renamed. None for a target that cannot reach one.
    string -> string -> string option *)
let implementation_name name target =
  match Targets.family_of target with
  | Targets.Python -> Some (name ^ ".py")
  (* Every JavaScript target imports a module as `./<name>.js`, so that
     is what the file must be called in the output, whichever source it
     was copied from -- see `implementation_path`. *)
  | Targets.Node | Targets.Web | Targets.Iweb -> Some (name ^ ".js")
  | Targets.C -> Some (name ^ ".c")
  | Targets.Java -> Some (class_name name ^ ".java")
  | Targets.Ocaml -> Some (name ^ ".ml")
  | Targets.Pyking -> None

(** An external module's implementation for a target, checked to exist.
    Raises Module_error naming both the module and the file it looked
    for. string -> string -> string -> info -> string *)
let implementation_path directory name target info =
  match implementation_name name target with
  | None ->
      raise
        (Module_error
           ( info,
             Printf.sprintf
               "target '%s' cannot use the external module '%s': it has no \
                file of its own for a module to be implemented in"
               target name ))
  | Some file ->
      (* Where the implementation is *read* from, which is not always
         what it is called in the output. A browser may need different
         code from node, and `<name>.web.js` is where that goes -- but
         most modules need none, so a plain `<name>.js` serves both.
         Whichever is found is copied out as `<name>.js`, which is what
         every generated import names. *)
      let browser =
        match Targets.family_of target with
        | Targets.Web | Targets.Iweb -> [ join directory (name ^ ".web.js") ]
        | _ -> []
      in
      let candidates = browser @ [ join directory file ] in
      (match List.find_opt Sys.file_exists candidates with
      | Some path -> path
      | None ->
          raise
            (Module_error
               ( info,
                 Printf.sprintf
                   "the external module '%s' has no implementation for target \
                    '%s': there is no file %s"
                   name target
                   (String.concat " and no "
                      (List.map
                         (fun path -> Printf.sprintf "'%s'" (Filename.basename path))
                         candidates)) )))

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
let rec visit ?(from = disk) name path info parsed order stack =
  if List.exists (fun (held, _) -> held = name) stack then
    (* Only a recursive call has a non-empty stack, and every one of
       those carries the import that asked for the module. *)
    raise (Module_error (Option.get info, cycle_message name stack))
  else if List.mem_assoc name parsed then (parsed, order)
  else
    let module_ = read_file ~from path info in
    if module_.is_external then check_declaration module_.stmts module_.path;
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
              let imported_path, _ =
                module_file ~from directory imported_name (Some import_info)
              in
              visit ~from imported_name imported_path (Some import_info) parsed
                order
                (stack @ [ (name, info) ])
          | _ -> (parsed, order))
        (parsed, order) module_.stmts
    in
    (parsed, order @ [ name ])

(** Every module the program in `path` needs, dependencies first and the
    program itself last: read, parsed, symbolized with one numbering
    across the whole program, and with every import resolved. Raises
    Module_error for a missing module or a cycle. string -> [t] *)
let load ?(from = disk) path =
  (* The program's own file is named on the command line rather than
     resolved, but a name with both files is still a name meaning two
     things, so it is refused here too. *)
  let path, _ =
    if is_external_path path then (path, true)
    else module_file ~from (dirname path) (module_name path) None
  in
  let parsed, order = visit ~from (module_name path) path None [] [] [] in
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
           (List.map (fun (other, _) -> other) units)
         (* An external module has no Pyking top level, so there is
            nothing to run before the program's own: what it exports is
            already there when the host loads its implementation. *)
         |> List.filter (fun (other : t) -> not other.is_external)
         |> List.map (fun (other : t) -> other.name)
       else []);
    sigmaps =
      List.map
        (fun (other, _) -> (other.name, Option.value other.sigmap ~default:[]))
        units;
    externals =
      List.filter_map
        (fun ((other : t), _) -> if other.is_external then Some other.name else None)
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

(** An external module's exported names and their types, which are the
    ones its declaration wrote: nothing was checked, because there is no
    body here to check. [stmt] -> [(string, typ)] *)
let external_sigmap stmts = external_signatures stmts

(** The signatures needed to check one module: its own imports', out of
    every module checked so far.
    t -> [(string, [(string, typ)])] -> [(string, [(string, typ)])] *)
let sigmaps_for module_ sigmaps =
  List.map (fun name -> (name, List.assoc name sigmaps)) module_.imports
