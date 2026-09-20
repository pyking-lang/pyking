(** Turns source text into a list of tokens. Also defines info, the
    source-position type every later stage (parser, analyses, type
    checker) attaches to its own nodes. See docs/architecture.md for
    the pipeline this feeds into and the indentation rules.

    The scanning itself is private: `lexing` is the whole of what a
    caller does with this module, and the character classes, the
    escape decoding and the literal bound it enforces are its own.

    Data structures:
      info -- a source span (file, row1, col1, row2, col2).
      Lex_error -- a lexical failure, with the source position.
      token -- the token ADT; one constructor per kind (below).

    Functions:
      lexing file chars -- lexes a character list into a list of tokens.
      chars_of_string s -- a string as the character list `lexing` reads.
      token_info tok -- the source span a token carries.
      pprint_token tok -- formats one token for display.
      pprint_info info -- formats a source span as 'file' row:col-row:col.
      keywords -- every reserved word, for an editor or a page that
        highlights Pyking. *)

(** A source span. Rows count from 1, columns from 0. *)
type info = {
  file : string;
  row1 : int;
  col1 : int;
  row2 : int;
  col2 : int;
}

(** A lexical failure, with the source position. *)
exception Lex_error of info * string

(* One constructor per token kind, each carrying its source info. *)
type token =
  | TokInt of info * int
  | TokFloat of info * float
  | TokString of info * string
  | TokAdd of info (* '+' user defined *)
  | TokConcat of info (* '++' (string and list concatenation) *)
  | TokSub of info (* '-' user defined *)
  | TokArrow of info (* '->' (single-expression `case` clause) *)
  | TokFatArrow of info (* '=>' (lambda: `x => x + 1`) *)
  | TokMul of info (* '*' user defined *)
  | TokDiv of info (* '/' user defined *)
  | TokLessThanEq of info (* '<=' *)
  | TokLessThan of info (* '<' *)
  | TokGreatThanEq of info (* '>=' *)
  | TokGreatThan of info (* '>' *)
  | TokEqEq of info (* '==' *)
  | TokColon of info (* ':' *)
  | TokIndent of info (* start of an indented scope *)
  | TokDedent of info (* end of an indented scope *)
  | TokEq of info (* '=' *)
  | TokLParen of info (* '(' *)
  | TokRParen of info (* ')' *)
  | TokDot of info (* '.' *)
  | TokDotDot of info (* '..' (list-pattern "rest" marker: `..`/`..name`) *)
  | TokComma of info (* ',' *)
  | TokLBracket of info (* '[' *)
  | TokRBracket of info (* ']' *)
  | TokDef of info (* 'def' *)
  | TokReturn of info (* 'return' *)
  | TokFor of info (* 'for' *)
  | TokIn of info (* 'in' *)
  | TokIf of info (* 'if' *)
  | TokWhile of info (* 'while' *)
  | TokLoop of info (* 'loop' (accumulator loop: `loop x = e:`) *)
  | TokBreak of info (* 'break' (ends the enclosing `loop`) *)
  | TokContinue of info (* 'continue' (next turn of the enclosing `loop`) *)
  | TokThen of info (* 'then' (if expression: `if e then e else e`) *)
  | TokElse of info (* 'else' *)
  | TokVar of info (* 'var' *)
  | TokPublic of info (* 'public' (module export marker) *)
  | TokImport of info (* 'import' *)
  | TokFrom of info (* 'from' (`from module import name`) *)
  | TokAs of info (* 'as' (renaming an import) *)
  | TokMatch of info (* 'match' *)
  | TokCase of info (* 'case' *)
  | TokAssign of info (* ':=' (mutation of a `var`) *)
  | TokTypeInt of info (* 'Int' (type annotation) *)
  | TokTypeFloat of info (* 'Float' (type annotation) *)
  | TokTypeString of info (* 'String' (type annotation) *)
  | TokTypeBool of info (* 'Bool' (type annotation) *)
  | TokTrue of info (* 'true' (boolean literal) *)
  | TokFalse of info (* 'false' (boolean literal) *)
  | TokIdent of info * string

(** The source span a token carries. token -> info *)
val token_info : token -> info

(** Formats one token for display, as `--tokens` prints it.
    token -> string *)
val pprint_token : token -> string

(** Formats a source span. info -> string *)
val pprint_info : info -> string

(** Every word the lexer reserves. [string] *)
val keywords : string list

(** A string as the character list the lexer reads. string -> [char] *)
val chars_of_string : string -> char list

(** Lexes a character list into a list of tokens, attributing every one
    of them to `file`. Raises Lex_error on the first character that
    cannot start a token, on a bad string escape, on an integer literal
    too large to hold, and on an indentation that matches no enclosing
    block. string -> [char] -> [token] *)
val lexing : string -> char list -> token list
