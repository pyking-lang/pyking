(** tinyweb's splash screen, called where a program would otherwise
    start a sound no browser lets it play: a program any of whose
    modules can call tinyweb's `play` or `play_file` gets a call to
    `tinyweb.splash()` as the last statement of its own top level. See
    docs/libraries.md, "The splash screen".

    Functions:
      program name file modules main -- the main module's statements,
        with the call added where the program can play. *)

(** The main module's statements, with `tinyweb.splash()` added as the
    last of them where any module of the program can play a sound -- and
    an import of tinyweb first where the main module has no plain one.
    `modules` is every module of the program by name, the main one among
    them, and `file` the main module's path.
    string -> string -> [(string, [stmt])] -> [stmt] -> [stmt] *)
val program :
  string ->
  string ->
  (string * Syntax.stmt list) list ->
  Syntax.stmt list ->
  Syntax.stmt list
