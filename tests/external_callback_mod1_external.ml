(* A Pyking function is an OCaml function, curried; `later` runs its
   callback at exit. *)

let each f n =
  for i = 0 to n - 1 do
    f i
  done

let with_float f x = f (x *. 2.)
let with_pair f n s = f (n + 1) (s ^ "!")
let later f = at_exit f
