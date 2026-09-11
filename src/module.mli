(** The module system: one file is one module, and a program is the
    acyclic graph of the modules its main file reaches. Reads and parses
    every module a program needs, puts them in dependency order, and
    settles what each one exports and what each import means, before the
    type checker sees any of them. See docs/modules.md for the design
    and PYKING.md ("Modules") for the language.

    This is step 1 of the three the compiler takes over a program of
    several modules: `load` here, then the type checker once per module
    in the order `load` gives, and then `make_sigmap` on each result,
    which is what the next module is checked against.

    `load` is the whole of step 1: resolving a name to a file, refusing
    a cycle, and settling every import against what the imported module
    exports all happen inside it. What is public besides is what the
    stages after it need -- the driver, the backends that must name a
    module's file, and the two front ends (the REPL and the playground)
    that compile a file with no program around it and therefore call
    `check_publics` directly.

    An *external* module is declared in `sys.external.pyk` and
    implemented in the target's own language (`sys.py`, `sys.js`,
    `Sys.java`, ...). The declaration file holds signatures and nothing
    else; the implementation is read by the host toolchain, never by
    this compiler, and is copied beside the program's output so the
    host finds it where it expects to.

    Data structures:
      Module_error -- a module-level failure, with the source position.
      t -- one file: its name, path, tokens, statements, the modules it
        imports and the names it exports.
      context -- what a backend is told about the module it is compiling
        beyond its statements.
      sources -- where a program's files come from.
      lib_entry -- one directory of the library search path.

    Functions:
      load path -- every module the program at path needs, dependencies
        first, parsed, symbolized and with every import resolved.
      read_file path info -- one file, lexed and parsed, and nothing else.
      read_whole_file path -- the contents of a file.
      context units unit -- what a backend needs to know about one
        module of a program beyond its statements.
      reached_module external_fields module field -- the module a
        qualified name is reached through.
      make_sigmap stmts tmap -- a module's exported names and their types.
      external_sigmap declarations -- what a declaration half offers
        another module: its public names and their declared types.
      module_sigmap stmts declarations tmap -- what one module exports,
        both halves together.
      public_declarations declarations -- a declaration half's public
        names and their types.
      sigmaps_for module sigmaps -- the signatures one module needs.
      public_names stmts -- the names a module exports, unchecked.
      check_publics stmts -- the names a module exports, checked.
      external_signatures stmts -- an external module's declared names
        and their types.
      external_extension -- what an external module's declaration file
        is called.
      class_name stem -- the Java class (and file) name for a stem.
      implementation_name name target -- what an external module's
        implementation file is called on that target.
      implementation_path directory name target info -- that file,
        checked to exist.
      dirname path / join a b / absolute path -- the path helpers the
        compiler needs, in the shapes Python's os.path gives them. *)

open Syntax

(** A module-level failure -- a missing module, a cycle, a collision, a
    name that is not exported -- with the source position. *)
exception Module_error of Lexer.info * string

(** One module of a program: its file's stem, which is what another
    module imports it by; the file it was read from; its tokens (kept
    for `--tokens`, which prints every module of the program); its
    statements; the modules it imports, in source order and without
    repeats; the names it exports, and where each was made public; and
    each of those names with the type the checker gave it -- filled in
    after the module is checked, and None until then.

    A module is up to *two* files. `stmts` is its Pyking half and
    `declarations` the signatures of its external half, the names a
    target's own source provides; either may be empty, and they are kept
    apart because a pass over a module's statements must not see a
    signature it would move or drop. `is_external` says there is no
    Pyking half at all, which is what a backend asks when deciding
    whether a file is generated for this module. See docs/modules.md,
    "A module in two halves". *)
type t = {
  name : string;
  path : string;
  tokens : Lexer.token list;
  stmts : stmt list;
  declarations : stmt list;
  declaration_path : string option;
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
  external_fields : (string * string list) list;
  externals : string list;
}

