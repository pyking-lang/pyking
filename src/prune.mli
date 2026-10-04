(** What a program uses of the modules it imports: every module but the
    program's own with the definitions nothing reaches taken out, and
    every import narrowed to the names the importing module uses. Run by
    pyk.ml for the C and Java targets. See docs/modules.md, "What a
    program uses".

    Functions:
      program units -- every module of a program, dependencies first,
        with what the program does not use removed. *)

(** Every module of a program, dependencies first and the program's own
    last, with the definitions nothing reaches removed from each module
    it imports and every import narrowed to what is used of it.
    [(Module.t, 'a)] -> [(Module.t, 'a)] *)
val program : (Module.t * 'a) list -> (Module.t * 'a) list
