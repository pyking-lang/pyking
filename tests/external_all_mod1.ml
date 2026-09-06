(* The OCaml implementation of the Pyking module declared in
   external_all_mod1.external.pyk. OCaml's own module name comes from
   this file's name, which is what the generated code refers to. An Int
   is an int, and nothing here narrows a result: past the signed 32-bit
   range Pyking leaves the answer undefined. *)

let shout s = s ^ "!"
let twice n = n * 2
let flip b = not b
let origin = 0
let greeting = "hello"
