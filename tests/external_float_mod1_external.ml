(* The OCaml implementation of the Pyking module declared in
   external_float_mod1.external.pyk. A Pyking Float is an OCaml float,
   so the arithmetic here is OCaml's own float operators. *)

let halve x = x /. 2.0
let hypot_sq a b = (a *. a) +. (b *. b)
let widen n = float_of_int n
let epsilon = 0.5
