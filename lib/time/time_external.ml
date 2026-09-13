(* The OCaml implementation of the names declared in time.external.pyk.
   OCaml's own module name comes from this file's name, which is what
   the generated code refers to.

   Every standard-library name here is written `Stdlib.`-qualified, and
   has to be: a Pyking module compiles to an OCaml module of the same
   name, so a program importing `time` puts a module `Time` in the same
   directory as this file.

   Nothing in Stdlib reads the clock as a calendar, so this file uses
   `Unix`, and the OCaml target links it (docs/target_ocaml.md,
   "Linking unix"). Decomposition is UTC: `gmtime`, never `localtime`. *)

let instant () = Stdlib.int_of_float (Unix.time ())
let parts t = Unix.gmtime (Stdlib.float_of_int t)

(* One reading of the clock, decomposed in one go, so the six fields
   cannot straddle a second. Unix counts months from 0 and years from
   1900; Pyking writes them as a reader does. *)
let now () =
  let p = parts (instant ()) in
  ( p.Unix.tm_year + 1900,
    p.Unix.tm_mon + 1,
    p.Unix.tm_mday,
    p.Unix.tm_hour,
    p.Unix.tm_min,
    p.Unix.tm_sec )

let year_of t = (parts t).Unix.tm_year + 1900
let month_of t = (parts t).Unix.tm_mon + 1
let day_of t = (parts t).Unix.tm_mday
let hour_of t = (parts t).Unix.tm_hour
let minute_of t = (parts t).Unix.tm_min
let second_of t = (parts t).Unix.tm_sec
