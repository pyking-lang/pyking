(** Recursive-descent parser: tokens (from lexer.ml) to the AST defined
    in syntax.ml. Also enforces the handful of grammar rules that cannot
    be expressed in EBNF -- duplicate pattern captures, value-form
    if/match branches, one statement per line, and where a
    'break'/'continue' may stand. See PYKING.md for the grammar.

    One function is public. Every non-terminal is a function of its own
    inside, each threading the token list and the end-of-input position
    -- the position to blame when there is no next token to blame -- but
    a caller parses a program, not a fragment of one: the REPL, the
    module system and the playground all reach this module through
    `parse` alone.

    Data structures:
      Parse_error -- a parse failure, with the source position.

    Functions:
      parse tokens -- parses a full token stream into a list of
        statements. *)

(** A syntax failure, with the source position. *)
exception Parse_error of Lexer.info * string

(** Parses a full token stream into a list of top-level statements.
    Raises Parse_error for a token that cannot stand where it does and
    for the grammar rules above -- including where the input simply ran
    out, which is what a prompt reads to know an entry is unfinished
    (see repl.ml's `incomplete_reasons`). [token] -> [stmt] *)
val parse : Lexer.token list -> Syntax.stmt list
