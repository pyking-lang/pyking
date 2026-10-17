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

    An *external* module is declared in `sys_external.pyk` and
    implemented in the target's own language (`sys.py`, `sys.js`,
    `Sys.java`, ...). The declaration file holds signatures and nothing
    else; the implementation is read by the host toolchain, never by
    this compiler, and is copied beside the program's output so the
    host finds it where it expects to.

    Functions:
      load path -- every module the program at path needs, dependencies
        first, parsed, symbolized and with every import resolved.
      load_imports loaded start signatures directory entry -- the modules
        an entry at the prompt newly reaches, prepared the same way.
      read_file path info -- one file, lexed and parsed, and nothing else.
      context units unit -- what a backend needs to know about one
        module of a program beyond its statements.
      make_sigmap stmts tmap -- a module's exported names and their types.
      public_names stmts -- the names a module exports, unchecked.
      check_publics stmts -- the names a module exports, checked.
      datatype_names stmt -- the names a datatype declares.
      module_sigmap name stmts declarations tmap -- what one module
        exports, its own datatypes named as another module names them.
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
      found_implementation directory name target info -- the same for a
        module found the way an import of it would be.
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

(* An external module's declaration file. `sys_external.pyk` says what
   `sys` offers and at what type; `sys.py`, `sys.js`, `Sys.java` and
   the rest implement it, one per target. Only the declaration is
   Pyking, and only the declaration is read here. *)
let external_marker = "_external"

let external_extension = external_marker ^ extension

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
  declarations : stmt list;
  declaration_path : string option;
  imports : string list;
  publics : (string * Lexer.info) list;
  sigmap : (string * typ * bool) list option;
  is_external : bool;
}

(** Every file a module is written in, the declaration half first: a
    module is up to two files, and a caller that ships or copies a
    module's source has both to account for.
    t -> [string] *)
let source_paths unit =
  (match unit.declaration_path with Some path -> [ path ] | None -> [])
  @ if unit.stmts = [] && unit.declarations <> [] then [] else [ unit.path ]

(** The module a qualified name is reached through. A module is up to
    two files, and a name the target's own source provides lives in the
    implementation rather than in the file this compiler generates -- so
    `foo.g1` reaches `foo_external` where `g1` is declared, and `foo`
    where it is written in Pyking. Every backend asks this rather than
    deciding for itself, which is what keeps one module one module from
    the import side (docs/modules.md, "A module in two halves").

    C is the one target that needs no such distinction: a name there is
    `<module>_<field>` whichever half provides it, and both halves are
    linked into one program.
    [(string, [string])] -> string -> string -> string *)
let reached_module external_fields module_ field =
  match List.assoc_opt module_ external_fields with
  | Some fields when List.mem field fields -> module_ ^ "_external"
  | _ -> module_

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
    this compiler wrote; and every name the module's own declaration half
    declares, private ones included, with its type. *)
