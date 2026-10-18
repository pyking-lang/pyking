(** What `--run` runs: the commands each target's host uses to build and
    run what `pyk compile` wrote. One table, so the driver stays a
    sequencer and each target's toolchain is stated in one place.
    See docs/pyk.md ("Running what was
    compiled").

    The commands are the ones a user would type by hand, and each is
    printed before it runs -- to stderr, so a program's own output on
    stdout stays its own. The toolchain is taken from the environment
    where there is a choice about it: $CC, $JAVAC, $JAVA and $OCAMLOPT.

    Data structures:
      plan -- the commands one target needs, and where to run them.

    Functions:
      plan_for target path modules -- the commands that build and run
        path, given the program's other files in dependency order.
      execute target path modules -- runs them; answers the program's
        status. *)

(* Where there is a choice of tool, the environment makes it -- the same
   names tests/test_script.py reads, so a machine set up for one is set
   up for the other. *)
let from_environment name fallback =
  match Sys.getenv_opt name with Some value when value <> "" -> value | _ -> fallback

let c_compiler () = from_environment "CC" "cc"
let java_compiler () = from_environment "JAVAC" "javac"
let java_runtime () = from_environment "JAVA" "java"

(* Plain `ocamlopt`: nothing here needs a package, and `ocamlfind` adds a
   dependency on a working ld.conf for no gain. Split, since an override
   may still be more than one word. *)
let ocaml_compiler () =
  List.filter (fun w -> w <> "")
    (String.split_on_char ' ' (from_environment "OCAMLOPT" "ocamlopt"))

let pyking_target = "pyking"

(* What `--run` serves a page on, the port `pyk serve` starts at.
   The server refuses to start if it is taken, which is the right answer:
   silently choosing another port would print an address for a server
   somebody else is running. *)
let web_port = "8000"

(** The commands one target needs to turn its output into a running
    program: the ones run first, each of which must succeed; the program
    itself; where to run them; and a line to print before running, for a
    target whose "run" is a server rather than the program -- there the
    address of the page is what a reader actually needs. *)
type plan = {
  build : string list list;
  run : string list;
  directory : string;
  note : string option;
}

(** The commands that build and run what was compiled to path. `modules`
    names the other files the program was compiled to, in the order they
    must be built and run -- dependencies first -- which is what the
    targets that link a program rather than importing at run time need.
    `arguments` is what the program itself is passed, after any the host
    needs to be told.
    string -> string -> [string] -> [string] -> plan *)
let plan_for target path modules arguments =
  (* Everything is made absolute, since the commands run in the output
     file's own directory rather than the one `pyk` was called from. *)
  let path = Module.absolute path in
  let directory = Module.dirname path in
  let binary = Filename.remove_extension path in
  let others = List.map Module.absolute modules in
  if Targets.family_of target = Targets.Python then
    { build = []; run = ([ "python3"; path ] @ arguments); directory; note = None }
  else if target = pyking_target then
    (* The interpreter, reached the way this process was: `pyking`
       compiles to Pyking, and what runs Pyking is this compiler. *)
    (* `--` before the program's own arguments, since this host is a
       compiler and would otherwise read them as its own. *)
    let passed = if arguments = [] then [] else "--" :: arguments in
    { build = []; run = ([ Sys.executable_name; path ] @ passed); directory; note = None }
  else if Targets.family_of target = Targets.Node then
    { build = []; run = ([ "node"; path ] @ arguments); directory; note = None }
  else if List.mem (Targets.family_of target) [ Targets.Web; Targets.Iweb ] then
    (* A page of ES modules has to be *served*: a browser refuses a
       module fetched over file://. So `--run` serves the page with this
       executable's own server (`pyk serve`), which serves its directory
       and prints the page's own address, and leaves it running, which
       is what looking at the page needs. *)
    {
      build = [];
      run = [ Sys.executable_name; "serve"; "--port"; web_port; path ];
      directory;
      note = None;
    }
  else if Targets.family_of target = Targets.C then
    (* Every translation unit of the program, the modules first: each is
       a file of its own, and `main` is in the last. `-lm` after them,
       for the math library's functions, which a Linux C library keeps
       in libm. *)
    {
      build =
        [
          [ c_compiler (); "-std=" ^ target; "-o"; binary ]
          @ others @ [ path; "-lm" ];
        ];
      run = ([ binary ] @ arguments);
      directory;
      note = None;
    }
  else if Targets.family_of target = Targets.Java then
    (* Java's class is its file's name, which is what the compiler
       already made sure of when it chose that name. *)
    let class_name = Filename.remove_extension (Filename.basename path) in
    let release =
      String.sub target 4 (String.length target - 4)
    in
    {
      build =
        [
          [ java_compiler (); "--release"; release; "-d"; directory ]
          @ others
          @ [ Filename.concat directory Target_java.runtime_file; path ];
        ];
      run = ([ java_runtime (); "-cp"; directory; class_name ] @ arguments);
      directory;
      note = None;
    }
  else if Targets.family_of target = Targets.Ocaml then
    (* OCaml links in the order given, and runs each module's top level
       in that order, which is why the modules come first: a module runs
       after everything it imports. An interface is named ahead of the
       implementation it describes. *)
    let sources =
      List.concat_map
        (fun other ->
          let interface =
            Filename.remove_extension other ^ Target_ocaml.interface_extension
          in
          if Sys.file_exists interface then [ interface; other ] else [ other ])
        others
    in
    {
      build =
        [
          (* `unix` is linked for every program on this target. Nothing
             the compiler *generates* needs it, but an external module's
             implementation may -- lib/sys/sys_external.ml does, since
             nothing in OCaml's Stdlib enumerates the environment -- and
             it ships with the compiler, so there is no dependency to
             install. It is named before the modules that use it,
             because OCaml links in the order it is given. *)
          ocaml_compiler ()
          @ [ "-I"; "+unix"; "unix.cmxa"; "-I"; directory; "-o"; binary ]
          @ sources @ [ path ];
        ];
      run = ([ binary ] @ arguments);
      directory;
      note = None;
    }
  else invalid_arg target

(** One word as a shell would need it written, so a printed command can
    be pasted back. string -> string *)
let shell_quote word =
  let safe c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    || String.contains "@%+=:,./-_" c
  in
  if word <> "" && String.for_all safe word then word
  else
    let buffer = Buffer.create (String.length word + 2) in
    Buffer.add_char buffer '\'';
    String.iter
      (fun c ->
        if c = '\'' then Buffer.add_string buffer "'\"'\"'"
        else Buffer.add_char buffer c)
      word;
    Buffer.add_char buffer '\'';
    Buffer.contents buffer

(** One command as it is announced: a word naming something in the
    directory the command runs in is shortened to what a user standing
    there would type -- `.` for the directory itself, and `./name` where
    the name is the program being run, since a bare name would be looked
    up on PATH. [string] -> string -> string *)
let shown command directory =
  let inside = directory ^ Filename.dir_sep in
  let word text first =
    if text = directory then "."
    else if (not (Filename.is_relative text)) && Filename.dirname text = directory
    then (if first then "./" else "") ^ Filename.basename text
    else if
      (not (Filename.is_relative text))
      && String.length text > String.length inside
      && String.sub text 0 (String.length inside) = inside
    then
      (if first then "./" else "")
      ^ String.sub text (String.length inside) (String.length text - String.length inside)
    else text
  in
  String.concat " "
    (List.mapi (fun index text -> shell_quote (word text (index = 0))) command)

(** Announces one command and runs it. [string] -> string -> int *)
let run_command command directory =
  Printf.eprintf "$ %s\n" (shown command directory);
  flush stderr;
  match command with
  | [] -> 0
  | program :: _ -> (
      match Unix.fork () with
      | 0 -> (
          (* In the child: everything from here either becomes the
             program or exits. *)
          try
            Unix.chdir directory;
            Unix.execvp program (Array.of_list command)
          with _ ->
            Printf.eprintf "pyk: '%s' not found\n" program;
            flush stderr;
            exit 127)
      | pid -> (
          match snd (Unix.waitpid [] pid) with
          | Unix.WEXITED code -> code
          | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal))

(** Runs what builds what was compiled to path, each command printed
    first, in the directory it was compiled into. Answers 0, or the
    status of the step that failed. string -> string -> [string] -> int *)
let build target path modules =
  let plan = plan_for target path modules [] in
  let rec go commands =
    match commands with
    | [] -> 0
    | command :: rest ->
        let status = run_command command plan.directory in
        if status <> 0 then status else go rest
  in
  go plan.build

(** Runs the program built from path, printed first, in `directory`,
    passing it `arguments`. Answers its status.
    string -> string -> [string] -> [string] -> string -> int *)
let run target path modules arguments directory =
  let plan = plan_for target path modules arguments in
  (match plan.note with
  | Some note -> Printf.eprintf "  %s\n%!" note
  | None -> ());
  run_command plan.run (Module.absolute directory)

(** The shell line a launcher runs the program compiled to path with,
    where the target builds no binary and is no page: its host, named by
    the variable a shell may override, and the file it is handed, under
    `here`. None for the other targets.
    string -> string -> string -> string? *)
let launcher target path here =
  let relative = Filename.concat here (Filename.basename path) in
  match Targets.family_of target with
  | Targets.Python -> Some (Printf.sprintf "exec \"${PYTHON:-python3}\" \"%s\" \"$@\"" relative)
  | Targets.Node -> Some (Printf.sprintf "exec \"${NODE:-node}\" \"%s\" \"$@\"" relative)
  | Targets.Java ->
      Some
        (Printf.sprintf "exec \"${JAVA:-java}\" -cp \"%s\" %s \"$@\"" here
           (Filename.remove_extension (Filename.basename path)))
  | _ -> None

(** A Makefile for the directory path was compiled into, saying with the
    commands `--run` uses how to build the program (`make`), run it
    (`make run`, with `ARGS`) and remove what `make` made (`make clean`).
    Each tool is a variable the command line may set.
    string -> string -> [string] -> string *)
let makefile target path modules =
  let plan = plan_for target path modules [] in
  let directory = plan.directory in
  let local word =
    if word = directory then "."
    else if (not (Filename.is_relative word)) && Module.dirname word = directory then
      Filename.basename word
    else word
  in
  let ocaml = ocaml_compiler () in
  (* A command's tool as the variable naming it, and its other words as
     a shell reads them. *)
  let line command =
    let tool, rest =
      match command with
      | first :: rest when first = c_compiler () -> ("$(CC)", rest)
      | first :: rest when first = java_compiler () -> ("$(JAVAC)", rest)
      | first :: rest when first = java_runtime () -> ("$(JAVA)", rest)
      | "python3" :: rest -> ("$(PYTHON)", rest)
      | "node" :: rest -> ("$(NODE)", rest)
      | first :: rest when first = Sys.executable_name -> ("$(PYK)", rest)
      | words
        when List.length words >= List.length ocaml
             && List.filteri (fun i _ -> i < List.length ocaml) words = ocaml ->
          ("$(OCAMLOPT)", List.filteri (fun i _ -> i >= List.length ocaml) words)
      | first :: rest -> ("./" ^ local first, rest)
      | [] -> ("", [])
    in
    "\t" ^ String.concat " " (tool :: List.map (fun w -> shell_quote (local w)) rest)
  in
  let binary = Filename.remove_extension (Filename.basename path) in
  let sources = List.map (fun p -> local (Module.absolute p)) (modules @ [ path ]) in
  let built, product, clean =
    match Targets.family_of target with
    | Targets.C -> (true, binary, [ binary ])
    | Targets.Ocaml -> (true, binary, [ binary; "*.cmi"; "*.cmx"; "*.o" ])
    | Targets.Java -> (true, binary ^ ".class", [ "*.class" ])
    | _ -> (false, "", [])
  in
  let recipes = List.map line plan.build @ [ line plan.run ] in
  let tools =
    List.filter
      (fun (variable, _) ->
        List.exists
          (fun recipe ->
            let needle = "$(" ^ variable ^ ")" in
            let n = String.length needle in
            let rec at i = i + n <= String.length recipe && (String.sub recipe i n = needle || at (i + 1)) in
            at 0)
          recipes)
      [
        ("CC", c_compiler ());
        ("OCAMLOPT", String.concat " " ocaml);
        ("JAVAC", java_compiler ());
        ("JAVA", java_runtime ());
        ("PYTHON", "python3");
        ("NODE", "node");
        ("PYK", shell_quote Sys.executable_name);
      ]
  in
  String.concat "\n"
    ([
       Printf.sprintf "# Made by `pyk compile -t %s`: `make` builds the program, `make run`" target;
       "# runs it (`make run ARGS='a b'` passes it arguments), and `make clean`";
       "# removes what `make` made. The next `pyk compile` replaces this folder.";
       "";
     ]
    @ List.map (fun (variable, value) -> variable ^ " ?= " ^ value) tools
    @ [ ""; (if built then "all: " ^ product else "all:"); "" ]
    @ (if built then
         [ product ^ ": " ^ String.concat " " sources ]
         @ List.map line plan.build @ [ "" ]
       else [])
    @ [ "run: all"; line plan.run ^ " $(ARGS)"; "" ]
    @ [ "clean:"; (if clean = [] then "\t@true" else "\trm -f " ^ String.concat " " clean); "" ]
    @ [ ".PHONY: all run clean"; "" ])

(** Builds and runs what was compiled to path, printing each command
    before it runs. `modules` names the program's other files, in the
    order they must be built. Answers the program's exit status, or that
    of the build step that failed.
    `arguments` is passed to the program itself.
    string -> string -> [string] -> [string] -> int *)
let execute target path modules arguments =
  let plan = plan_for target path modules arguments in
  (* Printed before the command, on stderr like the commands themselves,
     since a served page's address is not something the server says. *)
  (match plan.note with
  | Some note -> Printf.eprintf "  %s\n%!" note
  | None -> ());
  let rec build commands =
    match commands with
    | [] -> run_command plan.run plan.directory
    | command :: rest ->
        let status = run_command command plan.directory in
        if status <> 0 then status else build rest
  in
  build plan.build
