(** The standard library's externals, implemented for the interpreter.
    A library under lib/ reaches the host through an external module,
    which has no Pyking body; a compiled program reaches the target's
    own file, and an interpreted one reaches this. See
    docs/libraries.md.

    Only the modules named here are implemented. Any other external
    module is still refused before a program runs, in pyk.ml, which is
    what stops a folder named `fs` on a `-L` path from being answered by
    this file instead of by the file that resolved.

    This module is in the executable rather than the library because it
    reads files, the clock and the environment, and nothing in the
    library half may (see docs/build.md).

    Functions:
      implements name -- whether an external module is implemented here.
      externals program arguments -- the implementations, as the
        interpreter's own record. *)

(** The external modules implemented here, in the order the libraries
    are documented. Each is the declaration half of one library under
    lib/. [string] *)
let modules = [ "fs"; "sys"; "time" ]

(** Whether an external module is one this host can answer for.
    string -> bool *)
let implements name = List.mem name modules

(* Where a refusal from this side of the boundary is reported. A host
   operation is not written anywhere in the program, so there is no span
   to point at -- the same arrangement typesystem.ml uses for the type
   of a builtin. *)
let host_info =
  { Lexer.file = "<host>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** Raises the Pyking runtime error a host operation asked for something
    it cannot do. string -> 'a *)
let trap message = raise (Interpreter.Trap (host_info, message))

(** The refusal for a call this module has no implementation for, which
    is a mismatch between a declaration under lib/ and this file rather
    than anything a program did. string -> string -> [value] -> 'a *)
let unknown module_ field args =
  trap
    (Printf.sprintf
       "'%s.%s' is not implemented for the interpreter (%d argument%s)"
       module_ field (List.length args)
       (if List.length args = 1 then "" else "s"))

(* --- reading the environment ---
   Read once, into a list, so that a name and its value always agree
   about which index they are: `environment_name` and
   `environment_value` are two calls, and nothing may change between
   them. *)

let variables =
  lazy
    (List.filter_map
       (fun entry ->
         match String.index_opt entry '=' with
         | None -> None
         | Some at ->
             Some
               ( String.sub entry 0 at,
                 String.sub entry (at + 1) (String.length entry - at - 1) ))
       (Array.to_list (Unix.environment ())))

(* --- the filesystem ---
   Reading a file that is not there is undefined
   (lib/fs/fs.external.pyk), and the empty string is this host's version
   of undefined, exactly as it is in the compiled implementations: there
   is no value in Pyking that means "no file". *)

let read_text path =
  try Module.read_whole_file path with Sys_error _ -> ""

let write_text path text =
  try
    let channel = open_out_bin path in
    output_string channel text;
    close_out channel
  with Sys_error _ -> ()

let file_exists path =
  try Sys.file_exists path && not (Sys.is_directory path)
  with Sys_error _ -> false

(* --- the clock ---
   UTC on every host, which is what lets one program print the same
   characters whichever target ran it (lib/time/time.external.pyk).
   `gmtime`, never `localtime`. *)

let parts instant = Unix.gmtime (float_of_int instant)

(** The absolute directory a path names a file in, which is what
    `sys.prog_path` answers with. string -> string *)
let directory_of path =
  let directory = Filename.dirname path in
  if Filename.is_relative directory then
    Filename.concat (Sys.getcwd ()) directory
  else directory

(** The implementations, as the interpreter's own record. `program` is
    the file `pyk` was asked to run, and `arguments` what followed `--`
    on the command line -- the program's own, never this compiler's.
    string -> [string] -> Interpreter.externals *)
let externals program arguments =
  let string_arg module_ field args =
    match args with
    | [ Interpreter.VString text ] -> text
    | _ -> unknown module_ field args
  in
  let int_arg module_ field args =
    match args with
    | [ Interpreter.VInt n ] -> n
    | _ -> unknown module_ field args
  in
  Interpreter.
    {
      (* None of the three libraries declares a value: every name in
         them is a function, so there is nothing to ask for here. *)
      field =
        (fun module_ field ->
          trap
            (Printf.sprintf "'%s.%s' is not a value this host provides" module_
               field));
      call =
        (fun module_ field args ->
          (* A call with no arguments arrives with none. *)
          let none = args = [] || args = [ VUnit ] in
          match (module_, field) with
          | "fs", "read_text" ->
              VString (read_text (string_arg module_ field args))
          | "fs", "write_text" -> (
              match args with
              | [ VString path; VString text ] ->
                  write_text path text;
                  VUnit
              | _ -> unknown module_ field args)
          | "fs", "exists" ->
              VBool (file_exists (string_arg module_ field args))
          | "sys", "args" when none ->
              VList (List.map (fun a -> VString a) arguments)
          | "sys", "env" when none ->
              VList
                (List.map
                   (fun (name, value) -> VTuple [ VString name; VString value ])
                   (Lazy.force variables))
          | "sys", "prog_name" when none -> VString (Filename.basename program)
          | "sys", "prog_path" when none ->
              VString (directory_of program)
          | "time", "instant" when none -> VInt (int_of_float (Unix.time ()))
          | "time", "now" when none ->
              let at = parts (int_of_float (Unix.time ())) in
              VTuple
                [
                  VInt (at.tm_year + 1900);
                  VInt (at.tm_mon + 1);
                  VInt at.tm_mday;
                  VInt at.tm_hour;
                  VInt at.tm_min;
                  VInt at.tm_sec;
                ]
          | "time", "year_of" ->
              VInt ((parts (int_arg module_ field args)).tm_year + 1900)
          | "time", "month_of" ->
              VInt ((parts (int_arg module_ field args)).tm_mon + 1)
          | "time", "day_of" ->
              VInt (parts (int_arg module_ field args)).tm_mday
          | "time", "hour_of" ->
              VInt (parts (int_arg module_ field args)).tm_hour
          | "time", "minute_of" ->
              VInt (parts (int_arg module_ field args)).tm_min
          | "time", "second_of" ->
              VInt (parts (int_arg module_ field args)).tm_sec
          | _ -> unknown module_ field args);
    }
