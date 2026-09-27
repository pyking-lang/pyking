(** `pyk notebook` and `pyk playground`: finds the web tool beside this
    executable, checks that a new enough Python is installed, and hands
    the process over to the tool's own Python server. Nothing here serves
    a page; tools/webrun/server.py does. See docs/build.md ("The web
    tools").

    Data structures:
      tool -- which web tool.

    Functions:
      start tool port document -- replaces this process with the tool's
        server, or answers why it could not. *)

type tool = Notebook | Playground

(** The oldest Python the web tools run on. (int, int) *)
let minimum_python = (3, 14)

(** The tool's name, as its directory and its script are called.
    tool -> string *)
let name tool = match tool with Notebook -> "notebook" | Playground -> "playground"

(** The tool's script: tools/<name>/<name>.py beside this executable,
    which is where both a checkout and a distribution keep it.
    tool -> string *)
let script tool =
  let root = Install.root () in
  Module.join (Module.join (Module.join root "tools") (name tool)) (name tool ^ ".py")

(** The Python to run: $PYTHON, else the platform's usual name for it.
    () -> string *)
let python () =
  match Sys.getenv_opt "PYTHON" with
  | Some p when p <> "" -> p
  | _ -> if Sys.win32 then "python" else "python3"

(** The version `program` reports as (major, minor), or None when it
    could not be run or answered something else. string -> (int, int)? *)
let python_version program =
  match
    Unix.open_process_args_in program
      [| program; "-c"; "import sys; print('%d %d' % sys.version_info[:2])" |]
  with
  | exception Unix.Unix_error _ -> None
  | channel -> (
      let line = try Some (input_line channel) with End_of_file -> None in
      let status = Unix.close_process_in channel in
      match (line, status) with
      | Some line, Unix.WEXITED 0 -> (
          try Scanf.sscanf line "%d %d" (fun major minor -> Some (major, minor))
          with Scanf.Scan_failure _ | Failure _ | End_of_file -> None)
      | _ -> None)

let start tool port document =
  let command = "pyk " ^ name tool in
  let path = script tool in
  let program = python () in
  let wanted = Printf.sprintf "%d.%d" (fst minimum_python) (snd minimum_python) in
  if not (Sys.file_exists path) then
    Printf.sprintf
      "%s: the web tools are not installed beside this executable (there is \
       no %s). They ship with pyk as tools/ next to it."
      command path
  else
    match python_version program with
    | None ->
        Printf.sprintf
          "%s needs Python %s or later, and '%s' could not be run. Install \
           Python, or name one with $PYTHON."
          command wanted program
    | Some version when version < minimum_python ->
        Printf.sprintf
          "%s needs Python %s or later, and '%s' is Python %d.%d. Install a \
           newer one, or name it with $PYTHON."
          command wanted program (fst version) (snd version)
    | Some _ -> (
        let port =
          match port with Some p -> [ "--port"; string_of_int p ] | None -> []
        in
        let arguments =
          match tool with
          | Playground -> [ "serve" ] @ port
          | Notebook -> port @ Option.to_list document
        in
        (* Flushed, since whatever is buffered is lost when the process
           is replaced. *)
        flush stdout;
        flush stderr;
        try Unix.execvp program (Array.of_list ((program :: path :: arguments)))
        with Unix.Unix_error (error, _, _) ->
          Printf.sprintf "%s: could not start %s: %s" command program
            (Unix.error_message error))
