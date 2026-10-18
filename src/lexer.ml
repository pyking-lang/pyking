(** Turns source text into a list of tokens. Also defines info, the
    source-position type every later stage (parser, analyses, type
    checker) attaches to its own nodes.
    See docs/architecture.md for the pipeline this feeds into and the
    indentation rules.

    Data structures:
      info -- a source span (file, row1, col1, row2, col2).
      Lex_error -- a lexical failure, with the source position.
      token -- the token ADT; one constructor per kind (below).

    Functions:
      lexing file chars -- lexes a character list into a list of tokens.
      pprint_info info -- formats a source span as 'file' row:col-row:col.
      pprint_token tok -- formats one token for display.
      keyword_token name info -- the keyword token for a reserved word.
      string_until pred chars -- splits off the longest prefix matching pred.
      scan_string file r c quote chars -- reads a string literal body.
      is_digit x / is_letter x / is_digit_letter x -- character classes.
      token_info tok -- the source span a token carries.
      chars_of_string s -- a string as the character list the lexer reads. *)

(* --- info --- *)

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

(** Formats a source span. info -> string *)
let pprint_info i =
  Printf.sprintf "'%s' %d:%d-%d:%d" i.file i.row1 i.col1 i.row2 i.col2

(* --- token ADT --- *)

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
  | TokBar of info (* '|' (or-pattern: `case 1 | 2:`) *)
  | TokLBracket of info (* '[' *)
  | TokRBracket of info (* ']' *)
  | TokDef of info (* 'def' *)
  | TokDatatype of info (* 'datatype' (an algebraic data type) *)
  | TokStruct of info (* 'struct' (a datatype of one constructor) *)
  | TokReturn of info (* 'return' *)
  | TokFor of info (* 'for' *)
  | TokIn of info (* 'in' *)
  | TokIf of info (* 'if' *)
  | TokWhile of info (* 'while' *)
  | TokLoop of info (* 'loop' (accumulator loop: `loop x = e:`) *)
  | TokBreak of info (* 'break' (ends the enclosing `loop`) *)
  | TokContinue of info (* 'continue' (next turn of the enclosing `loop`) *)
  | TokThen of info (* 'then' (if expression: `if e then e else e`) *)
  | TokLet of info (* 'let' (let expression: `let x = e in e`) *)
  | TokElse of info (* 'else' *)
  | TokVar of info (* 'var' *)
  | TokPublic of info (* 'public' (module export marker) *)
  | TokImplicit of info (* 'implicit' (an implicit definition or parameter) *)
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
let token_info tok =
  match tok with
  | TokInt (i, _) -> i
  | TokFloat (i, _) -> i
  | TokString (i, _) -> i
  | TokAdd i -> i
  | TokConcat i -> i
  | TokSub i -> i
  | TokArrow i -> i
  | TokFatArrow i -> i
  | TokMul i -> i
  | TokDiv i -> i
  | TokLessThanEq i -> i
  | TokLessThan i -> i
  | TokGreatThanEq i -> i
  | TokGreatThan i -> i
  | TokEqEq i -> i
  | TokColon i -> i
  | TokIndent i -> i
  | TokDedent i -> i
  | TokEq i -> i
  | TokLParen i -> i
  | TokRParen i -> i
  | TokDot i -> i
  | TokDotDot i -> i
  | TokComma i -> i
  | TokBar i -> i
  | TokLBracket i -> i
  | TokRBracket i -> i
  | TokDef i -> i
  | TokDatatype i -> i
  | TokStruct i -> i
  | TokReturn i -> i
  | TokFor i -> i
  | TokIn i -> i
  | TokIf i -> i
  | TokWhile i -> i
  | TokLoop i -> i
  | TokBreak i -> i
  | TokContinue i -> i
  | TokThen i -> i
  | TokLet i -> i
  | TokElse i -> i
  | TokVar i -> i
  | TokPublic i -> i
  | TokImplicit i -> i
  | TokImport i -> i
  | TokFrom i -> i
  | TokAs i -> i
  | TokMatch i -> i
  | TokCase i -> i
  | TokAssign i -> i
  | TokTypeInt i -> i
  | TokTypeFloat i -> i
  | TokTypeString i -> i
  | TokTypeBool i -> i
  | TokTrue i -> i
  | TokFalse i -> i
  | TokIdent (i, _) -> i

