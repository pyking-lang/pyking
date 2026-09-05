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

(* Opening a page is the one "run" that hands the file to something else
   entirely, and the two systems spell it differently. This is the
   directory only macOS has, since OCaml cannot ask for the platform's
   name. *)
let browser () =
  if Sys.file_exists "/System/Library/CoreServices" then "open" else "xdg-open"

let pyking_target = "pyking"

(** The commands one target needs to turn its output into a running
    program: the ones run first, each of which must succeed; the program
    itself; and where to run them. *)
type plan = { build : string list list; run : string list; directory : string }

(** The commands that build and run what was compiled to path. `modules`
    names the other files the program was compiled to, in the order they
    must be built and run -- dependencies first -- which is what the
    targets that link a program rather than importing at run time need.
    string -> string -> [string] -> plan *)
let plan_for target path modules =
  (* Everything is made absolute, since the commands run in the output
     file's own directory rather than the one `pyk` was called from. *)
  let path = Module.absolute path in
  let directory = Module.dirname path in
  let binary = Filename.remove_extension path in
  let others = List.map Module.absolute modules in
  if target = "python" then { build = []; run = [ "python3"; path ]; directory }
  else if target = pyking_target then
    (* The interpreter, reached the way this process was: `pyking`
       compiles to Pyking, and what runs Pyking is this compiler. *)
    { build = []; run = [ Sys.executable_name; path ]; directory }
  else if target = "nodejs" then { build = []; run = [ "node"; path ]; directory }
  else if target = "esm" then
    (* The generated driver is the file a user would run: it imports the
       module and supplies it a runtime. *)
    { build = []; run = [ "node"; binary ^ ".node.js" ]; directory }
  else if target = "html" then { build = []; run = [ browser (); path ]; directory }
  else if List.mem target Target_c.standards then
    (* Every translation unit of the program, the modules first: each is
       a file of its own, and `main` is in the last. *)
    {
      build =
        [
          [ c_compiler (); "-std=" ^ target; "-o"; binary ] @ others @ [ path ];
        ];
      run = [ binary ];
      directory;
    }
  else if List.mem target Target_java.versions then
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
          @ others @ [ path ];
        ];
      run = [ java_runtime (); "-cp"; directory; class_name ];
      directory;
    }
  else if target = Target_ocaml.target then
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
          ocaml_compiler () @ [ "-I"; directory; "-o"; binary ] @ sources @ [ path ];
        ];
      run = [ binary ];
      directory;
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
  let word text first =
    if text = directory then "."
    else if (not (Filename.is_relative text)) && Filename.dirname text = directory
    then (if first then "./" else "") ^ Filename.basename text
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

(** Builds and runs what was compiled to path, printing each command
    before it runs. `modules` names the program's other files, in the
    order they must be built. Answers the program's exit status, or that
    of the build step that failed.
    string -> string -> [string] -> int *)
let execute target path modules =
  let plan = plan_for target path modules in
  let rec build commands =
    match commands with
    | [] -> run_command plan.run plan.directory
    | command :: rest ->
        let status = run_command command plan.directory in
        if status <> 0 then status else build rest
  in
  build plan.build
