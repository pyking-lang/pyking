(* A Pyking tuple is an OCaml tuple, and a list is a list. *)

let split s = (s, String.length s > 1)
let counts n = [ n; n + 1 ]