(** Formats one token for display. token -> string *)
let pprint_token tok =
  match tok with
  | TokInt (_, x) -> Printf.sprintf "TokInt(%d)" x
  | TokFloat (_, x) -> Printf.sprintf "TokFloat(%s)" (Builtin.float_text x)
  | TokString (_, s) -> Printf.sprintf "TokString('%s')" s
  | TokAdd _ -> "TokAdd"
  | TokConcat _ -> "TokConcat"
  | TokSub _ -> "TokSub"
  | TokArrow _ -> "TokArrow"
  | TokFatArrow _ -> "TokFatArrow"
  | TokMul _ -> "TokMul"
  | TokDiv _ -> "TokDiv"
  | TokLessThanEq _ -> "TokLessThanEq"
  | TokLessThan _ -> "TokLessThan"
  | TokGreatThanEq _ -> "TokGreatThanEq"
  | TokGreatThan _ -> "TokGreatThan"
  | TokEqEq _ -> "TokEqEq"
  | TokColon _ -> "TokColon"
  | TokIndent _ -> "TokIndent"
  | TokDedent _ -> "TokDedent"
  | TokEq _ -> "TokEq"
  | TokLParen _ -> "TokLParen"
  | TokRParen _ -> "TokRParen"
  | TokDot _ -> "TokDot"
  | TokDotDot _ -> "TokDotDot"
  | TokComma _ -> "TokComma"
  | TokBar _ -> "TokBar"
  | TokLBracket _ -> "TokLBracket"
  | TokRBracket _ -> "TokRBracket"
  | TokDef _ -> "TokDef"
  | TokDatatype _ -> "TokDatatype"
  | TokStruct _ -> "TokStruct"
  | TokReturn _ -> "TokReturn"
  | TokFor _ -> "TokFor"
  | TokIn _ -> "TokIn"
  | TokIf _ -> "TokIf"
  | TokWhile _ -> "TokWhile"
  | TokLoop _ -> "TokLoop"
  | TokBreak _ -> "TokBreak"
  | TokContinue _ -> "TokContinue"
  | TokThen _ -> "TokThen"
  | TokLet _ -> "TokLet"
  | TokElse _ -> "TokElse"
  | TokVar _ -> "TokVar"
  | TokPublic _ -> "TokPublic"
  | TokImplicit _ -> "TokImplicit"
  | TokImport _ -> "TokImport"
  | TokFrom _ -> "TokFrom"
  | TokAs _ -> "TokAs"
  | TokMatch _ -> "TokMatch"
  | TokCase _ -> "TokCase"
  | TokAssign _ -> "TokAssign"
  | TokTypeInt _ -> "TokTypeInt"
  | TokTypeFloat _ -> "TokTypeFloat"
  | TokTypeString _ -> "TokTypeString"
  | TokTypeBool _ -> "TokTypeBool"
  | TokTrue _ -> "TokTrue"
  | TokFalse _ -> "TokFalse"
  | TokIdent (_, s) -> Printf.sprintf "TokIdent('%s')" s

(* --- lexer --- *)

(** Whether x is one decimal digit. char -> bool *)
let is_digit x = x >= '0' && x <= '9'

