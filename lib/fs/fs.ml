(* The OCaml implementation of the Pyking module declared in
   fs.external.pyk. OCaml's own module name comes from this file's name,
   which is what the generated code refers to.

   `Sys` is written `Stdlib.Sys`, and has to be: a Pyking module
   compiles to an OCaml module of the same name, so a program importing
   the `sys` library alongside this one puts a module `Sys` in the same
   directory, and an unqualified `Sys.file_exists` would resolve to
   *that* one. *)

(* Reading a file that is not there is undefined (fs.external.pyk), and
   the empty string is this host's version of undefined: there is no
   value in Pyking that means "no file". *)
let read_text filename =
  try
    let channel = open_in_bin filename in
    let contents = really_input_string channel (in_channel_length channel) in
    close_in channel;
    contents
  with Sys_error _ -> ""

let write_text filename text =
  try
    let channel = open_out_bin filename in
    output_string channel text;
    close_out channel
  with Sys_error _ -> ()

let exists filename = Stdlib.Sys.file_exists filename && not (Stdlib.Sys.is_directory filename)