(** Every file a module is written in, the declaration half first: a
    module is up to two files, and a caller that ships or copies a
    module's source has both to account for. t -> [string] *)
val source_paths : t -> string list

(** The module a qualified name is reached through. A module is up to
    two files, and a name the target's own source provides lives in the
    implementation rather than in the file this compiler generates -- so
    `foo.g1` reaches `foo_external` where `g1` is declared, and `foo`
    where it is written in Pyking. Every backend asks this rather than
    deciding for itself, which is what keeps one module one module from
    the import side.

    C needs no such distinction: a name there is `<module>_<field>`
    whichever half provides it, and both are linked into one program.
    [(string, [string])] -> string -> string -> string *)
val reached_module : (string * string list) list -> string -> string -> string

(** Where a program's files come from. The compiler reads a directory;
    the browser has none and is handed the sources instead, which is
    what lets `iweb` run a program of several modules in a page (see
    docs/target_js.md, "The interpreted target"). *)
type sources = { exists : string -> bool; contents : string -> string }

(** A directory libraries may be found in, beyond the importing file's
    own. Such a directory holds one folder per library, named after the
    module it holds, so `sys` is `<directory>/sys/sys.pyk`. `origin`
    says which level of the search the entry came from -- `-L`,
    `PYKING_LIB_PATH`, `built-in` -- which is what a failed import names
    it by.

    The entries are assembled by the caller and handed in: reading an
    environment variable, or asking where the executable is, is
    something only src/pyk.ml may do (see docs/build.md). *)
type lib_entry = { lib_directory : string; lib_origin : string }

(** An external module's declaration file: `sys.external.pyk` says what
    `sys` offers and at what type, and only the declaration is Pyking.
    string *)
val external_extension : string

(* --- paths --- *)

(** The directory part of a path, or "." where there is none.
    string -> string *)
val dirname : string -> string

(** A path with one name appended. string -> string -> string *)
val join : string -> string -> string

(** A path made absolute against the current directory.
    string -> string *)
val absolute : string -> string

(** The contents of a file. string -> string *)
val read_whole_file : string -> string

(* --- reading a program --- *)

(** Every module the program at `path` needs, dependencies first: each
    one lexed, parsed, symbolized with one numbering across the whole
    program, and with every import resolved against what the module it
    names exports. `from` says where the files come from, and defaults
    to the disk. `libs` is the library search path, tried in order
    after the importing file's own directory. Raises Module_error for a
    missing module -- naming every path it looked in -- and for a cycle,
    a name that is not exported, or a collision, and the front end's own
    errors for a module that does not lex or parse.
    sources -> [lib_entry] -> string -> [t] *)
val load : ?from:sources -> ?libs:lib_entry list -> string -> t list


(** One file, lexed and parsed, and nothing else: no import resolved and
    nothing checked, which is where `--no-typechecking` stops. `info` is
    the import to blame where the file was named by one.
    sources -> string -> info? -> t *)
val read_file : ?from:sources -> string -> Lexer.info option -> t

(* --- what a module exports --- *)

(** The names a module marks `public`, with the statement that binds
    each. Unchecked: a name exported twice is still in the list.
    [stmt] -> [(string, stmt)] *)
val public_names : stmt list -> (string * Syntax.stmt) list

(** The names a module exports and where each was made public. Raises
    Module_error for a name exported twice, an exported name bound twice
    in the module, or a `public var`. [stmt] -> [(string, info)] *)
val check_publics : stmt list -> (string * Lexer.info) list

(** A checked module's exported names and the type the checker gave
    each: all of it another module sees. Made from the program the
    checker saw, before the tail-call pass.
    [stmt] -> typ IntMap.t -> [(string, typ)] *)
val make_sigmap :
  stmt list -> typ IntMap.t -> (string * typ) list

(** The same for an external module, taken from what it declared: there
    is no body for the checker to work its exports out from.
    [stmt] -> [(string, typ)] *)
val external_sigmap : stmt list -> (string * typ) list

(** A declaration half's *public* names and their types: what another
    module sees of it. A private declaration is reachable from this
    module's own Pyking half and from nowhere else.
    [stmt] -> [(string, typ)] *)
val public_declarations : stmt list -> (string * typ) list

(** What one module exports, both halves together: the public names of
    its Pyking half at the types the checker worked out, and the public
    names of its declaration half at the types it wrote down.
    [stmt] -> [stmt] -> typ IntMap.t -> [(string, typ)] *)
val module_sigmap : stmt list -> stmt list -> typ IntMap.t -> (string * typ) list

(** An external module's declared names and their types.
    [stmt] -> [(string, typ)] *)
val external_signatures : stmt list -> (string * typ) list

(** The signatures one module needs: the entry for each module it
    imports, and nothing else. t -> [(string, 'a)] -> [(string, 'a)] *)
val sigmaps_for : t -> (string * 'a) list -> (string * 'a) list


(* --- what a backend is told --- *)

(** What a backend needs to know about the module it is compiling beyond
    its statements. `units` is every module of the program in dependency
    order, paired with whatever the caller carries alongside each.
    [(t, 'a)] -> t -> context *)
val context : (t * 'a) list -> t -> context

(** The Java class -- and so the file -- a source stem is compiled to,
    since Java requires the two to match. string -> string *)
val class_name : string -> string

(** What an external module's implementation file is called on a target,
    or None for a target that has no such file.
    string -> string -> string option *)
val implementation_name : string -> string -> string option

(** That file, checked to exist. Raises Module_error naming the file a
    target needs and has not got.
    string -> string -> string -> info -> string *)
val implementation_path : string -> string -> string -> Lexer.info -> string
