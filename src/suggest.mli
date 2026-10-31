(** "Did you mean": the name a misspelled one was most likely meant to
    be, out of the names that were there to be meant. One rule for every
    message that offers one -- the parser's for a misspelled keyword,
    the checker's for an unbound name, the language server's quick fix
    -- so they never disagree about what is close.

    Functions:
      distance a b -- the edits that make a into b.
      near name -- how many edits a name may be from what it meant.
      closest name candidates -- the candidates near name, closest
        first. *)

val distance : string -> string -> int
(** The edits that make a into b: a character inserted, removed or
    changed, or two neighbours swapped. String -> String -> Int *)

val near : string -> int
(** How many edits a name may be from the one it was meant to be.
    String -> Int *)

val closest : string -> string list -> string list
(** The candidates near name, closest first, name itself left out.
    String -> [String] -> [String] *)
