(** Packaging for the JavaScript backends: wraps target_js_core.ml's
    target-independent output into the files each of node/web/iweb
    delivers, and supplies the JavaScript side of the runtime interface
    (where print goes). See docs/target_js.md, "The three targets".

    `package_program` is the whole of it for a compiled program: it
    answers every file to write and the text `--stdout` prints, so which
    target writes which file, what the prelude holds, and how a module
    is imported are all private. The rest is what the driver has to know
    about the files themselves -- the manifest it must not overwrite,
    and the two pieces an `iweb` page is made of.

    Functions:
      package_program target units output_path stdout -- every file a
        whole program emits, and the text --stdout prints.
      reserved_names modules -- the JavaScript names a packaging writes
        around a program, which a Pyking binding may not take.
      module_manifest -- what the ES-module manifest is called.
      manifest_declares_module text -- whether an existing one already
        puts its directory in ES module mode.
      interpreter_module -- what the compiler-as-JavaScript is called
        beside an `iweb` page.
      interpreted_page main sources externals -- that page.
      format_js -- the shared value formatter every host needs. *)

(** Every JavaScript name a packaging writes around a program, which a
    Pyking binding must therefore not take. A module reached under its
    own name is bound by the `import` line, so each module's name is one
    of them. [string] -> [string] *)
val reserved_names : string list -> string list

(** The formatter every host needs, implementing builtin.ml's
    print rules. string *)
val format_js : string

(** Every file a whole program compiles to, as (path, contents), and the
    text `--stdout` prints -- the program's own module, since the
    modules it imports are files and `--stdout` writes none.
    string -> [(Module.t, [jsstmt], [(string, string)])] -> string option
    -> bool
    -> ([(string, string)], string) *)
val package_program :
  string ->
  (Module.t * Target_js_core.jsstmt list * (string * string) list) list ->
  string option ->
  bool ->
  (string * string) list * string

(** What the manifest that puts a directory in ES module mode is called.
    string *)
val module_manifest : string

(** Whether an existing package.json already puts its directory in ES
    module mode. Looks for the one key rather than parsing JSON: nothing
    here has a JSON reader, and the answer only decides whether the
    driver prints a note. string -> bool *)
val manifest_declares_module : string -> bool

(** What the compiler-as-JavaScript is called beside an `iweb` page.
    string *)
val interpreter_module : string

(** The page an `iweb` program is opened with: the interpreter, the
    program's own sources, and the call that runs them. The sources are
    inlined rather than fetched so the page needs no second round trip
    and no fetch permissions -- it is still served, because a module
    script is. `release` has the page run the program with every call to
    `debug` removed, which is what --release means for a program that is
    interpreted rather than compiled.
    bool -> string -> [string] -> [(string, string)] -> string *)
val interpreted_page :
  ?release:bool -> string -> string list -> (string * string) list -> string
