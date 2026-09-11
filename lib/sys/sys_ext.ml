(* The OCaml implementation of the Pyking module declared in
   sys_ext.external.pyk. OCaml's own module name comes from this file's
   name, which is what the generated code refers to.

   Every standard-library name here is written `Stdlib.`-qualified, and
   has to be: a Pyking module compiles to an OCaml module of the same
   name, so a program importing the `sys` library puts a module `Sys` in
   the same directory as this file. An unqualified `Sys.argv` then
   resolves to *that* one -- which has no `argv` -- as soon as its
   `.cmi` is on the include path. `Array` and `List` are shadowable the
   same way by a Pyking module named `array` or `list`.

   `Sys.argv` is the standard library's, but enumerating the environment
   is not: nothing in Stdlib lists it, so this file uses `Unix`, and the
   OCaml target links it (see docs/target_ocaml.md, "Linking unix").

   Both lists are read once, so that a name and its value always agree
   about which index they are: `environment_name` and
   `environment_value` are two calls, and nothing may change between
   them. *)

(* argv.(0) is the program itself; a program's own arguments start at 1. *)
let arguments =
  lazy
    (Stdlib.Array.to_list
       (Stdlib.Array.sub Stdlib.Sys.argv 1
          (Stdlib.Array.length Stdlib.Sys.argv - 1)))

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

let argument_count () = Stdlib.List.length (Stdlib.Lazy.force arguments)
let argument i = Stdlib.List.nth (Stdlib.Lazy.force arguments) i
let program () = Stdlib.Sys.argv.(0)
let environment_count () = Stdlib.List.length (Stdlib.Lazy.force variables)

let environment_name i =
  Stdlib.fst (Stdlib.List.nth (Stdlib.Lazy.force variables) i)

let environment_value i =
  Stdlib.snd (Stdlib.List.nth (Stdlib.Lazy.force variables) i)
