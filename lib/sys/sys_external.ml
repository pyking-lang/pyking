(* The OCaml implementation of the names declared in sys_external.pyk.
   OCaml's own module name comes from this file's name, which is what
   the generated code refers to.

   Every standard-library name here is written `Stdlib.`-qualified, and
   has to be: a Pyking module compiles to an OCaml module of the same
   name, so a program importing `sys` puts a module `Sys` in the same
   directory as this file, and an unqualified `Sys.argv` would resolve
   to that one.

   `Sys.argv` is the standard library's, but enumerating the environment
   is not: nothing in Stdlib lists it, so this file uses `Unix`, and the
   OCaml target links it (docs/target_ocaml.md, "Linking unix"). *)

let variables =
  lazy
    (Stdlib.List.filter_map
       (fun entry ->
         match Stdlib.String.index_opt entry '=' with
         | None -> None
         | Some at ->
             Some
               ( Stdlib.String.sub entry 0 at,
                 Stdlib.String.sub entry (at + 1)
                   (Stdlib.String.length entry - at - 1) ))
       (Stdlib.Array.to_list (Unix.environment ())))

(* argv.(0) is the program itself; a program's own arguments start at 1. *)
let args () =
  Stdlib.Array.to_list
    (Stdlib.Array.sub Stdlib.Sys.argv 1 (Stdlib.Array.length Stdlib.Sys.argv - 1))

let env () = Stdlib.Lazy.force variables
let prog_name () = Stdlib.Filename.basename Stdlib.Sys.argv.(0)

let prog_path () =
  let path = Stdlib.Sys.argv.(0) in
  let directory = Stdlib.Filename.dirname path in
  if Stdlib.Filename.is_relative directory then
    Stdlib.Filename.concat (Stdlib.Sys.getcwd ()) directory
  else directory

(* `exit` writes out every channel before the process ends. Its type is
   the declared `(Int) -> ()` rather than Stdlib.exit's own, which says it
   never returns -- a statement after a call to it would be a warning. *)
let exit (code : int) : unit = Stdlib.exit code
