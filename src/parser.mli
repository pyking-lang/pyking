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
        statements.
      parse_with enabled tokens -- the same, with features already on.
      uses tokens -- the features a module's `use` lines turn on.
      features -- every feature `use` may name. *)

(** A syntax failure, with the source position. *)
exception Parse_error of Lexer.info * string

(** Parses a full token stream into a list of top-level statements.
    Raises Parse_error for a token that cannot stand where it does and
    for the grammar rules above -- including where the input simply ran
    out, which is what a prompt reads to know an entry is unfinished
    (see repl.ml's `incomplete_reasons`). [token] -> [stmt] *)
val parse : Lexer.token list -> Syntax.stmt list

(** Parses a module whose session already has features on -- a REPL's,
    turned on by an earlier entry's `use` -- answering the features this
    text's own `use` lines turn on beside its statements. `parse` is this
    with none on. [string] -> [token] -> ([string], [stmt]) *)
val parse_with : string list -> Lexer.token list -> string list * Syntax.stmt list

(** The features a module's leading `use` lines name, read from its
    tokens alone; [] where they do not parse. [token] -> [string] *)
val uses : Lexer.token list -> string list

(** The `use` lines those features are written back as, one a line,
    for a printed program. [token] -> string *)
val use_lines : Lexer.token list -> string

(** Every feature a `use` line may name. [string] *)
val features : string list