type context = {
  context_name : string;
  main : bool;
  separate : bool;
  starts : string list;
  sigmaps : (string * (string * typ * bool) list) list;
  external_fields : (string * string list) list;
  externals : string list;
  own_declared : (string * typ) list;
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
  (* `sys_external.pyk` is module `sys`: the marker is part of the file
     name, not of the name another module imports it by. *)
  if Filename.check_suffix path external_extension then
    Filename.chop_suffix stem external_marker
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

(** A directory libraries may be found in, beyond the importing file's
    own. Such a directory holds one folder per library, named after the
    module it holds, so `sys` is `<directory>/sys/sys.pyk`. `origin`
    says which level of the search the entry came from, which is what a
    failed import names it by. *)
type lib_entry = { lib_directory : string; lib_origin : string }

(** The folder one library occupies in a search-path directory: one per
    library, named after the module. string -> string -> string *)
let library_directory directory name = join directory name

(** Where a module's files are. At least one is Some: a module written
    in Pyking has `pyking`, one declared for a target has `declared`,
    and one written in Pyking against a target's own source has both --
    they are one module, not two. *)
type found = { pyking : string option; declared : string option }

(** Both files a module name could be in one directory, each with
    whether it is there. sources -> string -> string ->
    (string, bool, string, bool) *)
let candidates from directory name =
  let declared = external_module_path directory name in
  let plain = module_path directory name in
  (declared, from.exists declared, plain, from.exists plain)

(** The refusal for a name no level of the search found, naming every
    path tried in the order it was tried and where each came from. A
    search path that will not say where it looked is the hardest kind to
    fix. string -> [(string, string)] -> string *)
let not_found name tried =
  Printf.sprintf
    "cannot read module '%s': looked for %s. A module is beside the file \
     that imports it, or in a library folder on the search path (-L, \
     PYKING_LIB_PATH)"
    name
    (String.concat ", "
       (List.map (fun (path, origin) -> Printf.sprintf "'%s' (%s)" path origin) tried))

(** The files one module name means. A module is written in Pyking, or
    declared for a target, or **both**: `foo.pyk` and `foo_external.pyk`
    are one module `foo`, the second saying what the target's own source
    provides and the first written in Pyking against it (see
    docs/modules.md, "A module in two halves").

    The importing file's own directory is tried first, flat, then each
    library directory in `libs` in order, and the first level holding
    *either* file answers with whatever it holds -- so the two halves
    always come from one place and a library cannot be half shadowed.
    Raises Module_error naming every path tried where an import asked
    for a module nothing has. The program's own file is not resolved
    this way -- it was named on the command line -- so with no import to
    blame the plain path is answered and reading it reports the failure.
    sources -> [lib_entry] -> string -> string -> info option -> found *)
let module_file ?(from = disk) ?(libs = []) directory name info =
  let levels =
    (directory, "local")
    :: List.map
         (fun entry ->
           (library_directory entry.lib_directory name, entry.lib_origin))
         libs
  in
  let rec search tried levels =
    match levels with
    | [] -> (tried, None)
    | (where, origin) :: rest -> (
        let declared, has_declared, plain, has_plain = candidates from where name in
        match (has_declared, has_plain) with
        | false, false ->
            search (tried @ [ (declared, origin); (plain, origin) ]) rest
        | _ ->
            ( tried,
              Some
                {
                  pyking = (if has_plain then Some plain else None);
                  declared = (if has_declared then Some declared else None);
                } ))
  in
  match search [] levels with
  | _, Some found -> found
  | tried, None -> (
      match info with
      | None -> { pyking = Some (module_path directory name); declared = None }
      | Some i -> raise (Module_error (i, not_found name tried)))

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
    declarations = [];
    declaration_path = None;
    imports = [];
    publics = [];
    sigmap = None;
    is_external = is_external_path path;
  }

(** One module from the files it is in: the Pyking half in `stmts`, the
    declaration half in `declarations`, and `is_external` saying there
    is no Pyking half at all. The two are kept apart rather than joined
    into one list because a pass over a module's statements must not see
    a signature it would move or drop -- `Analyses.apply_signatures`
    deletes every signature it does not fold onto a definition, which
    would empty a declaration.
    sources -> found -> info option -> t *)
