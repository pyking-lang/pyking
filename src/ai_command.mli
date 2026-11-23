(** `pyk ai`: what a coding assistant reads to write Pyking -- the short
    guide, the language reference and the standard library as plain
    text, from share/help/ai/ (tools/help/aidoc.py) -- printed on
    standard output, or put in a project by `pyk ai init`. See
    sitesrc/documentation/ai.md.

    Functions:
      run argv -- runs `pyk ai ARGV...`, answering the exit code. *)

(** Runs `pyk ai` with the words after it, printing what was asked for
    or why it was refused, and answers the exit code: 0, or 1 where it
    was refused. string list -> int *)
val run : string list -> int
