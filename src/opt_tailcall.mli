(** Tail-call optimization: Pyking AST in, Pyking AST out. A function
    that calls itself in tail position becomes a `loop` carrying its own
    parameters, and a group of functions that tail-call each other
    becomes one worker carrying a state tag. Runs for every mode unless
    --no-tail-call-opt is given, so every backend and the interpreter
    get it at once. See docs/optimization.md.

    It runs *after* the type checker and only on a program the checker
    accepted, which is what makes the rewrite safe to leave unchecked:
    the types decide which groups can be merged, and give the value a
    padded slot is entered with. See docs/optimization.md for what
    counts as a tail call, what is deliberately left alone, and why one
    check is enough.

    One function is public, and that is the whole point of the pass:
    what it produces is ordinary Pyking, so no backend and not the
    interpreter knows this module exists.

    Functions:
      optimize stmts tmap -- the whole program, tail calls rewritten,
        with the type table extended for what was built. *)

(** A whole program with its tail calls rewritten, and the checker's
    table extended for the nodes that rewriting built. Never rejects: a
    program it cannot improve comes back as it was.
    [stmt] -> typ IntMap.t -> ([stmt], typ IntMap.t) *)
val optimize :
  Syntax.stmt list ->
  Syntax.typ Syntax.IntMap.t ->
  Syntax.stmt list * Syntax.typ Syntax.IntMap.t
