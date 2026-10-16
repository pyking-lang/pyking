(* The OCaml implementation of the names declared in math_external.pyk.
   OCaml's own module name comes from this file's name, which is what
   the generated code refers to.

   Every standard-library name here is written `Stdlib.`-qualified, as
   in the other libraries: a Pyking module compiles to an OCaml module
   of the same name, so a program importing `math` puts a module `Math`
   beside this file. *)

let host_sin = Stdlib.Float.sin
let host_cos = Stdlib.Float.cos
let host_tan = Stdlib.Float.tan
let host_asin = Stdlib.Float.asin
let host_acos = Stdlib.Float.acos
let host_atan = Stdlib.Float.atan
let host_atan2 = Stdlib.Float.atan2
let host_sinh = Stdlib.Float.sinh
let host_cosh = Stdlib.Float.cosh
let host_tanh = Stdlib.Float.tanh
let host_exp = Stdlib.Float.exp
let host_log = Stdlib.Float.log
let host_log2 = Stdlib.Float.log2
let host_log10 = Stdlib.Float.log10
let host_sqrt = Stdlib.Float.sqrt
let host_cbrt = Stdlib.Float.cbrt
let host_pow = Stdlib.Float.pow
let host_hypot = Stdlib.Float.hypot
let host_floor = Stdlib.Float.floor
let host_ceil = Stdlib.Float.ceil
let host_trunc = Stdlib.Float.trunc
