(** The spelling rules for a qualified name: `int::leq`, the name an
    overloaded definition is given. A qualified name is one identifier
    that happens to hold a `::`, so this is the only place one is taken
    apart -- the lexer, the parser, the type checker and `elaborate.ml`
    all ask here rather than each splitting a string of its own.
    See docs/overloading.md.

    Functions:
      separator -- the two characters a qualifier is joined with.
      is_qualified name -- whether a name carries a qualifier.
      qualifier name -- the part before the `::`, where there is one.
      base name -- the part after it, or the whole name.
      renamed name -- the plain name a qualified one compiles to.
      field name -- the part of a dotted name after the module. *)

(* The two characters that join a qualifier to a base name. *)
let separator = "::"

(** Where the separator is in name, if it is. string -> int option *)
let position name =
  let width = String.length separator in
  let rec at i =
    if i + width > String.length name then None
    else if String.sub name i width = separator then Some i
    else at (i + 1)
  in
  at 0

(** Whether this name carries a qualifier. String -> Bool *)
let is_qualified name = position name <> None

(** The qualifier, where there is one. String -> String? *)
let qualifier name =
  match position name with Some i -> Some (String.sub name 0 i) | None -> None

(** The name without its qualifier, which is the whole of an unqualified
    one. String -> String *)
let base name =
  match position name with
  | Some i ->
      let start = i + String.length separator in
      String.sub name start (String.length name - start)
  | None -> name

(** The plain name a qualified one compiles to. `elaborate.ml` renames
    every definition and every reference to it, so no backend and not
    the interpreter ever sees a `::`. A program that also binds this
    name is refused there. String -> String *)
let renamed name =
  match position name with
  | Some i ->
      let start = i + String.length separator in
      String.sub name 0 i ^ "__"
      ^ String.sub name start (String.length name - start)
  | None -> name

(** The part of a dotted name after the module it is reached through --
    `int::leq` of `mod.int::leq`, and the whole of a name with no dot.
    String -> String *)
let field name =
  match String.rindex_opt name '.' with
  | Some i -> String.sub name (i + 1) (String.length name - i - 1)
  | None -> name