(** Whether x is a letter or underscore. char -> bool *)
let is_letter x =
  x = '_' || (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z')

(** Whether x is a digit, letter, or underscore. char -> bool *)
let is_digit_letter x = is_digit x || is_letter x

(* The largest integer literal a program may write. A negative literal
   is unary minus applied to one of these, so the lower bound needs no
   constant of its own: -2147483648 is `-` on 2147483648, which this
   refuses, and PYKING.md says so. *)
let max_int_literal = 2147483647

let keywords =
  [
    "for"; "in"; "if"; "while"; "loop"; "break"; "continue"; "then"; "let";
    "else"; "var"; "def"; "return"; "match"; "case"; "public"; "implicit";
    "import";
    "from"; "as"; "datatype"; "struct"; "Int"; "Float"; "String"; "Bool"; "true"; "false";
  ]

(** The keyword token `name` denotes, or None where it names no keyword.
    string -> info -> token option *)
let keyword_token name i =
  match name with
  | "for" -> Some (TokFor i)
  | "in" -> Some (TokIn i)
  | "if" -> Some (TokIf i)
  | "while" -> Some (TokWhile i)
  | "loop" -> Some (TokLoop i)
  | "break" -> Some (TokBreak i)
  | "continue" -> Some (TokContinue i)
  | "then" -> Some (TokThen i)
  | "let" -> Some (TokLet i)
  | "else" -> Some (TokElse i)
  | "var" -> Some (TokVar i)
  | "def" -> Some (TokDef i)
  | "return" -> Some (TokReturn i)
  | "match" -> Some (TokMatch i)
  | "case" -> Some (TokCase i)
  | "public" -> Some (TokPublic i)
  | "implicit" -> Some (TokImplicit i)
  | "import" -> Some (TokImport i)
  | "from" -> Some (TokFrom i)
  | "as" -> Some (TokAs i)
  | "datatype" -> Some (TokDatatype i)
  | "struct" -> Some (TokStruct i)
  | "Int" -> Some (TokTypeInt i)
  | "Float" -> Some (TokTypeFloat i)
  | "String" -> Some (TokTypeString i)
  | "Bool" -> Some (TokTypeBool i)
  | "true" -> Some (TokTrue i)
  | "false" -> Some (TokFalse i)
  | _ -> None

(** A character list as a string. [char] -> string *)
let string_of_chars chars = String.of_seq (List.to_seq chars)

(** A string as the character list the lexer reads. string -> [char] *)
let chars_of_string s = List.of_seq (String.to_seq s)

(** Splits off the longest prefix of chars matching pred.
    (char -> bool) -> [char] -> (string, [char]) *)
let string_until pred chars =
  let rec take taken rest =
    match rest with
    | x :: xs when pred x -> take (x :: taken) xs
    | _ -> (string_of_chars (List.rev taken), rest)
  in
  take [] chars

(** The fractional part of a float literal, or "" where there is none.
    A point needs a digit on each side, so `1.` is an Int followed by a
    point and `x.field` is never read as a number.
    [char] -> (string, [char]) *)
let scan_fraction chars =
  match chars with
  | '.' :: y :: _ when is_digit y ->
      let digits, rest = string_until is_digit (List.tl chars) in
      ("." ^ digits, rest)
  | _ -> ("", chars)

(** The exponent of a float literal, or "" where there is none. An `e`
    with no digits after it is not one, so `1e` is an Int followed by a
    name. [char] -> (string, [char]) *)
let scan_exponent chars =
  match chars with
  | (('e' | 'E') as marker) :: after -> (
      match after with
      | (('+' | '-') as sign) :: y :: _ when is_digit y ->
          let digits, rest = string_until is_digit (List.tl after) in
          (Printf.sprintf "%c%c%s" marker sign digits, rest)
      | y :: _ when is_digit y ->
          let digits, rest = string_until is_digit after in
          (Printf.sprintf "%c%s" marker digits, rest)
      | _ -> ("", chars))
  | _ -> ("", chars)

(** The character a backslash escape denotes, or None where it denotes
    none. char -> char option *)
let escape_char e =
  match e with
  | 'n' -> Some '\n'
  | 't' -> Some '\t'
  | 'r' -> Some '\r'
  | '\\' -> Some '\\'
  | '\'' -> Some '\''
  | '"' -> Some '"'
  | _ -> None

(** Reads a string literal body up to and including the closing quote,
    decoding backslash escapes. `r`/`c` is the position of the opening
    quote, for error reporting. The int returned counts source
    characters consumed, including the closing quote.
    string -> int -> int -> char -> [char] -> (string, int, [char]) *)
let scan_string file r c quote chars =
  let rec scan value length rest =
    match rest with
    | [] ->
        let i =
          { file; row1 = r; col1 = c + 1 + length; row2 = r;
            col2 = c + 1 + length }
        in
        raise (Lex_error (i, "unexpected end of string literal"))
    | '\\' :: e :: xs when escape_char e <> None ->
        let decoded = match escape_char e with Some d -> d | None -> e in
        scan (decoded :: value) (length + 2) xs
    | '\\' :: e :: _ ->
        let i =
          { file; row1 = r; col1 = c + 1 + length; row2 = r;
            col2 = c + 3 + length }
        in
        raise
          (Lex_error (i, Printf.sprintf "unknown escape sequence '\\%c'" e))
    | c2 :: xs when c2 = quote ->
        (string_of_chars (List.rev value), length + 1, xs)
    | c2 :: xs -> scan (c2 :: value) (length + 1) xs
  in
  scan [] 0 chars

(** Lexes a character list into a list of tokens.
    string -> [char] -> [token] *)
let lexing file chars =
  let fi r c length =
    { file; row1 = r; col1 = c; row2 = r; col2 = c + length }
  in
  (* The lexer's whole state is carried here rather than mutated: the
     tokens produced so far (reversed), the row and column, the stack of
     indentation levels, the number of brackets left open (a line break
     inside one continues the line rather than starting a new one), and
     whether nothing but spaces has been seen on this line yet. *)
  let rec lex rest r c stack depth line_start tokens =
    match rest with
    | x :: _ when line_start && x <> '\n' && x <> '#' ->
        let spaces, ys = string_until (fun ch -> ch = ' ') rest in
        let width = String.length spaces in
        (match ys with
        | y :: _ when y <> '\n' && y <> '#' ->
            if width mod 4 <> 0 then
              raise
                (Lex_error
                   (fi r c width, "indentation must be a multiple of 4 spaces"));
            let level = width / 4 in
            let top = List.hd stack in
            if level > top then
              lex ys r (c + width) (level :: stack) depth false
                (TokIndent (fi r c 0) :: tokens)
            else
              let rec dedent stack tokens =
                match stack with
                | top :: outer when level < top ->
                    dedent outer (TokDedent (fi r c 0) :: tokens)
                | _ -> (stack, tokens)
              in
              let stack, tokens = dedent stack tokens in
              if level <> List.hd stack then
                raise
                  (Lex_error
                     ( fi r c width,
                       "unindent does not match any outer indentation level" ));
              lex ys r (c + width) stack depth false tokens
        | _ -> lex ys r (c + width) stack depth line_start tokens)
    (* Integer, or float *)
    | x :: _ when is_digit x ->
        let y, ys = string_until is_digit rest in
        let fraction, after_fraction = scan_fraction ys in
        let exponent, after_exponent = scan_exponent after_fraction in
        if fraction = "" && exponent = "" then
          let width = String.length y in
          (* What a program may write down is fixed at the signed 32-bit
             range, whatever the host's own int is, so the front end
             refuses the same literals wherever it runs. What arithmetic
             may *produce* is a separate question the language leaves
             undefined (see PYKING.md, "Integers"). *)
          let value =
            match int_of_string_opt y with
            | Some value when value <= max_int_literal -> value
            | _ ->
                raise
                  (Lex_error
                     ( fi r c width,
                       Printf.sprintf "integer literal '%s' is too large" y ))
          in
          lex ys r (c + width) stack depth line_start
            (TokInt (fi r c width, value) :: tokens)
        else
          let text = y ^ fraction ^ exponent in
          let width = String.length text in
          (* No bound the way an integer literal has one: a literal past
             binary64's range is an infinity, which is IEEE's own answer
             and the same on every host and in both builds. *)
          lex after_exponent r (c + width) stack depth line_start
            (TokFloat (fi r c width, float_of_string text) :: tokens)
    (* Line comment *)
    | '#' :: xs ->
        let text, ys = string_until (fun ch -> ch <> '\n') xs in
        lex ys r (c + 1 + String.length text) stack depth line_start tokens
    (* String *)
    | s :: xs when s = '\'' || s = '"' ->
        let text, body_length, ys = scan_string file r c s xs in
        let length = 1 + body_length in
        lex ys r (c + length) stack depth line_start
          (TokString (fi r c length, text) :: tokens)
    (* Operators that are user defined in real pyking *)
    | '+' :: '+' :: xs ->
        lex xs r (c + 2) stack depth line_start (TokConcat (fi r c 2) :: tokens)
    | '+' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokAdd (fi r c 1) :: tokens)
    | '-' :: '>' :: xs ->
        (* Pyking extension: single-expression `case` clauses *)
        lex xs r (c + 2) stack depth line_start (TokArrow (fi r c 2) :: tokens)
    | '-' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokSub (fi r c 1) :: tokens)
    | '*' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokMul (fi r c 1) :: tokens)
    | '/' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokDiv (fi r c 1) :: tokens)
    | '<' :: '=' :: xs ->
        lex xs r (c + 2) stack depth line_start (TokLessThanEq (fi r c 2) :: tokens)
    | '<' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokLessThan (fi r c 1) :: tokens)
    | '>' :: '=' :: xs ->
        lex xs r (c + 2) stack depth line_start (TokGreatThanEq (fi r c 2) :: tokens)
    | '>' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokGreatThan (fi r c 1) :: tokens)
    | '=' :: '=' :: xs ->
        lex xs r (c + 2) stack depth line_start (TokEqEq (fi r c 2) :: tokens)
    | '=' :: '>' :: xs ->
        (* Pyking extension: a lambda, `x => x + 1` *)
        lex xs r (c + 2) stack depth line_start
          (TokFatArrow (fi r c 2) :: tokens)
    (* Language lex items *)
    | ':' :: '=' :: xs ->
        lex xs r (c + 2) stack depth line_start (TokAssign (fi r c 2) :: tokens)
    | ':' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokColon (fi r c 1) :: tokens)
    | '=' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokEq (fi r c 1) :: tokens)
    | '(' :: xs ->
        lex xs r (c + 1) stack (depth + 1) line_start
          (TokLParen (fi r c 1) :: tokens)
    | ')' :: xs ->
        lex xs r (c + 1) stack (max 0 (depth - 1)) line_start
          (TokRParen (fi r c 1) :: tokens)
    | '[' :: xs ->
        lex xs r (c + 1) stack (depth + 1) line_start
          (TokLBracket (fi r c 1) :: tokens)
    | ']' :: xs ->
        lex xs r (c + 1) stack (max 0 (depth - 1)) line_start
          (TokRBracket (fi r c 1) :: tokens)
    | '.' :: '.' :: xs ->
        (* list-pattern rest marker: `..` / `..name` *)
        lex xs r (c + 2) stack depth line_start (TokDotDot (fi r c 2) :: tokens)
    | '.' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokDot (fi r c 1) :: tokens)
    | ',' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokComma (fi r c 1) :: tokens)
    | '|' :: xs ->
        lex xs r (c + 1) stack depth line_start (TokBar (fi r c 1) :: tokens)
    | ' ' :: xs -> lex xs r (c + 1) stack depth line_start tokens
    | '\n' :: xs -> lex xs (r + 1) 0 stack depth (depth = 0) tokens
    (* Keywords and identifiers *)
    | x :: _ when is_letter x ->
        let word, after = string_until is_digit_letter rest in
        (* A qualified name -- `int::str` -- is one identifier that holds
           a `::`, so nothing after the lexer has to take one apart
           (docs/overloading.md). No space is allowed on either side,
           which is what keeps it clear of the block `:` and the
           annotation `:`. *)
        let y, ys, halves =
          match after with
          | ':' :: ':' :: (c :: _ as base_chars) when is_letter c ->
              let b, zs = string_until is_digit_letter base_chars in
              (word ^ "::" ^ b, zs, Some (word, b))
          | _ -> (word, after, None)
        in
        let length = String.length y in
        let tok =
          match halves with
          | Some (q, b) ->
              let reserved = if List.mem q keywords then q else b in
              if List.mem q keywords || List.mem b keywords then
                raise
                  (Lex_error
                     ( fi r c length,
                       Printf.sprintf
                         "'%s' is not a name: '%s' is a keyword, and a \
                          qualified name is made of two ordinary names"
                         y reserved ))
              else TokIdent (fi r c length, y)
          | None ->
              if List.mem y keywords then
                match keyword_token y (fi r c length) with
                | Some t -> t
                | None -> TokIdent (fi r c length, y)
              else TokIdent (fi r c length, y)
        in
        lex ys r (c + length) stack depth line_start (tok :: tokens)
    | [] ->
        let rec close stack tokens =
          match stack with
          | top :: outer when top > 0 -> close outer (TokDedent (fi r c 0) :: tokens)
          | _ -> tokens
        in
        List.rev (close stack tokens)
    | x :: _ ->
        raise
          (Lex_error (fi r c 1, Printf.sprintf "unexpected character '%c'" x))
  in
  lex chars 1 0 [ 0 ] 0 true []
