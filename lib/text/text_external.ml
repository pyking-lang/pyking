(* The OCaml implementation of the names declared in text_external.pyk.
   OCaml's own module name comes from this file's name, which is what
   the generated code refers to.

   A string is UTF-8 bytes, so a position in code points is found by
   walking from the start: a code point begins at every byte that is not
   a continuation byte (10xxxxxx).

   Every standard-library name here is written `Stdlib.`-qualified, as
   in the other libraries: a Pyking module compiles to an OCaml module
   of the same name, so a program importing `text` puts a module `Text`
   beside this file. *)

let continues s i = Stdlib.Char.code (Stdlib.String.get s i) land 0xC0 = 0x80

(* The byte position of code point `k`, counting from byte `from`. *)
let rec bytes s from k =
  if k = 0 || from >= Stdlib.String.length s then from
  else
    let rec next i =
      if i < Stdlib.String.length s && continues s i then next (i + 1) else i
    in
    bytes s (next (from + 1)) (k - 1)

(* The number of code points in the bytes before `stop`. *)
let points s stop =
  let rec go i n = if i >= stop then n else go (i + 1) (if continues s i then n else n + 1) in
  go 0 0

let host_length s = points s (Stdlib.String.length s)

let host_slice s start stop =
  let i = bytes s 0 start in
  Stdlib.String.sub s i (bytes s i (stop - start) - i)

(* The first byte position at or after `from` where `part` begins, or -1. *)
let search s part from =
  let n = Stdlib.String.length s and m = Stdlib.String.length part in
  let rec matches i j = j >= m || (Stdlib.String.get s (i + j) = Stdlib.String.get part j && matches i (j + 1)) in
  let rec go i = if i + m > n then -1 else if matches i 0 then i else go (i + 1) in
  go from

let host_find s part start =
  let i = search s part (bytes s 0 start) in
  if i < 0 then -1 else points s i

let host_code s k =
  let d = Stdlib.String.get_utf_8_uchar s (bytes s 0 k) in
  Stdlib.Uchar.to_int (Stdlib.Uchar.utf_decode_uchar d)

let host_from_code n =
  let out = Stdlib.Buffer.create 4 in
  Stdlib.Buffer.add_utf_8_uchar out (Stdlib.Uchar.of_int n);
  Stdlib.Buffer.contents out

let host_replace s old by =
  let out = Stdlib.Buffer.create (Stdlib.String.length s) in
  let m = Stdlib.String.length old in
  let rec go from =
    let i = search s old from in
    if i < 0 then Stdlib.Buffer.add_substring out s from (Stdlib.String.length s - from)
    else (
      Stdlib.Buffer.add_substring out s from (i - from);
      Stdlib.Buffer.add_string out by;
      go (i + m))
  in
  go 0;
  Stdlib.Buffer.contents out

let host_upper = Stdlib.String.uppercase_ascii
let host_lower = Stdlib.String.lowercase_ascii