let read_module ?(from = disk) found info =
  let half path = read_file ~from path info in
  match (found.pyking, found.declared) with
  | None, None -> invalid_arg "read_module: a module with no files"
  | Some path, None -> half path
  | None, Some path ->
      let unit = half path in
      {
        unit with
        stmts = [];
        declarations = unit.stmts;
        declaration_path = Some path;
        is_external = true;
      }
  | Some path, Some declared ->
      let unit = half path in
      let other = half declared in
      (* The Pyking half is the module's own file: its path is what an
         error about the module names, and its tokens are what
         `--tokens` prints. *)
      {
        unit with
        declarations = other.stmts;
        declaration_path = Some declared;
        is_external = false;
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

(** The names a datatype declares: its own, and each constructor's that
    is not the same. A datatype and its one constructor often share a
    name, and it is one name of the module. stmt -> [string] *)
let datatype_names statement =
  match statement with
  | SDatatype (_, name, _, constructors, _, _) ->
      name
      :: List.filter_map
           (fun (Constructor (_, n, _, _)) -> if n = name then None else Some n)
           constructors
  | _ -> []

(** Every name the source marked `public`, in order, paired with the
    statement that marked it. A `def` may be marked on its definition or
    on its signature line, so a name can appear twice.
    [stmt] -> [(string, stmt)] *)
let public_names stmts =
  List.filter_map
    (fun statement ->
      match statement with
      | SFunctionDef (_, name, _, _, _, _, true, _, _)
      | SFunctionSig (_, name, _, _, true) ->
          Some [ (name, statement) ]
      (* The parser refuses `public` on a binding that takes a tuple
         apart, so a public target is always one name. *)
      | SLet (_, TargetName (_, name, _), _, _, _, true, _)
      | SLetStmt (_, TargetName (_, name, _), _, _, _, true) ->
          Some [ (name, statement) ]
      | SDatatype (_, _, _, _, _, true) ->
          Some (List.map (fun n -> (n, statement)) (datatype_names statement))
      | _ -> None)
    stmts
  |> List.concat

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
      | SFunctionDef (_, name, _, _, _, _, _, _, _) | SVar (_, name, _, _) ->
          [ (name, statement) ]
      | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
          List.map (fun name -> (name, statement)) (target_names target)
      | SDatatype _ ->
          List.map (fun name -> (name, statement)) (datatype_names statement)
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
    but as a parameter that is a callback -- a function of boundary
    types answering () -- since a host can call a Pyking function back
    and has no convention for anything more (see docs/modules.md, "What
    may cross the boundary").
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
    | TFunction (_, params, result, _, _, _, _) ->
        if nested then refuse "a function type";
        List.iter (walk true) params;
        walk true result
    | TList (_, element, _) -> walk nested element
    | TTuple (_, elements, _) -> List.iter (walk nested) elements
    | _ -> ()
  in
  let callback type_ =
    match type_ with
    | TFunction (_, params, result, _, _, _, _) ->
        (match result with
        | TTuple (_, [], _) -> ()
        | _ -> refuse "a callback answering a value");
        List.iter (walk true) params
    | type_ -> walk true type_
  in
  match type_ with
  | TFunction (_, params, result, _, _, _, _) ->
      List.iter callback params;
      walk true result
  | type_ -> walk false type_

(** Refuses anything but a signature in a declaration file: a body there
    would have to be compiled into the very file the target's own
    implementation already occupies.

    A signature may be private. It is then reachable from the module's
    own Pyking half and from nowhere else -- which is how a library
    keeps a host function it needs but does not offer (see
    docs/modules.md, "A module in two halves"). The boundary rule
    applies to a private signature exactly as to a public one, because
    what crosses the boundary is the *call*, and the Pyking half makes
    it. [stmt] -> string -> () *)
let check_declaration stmts path =
  ignore path;
  List.iter
    (fun statement ->
      match statement with
      | SFunctionSig (info, name, type_, _, _) ->
          (* A declaration is not rewritten by any pass, so a qualified
             name here would reach the implementation under a spelling
             no target has (docs/overloading.md). *)
          if Names.is_qualified name then
            raise
              (Module_error
                 ( info,
                   Printf.sprintf
                     "'%s' cannot be declared here: a '::' name is \
                      resolved and renamed by the compiler, and what a \
                      declaration names is provided by the target's own \
                      source under the name written"
                     name ));
          check_boundary_type type_ name info
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
  let name = name ^ "_external" in
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
         what it is called in the output. JavaScript runs in two
         environments, so a module has one source for each:
         `<name>_external_node.js` for node and
         `<name>_external_browser.js` for web and iweb -- except that
         iweb, where the interpreter runs the program, takes
         `<name>_external_interpreter.js` where there is one. Each is
         copied out as `<name>_external.js`, which is what every
         generated import names. *)
      let source =
        match Targets.family_of target with
        | Targets.Node -> join directory (name ^ "_external_node.js")
        | Targets.Web -> join directory (name ^ "_external_browser.js")
        | Targets.Iweb ->
            let interpreted = join directory (name ^ "_external_interpreter.js") in
            if Sys.file_exists interpreted then interpreted
            else join directory (name ^ "_external_browser.js")
        | _ -> join directory file
      in
      if Sys.file_exists source then source
      else
        raise
          (Module_error
             ( info,
               Printf.sprintf
                 "the external module '%s' has no implementation for target \
                  '%s': there is no file '%s'"
                 name target (Filename.basename source) ))

(** The implementation a module has for a target, found the way an
    import of it from `directory` would find the module: what a page
    ships for a library the program never imports. Raises Module_error
    where the module or its implementation is missing, or where the
    module has no external half. sources -> [lib_entry] -> string ->
    string -> string -> info -> string *)
let found_implementation ?(from = disk) ?(libs = []) directory name target info =
  match (module_file ~from ~libs directory name (Some info)).declared with
  | Some declared -> implementation_path (dirname declared) name target info
  | None ->
      raise
        (Module_error
           ( info,
             Printf.sprintf
               "target '%s' needs the external module '%s', and the '%s' found \
                has no external half"
               target name name ))

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
      [] Builtin.names
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

(** Refuses an import naming a module's external half, which is not a
    module of its own: `foo_external.pyk` is imported as `foo`.
    info -> string -> 'a *)
let refuse_external_half info name =
  raise
    (Module_error
       ( info,
         Printf.sprintf
           "cannot import '%s': a name ending in '%s' is the external half of \
            a module, and is imported by the module's own name '%s'"
           name external_marker
           (Filename.chop_suffix name external_marker) ))

(** Depth-first over the import graph, appending each module to `order`
    after everything it imports. `stack` is the path of imports being
    followed, which is what a cycle is reported from.
    string -> string -> info option -> [(string, t)] -> [string] ->
    [(string, info option)] -> ([(string, t)], [string]) *)
let rec visit ?(from = disk) ?(libs = []) name found info parsed order stack =
  if List.exists (fun (held, _) -> held = name) stack then
    (* Only a recursive call has a non-empty stack, and every one of
       those carries the import that asked for the module. *)
    raise (Module_error (Option.get info, cycle_message name stack))
  else if List.mem_assoc name parsed then (parsed, order)
  else
    let module_ = read_module ~from found info in
    if module_.declarations <> [] then
      check_declaration module_.declarations
        (Option.value found.declared ~default:module_.path);
    let module_ =
      {
        module_ with
        imports = imported_modules module_.stmts;
        (* Over both halves: `public` says what the *module* offers, and
           a module is its two files together. *)
        publics = check_publics (module_.stmts @ module_.declarations);
      }
    in
    let parsed = parsed @ [ (name, module_) ] in
    (* The importing file's own directory, as it was named rather than
       made absolute: a module is beside the file that imports it (see
       docs/modules.md, "Finding a module"), and an error naming it
       should read the way the command that found it did. *)
    let directory = dirname module_.path in
    let parsed, order =
      List.fold_left
        (fun (parsed, order) statement ->
          match statement with
          | SImport (import_info, imported_name, _, _, _, _)
            when Filename.check_suffix imported_name external_marker ->
              refuse_external_half import_info imported_name
          | SImport (import_info, imported_name, _, _, _, _) ->
              let imported =
                module_file ~from ~libs directory imported_name
                  (Some import_info)
              in
              visit ~from ~libs imported_name imported (Some import_info) parsed
                order
                (stack @ [ (name, info) ])
          | _ -> (parsed, order))
        (parsed, order) module_.stmts
    in
    (parsed, order @ [ name ])

(** The modules `order` names, taken from `parsed` and made ready in
    that order: the sugar removed, symbolized past `highest`, what each
    exports settled again, and every import resolved against the modules
    before it. Answers the highest symbol handed out, the sugar's
    signatures, every module ready so far, and the ones made ready here.
    [(string, t)] -> [string] -> int -> signatures -> [(string, t)] ->
    (int, signatures, [(string, t)], [t]) *)
let prepare parsed order highest signatures loaded =
  List.fold_left
    (fun (highest, signatures, loaded, modules) name ->
      let module_ = List.assoc name parsed in
      (* The sugar goes first, so what every later stage sees is
         ordinary Pyking; dependency order is what lets a call reach an
         imported definition's parameters. *)
      let stmts, signatures =
        if module_.is_external then
          (module_.stmts, Desugar_args.external_module signatures name)
        else Desugar_args.desugar signatures name module_.stmts
      in
      let module_ =
        {
          module_ with
          stmts = Analyses.symbolize ~start:highest stmts;
          (* The defs holding a public function's defaults are public
             too, so what the module offers is settled again here. *)
          publics = check_publics (stmts @ module_.declarations);
        }
      in
      let highest = max highest (Analyses.highest_sym module_.stmts) in
      let module_ = resolve_imports module_ loaded in
      (highest, signatures, loaded @ [ (name, module_) ], modules @ [ module_ ]))
    (highest, signatures, loaded, []) order

(** `parsed` with tinyweb's splash called at the end of the main module
    `main` where the program can play a sound (splash.ml).
    string -> [(string, t)] -> [(string, t)] *)
let with_splash main parsed =
  let all = List.map (fun (name, module_ : string * t) -> (name, module_.stmts)) parsed in
  List.map
    (fun (name, module_) ->
      if name <> main then (name, module_)
      else
        let stmts = Splash.program name module_.path all module_.stmts in
        (name, { module_ with stmts; imports = imported_modules stmts }))
    parsed

(** Every module the program in `path` needs, dependencies first and the
    program itself last: read, parsed, symbolized with one numbering
    across the whole program, and with every import resolved. Raises
    Module_error for a missing module or a cycle. Unless `splash` is
    false, the main module calls tinyweb's splash at its end where the
    program can play a sound. bool? -> string -> [t] *)
let load ?(from = disk) ?(libs = []) ?(splash = true) path =
  (* The program's own file is named on the command line rather than
     resolved, but a name with both files is still a name meaning two
     things, so it is refused here too. *)
  (* The program's own file is named on the command line, so it is taken
     as given -- but a `foo.pyk` named there still has its `foo_external.pyk`
     half beside it, which is what makes the two one module however the
     module was reached. *)
  let found =
    if is_external_path path then { pyking = None; declared = Some path }
    else module_file ~from ~libs (dirname path) (module_name path) None
  in
  let parsed, order =
    visit ~from ~libs (module_name path) found None [] [] []
  in
  let parsed = if splash then with_splash (module_name path) parsed else parsed in
  let _, _, _, modules =
    prepare parsed order 0 Desugar_args.no_signatures []
  in
  modules

(** The modules an entry typed at the prompt reaches through its imports
    and the session has not loaded yet, prepared as `load` prepares a
    program's -- dependencies first, the sugar removed, symbolized past
    `start`, every import resolved -- and the entry with its own imports
    resolved against them. `loaded` is every module the session has, so
    none is read twice; `signatures` is what the sugar knows so far, and
    comes back extended, with the highest symbol handed out. A module is
    looked for beside `directory` and then on the search path.
    sources -> [lib_entry] -> [(string, t)] -> int -> signatures ->
    string -> [stmt] -> ([t], [stmt], signatures, int) *)
let load_imports ?(from = disk) ?(libs = []) ~loaded ~start ~signatures directory
    entry =
  let prompt = { name = "<repl>"; path = "<repl>"; tokens = []; stmts = entry;
                 declarations = []; declaration_path = None; imports = [];
                 publics = []; sigmap = None; is_external = false } in
  let parsed, order =
    List.fold_left
      (fun (parsed, order) statement ->
        match statement with
        | SImport (info, name, _, _, _, _) when not (List.mem_assoc name parsed) ->
            if Filename.check_suffix name external_marker then
              refuse_external_half info name;
            let found = module_file ~from ~libs directory name (Some info) in
            visit ~from ~libs name found (Some info) parsed order
              [ (prompt.name, None) ]
        | _ -> (parsed, order))
      (loaded, []) entry
  in
  let highest, signatures, loaded, modules =
    prepare parsed order start signatures loaded
  in
  let resolved = resolve_imports prompt loaded in
  (modules, resolved.stmts, signatures, highest)

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
    (* A backend sees what `elaborate.ml` left: every name plain, and
       every implicit parameter an ordinary one. The sigmap the *checker*
       is given keeps the source's own spelling, since that is what the
       file importing the module writes (docs/overloading.md). *)
    sigmaps =
      List.map
        (fun (other, _) ->
          ( other.name,
            List.map
              (fun (name, type_, implicit) ->
                ( Names.renamed name,
                  Typesystem.without_implicits type_,
                  implicit ))
              (Option.value other.sigmap ~default:[]) ))
        units;
    (* Which of each module's names the target's own source provides,
       rather than the file this compiler generates for it. A backend
       rewrites a qualified name to reach the implementation where the
       name is in this list -- see docs/modules.md, "A module in two
       halves". *)
    external_fields =
      List.map
        (fun ((other : t), _) ->
          ( other.name,
            List.map fst (external_signatures other.declarations) ))
        units;
    externals =
      List.filter_map
        (fun ((other : t), _) -> if other.is_external then Some other.name else None)
        units;
    own_declared = external_signatures unit.declarations;
  }

(** A module's exported names and the types the checker worked out for
    them -- what another module is checked against, and all of this
    module that another one can see. Every exported name has one:
    `Typesystem.check_exports` refuses a module that exports a `def` it
    worked out no type for.
    Each carries whether it was written `implicit`, since a public
    implicit is imported unqualified and automatically (PYKING.md,
    "Modules").
    [stmt] -> typ IntMap.t -> [(string, typ, bool)] *)
let make_sigmap stmts tmap =
  let exported = check_publics stmts in
  List.filter_map
    (fun (name, statement) ->
      if List.mem_assoc name exported then
        Some
          ( name,
            (* A datatype's name and its constructors' are all the
               datatype, recorded under the declaration's symbol. *)
            IntMap.find (stmt_sym statement) tmap,
            match statement with
            | SFunctionDef (_, _, _, _, _, _, _, _, implicit) -> implicit
            | SLet (_, _, _, _, _, _, implicit) -> implicit
            | _ -> false )
      else None)
    (bound_at_top_level stmts)

(** A declaration half's *public* names and their types: what another
    module sees of it. A private declaration is reachable from this
    module's own Pyking half and from nowhere else.
    [stmt] -> [(string, typ, bool)] *)
let public_declarations declarations =
  List.filter_map
    (function
      | SFunctionSig (_, name, type_, _, true) -> Some (name, type_, false)
      | _ -> None)
    declarations

let external_sigmap declarations = public_declarations declarations

(** What one module exports, both halves together: the public names of
    its Pyking half at the types the checker worked out, and the public
    names of its declaration half at the types it wrote down. Its own
    datatypes are named `name.Type`, as every other module names them.
    string -> [stmt] -> [stmt] -> typ IntMap.t -> [(string, typ, bool)] *)
let rec module_sigmap name stmts declarations tmap =
  List.map
    (fun (field, type_, implicit) -> (field, qualified name type_, implicit))
    (make_sigmap stmts tmap)
  @ public_declarations declarations

(** A type as another module sees it: every datatype of module `name`
    named `name.Type`, since in the module's own types it is bare.
    string -> typ -> typ *)
and qualified name type_ =
  let rec go t =
    match t with
    | TCon (i, n, args, s) ->
        let n = if String.contains n '.' then n else name ^ "." ^ n in
        TCon (i, n, List.map go args, s)
    | TData (i, Datatype (n, params, constructors), s) ->
        let n = if String.contains n '.' then n else name ^ "." ^ n in
        TData
          ( i,
            Datatype
              ( n,
                params,
                List.map
                  (fun (c, fields) ->
                    (c, List.map (fun (label, t) -> (label, go t)) fields))
                  constructors ),
            s )
    | TList (i, e, s) -> TList (i, go e, s)
    | TTuple (i, es, s) -> TTuple (i, List.map go es, s)
    | TFunction (i, ps, r, s, tm, d, ips) ->
        TFunction
          ( i,
            List.map go ps,
            go r,
            s,
            tm,
            d,
            List.map (fun (IParam (n, t)) -> IParam (n, go t)) ips )
    | TForall (i, vs, b, s) -> TForall (i, vs, go b, s)
    | TInt _ | TFloat _ | TString _ | TBool _ | TUnknown _ | TBuiltin _
    | TVar _ ->
        t
  in
  go type_

(** The signatures needed to check one module: its own imports', out of
    every module checked so far.
    t -> [(string, [(string, typ, bool)])]
    -> [(string, [(string, typ, bool)])] *)
let sigmaps_for module_ sigmaps =
  List.map (fun name -> (name, List.assoc name sigmaps)) module_.imports
