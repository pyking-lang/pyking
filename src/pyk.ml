(** The driver: what `pyk` on the command line runs. Parses argv,
    sequences the front-end stages, and dispatches to one of its
    commands (`pyk <file>`, `repl`, `compile`, `notebook`,
    `playground`, `example`, `highlight`, ...). Every program is
    type-checked, so a program that does not check is refused whatever
    was asked for. A program of several modules runs the middle of that
    sequence once per module, in the order module.ml puts them in. Each
    backend owns its own translation, packaging and file naming.
    See docs/architecture.md ("Command
    line"), docs/modules.md and docs/source.md ("pyk.ml").

    Data structures:
      options -- argv parsed into one value: command, filename, flags.

    Functions:
      main argv -- argv in, exit status out.
      parse_args argv -- argv, as an options.
      front_end options -- loads the program's modules, then checks and
        analyses each of them.
      format_error error -- formats any front-end error as one line.
      command_interpret checked arguments -- `pyk <file>`.
      command_compile checked options -- `pyk compile`.
      command_web tool options -- `pyk notebook` and `pyk playground`.
      command_example options -- `pyk example`.
      command_highlight argv -- `pyk highlight`, which parses its own
        options.
      wrap text -- reflows text to the driver's line width. *)

(* The compiling targets, in the order the usage message lists them. The
   interpreter is *not* one of them: it produces no source file, so it
   is what `pyk <file>` does rather than something `--target` selects.
   The test harness calls it a target because there it is one -- a way
   of running a program and comparing its output.

   `pyking` is the odd one: it compiles Pyking to Pyking, which is to
   say it prints the program the front end worked out -- with the types
   the checker inferred, and the loops the tail-call pass built. *)
let pyking_target = Execution.pyking_target

(* Every target, and every unversioned alias for one, comes from
   src/targets.ml -- nothing here names a target. Adding one there
   reaches the usage message, `--target`'s check and the default output
   name at once. *)
let targets = Targets.all

(* The targets whose host language eliminates tail calls itself, and
   which are therefore compiled from the program as written rather than
   from the one opt_tailcall.ml rewrote -- there the rewrite would only
   be undone (see docs/optimization.md, "The target that needs none of
   this"). *)
let native_tail_calls = Targets.members Targets.Ocaml

(* What the primary output file is called when `--output` doesn't say. *)
let extensions = List.map (fun target -> (target, Targets.extension target)) targets

(* Every message this module prints is laid out for a terminal this
   wide. 70 rather than the usual 80 so that output still reads well
   once a `$ ` prompt, a quoting mail client, or a docs code block has
   eaten a few columns. *)
let width = 70

(** Reflows text to `width`, continuation lines indented; never breaks a
    word. string -> string -> string *)
let wrap ?(indent = "  ") text =
  let words = List.filter (fun w -> w <> "") (String.split_on_char ' ' text) in
  let rec fill words line lines =
    match words with
    | [] -> List.rev (if line = "" then lines else line :: lines)
    | w :: rest ->
        if line = "" then
          let start = if lines = [] then "" else indent in
          fill rest (start ^ w) lines
        else
          let candidate = line ^ " " ^ w in
          if String.length candidate <= width then fill rest candidate lines
          else fill words "" (line :: lines)
  in
  String.concat "\n" (fill words "" [])

(* --- paths ---
   Python's os.path, in the few shapes this driver needs. `dirname` is
   "" rather than "." for a bare file name, which is what keeps a
   generated path reading the way the command that produced it did. *)

let dirname = Module.dirname
let absolute = Module.absolute
let join = Module.join
let basename path = Filename.basename path
let stem path = Filename.remove_extension (Filename.basename path)

(** The unversioned aliases, as one line for --help: each family's name
    and the version it currently means. () -> string *)
let alias_line () =
  String.concat ", "
    (List.map (fun (alias, target) -> alias ^ " = " ^ target) Targets.aliases)

(** What a version counts in each family, for --help: one row per
    family, naming its targets. () -> string *)
let version_table () =
  let counts =
    [
      (Targets.Python, "the Python release: 3.12, 3.14");
      (Targets.Node, "the node release; node22 writes ES2020, node ES2024");
      (Targets.Web, "the ECMAScript edition the page's JavaScript is written in");
      (Targets.Iweb, "the same, for the page running the interpreter");
      (Targets.C, "the C standard");
      (Targets.Java, "the Java release, as `javac --release` takes it");
      (Targets.Ocaml, "the OCaml release");
    ]
  in
  let rows =
    List.map (fun (f, says) -> (String.concat ", " (Targets.members f), says)) counts
  in
  let column = List.fold_left (fun w (n, _) -> max w (String.length n)) 0 rows + 4 in
  (* Each description filled to what is left of the line, its
     continuation lines under its first word. *)
  let fill text =
    List.fold_left
      (fun lines word ->
        match lines with
        | last :: before when String.length last + 1 + String.length word <= width - column ->
            (last ^ " " ^ word) :: before
        | _ -> word :: lines)
      [] (String.split_on_char ' ' text)
    |> List.rev
  in
  String.concat "\n"
    (List.concat_map
       (fun (names, says) ->
         List.mapi
           (fun i text ->
             let left = if i = 0 then "  " ^ names else "" in
             left ^ String.make (column - String.length left) ' ' ^ text)
           (fill says))
       rows)

(** The commands `--run` uses, one row per family. () -> string *)
let run_table () =
  let rows =
    [
      (Targets.Python, [ "python3 prog.py" ]);
      (Targets.Node, [ "node prog.js" ]);
      (Targets.Web, [ "pyk serve prog.html (a page must be"; "served; the link printed opens the page)" ]);
      (Targets.Iweb, [ "the same" ]);
      (Targets.C, [ "cc -std=<standard> -o prog prog.c, then prog" ]);
      (Targets.Java, [ "javac --release <version> prog.java, then"; "java prog" ]);
      (Targets.Ocaml, [ "ocamlopt -I +unix unix.cmxa -o prog prog.ml,"; "then prog" ]);
      (Targets.Pyking, [ "pyk prog.pyk" ]);
    ]
  in
  let rows =
    List.map (fun (f, says) -> (String.concat ", " (Targets.members f), says)) rows
  in
  let column = List.fold_left (fun w (n, _) -> max w (String.length n)) 0 rows + 2 in
  String.concat "\n"
    (List.concat_map
       (fun (names, says) ->
         List.mapi
           (fun i text ->
             let left = if i = 0 then names else "" in
             Printf.sprintf "  %s%s%s" left (String.make (column - String.length left) ' ') text)
           says)
       rows)

(** The Targets: block for --help: one row per group of targets sharing
    an output extension. () -> string *)
let target_table () =
  let groups =
    List.fold_left
      (fun groups name ->
        let extension = List.assoc name extensions in
        match List.assoc_opt extension groups with
        | Some _ ->
            List.map
              (fun (e, ns) -> if e = extension then (e, ns @ [ name ]) else (e, ns))
              groups
        | None -> groups @ [ (extension, [ name ]) ])
      [] targets
  in
  let rows =
    List.map (fun (extension, names) -> (String.concat ", " names, extension)) groups
  in
  let column =
    List.fold_left (fun width (names, _) -> max width (String.length names)) 0 rows
    + 3
  in
  String.concat "\n"
    (List.map
       (fun (names, extension) ->
         Printf.sprintf "  %s%s" names
           (String.make (column - String.length names) ' ' ^ extension))
       rows)

(* The help comes in two lengths, sharing the part nobody can do
   without. What someone who typed `pyk` by itself needs is the shape of
   the command and the flags; what someone who asked for `--help` wants
   is everything, including the target table and the paragraphs
   explaining what the commands actually do. *)

let synopsis =
  "Usage: pyk [options] <filename> [-- args]   run it with the interpreter\n\
  \       pyk repl                             start the REPL\n\
  \       pyk compile [options] <filename>     compile it (alias: pyk c)\n\
  \       pyk notebook [--port N] [--mode M] <file.md>\n\
  \                                            open a notebook in the browser\n\
  \       pyk playground [--port N]            open the playground\n\
  \       pyk pykhelp [--port N]               open the help in the browser\n\
  \       pyk serve [--port N] [<dir>|<file>]  serve a directory's files\n\
  \       pyk lsp [--stdio] [--log FILE]       the language server, for editors\n\
  \       pyk dap [--stdio] [--log FILE]       the debug adapter, for editors\n\
  \       pyk example [<name>]                 list the examples, or save one\n\
  \       pyk highlight <file> [options]       colour code for slides: HTML, RTF\n\
  \                                            or text\n\
  \n\
   Options:\n\
  \  -t, --target <name>   compile for <name> (default: python); with\n\
  \                        `pyk <filename>`, compile for it and run it\n\
  \  -o, --output <file>   name the executable (default: the source's\n\
  \                        name); what is generated goes in build/ beside\n\
  \                        it\n\
  \  -L, --lib-path <dir>  a directory of libraries to import from; repeat\n\
  \                        for several\n\
  \  --stdout              print the generated code instead of writing it\n\
  \  --run                 build and run what was compiled, with the\n\
  \                        target's own commands\n\
  \  --release             compile in release mode: every call to debug()\n\
  \                        is removed, and print() is kept\n\
  \  -W<name>, -Wno-<name> turn one warning on or off; -Wall turns every\n\
  \                        one on and -w every one off (`pyk --help` lists\n\
  \                        them)\n\
  \  -Werror[=<name>]      make every warning an error, or just that one;\n\
  \                        -Wno-error[=<name>] undoes it\n\
  \  --use <feature>       with the REPL, turn a feature on from the start,\n\
  \                        as a 'use' line would: mutation or objects\n\
  \  --tinyweb-log         with the interpreter or the REPL, print what a\n\
  \                        program sends its tinyweb page, and what the page\n\
  \                        answers, on stderr as the page runs\n\
  \  --port <n>            serve the notebook, the playground, the help\n\
  \                        or a directory on port <n>\n\
  \  --mode <mode>         the notebook for a student (the default) or a\n\
  \                        teacher, or test: check it instead of serving it\n\
  \  --                    everything after it is the program's own\n\
  \                        arguments, read by sys.args()\n\
  \  --version             print the version and exit\n\
  \  --help                this, in full: the rest of the flags, what each\n\
  \                        command does, and what each target writes"

(* The flags someone reaches for once they know the shape of the tool:
   two that show a stage's own output, and two that turn off a
   transformation nobody has to know about to use the compiler. *)
let more_options =
  "More options:\n\
  \  --to-json             with `notebook`, write the notebook's Markdown\n\
  \                        as JSON: notebook.md -> notebook.json\n\
  \  --to-markdown         with `notebook`, write a notebook's JSON as\n\
  \                        the Markdown it stands for: notebook.json ->\n\
  \                        notebook.md\n\
  \  --json-schema         with `notebook` and no file, write the JSON\n\
  \                        Schema every notebook's JSON follows:\n\
  \                        notebook.schema.json. With these three, -o names\n\
  \                        the file written, and -o - prints it; a file of\n\
  \                        the default name is not written over\n\
  \  --symbols             with -t pyking, also print each node's symbol\n\
  \  --tokens              print the token stream first\n\
  \  --no-build            with `compile`, write build/ and its Makefile\n\
  \                        and build nothing\n\
  \  --no-typechecking     skip the type checker, and with it the\n\
  \                        mutability analysis and the tail-call pass,\n\
  \                        which both need what it works out. Only\n\
  \                        `compile -t pyking` accepts it: every other\n\
  \                        target and the interpreter need the types.\n\
  \                        What it prints is then the program as written,\n\
  \                        with the source's own annotations and its\n\
  \                        default parameters and named arguments still\n\
  \                        in it, and nothing it imports is read.\n\
  \  --type-experiment     check the program with the alternative type\n\
  \                        checker in src/type_experiment.ml instead of\n\
  \                        the real one. That checker is a fragment --\n\
  \                        integer literals, names, `+`, and the bindings\n\
  \                        those need -- so most programs are refused with\n\
  \                        'Construct is not supported'. It is there to be\n\
  \                        grown, and this flag is how it is run.\n\
  \  --no-tail-call-opt    leave tail calls as calls. A function that calls\n\
  \                        itself in tail position is otherwise rewritten\n\
  \                        into a `loop` carrying its parameters, and a\n\
  \                        group of functions that tail-call each other\n\
  \                        into one loop they share -- so such a function\n\
  \                        runs in constant space on every target. Turning\n\
  \                        it off is for reading the program as written,\n\
  \                        and for the recursion depth it restores."

(** The Warnings: block for --help: every warning's flag, whether it is
    on with no flag given, and what it reports. () -> string *)
let warning_table () =
  (* A description is filled to the width, six columns in. *)
  let described text =
    let words = List.filter (fun w -> w <> "") (String.split_on_char ' ' text) in
    let lines, last =
      List.fold_left
        (fun (lines, line) w ->
          if line = "" then (lines, "      " ^ w)
          else if String.length line + 1 + String.length w <= width then (lines, line ^ " " ^ w)
          else (lines @ [ line ], "      " ^ w))
        ([], "") words
    in
    String.concat "\n" (lines @ [ last ])
  in
  "Warnings:\n"
  ^ String.concat "\n"
      (List.map
         (fun kind ->
           Printf.sprintf "  -W%s%s\n%s" (Warnings.name kind)
             (if Warnings.default_on kind then " (on by default)" else " (off by default)")
             (described (Warnings.description kind)))
         Warnings.kinds)
  ^ "\n"
  ^ wrap
      "A warning is printed to stderr and the program still runs. -Wall turns every \
       one on, -w turns every one off, and -Werror makes every warning that is on an \
       error, which stops the program before it runs; -Werror=<name> does that for \
       one warning (and turns it on). The flags apply in the order given. A name \
       starting with '_', a public name and a name in a module of a library are \
       never reported."

(* The short form names the targets in a sentence rather than a table:
   someone who wants to know what `-t` takes is answered by the list,
   and someone who wants to know what each one *writes* is asking for
   --help. *)
let usage () =
  Printf.sprintf "%s\n\nTargets:\n%s" synopsis
    (wrap
       ("  " ^ String.concat ", " (List.map fst Targets.aliases @ [ "pyking" ])
      ^ " -- each its family's default version; `pyk --help` lists the \
         versions."))

let usage_full () =
  Printf.sprintf
    "%s\n\n\
     %s\n\n\
     Targets:\n\
     %s\n\n\
     %s\n\n\
     %s\n\n\
     Pyking is statically typed, and every program is type-checked before\n\
     anything else happens -- there is no flag for it and no way round it.\n\n\
     `pyk <filename>` runs the program on the AST, with Pyking's own\n\
     semantics: at least 32-bit integers, and its own runtime errors.\n\n\
     `pyk compile foo.pyk` writes everything it generates into build/ --\n\
     a file named after the source, every module's, the runtime -- with a\n\
     Makefile (make, make run, make clean), builds it with the target's own\n\
     tools, and puts the executable beside build/: ./foo, or what --output\n\
     names. For Python, Node and Java that is a script running what is in\n\
     build/; a page leaves nothing beside it. A build/ an earlier pyk\n\
     compile made is replaced, and any other is refused. The Java targets\n\
     name the file and its class in Java's own casing: foo_bar.pyk ->\n\
     FooBar.java. `pyk foo.pyk -t <target>` builds the same way and runs\n\
     it from build/, putting nothing beside it. `--stdout` writes nothing,\n\
     and `-t pyking` writes its one file where --output says. The `iweb`\n\
     target compiles nothing -- it\n\
     ships the Pyking source and the interpreter, so a browser runs the\n\
     whole language. The `pyking` target writes Pyking again -- the program\n\
     as the front end worked it out, with the types the checker inferred and\n\
     the loops the tail-call pass built.\n\n\
     `--run` builds and runs what was compiled, with the commands that\n\
     target's host uses, each printed before it runs:\n\n\
     %s\n\n\
     $PYTHON, $NODE, $CC, $JAVAC, $JAVA and $OCAMLOPT say which tool to\n\
     use where there is a choice. --run needs a file to run, so it cannot\n\
     be combined with --stdout.\n\n\
     Everything after `--` is passed to the program rather than read as a\n\
     flag, which is what `sys.args()` answers with. It applies to a\n\
     program being *run*: `pyk prog.pyk -- a b`, or `pyk compile --run` for\n\
     a target whose host takes arguments. `pyk compile` on its own writes a\n\
     file and runs nothing, so it refuses them.\n\n\
     A module is looked for beside the file that imports it, then in each\n\
     -L directory, then in each entry of $PYKING_LIB_PATH (separated by ':'\n\
     here), then in the lib/ beside this executable -- which is where the\n\
     standard library is found with no flag at all. A -L directory holds one\n\
     folder per library: -L libs finds libs/fs/fs_external.pyk for `fs`.\n\n\
     A module implemented in a target language is interpreted through its\n\
     OCaml implementation, loaded as a plugin: `<name>_external.cmxs` beside\n\
     `<name>_external.ml` where it is up to date, and otherwise one compiled\n\
     on demand into ~/.cache/pyking with $OCAMLOPT, which must be the OCaml\n\
     pyk was built by. `pyk plugins <dir>` builds them beside every library\n\
     in a directory of libraries; `make libs` runs it over lib/.\n\n\
     A program using tinyweb shows its page wherever it runs. In a browser\n\
     the page is there already; anywhere else, tinyweb.web_init(port)\n\
     serves it and prints its address (port 0 picks a free one). Two\n\
     environment variables, each holding a file path, run it with no page\n\
     at all, on every target -- which is how it is tested:\n\
    \  PYKING_TINYWEB_LOG=<file>     each command the program sends its\n\
    \                                page is appended to the file, one line\n\
    \                                each, with a `> ` line per event\n\
    \                                delivered (/dev/stderr shows it in the\n\
    \                                terminal). Setting it is what turns\n\
    \                                the page off.\n\
    \  PYKING_TINYWEB_EVENTS=<file>  a file you write, read once the\n\
    \                                program's top level has ended: one\n\
    \                                event per line -- click ID, slide ID\n\
    \                                VALUE, frame T, mouse ID X Y, key NAME\n\
     e.g. PYKING_TINYWEB_LOG=page.log PYKING_TINYWEB_EVENTS=clicks.txt\n\
    \     pyk prog.pyk\n\n\
     `pyk notebook <file.md>` serves a Markdown document whose Pyking code\n\
     blocks can be edited and run in the browser, and `pyk playground`\n\
     serves the compiler's playground. Both print a link to open, are\n\
     served by pyk itself, and look for tools/ beside this executable.\n\
     `pyk pykhelp` serves the help -- getting started, the language\n\
     reference and the libraries, with runnable examples -- which the\n\
     playground's Help tab shows too.\n\
     `pyk serve <dir>` serves a directory's files as they are, such as a\n\
     page compiled for web or iweb; `pyk serve <file>` serves the\n\
     file's directory and prints a link to the file. Without --port they start at 8000\n\
     and take the first free port, or any free port if 8000..8019 are\n\
     all taken. They listen on 127.0.0.1, or on the\n\
     address $PYKING_WEB_HOST names (0.0.0.0 for every interface, as in a\n\
     container). --mode student hides a task's solution and\n\
     tests until a student asks for them, --mode teacher shows every\n\
     block and what test mode finds under each, and --mode test serves\n\
     nothing: it runs every cell, task and solution under node,\n\
     checks each against the stdout and stderr blocks after it, prints\n\
     file:line: message for what is wrong, and exits with 1 if anything\n\
     is. The notebook's page reloads when its file changes. A notebook's\n\
     JSON (.json, as --to-json writes it) is served and tested as the\n\
     Markdown it stands for.\n\n\
     `pyk lsp` is the language server an editor starts: it reads and\n\
     writes the Language Server Protocol on standard input and output,\n\
     and reports errors, types on hover, definitions, an outline and\n\
     completion. --stdio is accepted and is the only transport; -L adds\n\
     library directories as for a program; --log FILE appends every\n\
     message to FILE, for finding out what an editor sent.\n\n\
     `pyk dap` is the debug adapter an editor starts to debug a program:\n\
     it reads and writes the Debug Adapter Protocol on standard input\n\
     and output, runs the program with the interpreter, and stops at\n\
     breakpoints, steps, and shows the calls in progress and their\n\
     variables. The editor's launch request names the program. --stdio\n\
     and --log are as for `pyk lsp`.\n\n\
     `pyk example` lists the example programs, one per line, and `pyk\n\
     example <name>` saves the one named in the current directory, which\n\
     it refuses to do over a file already there. The playground offers\n\
     the same examples.\n\n\
     `pyk highlight <file>` writes Pyking code coloured as the playground\n\
     colours it, for a slide: HTML with every style inline, RTF or plain\n\
     text, with leading spaces as non-breaking spaces so a PDF keeps them.\n\
     <file> is a program or a notebook; `pyk highlight --help` lists its\n\
     options."
    synopsis more_options (target_table ())
    (wrap ("An unversioned name is the family's default: " ^ alias_line () ^ ".")
    ^ "\n\n"
    ^ wrap
        "A version names the oldest host the output is promised to run on, \
         and what it counts depends on the family:"
    ^ "\n" ^ version_table ())
    (warning_table ())
    (run_table ())

(* --- what was asked for --- *)

(* The commands, and the one that is meant when a command word is left
   out. A bare `pyk foo.pyk` runs the program -- the thing someone with
   a file in their hand almost always wants -- and every other command
   says its name. *)
let commands =
  [
    ("repl", "repl");
    ("compile", "compile");
    ("c", "compile");
    ("notebook", "notebook");
    ("playground", "playground");
    ("pykhelp", "pykhelp");
    ("serve", "serve");
    ("lsp", "lsp");
    ("dap", "dap");
    ("plugins", "plugins");
    ("example", "example");
  ]
let default_command = "interpret"

(** argv parsed into one value. Flags are shared by every command. *)
type options = {
  command : string;
  filename : string option;
  target : string;
  target_given : bool;
  output : string option;
  no_build : bool;
  stdout : bool;
  run : bool;
  symbols : bool;
  tokens : bool;
  tail_calls : bool;
  release : bool;
  tinyweb_log : bool;
  typecheck : bool;
  type_experiment : bool;
  lib_paths : string list;
  arguments : string list;
  port : int option;
  mode : string option;
  convert : string option;
  log : string option;
  uses : string list;  (* `--use`: the REPL's features from the start *)
  warnings : string list;  (* every `-W...` and `-w`, in order *)
}

let default_options command =
  {
    command;
    filename = None;
    target = Targets.default;
    target_given = false;
    output = None;
    no_build = false;
    stdout = false;
    run = false;
    symbols = false;
    tokens = false;
    tail_calls = true;
    release = false;
    tinyweb_log = false;
    typecheck = true;
    type_experiment = false;
    lib_paths = [];
    arguments = [];
    port = None;
    mode = None;
    convert = None;
    log = None;
    uses = [];
    warnings = [];
  }

(* --- the library search path ---
   Three levels a caller can set and one this executable knows, tried in
   that order after the importing file's own directory. Reading an
   environment variable and asking where the executable is are done
   here rather than in module.ml: the browser build compiles that
   module too, and it may do neither (see docs/build.md). *)

(** The separator a path list uses inside an environment variable: the
    platform's own, since every other tool on it uses that one. char *)
let path_separator = if Sys.win32 then ';' else ':'

(** The directories PYKING_LIB_PATH names, in order. An empty entry is
    dropped rather than read as the current directory, which is what a
    trailing separator would otherwise mean. () -> [string] *)
let environment_libs () =
  match Sys.getenv_opt "PYKING_LIB_PATH" with
  | None -> []
  | Some text ->
      List.filter
        (fun entry -> entry <> "")
        (String.split_on_char path_separator text)

(** The library directory shipped beside the executable: `lib` next to
    the `pyk` that is running. It is what makes the standard library
    work with no flag set and no variable exported, and it is last, so
    anything a caller says overrides it. () -> [string] *)
let builtin_libs () =
  let beside = join (Install.root ()) "lib" in
  if Sys.file_exists beside then [ beside ] else []

(** The whole search path, in the order a module name is looked for:
    every `-L` as it was written, then every PYKING_LIB_PATH entry, then
    the one beside the executable. The importing file's own directory
    comes before all of them and is module.ml's own business.
    options -> [Module.lib_entry] *)
let library_path options =
  let at origin directories =
    List.map
      (fun directory -> { Module.lib_directory = directory; lib_origin = origin })
      directories
  in
  at "-L" options.lib_paths
  @ at "PYKING_LIB_PATH" (environment_libs ())
  @ at "built-in" (builtin_libs ())

(** The warnings the -W flags ask for; parse_args has refused any it
    could not read. options -> Warnings.config *)
let warning_config options =
  match Warnings.of_flags options.warnings with Ok config -> config | Error _ -> Warnings.default

(** Whether this run hands the program to a backend whose own host
    eliminates tail calls, in which case the pass would only be undone
    (see docs/optimization.md). options -> bool *)
let compiling_natively options =
  options.command = "compile" && List.mem options.target native_tail_calls

(** Prints message and the usage text to stderr, and exits 1.
    string -> 'a *)
let usage_error message =
  prerr_endline (wrap (Printf.sprintf "Usage error: %s" message));
  prerr_endline (usage ());
  exit 1

(** Prints message to stderr without the usage text, and exits 1: a
    refusal about the files a compile would write, not about the
    command line. string -> 'a *)
let build_error message =
  prerr_endline (wrap (Printf.sprintf "Error: %s" message));
  exit 1

(** Parses argv into an options; exits via usage_error on anything
    malformed. [string] -> options *)
let parse_args argv =
  let command, argv =
    match argv with
    | first :: rest when List.mem_assoc first commands ->
        (List.assoc first commands, rest)
    | argv -> (default_command, argv)
  in
  let rec go options positional rest =
    match rest with
    | [] -> (options, List.rev positional)
    | "--help" :: _ | "-h" :: _ ->
        print_endline (usage_full ());
        exit 0
    | "--version" :: _ ->
        print_endline ("pyk " ^ Version.version);
        exit 0
    | "--tokens" :: rest -> go { options with tokens = true } positional rest
    | "--run" :: rest -> go { options with run = true } positional rest
    | "--release" :: rest -> go { options with release = true } positional rest
    | "--tinyweb-log" :: rest -> go { options with tinyweb_log = true } positional rest
    | "--use" :: rest -> (
        match rest with
        | [] -> usage_error "--use requires a <feature> argument"
        | feature :: rest ->
            if not (List.mem feature Parser.features) then
              usage_error
                (Printf.sprintf "there is no feature '%s'; the features are %s" feature
                   (String.concat " and " Parser.features));
            go { options with uses = options.uses @ [ feature ] } positional rest)
    | "--symbols" :: rest -> go { options with symbols = true } positional rest
    | "--no-tail-call-opt" :: rest ->
        go { options with tail_calls = false } positional rest
    | "--no-typechecking" :: rest ->
        go { options with typecheck = false } positional rest
    | "--type-experiment" :: rest ->
        go { options with type_experiment = true } positional rest
    | "--stdout" :: rest -> go { options with stdout = true } positional rest
    | "--no-build" :: rest -> go { options with no_build = true } positional rest
    | ("--target" | "-t") :: rest -> (
        match rest with
        | [] -> usage_error "--target requires a <target> argument"
        | given :: rest ->
            (* An unversioned name is an alias for its family's latest,
               so what the rest of the driver sees is always a versioned
               target (src/targets.ml). *)
            let target =
              match Targets.resolve given with
              | Some target -> target
              | None ->
                  usage_error
                    (Printf.sprintf
                       "unknown target '%s'; expected one of %s, or one of \
                        the unversioned names %s"
                       given (String.concat ", " targets)
                       (String.concat ", " (List.map fst Targets.aliases)))
            in
            go { options with target; target_given = true } positional rest)
    | "--port" :: rest -> (
        match rest with
        | [] -> usage_error "--port requires a <number> argument"
        | given :: rest -> (
            match int_of_string_opt given with
            | Some port when port > 0 && port < 65536 ->
                go { options with port = Some port } positional rest
            | _ -> usage_error (Printf.sprintf "--port expects a port number, not '%s'" given)))
    | "--stdio" :: rest when command = "lsp" || command = "dap" -> go options positional rest
    | "--stdio" :: _ -> usage_error "--stdio only applies to 'pyk lsp' and 'pyk dap'"
    | "--log" :: rest -> (
        match rest with
        | [] -> usage_error "--log requires a <file> argument"
        | file :: rest -> go { options with log = Some file } positional rest)
    | "--mode" :: rest -> (
        match rest with
        | [] -> usage_error "--mode requires student, teacher or test"
        | given :: rest ->
            if List.mem given [ "student"; "teacher"; "test" ] then
              go { options with mode = Some given } positional rest
            else
              usage_error
                (Printf.sprintf "--mode is student, teacher or test, not '%s'" given))
    | (("--to-json" | "--to-markdown" | "--json-schema") as flag) :: rest -> (
        let wanted = String.sub flag 2 (String.length flag - 2) in
        match options.convert with
        | Some given when given <> wanted ->
            usage_error
              (Printf.sprintf "--%s and --%s each say what 'pyk notebook' writes, so only one may be given" given wanted)
        | _ -> go { options with convert = Some wanted } positional rest)
    | ("--output" | "-o") :: rest -> (
        match rest with
        | [] -> usage_error "--output requires a <file> argument"
        | output :: rest -> go { options with output = Some output } positional rest)
    (* `-Lpath` and `--lib-path=path` as well as the separated forms:
       this flag borrows its spelling from every other compiler's, so it
       borrows the shapes people type it in too. *)
    | argument :: rest
      when String.starts_with ~prefix:"-L" argument && String.length argument > 2
      ->
        go
          {
            options with
            lib_paths =
              options.lib_paths
              @ [ String.sub argument 2 (String.length argument - 2) ];
          }
          positional rest
    | argument :: rest when String.starts_with ~prefix:"--lib-path=" argument ->
        let at = String.length "--lib-path=" in
        go
          {
            options with
            lib_paths =
              options.lib_paths @ [ String.sub argument at (String.length argument - at) ];
          }
          positional rest
    | ("--lib-path" | "-L") :: rest -> (
        (* Repeated rather than separated: a list would need a
           separator, and the separator is what differs between
           platforms. The environment variable has no such choice and
           takes the platform's own (see `environment_libs`). *)
        match rest with
        | [] -> usage_error "--lib-path requires a <path> argument"
        | path :: rest ->
            go { options with lib_paths = options.lib_paths @ [ path ] }
              positional rest)
    (* Everything after `--` belongs to the program being run, not to
       this compiler: it is how a Pyking program is given arguments of
       its own (`sys.args`), and it stops a program's `-t` or
       `--run` being read as ours. *)
    | "--" :: rest -> ({ options with arguments = rest }, List.rev positional)
    | argument :: rest when Warnings.is_flag argument -> (
        match Warnings.of_flags (options.warnings @ [ argument ]) with
        | Ok _ -> go { options with warnings = options.warnings @ [ argument ] } positional rest
        | Error message -> usage_error message)
    | argument :: rest -> go options (argument :: positional) rest
  in
  let options, positional = go (default_options command) [] argv in
  if options.run && options.stdout then
    usage_error "--run needs a file to run, so it cannot be used with --stdout";
  if options.no_build && (command <> "compile" || options.run || options.stdout) then
    usage_error
      "--no-build writes build/ for 'pyk compile' and builds nothing, so it \
       cannot be used with --run or --stdout, or with another command";
  if options.target_given && command <> "compile" && command <> default_command then
    usage_error
      (Printf.sprintf "--target says what a program is compiled for, so 'pyk %s' takes none" command);
  if command = default_command && options.output <> None then
    usage_error
      "--output names what 'pyk compile' writes; 'pyk <file> -t <target>' builds \
       into build/ and runs it from there";
  if options.release && command <> "compile" then
    usage_error
      "--release says how a program is compiled, so it only applies to 'pyk \
       compile'";
  if options.tinyweb_log && command <> default_command && command <> "repl" then
    usage_error
      "--tinyweb-log shows what an interpreted program sends its page, so it only \
       applies to 'pyk <file>' and 'pyk repl'";
  if options.uses <> [] && command <> "repl" then
    usage_error
      "--use turns a feature on for a REPL session; a file turns its own on \
       with a 'use' line";
  if options.release && not options.typecheck then
    usage_error
      "--release needs the types the checker works out, so it cannot be used \
       with --no-typechecking";
  let web =
    command = "notebook" || command = "playground" || command = "serve" || command = "pykhelp"
  in
  if options.port <> None && not web then
    usage_error
      "--port only applies to 'pyk notebook', 'pyk playground', 'pyk pykhelp' and \
       'pyk serve'";
  if options.warnings <> [] && not (List.mem command [ default_command; "compile"; "repl"; "lsp"; "dap"; "notebook" ])
  then
    usage_error
      (Printf.sprintf
         "-W and -w say which warnings a program is checked with, so they apply to \
          'pyk <file>', 'pyk compile', 'pyk repl', 'pyk lsp', 'pyk dap' and 'pyk \
          notebook', not 'pyk %s'"
         command);
  if options.warnings <> [] && command = "notebook" && (options.mode = Some "test" || options.convert <> None) then
    usage_error
      "-W and -w say which warnings the notebook's page shows under a block, so \
       they are not for --mode test, --to-json, --to-markdown or --json-schema";
  if options.log <> None && command <> "lsp" && command <> "dap" then
    usage_error "--log only applies to 'pyk lsp' and 'pyk dap'";
  if options.mode <> None && command <> "notebook" then
    usage_error "--mode only applies to 'pyk notebook'";
  if options.mode = Some "test" && options.port <> None then
    usage_error "--mode test serves nothing, so it takes no --port";
  (match options.convert with
  | Some flag when command <> "notebook" ->
      usage_error (Printf.sprintf "--%s only applies to 'pyk notebook'" flag)
  | Some flag when options.mode <> None || options.port <> None ->
      usage_error
        (Printf.sprintf "--%s writes a file and serves nothing, so it takes no --mode or --port" flag)
  | None when command = "notebook" && options.output <> None ->
      usage_error "--output names what --to-json, --to-markdown or --json-schema writes"
  | _ -> ());
  if options.arguments <> [] then
    if command = "repl" || command = "lsp" || command = "dap" || command = "example" || web then
      usage_error
        (Printf.sprintf
           "everything after -- is passed to a program being run, and 'pyk %s' \
            runs none"
           command)
    else if command = "compile" && not options.run then
      usage_error
        "everything after -- is passed to a program being run; 'pyk compile' \
         writes a file, so add --run or drop the --"
    else if
      options.run
      && List.mem (Targets.family_of options.target) [ Targets.Web; Targets.Iweb ]
    then
      usage_error
        (Printf.sprintf
           "--run on '%s' starts a server for the page to be fetched from, so \
            there is no program invocation to pass arguments to"
           options.target);
  if (not options.typecheck) && (command <> "compile" || options.target <> pyking_target)
  then
    (* Every backend but this one reads the types, and so does the
       interpreter: the Python one to know what to format, the OCaml one
       for every type it emits, and the rest through the tail-call pass,
       which the checker's table is what makes decidable. `-t pyking` is
       the one that can print a program nothing has checked, since it
       prints the program itself. *)
    usage_error
      (Printf.sprintf
         "--no-typechecking only applies to 'pyk compile -t %s': every other \
          target, and the interpreter, need the types the checker works out"
         pyking_target);
  if
    command = "repl" || command = "playground" || command = "pykhelp" || command = "lsp"
    || command = "dap"
  then (
    if positional <> [] then
      usage_error (Printf.sprintf "'pyk %s' takes no filename" command);
    options)
  else if command = "serve" then
    match positional with
    | [] -> options
    | [ directory ] -> { options with filename = Some directory }
    | _ -> usage_error "'pyk serve' takes one directory, or one file in it, at most"
  else if command = "notebook" && options.convert = Some "json-schema" then
    match positional with
    | [] -> options
    | _ -> usage_error "--json-schema writes the schema of every notebook, so it takes no notebook"
  else if command = "example" then
    match positional with
    | [] -> options
    | [ name ] -> { options with filename = Some name }
    | _ -> usage_error "'pyk example' takes one example's name at most"
  else
    match positional with
    | [ filename ] -> { options with filename = Some filename }
    | _ ->
        prerr_endline (usage ());
        exit 1

(* --- reporting --- *)

(** Formats a front-end error as `'file' row:col-row:col Kind: message`,
    or None if error is not one of the stages'. One line per stage that
    can refuse a program, in the order the stages run: every one of them
    carries an info, which is what lets them all be reported the same
    way, and the label is the only thing that differs.
    exn -> string option *)
let format_error error =
  let line label (i : Lexer.info) message =
    Some (wrap (Printf.sprintf "%s %s: %s" (Lexer.pprint_info i) label message))
  in
  match error with
  | Lexer.Lex_error (i, message) -> line "Lexing error" i message
  | Parser.Parse_error (i, message) -> line "Parsing error" i message
  | Module.Module_error (i, message) -> line "Module error" i message
  | Analyses.Analysis_error (i, message) -> line "Name error" i message
  | Typesystem.Type_error (i, message) -> line "Type error" i message
  | Type_experiment.Type_error (i, message) -> line "Type error" i message
  | Interpreter.Runtime_error (i, message) -> line "Runtime error" i message
  | Warnings.Refused found -> Some (String.concat "\n" (List.map (fun w -> wrap (Warnings.format w)) found))
  | _ -> None

(** Prints error and exits 1. exn -> 'a *)
let fail error =
  (match format_error error with
  | Some text -> prerr_endline text
  | None -> raise error);
  exit 1

(** Prints an unsupported-construct error, naming the target that
    refused it, and exits 1. string -> info -> string -> 'a *)
let fail_unsupported target (i : Lexer.info) message =
  prerr_endline
    (wrap
       (Printf.sprintf "%s Unsupported by target '%s': %s"
          (Lexer.pprint_info i) target message));
  exit 1

(* --- the front end --- *)

(** The warnings a config reports in one module of the program: its
    names as the source wrote them, a dotted one included, and its
    public ones exempt. config -> resolution IntMap.t -> Module.t ->
    [Warnings.warning] *)
let module_warnings warnings qmap (unit : Module.t) =
  let display name =
    match List.find_opt (fun (_, plain) -> plain = name) unit.dotted with
    | Some (dotted, _) -> dotted
    | None -> name
  in
  Warnings.check ~qmap ~public:(List.map fst unit.publics) ~display warnings unit.tokens unit.stmts

(** Prints every warning to stderr, and exits 1 if a -Werror made one an
    error. [Warnings.warning] -> () *)
let report_warnings found =
  List.iter (fun w -> prerr_endline (wrap (Warnings.format w))) found;
  if Warnings.has_error found then exit 1

(** One module through the type checker and the mutability analysis,
    answering the types it worked out. Exits via fail on the first
    error. Module.t -> [(string, Typesystem.sigmap)] -> bool
    -> ([stmt], typ IntMap.t) *)
let check_module ?(warnings = Warnings.default) ?(warn = false) (unit : Module.t) sigmaps experiment =
  let declared = Module.external_signatures unit.declarations in
  (* Pyking is statically typed, so this is not a mode: a program that
     does not check is refused, whatever was asked for. The checker
     carries a scope of its own, so it reports an unbound name too, in
     analyses.ml's words. *)
  let tmap, qmap =
    try
      if experiment then (Type_experiment.type_check unit.stmts, Syntax.IntMap.empty)
      else Typesystem.type_check ~declared unit.stmts sigmaps
    with
    | Analyses.Analysis_error _ as e -> fail e
    | Typesystem.Type_error _ as e -> fail e
    | Type_experiment.Type_error _ as e -> fail e
  in
  (* The one rule types do not state: only a `var` may be written to
     with `:=`, and nothing may shadow one. *)
  (try Analyses.analyze_mutability unit.stmts
   with Analyses.Analysis_error _ as e -> fail e);
  (* What checks may still be wrong: a name bound and never used. Each
     warning goes to stderr and the program goes on, unless a -Werror
     made one of them an error. *)
  if warn then report_warnings (module_warnings warnings qmap unit);
  (* Overloading and implicits are removed here, from what the checker
     settled: a qualified name becomes a plain one, a resolved call names
     the definition it reaches, and an implicit parameter becomes an
     ordinary argument. Everything after this point sees ordinary
     Pyking (docs/implicits.md). *)
  let stmts, tmap =
    try Elaborate.program qmap tmap unit.stmts
    with Analyses.Analysis_error _ as e -> fail e
  in
  (stmts, tmap)

(** One module through the tail-call pass, with the symbols it hands out
    continuing past `highest` -- the highest anywhere in the program so
    far, which is what the next module continues past in turn. Tail
    calls become loops before anything reads the program, so what the
    `pyking` target prints and what every backend compiles are the same
    program.
    [stmt] -> typ IntMap.t -> int -> options -> ([stmt], typ IntMap.t, int) *)
let optimize_module program tmap highest options =
  if not (options.tail_calls && not (compiling_natively options)) then
    (program, tmap, highest)
  else
    (* The pass builds nodes, so symbols are handed out again --
       `symbolize` keeps the ones already given -- and it extends `tmap`
       for what it built, since the checker will not run again to say
       what those nodes are. *)
    let program, tmap = Opt_tailcall.optimize program tmap in
    let program = Analyses.symbolize ~start:highest program in
    (program, tmap, max highest (Analyses.highest_sym program))

(** Prints the token stream of every module of the program.
    [Module.t] -> () *)
let report_tokens units =
  List.iter
    (fun (unit : Module.t) ->
      List.iter
        (fun token ->
          Printf.printf "%s %s\n"
            (Lexer.pprint_info (Lexer.token_info token))
            (Lexer.pprint_token token))
        unit.tokens;
      print_newline ())
    units

(** Every stage before a backend, over every module the program reaches:
    loading (which lexes, parses, symbolizes and orders them), type
    checking, the mutability analysis, and the tail-call pass, each
    module in the order it is loaded in -- so a module is checked after
    everything it imports, against what those export. Under
    `--no-typechecking` it stops after loading, and every table is None.
    Exits via fail on the first error.
    options -> [(Module.t, typ IntMap.t option)] *)
let front_end options =
  let filename = Option.get options.filename in
  (* `--no-typechecking` is the one flag that stops the front end early:
     the file named is lexed, parsed and symbolized, nothing it imports
     is read, and `-t pyking` -- the only target that accepts the flag
     (see `parse_args`) -- prints the program the parser built, with the
     source's own annotations. *)
  if not options.typecheck then (
    let unit =
      try Module.read_file filename None with
      | Lexer.Lex_error _ as e -> fail e
      | Parser.Parse_error _ as e -> fail e
      | Module.Module_error _ as e -> fail e
      | Sys_error message -> usage_error message
    in
    if options.tokens then report_tokens [ unit ];
    [ ({ unit with stmts = Analyses.symbolize unit.stmts }, None) ])
  else
    let units =
      try Module.load ~libs:(library_path options) filename with
      | Lexer.Lex_error _ as e -> fail e
      | Parser.Parse_error _ as e -> fail e
      | Analyses.Analysis_error _ as e -> fail e
      | Module.Module_error _ as e -> fail e
      | Sys_error message -> usage_error message
    in
    if options.tokens then report_tokens units;
    (* Every module is checked against what the ones it imports export,
       which is why they are checked in this order -- and `make_sigmap`
       is what turns each result into the next module's input. It is
       made from the program the *checker* saw, since the tail-call pass
       below can only change how a module computes what it exports,
       never what it exports or at what type. *)
    (* The tail-call pass builds nodes and so hands out more symbols;
       they continue past the highest in the whole program, since one
       numbering spans every module of it (see Analyses.symbolize). *)
    let highest =
      List.fold_left
        (fun highest (unit : Module.t) ->
          max highest (Analyses.highest_sym unit.stmts))
        0 units
    in
    let _, _, checked =
      List.fold_left
        (fun (sigmaps, highest, checked) (unit : Module.t) ->
          if unit.is_external then
            (* A module that is only a declaration half holds signatures
               and nothing else, so there is no body to check, nothing to
               infer and no tail call to rewrite. What it exports is what
               it wrote down. *)
            let sigmap = Module.external_sigmap unit.declarations in
            ( sigmaps @ [ (unit.name, sigmap) ],
              highest,
              checked @ [ ({ unit with sigmap = Some sigmap }, None) ] )
          else
            let elaborated, tmap =
              check_module ~warnings:(warning_config options)
                ~warn:(not (Module.in_library (library_path options) unit.path))
                unit
                (Module.sigmaps_for unit sigmaps)
                options.type_experiment
            in
            (* Both halves: a module with a declaration beside it exports
               what its Pyking half worked out *and* what that half
               declared public. The names are the source's own, since
               that is what the module importing this one writes. *)
            let sigmap = Module.module_sigmap unit.name unit.stmts unit.declarations tmap in
            let elaborated =
              if options.release then Release.program tmap elaborated
              else elaborated
            in
            let elaborated = Analyses.symbolize ~start:highest elaborated in
            let highest = max highest (Analyses.highest_sym elaborated) in
            let stmts, tmap, highest =
              optimize_module elaborated tmap highest options
            in
            ( sigmaps @ [ (unit.name, sigmap) ],
              highest,
              checked
              @ [
                  ( {
                      unit with
                      stmts;
                      sigmap = Some sigmap;
                      (* The names this module exports are the plain ones
                         the overloading pass gave them, since that is
                         what the generated file declares. *)
                      publics =
                        List.map
                          (fun (name, info) -> (Names.renamed name, info))
                          unit.publics;
                    },
                    Some tmap );
                ] ))
        ([], highest, []) units
    in
    checked

(* --- the commands --- *)

(* How many calls a runtime error's stack trace shows before it says how
   many more there were. *)
let trace_limit = 10

(** The lines a runtime error is reported in: the error, moved out of a
    library's own code to where the program called into the library, and
    the calls in progress there, at most `trace_limit` of them.
    [Module.lib_entry] -> Interpreter.state -> exn -> [string] *)
let runtime_report libs state error =
  let error, trace = Interpreter.outside_libraries (Module.in_library libs) state error in
  let first = match format_error error with Some text -> text | None -> raise error in
  let calls =
    List.filteri (fun index _ -> index < trace_limit) trace
    |> List.map (fun (name, info) ->
           wrap (Printf.sprintf "  in '%s', called at %s" name (Lexer.pprint_info info)))
  in
  let more =
    if List.length trace > trace_limit then
      [ Printf.sprintf "  ... %d more calls" (List.length trace - trace_limit) ]
    else []
  in
  (first :: calls) @ more

(** Runs `pyk <file>` with the interpreter; prints a runtime error (with
    a truncated stack trace) if one occurs. Every module of the program
    runs, in the order it was checked in, each in a top level of its
    own. [Module.lib_entry]? -> [(Module.t, typ IntMap.t option)] -> [string] -> int *)
let command_interpret ?(libs = []) checked arguments =
  (* The interpreter runs the AST, and an external module has none: what
     it exports is written in a target language. An interpreted program
     reaches the module's OCaml implementation, loaded as a plugin
     (src/plugin_host.ml), which is what the ocaml targets link. *)
  let plugins =
    List.filter_map
      (fun ((unit : Module.t), _) ->
        match unit.declaration_path with
        | Some declaration_path when unit.declarations <> [] ->
            Some
              Plugin_host.
                {
                  name = unit.name;
                  declared = Module.external_signatures unit.declarations;
                  declaration_path;
                }
        | _ -> None)
      checked
  in
  (try Plugin_host.load plugins with Module.Module_error _ as e -> fail e);
  let units =
    List.map
      (fun ((unit : Module.t), _) ->
        (* The two halves stay apart: `apply_signatures` folds a
           signature onto the definition it describes and drops every one
           it cannot, which would empty a declaration. *)
        ( unit.name,
          Analyses.apply_signatures unit.stmts,
          unit.declarations ))
      checked
  in
  (* The program's own module is last, since the modules are in
     dependency order, and its path is what `sys.prog_name` answers
     with; `arguments` is what followed `--`, which is what
     `sys.args` answers from. *)
  let program =
    match List.rev checked with
    | ((unit : Module.t), _) :: _ -> unit.path
    | [] -> ""
  in
  Plugin_host.set_arguments program arguments;
  let host =
    Interpreter.callback_host
      ~externals:(Plugin_host.externals plugins)
      (fun line ->
        print_string line;
        print_newline ())
  in
  let state = Interpreter.run_modules units host in
  (* What a plugin asked to run once the top level ended -- events
     delivered to the callbacks it was handed -- runs only after a top
     level that succeeded. *)
  let failure =
    match Interpreter.failure state with
    | None -> (
        try
          Pyk_plugin.run_after_program ();
          None
        with Interpreter.Runtime_error _ as error -> Some error)
    | failure -> failure
  in
  match failure with
  | None -> 0
  | Some error ->
      List.iter prerr_endline (runtime_report libs state error);
      1

(** What a file compiled from `stem` is called when nothing says: the
    source's own name with the target's extension -- except for the Java
    targets, which require the public class to share its file's name
    exactly, so the name is Java-cased rather than the source's own
    spelling: `foo_bar.pyk` writes `FooBar.java`.
    string -> string -> string *)
let default_name target stem =
  if Targets.family_of target = Targets.Java then
    Target_java.default_class_name stem ^ ".java"
  else stem ^ List.assoc target extensions

(** One module translated to Java, or the backend's refusal reported.
    Module.t -> typ IntMap.t option -> string -> Module.context
    -> Target_java.jprogram *)
let java_unit (unit : Module.t) tmap target context =
  try
    Target_java.translate_program
      (Analyses.apply_signatures unit.stmts)
      (Option.value tmap ~default:Syntax.IntMap.empty)
      context target
  with Target_java.Unsupported (info, message) -> fail_unsupported target info message

(** One module compiled for one target: the text of its own file, and
    the companion files that go beside it -- a C header, an OCaml
    interface -- keyed by path. Nothing is written here; a companion is
    left out entirely where there is no path to put it beside
    (`--stdout`).
    Module.t -> typ IntMap.t option -> string -> string option -> options
    -> (string, [(string, string)]) *)
let compile_unit ?c_program (unit : Module.t) tmap target path options checked =
  let context = Module.context checked unit in
  let source = basename unit.path in
  if target = pyking_target then
    (* Pyking back out again: the program as the front end worked it
       out, with the checker's types and the tail-call pass's loops. It
       is printed *before* `apply_signatures`, so a `def name : type`
       line stays the line the source wrote rather than being folded
       onto its header. *)
    (* The `use` lines are not statements, so they are read back off the
       module's tokens and written above it. *)
    (Parser.use_lines unit.tokens ^ Syntax.pprint_program unit.stmts options.symbols tmap ^ "\n", [])
  else
    let program = Analyses.apply_signatures unit.stmts in
    if Targets.family_of target = Targets.Python then
      let py_program =
        try
          Target_python.translate_program
            ~external_fields:context.external_fields
            ~externals:context.externals ~own:context.context_name ~target program
            (Option.value tmap ~default:Syntax.IntMap.empty)
        with Target_python.Unsupported (info, message) ->
          fail_unsupported target info message
      in
      (Target_python.pprint_py_program py_program ^ "\n", [])
    else if Targets.family_of target = Targets.C then
      (* One backend, two standards: the difference is in how the C is
         printed, not in what it means. *)
      let c_program =
        match c_program with
        | Some translated -> translated
        | None -> (
            try
              Target_c.translate_program program
                (Option.value tmap ~default:Syntax.IntMap.empty)
                context target
            with Target_c.Unsupported (info, message) ->
              fail_unsupported target info message)
      in
      let text = Target_c.pprint_c_program c_program target source in
      if context.main || path = None then (text, [])
      else
        (* The program's own module declares nothing for anyone else to
           include, so it has no header. *)
        let header =
          join
            (dirname (Option.get path))
            (unit.name ^ Target_c.header_extension)
        in
        (text, [ (header, Target_c.pprint_c_header c_program target source) ])
    else if Targets.family_of target = Targets.Java then
      (* Java requires the public class to share its file's name exactly.
         An explicit `--output` is trusted as-is: the class is named
         after whatever file the caller chose. With none, `path` was
         already picked in Java's own casing above, and the class matches
         it too. *)
      let class_name =
        match path with
        | Some path -> Filename.remove_extension (basename path)
        | None -> Target_java.default_class_name unit.name
      in
      let java_program = java_unit unit tmap target context in
      ( Target_java.pprint_java_program java_program target class_name source,
        [] )
    else if Targets.family_of target = Targets.Ocaml then
      (* The one backend that infers nothing: it reads the types back out
         of the table `front_end` filled, which is why this target
         type-checks whether or not it was asked for, and why a program
         that does not check has already been refused. *)
      let ocaml_program =
        try
          Target_ocaml.translate_program program
            (Option.value tmap ~default:Syntax.IntMap.empty)
            context target
        with Target_ocaml.Unsupported (info, message) ->
          fail_unsupported target info message
      in
      let text = Target_ocaml.pprint_ocaml_program ocaml_program target source in
      if context.main || path = None then (text, [])
      else
        (* Nothing imports the program's own module, so it needs no
           interface saying what it exports. *)
        let interface =
          Filename.remove_extension (Option.get path)
          ^ Target_ocaml.interface_extension
        in
        ( text,
          [ (interface, Target_ocaml.pprint_ocaml_interface ocaml_program source) ]
        )
    else
      (* Every target above is handled; `parse_args` refuses any other
         name. *)
      raise (Invalid_argument target)

(* The library whose implementation a browser's `print` writes through. *)
let browser_io_module = "io"

(** Every file the program compiles to, as (path, contents), and the
    text of the one `--stdout` prints -- the program's own module, since
    a module it imports is a file and `--stdout` writes none. A module
    is written beside the program's output under its own name, which is
    also what the generated import in that output names it by.
    [(Module.t, typ IntMap.t option)] -> string -> string option
    -> options -> ([(string, string)], string) *)
let compile_program checked target output_path options =
  (* C and Java compile a subset of the language, so they are given only
     what the program uses of the modules it imports: a library's
     function nobody calls is not refused for using what they lack
     (docs/modules.md, "What a program uses"). *)
  let checked =
    if List.mem (Targets.family_of target) [ Targets.C; Targets.Java ] then
      Prune.program checked
    else checked
  in
  let main_unit = fst (List.nth checked (List.length checked - 1)) in
  let directory = dirname (Option.value output_path ~default:"") in
  (* Every module the program reaches must have an implementation for
     the target chosen, and a missing one is the module system's error
     rather than a backend's: nothing has been translated yet. *)
  let external_implementation (unit : Module.t) target =
    try
      Module.implementation_path (dirname unit.path) unit.name target
        { Lexer.file = unit.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
    with Module.Module_error _ as e -> fail e
  in
  (* A function the target's implementation of a module cannot provide
     -- tinyweb's `sdelay` on the web -- is refused where it is called. *)
  if Targets.family_of target = Targets.Web then (
  try
     Module.check_available
       (fun unit ->
         match
           Module.implementation_path (dirname unit.path) unit.name target
             { Lexer.file = unit.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
         with
         | path -> Some (Module.read_whole_file path)
         | exception Module.Module_error _ -> None)
       (List.map fst checked) target
   with Module.Module_error _ as e -> fail e);
  (* The compiler as JavaScript, which the `iweb` target ships beside
     the program: `make` writes it to share/pyking.js, so it is looked
     for beside the executable that is asking for it. *)
  let interpreter_js () =
    let here = Install.root () in
    let candidates =
      [
        join (join here "share") Target_js_packaging.interpreter_module;
        join here Target_js_packaging.interpreter_module;
      ]
    in
    match List.find_opt Sys.file_exists candidates with
    | Some path -> Module.read_whole_file path
    | None ->
        usage_error
          (Printf.sprintf
             "target '%s' ships the interpreter, and '%s' is not beside the \
              compiler; run `make` to build it."
             target Target_js_packaging.interpreter_module)
  in
  (* In a browser `print` writes through the `io` library's own
     implementation (docs/target_js.md, "Standard output in a browser"),
     so a page ships it whether or not the program imports `io`. Found
     on the library search path like any import of it. *)
  let browser = List.mem (Targets.family_of target) [ Targets.Web; Targets.Iweb ] in
  let imports_io =
    List.exists
      (fun ((unit : Module.t), _) ->
        unit.name = browser_io_module && unit.declarations <> [])
      checked
  in
  let browser_io () =
    if (not browser) || imports_io then []
    else
      let source =
        try
          Module.found_implementation ~libs:(library_path options)
            (dirname main_unit.path) browser_io_module target
            { Lexer.file = main_unit.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
        with Module.Module_error _ as e -> fail e
      in
      [
        ( join directory
            (Option.get (Module.implementation_name browser_io_module target)),
          Module.read_whole_file source );
      ]
  in
  (* Every external module's implementation, as a file to write beside
     the program's output. Nothing is generated for one, and a copy onto
     itself -- compiling beside the implementation -- is skipped rather
     than truncating it. *)
  (* A library's `<name>_assets/` directory -- tinyweb's samples -- goes
     beside the program under the same name, so the library's
     implementation finds it beside itself wherever it is served from:
     a page on the web targets, and the page a program serves itself on
     the rest. *)
  let library_assets () =
    if Targets.family_of target = Targets.Pyking then []
    else
      List.concat_map
        (fun ((unit : Module.t), _) ->
          match unit.declaration_path with
          | None -> []
          | Some path ->
              let name = unit.name ^ "_assets" in
              let assets = join (dirname path) name in
              (* A library's page, `<name>_page.js`, is what its command
                 implementation mounts on an iweb page, beside itself. *)
              let renderer = unit.name ^ "_page.js" in
              let page =
                if
                  Targets.family_of target = Targets.Iweb
                  && Sys.file_exists (join (dirname path) renderer)
                then
                  [ (join directory renderer, Module.read_whole_file (join (dirname path) renderer)) ]
                else []
              in
              page
              @
              if not (Sys.file_exists assets && Sys.is_directory assets) then []
              else
                List.filter_map
                  (fun file ->
                    let source = join assets file in
                    if Sys.is_directory source || file.[0] = '.' then None
                    else
                      Some (join (join directory name) file, Module.read_whole_file source))
                  (List.sort compare (Array.to_list (Sys.readdir assets))))
        checked
  in
  let external_copies () =
    List.filter_map
      (fun (destination, contents, source) ->
        if absolute source = absolute destination then None
        else Some (destination, contents))
      (List.filter_map
         (fun ((unit : Module.t), _) ->
           if unit.declarations = [] then None
           else
             let source = external_implementation unit target in
             let destination =
               join directory
                 (Option.get (Module.implementation_name unit.name target))
             in
             Some (destination, Module.read_whole_file source, source))
         checked)
    @ browser_io () @ library_assets ()
  in
  if Targets.family_of target = Targets.Iweb then
    (* Nothing is compiled: the program ships as Pyking and is
       interpreted in the page by the same compiler, built to JavaScript
       (see docs/target_js.md, "The interpreted target"). *)
    let main_name = basename main_unit.Module.path in
    let page =
      Target_js_packaging.interpreted_page ~release:options.release target main_name
        (* Every module's Pyking file, an external module's declaration
           included: the module system reads that to know what the
           module offers, and only the *implementation* is JavaScript. *)
        (List.concat_map
           (fun ((unit : Module.t), _) ->
             List.map basename (Module.source_paths unit))
           checked)
        (List.filter_map
           (fun ((unit : Module.t), _) ->
             (* Any module with a declaration half needs its
                implementation on the page, whether or not it also has a
                Pyking half. *)
             if unit.declarations = [] then None
             else
               Some
                 ( unit.name,
                   Option.get (Module.implementation_name unit.name target) ))
           checked
        @
        if imports_io then []
        else
          [
            ( browser_io_module,
              Option.get (Module.implementation_name browser_io_module target) );
          ])
    in
    match output_path with
    | None -> ([], page)
    | Some output_path ->
        if options.stdout then ([], page)
        else
          let beside name = join (dirname output_path) name in
          ( [ (output_path, page) ]
            @ [ (beside Target_js_packaging.interpreter_module, interpreter_js ()) ]
            @ List.concat_map
                (fun ((unit : Module.t), _) ->
                  (* The page reads the program's own Pyking, so every
                     module's source ships beside it. Compiling in the
                     directory the sources already sit in copies each
                     onto itself, which is nothing to do -- and must not
                     look like overwriting the input. *)
                  List.filter_map
                    (fun source ->
                      let destination = beside (basename source) in
                      if absolute destination = absolute source then None
                      else Some (destination, Module.read_whole_file source))
                    (Module.source_paths unit))
                checked
            @ external_copies (),
            page )
  else if List.mem (Targets.family_of target) [ Targets.Node; Targets.Web ] then
    (* The JavaScript targets package a whole program at once: `html`
       has one file to put every module in, and the other two share one
       runtime module between them. *)
    let taken =
      Target_js_packaging.reserved_names
        (List.map (fun ((unit : Module.t), _) -> unit.name) checked)
    in
    try
      let files, primary =
        Target_js_packaging.package_program target
          (List.map
           (fun ((unit : Module.t), tmap) ->
             let context = Module.context checked unit in
             let js_program, renames =
               try
                 Target_js_core.translate_program ~taken
                   ~external_fields:context.external_fields
                   ~externals:context.externals ~own:context.context_name
                   (Analyses.apply_signatures unit.stmts)
                   (Option.value tmap ~default:Syntax.IntMap.empty)
               with Target_js_core.Unsupported (info, message) ->
                 fail_unsupported target info message
             in
             (unit, js_program, renames))
             checked)
          output_path options.stdout
      in
      ((files @ if options.stdout then [] else external_copies ()), primary)
    with Target_js_core.Unsupported (info, message) ->
      (* Packaging refuses what only a whole program can be refused for:
         an external module on `html`, where a page has nothing to load
         an implementation from. *)
      fail_unsupported target info message
  else
  (* The C modules of a program are translated together, since each
     compiles the instances of its polymorphic functions the others
     call. *)
  let c_programs =
    if Targets.family_of target <> Targets.C then []
    else
      let units = List.filter (fun ((unit : Module.t), _) -> not unit.is_external) checked in
      let translated =
        try
          Target_c.translate_all
            (List.map
               (fun ((unit : Module.t), tmap) ->
                 ( Analyses.apply_signatures unit.stmts,
                   Option.value tmap ~default:Syntax.IntMap.empty,
                   Module.context checked unit ))
               units)
            target
        with Target_c.Unsupported (info, message) -> fail_unsupported target info message
      in
      List.map2 (fun ((unit : Module.t), _) c -> (unit.name, c)) units translated
  in
  let files, primary =
    List.fold_left
      (fun (files, primary) ((unit : Module.t), tmap) ->
        let is_main = unit.name = main_unit.Module.name in
        if unit.is_external && target <> pyking_target then
          (* Nothing is generated for an external module: its
             implementation is the target's own source, copied below
             under the name the host resolves the module by. `-t pyking`
             is the exception, since there the declaration *is* the
             output. *)
          (files, primary)
        else
          let path =
            if is_main then output_path
            else if unit.is_external then
              Some (join directory (unit.name ^ Module.external_extension))
            else Some (join directory (default_name target unit.name))
          in
          let contents, companions =
            compile_unit ?c_program:(List.assoc_opt unit.name c_programs) unit tmap target path options
              checked
          in
          let primary = if is_main then contents else primary in
          match path with
          | None -> (files, primary)
          | Some path -> (files @ [ (path, contents) ] @ companions, primary))
      ([], "") checked
  in
  (* Every module of a Java program calls into one runtime, written beside
     them. *)
  let runtime =
    if Targets.family_of target <> Targets.Java || options.stdout then []
    else
      [
        ( join directory Target_java.runtime_file,
          Target_java.runtime_source
            (List.filter_map
               (fun ((unit : Module.t), tmap) ->
                 if unit.is_external then None
                 else Some (java_unit unit tmap target (Module.context checked unit)))
               checked)
            target );
      ]
  in
  ((files @ runtime @ if options.stdout then [] else external_copies ()), primary)

(** The files a program's modules were compiled to, beside its own in
    `directory`, in the order they must be built and run: a module is up
    to two files, the implementation first, since the file generated for
    the module calls into it.
    [(Module.t, typ IntMap.t option)] -> string -> string -> [string] *)
let module_files checked target directory =
  List.filteri (fun i _ -> i < List.length checked - 1) checked
  |> List.concat_map (fun ((unit : Module.t), _) ->
         let implementation =
           if unit.declarations = [] then []
           else
             match Module.implementation_name unit.name target with
             | Some file -> [ join directory file ]
             | None -> []
         in
         let generated =
           if unit.is_external then [] else [ join directory (default_name target unit.name) ]
         in
         implementation @ generated)

(** Writes what compile_program made for the program compiled to
    output_path: every file, and a library's assets directory where one
    is wanted. Refuses to write over the program's own sources.
    [(Module.t, typ IntMap.t option)] -> options -> string -> [(string,
    string)] -> () *)
let write_compiled checked options files =
  let filename = Option.get options.filename in
  (* Every file the program was read from: the program's own, and every
     module it imports. `-t pyking` writes `.pyk` files, and a module is
     written under its own name, so without this a program compiled into
     its own directory would overwrite the module beside it. *)
  let sources =
    List.map (fun ((unit : Module.t), _) -> absolute unit.path) checked
  in
  let write path contents =
    if List.mem (absolute path) sources then
      usage_error
        (Printf.sprintf "writing '%s' would overwrite %s; choose a different \
                         output path."
           path
           (if absolute path = absolute filename then "the input file"
            else
              Printf.sprintf "'%s', a module this program imports"
                (basename path)));
    let directory = dirname path in
    if directory <> "" && not (Sys.file_exists directory && Sys.is_directory directory)
    then
      usage_error
        (Printf.sprintf "cannot write '%s': the directory '%s' does not exist."
           path directory);
    let channel = open_out_bin path in
    output_string channel contents;
    close_out channel
  in
  let write_manifest path contents =
    (* The esm target's package.json, unless one already exists there
       (with a note if it does not declare ES modules). *)
    if not (Sys.file_exists path) then write path contents
    else
      let channel = open_in_bin path in
      let existing = really_input_string channel (in_channel_length channel) in
      close_in channel;
      if not (Target_js_packaging.manifest_declares_module existing) then
        prerr_endline
          (wrap
             (Printf.sprintf
                "Note: '%s' already exists and does not set \"type\":                  \"module\"; node will read the generated .js files as                  CommonJS until it does. Left untouched."
                path))
  in
  (* A library's assets go in a directory of their own beside the
     output, which this makes where the output's own directory is. *)
  List.iter
    (fun (path, _) ->
      let assets = dirname path in
      let parent = dirname assets in
      if Filename.check_suffix assets "_assets"
         && (parent = "" || Sys.file_exists parent)
         && not (Sys.file_exists assets)
      then Sys.mkdir assets 0o755)
    files;
  List.iter
    (fun (path, contents) ->
      if basename path = Target_js_packaging.module_manifest then
        write_manifest path contents
      else write path contents)
    files

(** The file a `build/` directory pyk compile made holds, which is what
    lets the next one remove it. string *)
let build_marker = ".pyk-build"

(** Removes path and everything under it, never following a link.
    string -> () *)
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Sys.remove path

(** Makes `build` afresh: one an earlier `pyk compile` made, holding
    build_marker, is removed first, and anything else there is refused.
    string -> () *)
let fresh_build build =
  if Sys.file_exists build then
    if Sys.is_directory build && Sys.file_exists (join build build_marker) then remove_tree build
    else
      build_error
        (Printf.sprintf
           "'%s' is in the way: pyk compile writes what it generates there, \
            and this one was not made by pyk compile (it holds no %s). Move \
            it, or compile somewhere else with -o."
           build build_marker);
  Sys.mkdir build 0o755;
  let channel = open_out_bin (join build build_marker) in
  output_string channel
    "Made by pyk compile, which removes this folder and makes it again each time it compiles here.\n";
  close_out channel

(** Writes an executable file. string -> string -> () *)
let write_executable path contents =
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel;
  Unix.chmod path 0o755

(** Puts the program built into `build` where it was asked for, at exe:
    the binary itself where the target links one, and otherwise a
    launcher running what is in `build`; nothing for a page.
    string -> string -> string -> () *)
let place_executable target output_path exe =
  match Targets.family_of target with
  | Targets.C | Targets.Ocaml ->
      let built = Filename.remove_extension output_path in
      let channel = open_in_bin built in
      let contents = really_input_string channel (in_channel_length channel) in
      close_in channel;
      write_executable exe contents
  | _ -> (
      match Execution.launcher target output_path "$here/build" with
      | Some line ->
          write_executable exe
            ("#!/bin/sh\n# Made by pyk compile: runs the program compiled into build/.\n\
              here=$(dirname \"$0\")\n" ^ line ^ "\n")
      | None -> ())

(** Runs `pyk compile <file>`: translates every module of the program
    for options.target into a directory `build/` beside the executable --
    `-o` or the source's own name -- with a Makefile, builds it with the
    target's own tools, and puts the executable, or a launcher, there.
    `--run` then runs it. `--stdout` prints the program's own module and
    writes nothing; `-t pyking` writes its file where `-o` says, as one
    file. With `keep` false (`pyk <file> -t <target>`) nothing is put
    beside `build/` and the program is run from there.
    bool? -> [(Module.t, typ IntMap.t option)] -> options -> int *)
let command_compile ?(keep = true) checked options =
  let target = options.target in
  let filename = Option.get options.filename in
  if options.stdout || (target = pyking_target && keep) then begin
    let output_path =
      match (options.stdout, options.output) with
      | false, None ->
          (* Nothing said where to put it: use the source file's own
             name, with the target's extension, in the directory the
             command was run from. *)
          Some (default_name target (stem filename))
      | _, output -> output
    in
    let files, primary = compile_program checked target output_path options in
    if options.stdout then (
      print_string primary;
      0)
    else (
      write_compiled checked options files;
      if options.run then
        Execution.execute target (Option.get output_path)
          (module_files checked target (dirname (Option.get output_path)))
          options.arguments
      else 0)
  end
  else
    let exe = if keep then Option.value options.output ~default:(stem filename) else stem filename in
    let here = match dirname exe with "" -> "." | d -> d in
    if not (Sys.file_exists here && Sys.is_directory here) then
      usage_error
        (Printf.sprintf "cannot write '%s': the directory '%s' does not exist." exe here);
    if keep && List.mem (absolute exe) (List.map (fun ((unit : Module.t), _) -> absolute unit.path) checked)
    then
      usage_error
        (Printf.sprintf "writing '%s' would overwrite the program's own source; choose a different -o." exe);
    let build = join here "build" in
    let output_path = join build (default_name target (basename exe)) in
    let files, _ = compile_program checked target (Some output_path) options in
    fresh_build build;
    write_compiled checked options files;
    let modules = module_files checked target build in
    let makefile = Execution.makefile target output_path modules in
    let channel = open_out_bin (join build "Makefile") in
    output_string channel makefile;
    close_out channel;
    if options.no_build then 0
    else
      let status = Execution.build target output_path modules in
      if status <> 0 then status
      else (
        if keep then place_executable target output_path exe;
        if options.run || not keep then
          Execution.run target output_path modules options.arguments here
        else 0)

(** Runs `pyk plugins <dir>`: builds the plugin of every library in a
    directory of libraries -- each `<dir>/<name>` holding a
    `<name>_external.pyk` and a `<name>_external.ml` -- beside its
    implementation, where the interpreter looks first. A plugin already
    built from what it would be built from now is left as it is. `make
    libs` runs it over lib/. options -> int *)
let command_plugins options =
  let directory = Option.get options.filename in
  let names =
    try List.sort compare (Array.to_list (Sys.readdir directory))
    with Sys_error message -> usage_error message
  in
  List.iter
    (fun name ->
      let folder = join directory name in
      let declaration = join folder (name ^ Module.external_extension) in
      let source = join folder (name ^ "_external.ml") in
      let output = join folder (name ^ "_external.cmxs") in
      if
        Sys.is_directory folder && Sys.file_exists declaration
        && Sys.file_exists source
      then
        let unit =
          try Module.read_file declaration None with
          | Lexer.Lex_error _ as e -> fail e
          | Parser.Parse_error _ as e -> fail e
        in
        let plugin =
          {
            Plugin_host.name;
            declared = Module.external_signatures unit.stmts;
            declaration_path = declaration;
          }
        in
        if not (Plugin_host.built_from output (Plugin_host.digest plugin)) then (
          (try Plugin_host.build_plugin plugin output
           with Module.Module_error _ as e -> fail e);
          Printf.printf "plugins: %s\n" output))
    names;
  0

(** `pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve`: hands
    the process to the web
    tool's server, and answers 1 only if that could not be done.
    Web_tools.tool -> options -> int *)
let command_web tool options =
  match Web_tools.start ~warnings:options.warnings tool options.port options.mode options.filename with
  | Ok status -> status
  | Error message ->
      prerr_endline (wrap message);
      1

(** `pyk notebook --to-json`, `--to-markdown` and `--json-schema`: a
    notebook's Markdown as JSON, JSON as Markdown, or the schema of
    every notebook's JSON, written beside the notebook (the schema in the
    current directory) unless --output names a file, `-` for standard
    output. A file of the default name is not written over. options -> int *)
let command_notebook_convert options =
  let refuse message =
    prerr_endline (wrap ("pyk notebook: " ^ message));
    1
  in
  let write default text =
    let save path =
      match Out_channel.with_open_bin path (fun out -> Out_channel.output_string out text) with
      | () -> 0
      | exception Sys_error message -> refuse message
    in
    match options.output with
    | Some "-" ->
        print_string text;
        0
    | Some path -> save path
    | None when Sys.file_exists default ->
        refuse
          (Printf.sprintf
             "%s is there already, and was left as it is; --output names another file, or that one to write over it"
             default)
    | None -> save default
  in
  let read file extensions what =
    let extension = String.lowercase_ascii (Filename.extension file) in
    if not (List.mem extension extensions) then Error (Printf.sprintf "%s is not %s" file what)
    else
      match Module.read_whole_file file with
      | text -> Ok text
      | exception Sys_error _ -> Error (Printf.sprintf "no such file: %s" file)
  in
  let file = Option.value ~default:"" options.filename in
  let beside extension = Filename.remove_extension file ^ extension in
  match options.convert with
  | Some "to-json" -> (
      match read file [ ".md"; ".markdown" ] "a Markdown notebook (.md)" with
      | Error message -> refuse message
      | Ok text -> write (beside ".json") (Json.pretty (Notebook_format.of_markdown text)))
  | Some "to-markdown" -> (
      match read file [ ".json" ] "a notebook's JSON (.json)" with
      | Error message -> refuse message
      | Ok text -> (
          match Notebook_format.to_markdown (Json.parse text) with
          | markdown -> write (beside ".md") markdown
          | exception Json.Parse_error message -> refuse (Printf.sprintf "%s is not JSON: %s" file message)
          | exception Notebook_format.Format_error message ->
              refuse (Printf.sprintf "%s is not a notebook: %s" file message)))
  | _ -> write "notebook.schema.json" Notebook_format.schema

(** `pyk example`: lists the examples beside this executable, or saves
    the one named in the current directory unless a file of that name is
    there already. options -> int *)
let command_example options =
  let root = Install.root () in
  let examples =
    try Examples.read (Module.read_whole_file (join root Examples.file)) with Sys_error _ -> []
  in
  let refuse message =
    prerr_endline (wrap ("pyk example: " ^ message));
    1
  in
  match options.filename with
  | None when examples = [] -> refuse (Printf.sprintf "there are no examples in %s." (join root Examples.file))
  | None ->
      print_string (Examples.listing examples);
      print_endline "\n`pyk example <name>` saves one in the current directory.";
      0
  | Some name -> (
      match Examples.find name examples with
      | None -> refuse (Printf.sprintf "there is no example '%s'; `pyk example` lists them." name)
      | Some _ when Sys.file_exists name ->
          refuse (Printf.sprintf "'%s' is here already, and was left as it is." name)
      | Some example -> (
          match Module.read_whole_file (join root example.source) with
          | exception Sys_error message -> refuse message
          | text -> (
              match open_out_bin name with
              | exception Sys_error message -> refuse message
              | channel ->
                  output_string channel text;
                  close_out channel;
                  Printf.printf "Saved %s. Run it with: pyk %s\n" name name;
                  0)))

(** The first whole message in what has arrived, framed by a
    Content-Length header, and what follows it. string -> (string?,
    string) *)
let framed pending =
  let rec header_end i =
    if i + 3 >= String.length pending then None
    else if String.sub pending i 4 = "\r\n\r\n" then Some i
    else header_end (i + 1)
  in
  match header_end 0 with
  | None -> (None, pending)
  | Some stop -> (
      let headers = String.split_on_char '\n' (String.sub pending 0 stop) in
      let length =
        List.find_map
          (fun line ->
            match String.index_opt line ':' with
            | Some i
              when String.lowercase_ascii (String.trim (String.sub line 0 i)) = "content-length" ->
                int_of_string_opt (String.trim (String.sub line (i + 1) (String.length line - i - 1)))
            | _ -> None)
          headers
      in
      let body = stop + 4 in
      match length with
      | None -> (Some "", String.sub pending body (String.length pending - body))
      | Some n when String.length pending >= body + n ->
          (Some (String.sub pending body n), String.sub pending (body + n) (String.length pending - body - n))
      | Some _ -> (None, pending))

(** `pyk lsp`: the language server over standard input and output, until
    the editor says `exit`. Documents are checked once no message has
    arrived for 200 ms (design/lsp.md, "Debouncing"). options -> int *)
let command_lsp options =
  let log =
    Option.map
      (fun path -> open_out_gen [ Open_append; Open_creat; Open_binary ] 0o644 path)
      options.log
  in
  let note direction text =
    match log with
    | Some channel -> Printf.fprintf channel "%s %s\n%!" direction text
    | None -> ()
  in
  set_binary_mode_out stdout true;
  let send text =
    note "<--" text;
    print_string (Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length text) text);
    flush stdout
  in
  let disk = { Module.exists = Sys.file_exists; contents = Module.read_whole_file } in
  let readable timeout =
    match Unix.select [ Unix.stdin ] [] [] timeout with
    | ready, _, _ -> ready <> []
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
  in
  let chunk = Bytes.create 65536 in
  let rec loop state pending waiting =
    match Lsp.exit_code state with
    | Some code -> code
    | None -> (
        match framed pending with
        | Some "", rest -> loop state rest waiting
        | Some text, rest ->
            note "-->" text;
            let state, out = Lsp.handle state text in
            List.iter send out;
            loop state rest true
        | None, _ ->
            if readable (if waiting then 0.2 else -1.0) then
              match Unix.read Unix.stdin chunk 0 (Bytes.length chunk) with
              | 0 | (exception Unix.Unix_error _) ->
                  (* The editor went away: what `exit` would have said. *)
                  let state, _ = Lsp.handle state "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}" in
                  Option.value ~default:1 (Lsp.exit_code state)
              | n -> loop state (pending ^ Bytes.sub_string chunk 0 n) true
            else
              let state, out = Lsp.idle state in
              List.iter send out;
              loop state pending false)
  in
  let state = Lsp.create ~warnings:(warning_config options) disk (library_path options) Version.version in
  let status = try loop state "" false with error -> note "!!!" (Printexc.to_string error); 1 in
  Option.iter close_out log;
  status

(** Runs `pyk dap`, the debug adapter: Debug Adapter Protocol on standard
    input and output, over dap.ml, which this function feeds with
    messages and with slices of running. The program gets standard
    streams of its own -- what it writes goes to a file read back into
    `output` events, and what it reads is the launch's `stdin` file, or
    nothing -- so nothing it does reaches the protocol. A callback the
    host makes once the top level has ended -- tinyweb's events -- is
    debugged like the top level, in a loop of its own while the host
    waits; one made while a slice is running runs to its end unstopped.
    `state` is the one cell this function writes, since such a callback
    arrives from inside the host and has to reach the adapter as it
    stands. options -> int *)
let command_dap options =
  let log =
    Option.map
      (fun path -> open_out_gen [ Open_append; Open_creat; Open_binary ] 0o644 path)
      options.log
  in
  let note direction text =
    match log with
    | Some channel -> Printf.fprintf channel "%s %s\n%!" direction text
    | None -> ()
  in
  let protocol_in = Unix.dup Unix.stdin in
  let protocol_out = Unix.out_channel_of_descr (Unix.dup Unix.stdout) in
  set_binary_mode_out protocol_out true;
  let written_path = Filename.temp_file "pyk-dap" ".out" in
  let file = Unix.openfile written_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 file Unix.stdout;
  Unix.close file;
  let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  Unix.dup2 null Unix.stdin;
  Unix.close null;
  let written = open_in_bin written_path in
  let errors = ref [] in
  let output () =
    flush stdout;
    let available = in_channel_length written - pos_in written in
    let text = if available > 0 then really_input_string written available else "" in
    let lines = List.rev !errors in
    errors := [];
    (if text = "" then [] else [ ("stdout", text) ]) @ List.map (fun l -> ("stderr", l ^ "\n")) lines
  in
  let send text =
    note "<--" text;
    output_string protocol_out (Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length text) text);
    flush protocol_out
  in
  let quit code =
    close_in_noerr written;
    (try Sys.remove written_path with Sys_error _ -> ());
    Option.iter close_out log;
    exit code
  in
  let libs = ref (library_path options) in
  (* The report `pyk <file>` prints, each line whole: an editor's
     console wraps lines itself. *)
  let unwrapped line =
    String.concat " " (List.map String.trim (String.split_on_char '\n' line))
  in
  let report machine =
    match Interpreter.failure machine with
    | Some error -> (
        match runtime_report !libs machine error with
        | first :: calls -> String.concat "\n" (unwrapped first :: List.map (fun c -> "  " ^ unwrapped c) calls)
        | [] -> "")
    | None -> ""
  in
  let in_advance = ref false in
  let state = ref (Dap.create { Dap.start = (fun _ -> Error ""); report }) in
  let pending = ref "" in
  let chunk = Bytes.create 65536 in
  let read_more () =
    match Unix.read protocol_in chunk 0 (Bytes.length chunk) with
    | 0 | (exception Unix.Unix_error _) -> quit 0
    | n -> pending := !pending ^ Bytes.sub_string chunk 0 n
  in
  let ready descriptors timeout =
    match Unix.select descriptors [] [] timeout with
    | ready, _, _ -> ready
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> []
  in
  let finish code =
    let st, out = Dap.finish !state code output in
    state := st;
    List.iter send out
  in
  let failed error =
    (match error with
    | Interpreter.Runtime_error _ -> (
        match format_error error with Some text -> errors := !errors @ [ unwrapped text ] | None -> ())
    | error -> errors := !errors @ [ Printexc.to_string error ]);
    finish 1
  in
  let after_started = ref false in
  let rec serve until =
    (match Dap.exit_code !state with Some code -> quit code | None -> ());
    match until () with
    | Some result -> result
    | None ->
        (match framed !pending with
        | Some "", rest -> pending := rest
        | Some text, rest ->
            pending := rest;
            note "-->" text;
            let st, out = Dap.handle !state text output in
            state := st;
            List.iter send out
        | None, _ ->
            if Dap.running !state then (
              in_advance := true;
              let st, out =
                Fun.protect ~finally:(fun () -> in_advance := false) (fun () ->
                    Dap.advance !state 20000 output)
              in
              state := st;
              List.iter send out;
              if ready [ protocol_in ] 0.0 <> [] then read_more ())
            else if Dap.top_level_ended !state && not !after_started then (
              after_started := true;
              (* What a plugin asked to run once the top level ended: a
                 page's events are waited for beside the protocol, and
                 anything else is run now. *)
              if Pyk_plugin.idle_descriptors () = [] then
                match Pyk_plugin.run_after_program () with
                | () -> finish 0
                | exception error -> failed error)
            else
              let waiting =
                if !after_started && Dap.top_level_ended !state then
                  List.map (fun d : Unix.file_descr -> Obj.obj d) (Pyk_plugin.idle_descriptors ())
                else []
              in
              let found = ready (protocol_in :: waiting) 0.5 in
              if List.mem protocol_in found then read_more ();
              if List.exists (fun d -> d <> protocol_in) found then (
                match Pyk_plugin.run_idle () with () -> () | exception error -> failed error);
              let st, out = Dap.advance !state 0 output in
              state := st;
              List.iter send out);
        serve until
  in
  let drive machine =
    if !in_advance then Interpreter.run machine
    else (
      state := Dap.push_call !state machine;
      serve (fun () ->
          let st, ended = Dap.take_call !state in
          if ended <> None then state := st;
          ended))
  in
  let start arguments =
    let text name = Json.to_string_option (Json.member name arguments) in
    let flag name default = match Json.member name arguments with Json.Bool b -> b | _ -> default in
    match text "program" with
    | None | Some "" -> Error "the launch configuration names no program"
    | Some program -> (
        (match text "cwd" with
        | Some directory when directory <> "" -> ( try Sys.chdir directory with Sys_error _ -> ())
        | _ -> ());
        let more = List.filter_map Json.to_string_option (Json.to_list (Json.member "libPath" arguments)) in
        libs := library_path { options with lib_paths = options.lib_paths @ more };
        (* The launch's own -W flags go after the ones `pyk dap` was
           started with. *)
        let given = List.filter_map Json.to_string_option (Json.to_list (Json.member "warnings" arguments)) in
        match Warnings.of_flags (options.warnings @ given) with
        | Error message -> Error message
        | Ok warnings ->
        let refusal error =
          match format_error error with
          | Some text -> Error (unwrapped text)
          | None -> Error (Printexc.to_string error)
        in
        match
          let units = Module.load ~libs:!libs program in
          ( units,
            Debug_session.prepare ~release:(flag "release" false) ~warnings
              ~own:(fun (unit : Module.t) -> not (Module.in_library !libs unit.path))
              units )
        with
        | exception (Sys_error message) -> Error message
        | exception error -> refusal error
        | units, prepared -> (
            let plugins =
              List.filter_map
                (fun (unit : Module.t) ->
                  match unit.declaration_path with
                  | Some declaration_path when unit.declarations <> [] ->
                      Some
                        Plugin_host.
                          {
                            name = unit.name;
                            declared = Module.external_signatures unit.declarations;
                            declaration_path;
                          }
                  | _ -> None)
                units
            in
            match Plugin_host.load plugins with
            | exception error -> refusal error
            | () -> (
                let input =
                  match text "stdin" with
                  | None | Some "" -> Ok ()
                  | Some path -> (
                      match Unix.openfile path [ Unix.O_RDONLY ] 0 with
                      | descriptor ->
                          Unix.dup2 descriptor Unix.stdin;
                          Unix.close descriptor;
                          Ok ()
                      | exception Unix.Unix_error (e, _, _) ->
                          Error (Printf.sprintf "cannot read '%s': %s" path (Unix.error_message e)))
                in
                match input with
                | Error text -> Error text
                | Ok () ->
                    let arguments =
                      List.filter_map Json.to_string_option (Json.to_list (Json.member "args" arguments))
                    in
                    Plugin_host.set_arguments program arguments;
                    let host =
                      Interpreter.callback_host
                        ~externals:(Plugin_host.externals plugins)
                        ~debug_line:(fun line -> errors := !errors @ [ line ])
                        (fun line ->
                          print_string line;
                          print_newline ())
                    in
                    Ok
                      (Debug_session.create
                         ~stop_on_entry:(flag "stopOnEntry" false)
                         ~just_my_code:(flag "justMyCode" true)
                         ~is_library:(Module.in_library !libs) ~drive prepared host))))
  in
  state := Dap.create { Dap.start; report };
  match serve (fun () -> None) with
  | () -> quit 0
  | exception error ->
      note "!!!" (Printexc.to_string error);
      quit 1

(* --- pyk highlight --- *)

let highlight_usage =
  "Usage: pyk highlight <file> [options]\n\n\
   Writes Pyking code coloured as the playground colours it, as text a\n\
   slide program such as Keynote pastes and keeps as text: HTML with\n\
   every style inline, RTF, or plain text. <file> is a program (.pyk) or\n\
   a notebook (.md, or .json as `pyk notebook --to-json` writes it).\n\n\
   Options:\n\
  \  --html | --rtf | --text   the format (default: --html)\n\
  \  --theme light|dark        the playground's light or dark colours\n\
  \                            (default: light)\n\
  \  --font NAME               the font (default: Menlo; HTML falls back\n\
  \                            to monospace)\n\
  \  --size PT                 the size in points (default: the\n\
  \                            application's)\n\
  \  --background none|theme|#rrggbb\n\
  \                            behind the text: nothing (default), the\n\
  \                            theme's background, or a colour\n\
  \  --spaces indent|all|none  leading spaces as non-breaking spaces\n\
  \                            (default), every space outside a\n\
  \                            string, or none: a PDF\n\
  \                            keeps non-breaking ones when copied\n\
  \  -o, --output FILE         write it to FILE (default: standard output)\n\n\
   For a notebook, every ```pyking block counts, numbered from 1 in the\n\
   order written:\n\
  \  --notebook split          one file per block, <book>-<N>.html (or\n\
  \                            .rtf, .txt), in --output-dir (default:\n\
  \                            beside the notebook)\n\
  \  --notebook page           every block, without the prose\n\
  \  --notebook whole          the notebook, its prose rendered as its\n\
  \                            page renders it (HTML needs node)\n\
  \  --block N                 only block N, on standard output unless\n\
  \                            --output names a file\n\
  \  --output-dir DIR          where split writes its files"

(** What `pyk highlight` was asked: the file, the format, the options,
    and for a notebook the mode, the block and where it writes. *)
type highlight_request = {
  hl_file : string option;
  hl_format : string option;  (* "html", "rtf" or "text" *)
  hl_options : Highlight.options;
  hl_output : string option;
  hl_notebook : string option;  (* "split", "page" or "whole" *)
  hl_block : int option;
  hl_output_dir : string option;
}

(** `pyk highlight`: a program or a notebook's Pyking blocks, coloured.
    Every refusal is one line, `pyk highlight: ...`, and status 1.
    [string] -> int *)
let command_highlight argv =
  let exception Refused of string in
  let refuse message = raise (Refused message) in
  let ok = function Ok v -> v | Error message -> refuse message in
  let rec parse request = function
    | [] -> request
    | ("--help" | "-h") :: _ ->
        print_endline highlight_usage;
        exit 0
    | (("--html" | "--rtf" | "--text") as flag) :: rest ->
        let format = String.sub flag 2 (String.length flag - 2) in
        (match request.hl_format with
        | Some given when given <> format ->
            refuse (Printf.sprintf "--%s and --%s each say what is written, so only one may be given" given format)
        | _ -> ());
        parse { request with hl_format = Some format } rest
    | (("--theme" | "--font" | "--size" | "--background" | "--spaces" | "--output" | "-o" | "--notebook"
       | "--block" | "--output-dir") as flag)
      :: rest -> (
        match rest with
        | [] -> refuse (Printf.sprintf "%s needs a value" flag)
        | value :: rest ->
            let o = request.hl_options in
            let request =
              match flag with
              | "--theme" -> { request with hl_options = { o with theme = ok (Highlight.parse_theme flag value) } }
              | "--font" -> { request with hl_options = { o with font = ok (Highlight.parse_font flag value) } }
              | "--size" -> { request with hl_options = { o with size = Some (ok (Highlight.parse_size flag value)) } }
              | "--background" ->
                  { request with hl_options = { o with background = ok (Highlight.parse_background flag value) } }
              | "--spaces" -> { request with hl_options = { o with spaces = ok (Highlight.parse_spaces flag value) } }
              | "--output" | "-o" -> { request with hl_output = Some value }
              | "--notebook" ->
                  if List.mem value [ "split"; "page"; "whole" ] then { request with hl_notebook = Some value }
                  else refuse (Printf.sprintf "--notebook is split, page or whole, not '%s'" value)
              | "--block" -> (
                  match int_of_string_opt value with
                  | Some n when n >= 1 && String.for_all (fun c -> c >= '0' && c <= '9') value ->
                      { request with hl_block = Some n }
                  | _ -> refuse (Printf.sprintf "--block is a block's number, counted from 1, not '%s'" value))
              | _ -> { request with hl_output_dir = Some value }
            in
            parse request rest)
    | flag :: _ when String.length flag > 1 && flag.[0] = '-' ->
        refuse (Printf.sprintf "there is no option '%s'; `pyk highlight --help` lists them" flag)
    | file :: rest -> (
        match request.hl_file with
        | Some _ -> refuse "takes one file"
        | None -> parse { request with hl_file = Some file } rest)
  in
  let run () =
    let request =
      parse
        {
          hl_file = None;
          hl_format = None;
          hl_options = Highlight.default_options;
          hl_output = None;
          hl_notebook = None;
          hl_block = None;
          hl_output_dir = None;
        }
        argv
    in
    let file =
      match request.hl_file with
      | Some file -> file
      | None -> refuse "names no file; `pyk highlight --help` says what it takes"
    in
    let format = Option.value ~default:"html" request.hl_format in
    let options = request.hl_options in
    let extension = match format with "rtf" -> ".rtf" | "text" -> ".txt" | _ -> ".html" in
    let read () =
      match Module.read_whole_file file with
      | text -> text
      | exception Sys_error _ -> refuse (Printf.sprintf "no such file: %s" file)
    in
    let write path text =
      match path with
      | None | Some "-" -> print_string text
      | Some path -> (
          match Out_channel.with_open_bin path (fun out -> Out_channel.output_string out text) with
          | () -> ()
          | exception Sys_error message -> refuse message)
    in
    let snippet source =
      match format with
      | "rtf" -> Highlight.rtf options source
      | "text" -> Highlight.text options source
      | _ -> Highlight.html options source ^ "\n"
    in
    let kind = String.lowercase_ascii (Filename.extension file) in
    if kind = ".pyk" then (
      if request.hl_notebook <> None then refuse (Printf.sprintf "--notebook says how a notebook is written, and %s is a program" file);
      if request.hl_block <> None then refuse (Printf.sprintf "--block picks a notebook's block, and %s is a program" file);
      if request.hl_output_dir <> None then refuse (Printf.sprintf "--output-dir is where a notebook's blocks are written, and %s is a program" file);
      write request.hl_output (snippet (read ())))
    else if List.mem kind [ ".md"; ".markdown"; ".json" ] then (
      let text = read () in
      let markdown =
        if kind <> ".json" then text
        else
          match Notebook_format.to_markdown (Json.parse text) with
          | markdown -> markdown
          | exception Json.Parse_error message -> refuse (Printf.sprintf "%s is not JSON: %s" file message)
          | exception Notebook_format.Format_error message -> refuse (Printf.sprintf "%s is not a notebook: %s" file message)
      in
      let pieces = Highlight.notebook_pieces markdown in
      let blocks = Highlight.notebook_blocks markdown in
      let count = List.length blocks in
      if count = 0 then refuse (Printf.sprintf "%s has no pyking blocks" file);
      let mode = Option.value ~default:"split" request.hl_notebook in
      if request.hl_output_dir <> None && (mode <> "split" || request.hl_block <> None) then
        refuse "--output-dir is where --notebook split writes one file per block";
      match request.hl_block with
      | Some n ->
          if n > count then
            refuse
              (Printf.sprintf "--block %d: %s has %d pyking block%s, numbered from 1" n file count
                 (if count = 1 then "" else "s"));
          write request.hl_output (snippet (List.nth blocks (n - 1)).Highlight.source)
      | None -> (
          let book = Filename.remove_extension (Filename.basename file) in
          match mode with
          | "split" ->
              if request.hl_output <> None then
                refuse "--notebook split writes one file per block, so --output-dir names where, not --output";
              let directory = Option.value ~default:(Filename.dirname file) request.hl_output_dir in
              if not (Sys.file_exists directory && Sys.is_directory directory) then
                refuse (Printf.sprintf "no such directory: %s" directory);
              List.iter
                (fun (b : Highlight.block) ->
                  let path = Filename.concat directory (Printf.sprintf "%s-%d%s" book b.number extension) in
                  write (Some path) (snippet b.source);
                  print_endline ("Wrote " ^ path))
                blocks
          | "page" ->
              let codes = List.filter (function Highlight.Code _ -> true | _ -> false) pieces in
              write request.hl_output
                (match format with
                | "rtf" -> Highlight.rtf_document options codes
                | "text" -> Highlight.text_document options codes
                | _ -> Highlight.html_snippets options codes)
          | _ -> (
              match format with
              | "rtf" -> write request.hl_output (Highlight.rtf_document options pieces)
              | "text" -> write request.hl_output (Highlight.text_document options pieces)
              | _ ->
                  let html, title = ok (Web_tools.render_markdown (Highlight.marked_markdown pieces)) in
                  let theme = if options.theme = Highlight.Dark then "dark" else "light" in
                  let body =
                    Printf.sprintf
                      "<div class=\"pkn-notebook\" data-theme=\"%s\">\n<main class=\"pkn-main\">\n<div class=\"pkn-prose\">\n%s</div>\n</main>\n</div>\n"
                      theme
                      (Highlight.fill_markers options pieces html)
                  in
                  write request.hl_output
                    (Highlight.html_page ~title:(if title = "" then book else title)
                       ~style:(Web_tools.notebook_stylesheet ()) body))))
    else refuse (Printf.sprintf "%s is neither a Pyking program (.pyk) nor a notebook (.md, or .json)" file)
  in
  match run () with
  | () -> 0
  | exception Refused message ->
      prerr_endline (wrap ("pyk highlight: " ^ message));
      1

(** Runs every command but `pyk highlight`, whose options are its own.
    [string] -> int *)
let run_command argv =
  let options = parse_args argv in
  (* tinyweb's implementation reads this when its plugin is loaded, and
     prints its log on stderr as well (lib/tinyweb/tinyweb_external.ml). *)
  if options.tinyweb_log then Unix.putenv "PYKING_TINYWEB_TRACE" "1";
  if options.command = "repl" then
    Repl.start ~libs:(library_path options) ~features:options.uses
      ~warnings:(warning_config options)
      ~warning:(fun line -> prerr_endline (wrap line))
      format_error
  else if options.command = "plugins" then command_plugins options
  else if options.command = "notebook" && options.convert <> None then command_notebook_convert options
  else if options.command = "notebook" then command_web Web_tools.Notebook options
  else if options.command = "playground" then command_web Web_tools.Playground options
  else if options.command = "pykhelp" then command_web Web_tools.Help options
  else if options.command = "serve" then command_web Web_tools.Files options
  else if options.command = "lsp" then command_lsp options
  else if options.command = "dap" then command_dap options
  else if options.command = "example" then command_example options
  else if options.command = default_command && options.target_given then
    (* `pyk <file> -t <target>`: compiled into build/ and run from there,
       with nothing put beside it. *)
    let options = { options with command = "compile"; run = true } in
    command_compile ~keep:false (front_end options) options
  else
    let checked = front_end options in
    if options.command = "compile" then command_compile checked options
    else command_interpret ~libs:(library_path options) checked options.arguments

(** Runs pyk. [string] -> int *)
let main argv =
  match argv with
  | "highlight" :: rest -> command_highlight rest
  | _ -> run_command argv

let () = exit (main (List.tl (Array.to_list Sys.argv)))
