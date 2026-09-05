(* The OCaml implementation of the Pyking module declared in
   external_all_mod1.external.pyk. OCaml's own module name comes from
   this file's name, which is what the generated code refers to. An Int
   is an int; the 32-bit wrap is the implementation's to keep. *)

let shout s = s ^ "!"
let twice n = Int32.to_int (Int32.of_int (n * 2))
let flip b = not b
let origin = 0
let greeting = "hello"
