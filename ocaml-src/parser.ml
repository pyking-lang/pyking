(** Recursive-descent parser: tokens (from lexer.ml) to the AST defined
    in syntax.ml. Also enforces the handful of grammar rules that cannot
    be expressed in EBNF -- duplicate pattern captures, value-form
    if/match branches, one statement per line, and where a
    'break'/'continue' may stand. Translated from src/parser.py; see
    PYKING.md for the grammar.

    src/parser.py keeps the end-of-input position in a module-level
    variable that `parse` assigns. Here it is a value, `eof`, passed to
    every function that can run out of tokens -- the position to blame
    when there is no next token to blame.

    Data structures:
      Parse_error -- a parse failure, with the source position.
      bound_value -- the right-hand side of a binding: an expression, or
        a statement in value form.

    Functions:
      parse tokens -- parses a full token stream into a list of statements.
      parse_statement eof tokens -- parses one statement.
      parse_expr eof tokens -- parses one expression.
      parse_block eof tokens header_info -- parses one block: indented,
        or the single statement on its header's own line.
      parse_loop_stmt eof info tokens -- parses a loop after its 'loop'.
      parse_exit_operand eof info tokens -- the optional operand of a
        'break'/'continue', taken only from the keyword's own line.
      parse_type eof tokens -- parses one type annotation.
      parse_pattern eof tokens -- parses one match/case pattern.
      combine_info start end_ -- spans an Info from two nodes' Infos. *)

open Lexer
open Syntax

(** A syntax failure, with the source position. *)
exception Parse_error of info * string

(** Spans an Info from the start of start to the end of end_.
    info -> info -> info *)
let combine_info start end_ =
  {
    file = start.file;
    row1 = start.row1;
    col1 = start.col1;
    row2 = end_.row2;
    col2 = end_.col2;
  }

(** The Info to blame for a parse error at the current position: the
    next token's, or end-of-file. info -> [token] -> info *)
let here eof tokens =
  match tokens with t :: _ -> token_info t | [] -> eof

(* The right-hand side of a binding's '=': an expression, or a statement
   in value form -- an if/match, or a loop. src/parser.py returns the
   node itself and has its callers ask which it got; here the two are
   told apart by the constructor. *)
type bound_value = BExpr of expr | BStmt of stmt

(* --- parser --- *)

let join_error =
  "'++' joins list patterns or string patterns, and the two may not be mixed; \
   every part but one name must have a fixed length"


(** Parses one atom: a literal, name, parenthesized expression, tuple,
    list, or list comprehension. info -> [token] -> (expr, [token]) *)
let rec parse_atom eof tokens =
  match tokens with
  | TokInt (i, v) :: rest -> parse_call_tail eof (EInt (i, v, 0)) rest
  | TokString (i, s) :: rest -> parse_call_tail eof (EString (i, s, 0)) rest
  | TokTrue i :: rest -> parse_call_tail eof (EBool (i, true, 0)) rest
  | TokFalse i :: rest -> parse_call_tail eof (EBool (i, false, 0)) rest
  | TokIdent (i, module_name) :: TokDot dot :: TokIdent (name_info, name) :: rest
    when dot.row1 = i.row2 ->
      (* `module.name`: a public name of an imported module. The dot must
         be on the module name's own row, for the reason parse_call_tail
         requires it of a '(' -- otherwise a name ending one line would
         reach down and take the next. *)
      parse_call_tail eof
        (EQualified (combine_info i name_info, module_name, name, 0))
        rest
  | TokIdent (i, name) :: rest -> parse_call_tail eof (EVar (i, name, 0)) rest
  | TokLParen lp :: TokRParen rp :: rest ->
      (* (): the empty tuple, i.e. Unit. *)
      parse_call_tail eof (ETuple (combine_info lp rp, [], 0)) rest
  | TokLParen lp :: rest -> (
      let first, rest = parse_expr eof rest in
      match rest with
      | TokComma _ :: TokRParen rp :: rest ->
          (* (e,): a singleton tuple. *)
          parse_call_tail eof (ETuple (combine_info lp rp, [ first ], 0)) rest
      | TokComma _ :: rest ->
          (* (e, e, ...): reuse parse_args's shape -- it is exactly the
             tuple-tail grammar too. *)
          let elements, rp, rest = parse_args eof rest in
          parse_call_tail eof
            (ETuple (combine_info lp rp, first :: elements, 0))
            rest
      | TokRParen rp :: rest ->
          (* (e): just a parenthesized expression, not a tuple. *)
          parse_call_tail eof (set_expr_info (combine_info lp rp) first) rest
      | _ -> raise (Parse_error (here eof rest, "expected ',' or ')'")))
  | TokLBracket lb :: TokRBracket rb :: rest ->
      parse_call_tail eof (EList (combine_info lb rb, [], 0)) rest
  | TokLBracket lb :: rest -> (
      let first, rest = parse_expr eof rest in
      match rest with
      | TokFor _ :: _ ->
          (* [expr for pattern in seq ...]: a list comprehension, not a
             plain list literal. *)
          let clauses, rb, rest = parse_comp_clauses eof rest in
          parse_call_tail eof
            (EListComp (combine_info lb rb, first, clauses, 0))
            rest
      | TokComma _ :: rest ->
          let elements, rb, rest = parse_list_elements eof rest in
          parse_call_tail eof
            (EList (combine_info lb rb, first :: elements, 0))
            rest
      | TokRBracket rb :: rest ->
          parse_call_tail eof (EList (combine_info lb rb, [ first ], 0)) rest
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',', 'for', or ']' in list literal")))
  | t :: _ -> raise (Parse_error (token_info t, "unexpected token in expression"))
  | [] ->
      raise
        (Parse_error (here eof tokens, "unexpected end of input in expression"))

(** Parses zero or more call suffixes onto expr, chaining `f(1)(2)`. A
    `(` only extends expr if it starts on the same source row expr ended
    on, so it cannot swallow the next statement's.
    info -> expr -> [token] -> (expr, [token]) *)
and parse_call_tail eof e tokens =
  match tokens with
  | TokLParen lp :: rest when lp.row1 = (expr_info e).row2 ->
      let args, rparen, rest = parse_args eof rest in
      let call_info = combine_info (expr_info e) rparen in
      parse_call_tail eof (ECall (call_info, e, args, 0)) rest
  | _ -> (e, tokens)

(** Parses comma-separated call arguments up to and including ')'.
    info -> [token] -> ([expr], info, [token]) *)
and parse_args eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | _ -> (
      let arg, rest = parse_expr eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let args, rparen, rest = parse_args eof rest in
          (arg :: args, rparen, rest)
      | TokRParen i :: rest -> ([ arg ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in call arguments")))

(** Parses comma-separated list elements up to and including ']'.
    info -> [token] -> ([expr], info, [token]) *)
and parse_list_elements eof tokens =
  match tokens with
  | TokRBracket i :: rest -> ([], i, rest)
  | _ -> (
      let elem, rest = parse_expr eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let elems, rb, rest = parse_list_elements eof rest in
          (elem :: elems, rb, rest)
      | TokRBracket i :: rest -> ([ elem ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ']' in list literal")))

(** Parses a list comprehension's for/if clauses up to and including
    ']'. info -> [token] -> ([comp_clause], info, [token]) *)
and parse_comp_clauses eof tokens =
  let rec clauses_from tokens collected =
    match tokens with
    | TokFor i :: rest -> (
        let pattern, rest = parse_pattern eof rest in
        check_no_duplicate_captures pattern;
        match rest with
        | TokIn _ :: rest ->
            let seq, rest = parse_expr eof rest in
            let clause =
              CompFor (combine_info i (expr_info seq), pattern, seq, 0)
            in
            clauses_from rest (clause :: collected)
        | _ ->
            raise
              (Parse_error
                 (here eof rest, "expected 'in' after comprehension pattern")))
    | TokIf i :: rest ->
        let cond, rest = parse_expr eof rest in
        let clause = CompIf (combine_info i (expr_info cond), cond, 0) in
        clauses_from rest (clause :: collected)
    | TokRBracket i :: rest -> (List.rev collected, i, rest)
    | _ ->
        raise
          (Parse_error
             ( here eof tokens,
               "expected 'for', 'if', or ']' in list comprehension" ))
  in
  clauses_from tokens []

(** Parses unary minus (`-expr`) or falls through to an atom.
    info -> [token] -> (expr, [token]) *)
and parse_unary eof tokens =
  match tokens with
  | TokSub i :: rest ->
      let operand, rest = parse_unary eof rest in
      (ENeg (combine_info i (expr_info operand), operand, 0), rest)
  | _ -> parse_atom eof tokens

(** Parses `*`/`/`, left-associative. info -> [token] -> (expr, [token]) *)
and parse_multiplicative eof tokens =
  let left, rest = parse_unary eof tokens in
  let rec more left rest =
    match rest with
    | TokMul _ :: rest2 ->
        let right, rest2 = parse_unary eof rest2 in
        more
          (EMul (combine_info (expr_info left) (expr_info right), left, right, 0))
          rest2
    | TokDiv _ :: rest2 ->
        let right, rest2 = parse_unary eof rest2 in
        more
          (EDiv (combine_info (expr_info left) (expr_info right), left, right, 0))
          rest2
    | _ -> (left, rest)
  in
  more left rest

(** Parses `+`/`++`/`-`, left-associative.
    info -> [token] -> (expr, [token]) *)
and parse_additive eof tokens =
  let left, rest = parse_multiplicative eof tokens in
  let rec more left rest =
    match rest with
    | TokAdd _ :: rest2 ->
        let right, rest2 = parse_multiplicative eof rest2 in
        more
          (EAdd (combine_info (expr_info left) (expr_info right), left, right, 0))
          rest2
    | TokConcat _ :: rest2 ->
        let right, rest2 = parse_multiplicative eof rest2 in
        more
          (EConcat
             (combine_info (expr_info left) (expr_info right), left, right, 0))
          rest2
    | TokSub _ :: rest2 ->
        let right, rest2 = parse_multiplicative eof rest2 in
        more
          (ESub (combine_info (expr_info left) (expr_info right), left, right, 0))
          rest2
    | _ -> (left, rest)
  in
  more left rest

(** Parses the lowest-precedence expression level: an if expression or a
    comparison. info -> [token] -> (expr, [token]) *)
and parse_expr eof tokens =
  match tokens with
  | TokIf i :: rest ->
      let cond, rest = parse_expr eof rest in
      parse_if_expr_tail eof i cond rest
  | _ -> parse_comparison eof tokens

(** Parses the `then expr else expr` tail of an if expression, given the
    already-parsed `if` and condition.
    info -> info -> expr -> [token] -> (expr, [token]) *)
and parse_if_expr_tail eof if_info cond tokens =
  match tokens with
  | TokThen _ :: rest -> (
      let then_expr, rest = parse_expr eof rest in
      match rest with
      | TokElse _ :: rest ->
          let else_expr, rest = parse_expr eof rest in
          ( EIf
              ( combine_info if_info (expr_info else_expr),
                cond,
                then_expr,
                else_expr,
                0 ),
            rest )
      | _ ->
          raise
            (Parse_error (here eof rest, "expected 'else' in if expression")))
  | _ ->
      raise (Parse_error (here eof tokens, "expected 'then' in if expression"))

(** Parses the block and optional else/else-if tail of an if statement,
    given the already-parsed `if`, condition and the ':' that follows
    it; tokens starts just after that ':'.
    info -> info -> expr -> info -> [token] -> (stmt, [token]) *)
and parse_if_stmt_tail eof if_info cond colon_info tokens =
  let then_body, rest = parse_block eof tokens colon_info in
  (match rest with
  | TokElse _ :: _ -> check_ends_line then_body rest "else"
  | _ -> ());
  match rest with
  | TokElse _ :: TokIf elif_info :: rest -> (
      let elif_cond, rest = parse_expr eof rest in
      match rest with
      | TokColon elif_colon :: rest ->
          let nested, rest =
            parse_if_stmt_tail eof elif_info elif_cond elif_colon rest
          in
          let if_info = combine_info if_info (stmt_info nested) in
          (SIf (if_info, cond, then_body, Some [ nested ], 0), rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ':' after 'else if' condition")))
  | TokElse _ :: TokColon else_colon :: rest ->
      let else_body, rest = parse_block eof rest else_colon in
      let if_info = combine_info if_info (block_end_info if_info else_body) in
      (SIf (if_info, cond, then_body, Some else_body, 0), rest)
  | TokElse else_info :: _ ->
      raise (Parse_error (else_info, "expected ':' or 'if' after 'else'"))
  | _ ->
      let if_info = combine_info if_info (block_end_info if_info then_body) in
      (SIf (if_info, cond, then_body, None, 0), rest)

(** Parses a comparison operator; comparisons do not chain.
    info -> [token] -> (expr, [token]) *)
and parse_comparison eof tokens =
  let left, rest = parse_additive eof tokens in
  let span right = combine_info (expr_info left) (expr_info right) in
  match rest with
  | TokLessThan _ :: rest ->
      let right, rest = parse_additive eof rest in
      (ELessThan (span right, left, right, 0), rest)
  | TokLessThanEq _ :: rest ->
      let right, rest = parse_additive eof rest in
      (ELessThanEq (span right, left, right, 0), rest)
  | TokGreatThan _ :: rest ->
      let right, rest = parse_additive eof rest in
      (EGreatThan (span right, left, right, 0), rest)
  | TokGreatThanEq _ :: rest ->
      let right, rest = parse_additive eof rest in
      (EGreatThanEq (span right, left, right, 0), rest)
  | TokEqEq _ :: rest ->
      let right, rest = parse_additive eof rest in
      (EEq (span right, left, right, 0), rest)
  | _ -> (left, rest)

(** Parses one expression, or a bare (unparenthesized) tuple
    `expr, expr, ...`. info -> [token] -> (expr, [token]) *)
and parse_tuple_or_expr eof tokens =
  let first, rest = parse_expr eof tokens in
  parse_tuple_tail eof first rest

(** Continues a bare tuple from an already-parsed first element if the
    next token is a comma, otherwise returns first unchanged.
    info -> expr -> [token] -> (expr, [token]) *)
and parse_tuple_tail eof first tokens =
  match tokens with
  | TokComma _ :: rest ->
      let rec elements_from rest collected =
        let elem, rest = parse_expr eof rest in
        let collected = elem :: collected in
        match rest with
        | TokComma _ :: rest2 -> elements_from rest2 collected
        | _ -> (List.rev collected, rest)
      in
      let elements, rest = elements_from rest [ first ] in
      let last = List.nth elements (List.length elements - 1) in
      let tuple_info = combine_info (expr_info first) (expr_info last) in
      (ETuple (tuple_info, elements, 0), rest)
  | _ -> (first, tokens)

(** Parses one type. A single parameter needs no parentheses -- `x -> x`
    is `(x) -> x` -- so any atom followed by `->` is a one-parameter
    function; the parenthesized list form is read by parse_type_atom.
    info -> [token] -> (typ, [token]) *)
and parse_type eof tokens =
  let atom, rest = parse_type_atom eof tokens in
  match rest with
  | TokArrow _ :: after_arrow ->
      let result, rest = parse_type eof after_arrow in
      ( TFunction
          ( combine_info (type_info atom) (type_info result),
            [ atom ],
            result,
            0,
            0,
            None ),
        rest )
  | _ -> (atom, rest)

(** Parses one type that is not an unparenthesized `->`.
    info -> [token] -> (typ, [token]) *)
and parse_type_atom eof tokens =
  match tokens with
  | TokTypeInt i :: rest -> (TInt (i, 0), rest)
  | TokTypeString i :: rest -> (TString (i, 0), rest)
  | TokTypeBool i :: rest -> (TBool (i, 0), rest)
  | TokIdent (i, "all") :: rest ->
      (* `all a b. T`. `all` is reserved in type position, so it is
         never itself a variable name. *)
      let names, rest = parse_type_vars eof rest in
      let body, rest = parse_type eof rest in
      (TForall (combine_info i (type_info body), names, body, 0), rest)
  | TokIdent (i, name) :: rest when is_type_var name ->
      (TVar (i, name, 0, true), rest)
  | TokLBracket lb :: rest -> (
      let element, rest = parse_type eof rest in
      match rest with
      | TokRBracket rb :: rest -> (TList (combine_info lb rb, element, 0), rest)
      | _ -> raise (Parse_error (here eof rest, "expected ']' in list type")))
  | TokLParen lp :: rest -> (
      (* One parenthesized list, two types: it is a function's parameter
         list when `->` follows and a tuple otherwise. Deciding it on
         the token after `)` is what keeps a *parameter* that is itself
         a tuple writable, as `((Int, Bool)) -> Int`. *)
      let elements, trailing, rp, rest = parse_type_elements eof rest in
      match rest with
      | TokArrow _ :: after_arrow ->
          (* The result is a whole type in its turn, so `->` groups to
             the right: `(Int) -> (Int) -> Int`. *)
          let result, rest = parse_type eof after_arrow in
          ( TFunction
              ( combine_info lp (type_info result),
                elements,
                result,
                0,
                0,
                None ),
            rest )
      | _ ->
          if List.length elements = 1 && not trailing then
            (* `(T)` is grouping, exactly as `(e)` is among values; the
               comma is what makes a singleton. *)
            (set_type_info (combine_info lp rp) (List.hd elements), rest)
          else
            (* `()`, `(T,)`, `(T1, T2)`, ... -- one tuple type per tuple
               value, written the way the value is. *)
            (TTuple (combine_info lp rp, elements, 0), rest))
  | t :: _ -> raise (Parse_error (token_info t, "expected a type"))
  | [] ->
      raise (Parse_error (here eof tokens, "unexpected end of input in type"))

(** Parses comma-separated types up to and including ')', also saying
    whether a comma came just before that ')' -- which is the whole of
    what tells the singleton tuple `(T,)` from the grouping `(T)`.
    info -> [token] -> ([typ], bool, info, [token]) *)
and parse_type_elements eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], false, i, rest)
  | _ -> (
      let elem, rest = parse_type eof tokens in
      match rest with
      | TokComma _ :: TokRParen i :: rest -> ([ elem ], true, i, rest)
      | TokComma _ :: rest ->
          let elems, trailing, rp, rest = parse_type_elements eof rest in
          (elem :: elems, trailing, rp, rest)
      | TokRParen i :: rest -> ([ elem ], false, i, rest)
      | _ ->
          raise
            (Parse_error (here eof rest, "expected ',' or ')' in tuple type")))

(** Parses the variables an `all` binds, up to and including the `.`.
    info -> [token] -> ([string], [token]) *)
and parse_type_vars eof tokens =
  let rec vars_from tokens names =
    match tokens with
    | TokIdent (_, name) :: rest when is_type_var name ->
        vars_from rest (name :: names)
    | TokDot _ :: rest when names <> [] -> (List.rev names, rest)
    | _ ->
        raise
          (Parse_error
             ( here eof tokens,
               "expected type variables and then '.' after 'all'" ))
  in
  vars_from tokens []

(** Parses one parameter, `name` or `name:type`.
    info -> [token] -> (param, [token]) *)
and parse_param eof tokens =
  match tokens with
  | TokIdent (i, name) :: TokColon _ :: rest ->
      let type_, rest = parse_type eof rest in
      (Param (combine_info i (type_info type_), name, Some type_, 0), rest)
  | TokIdent (i, name) :: rest -> (Param (i, name, None, 0), rest)
  | _ -> raise (Parse_error (here eof tokens, "expected a parameter"))

(** Parses comma-separated parameters up to and including ')'.
    info -> [token] -> ([param], [token]) *)
and parse_params eof tokens =
  match tokens with
  | TokRParen _ :: rest -> ([], rest)
  | _ -> (
      let param, rest = parse_param eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let params, rest = parse_params eof rest in
          (param :: params, rest)
      | TokRParen _ :: rest -> ([ param ], rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in parameter list")))

(** Parses one assignment target: a name, or a parenthesized
    tuple-target group. info -> [token] -> (assign_target, [token]) *)
and parse_target_atom eof tokens =
  match tokens with
  | TokIdent (i, name) :: rest -> (TargetName (i, name, 0), rest)
  | TokLParen lp :: TokRParen rp :: rest ->
      (TargetTuple (combine_info lp rp, [], 0), rest)
  | TokLParen lp :: rest -> (
      let first, rest = parse_target_atom eof rest in
      match rest with
      | TokComma _ :: TokRParen rp :: rest ->
          (TargetTuple (combine_info lp rp, [ first ], 0), rest)
      | TokComma _ :: rest ->
          let elements, rp, rest = parse_target_paren_tail eof rest in
          (TargetTuple (combine_info lp rp, first :: elements, 0), rest)
      | TokRParen rp :: rest ->
          (set_target_info (combine_info lp rp) first, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in assignment target")))
  | t :: _ ->
      raise
        (Parse_error
           ( token_info t,
             "expected an identifier or '(' in assignment target" ))
  | [] ->
      raise
        (Parse_error
           ( here eof tokens,
             "unexpected end of input in assignment target" ))

(** Parses comma-separated targets up to and including ')'.
    info -> [token] -> ([assign_target], info, [token]) *)
and parse_target_paren_tail eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | _ -> (
      let elem, rest = parse_target_atom eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let elems, rp, rest = parse_target_paren_tail eof rest in
          (elem :: elems, rp, rest)
      | TokRParen i :: rest -> ([ elem ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in assignment target")))

(** Parses an assignment target: one parse_target_atom, or a bare
    comma-separated sequence of them.
    info -> [token] -> (assign_target, [token]) *)
and parse_target eof tokens =
  let first, rest = parse_target_atom eof tokens in
  match rest with
  | TokComma _ :: rest ->
      let rec elements_from rest collected =
        let elem, rest = parse_target_atom eof rest in
        let collected = elem :: collected in
        match rest with
        | TokComma _ :: rest2 -> elements_from rest2 collected
        | _ -> (List.rev collected, rest)
      in
      let elements, rest = elements_from rest [ first ] in
      let last = List.nth elements (List.length elements - 1) in
      let tuple_info = combine_info (target_info first) (target_info last) in
      (TargetTuple (tuple_info, elements, 0), rest)
  | _ -> (first, rest)

(** Speculatively parses tokens as `target [: type] =`. Answers None,
    rather than raising, if tokens does not begin with one.
    info -> [token] -> (assign_target, typ option, [token]) option *)
and try_parse_assignment_target eof tokens =
  match (try Some (parse_target eof tokens) with Parse_error _ -> None) with
  | None -> None
  | Some (target, rest) -> (
      (* Committed: a target followed by ':' can only be an annotated
         assignment, so a bad type here is reported as itself rather
         than swallowed into a None. *)
      let annotation, rest =
        match rest with
        | TokColon _ :: after_colon ->
            let type_, rest = parse_type eof after_colon in
            (Some type_, rest)
        | _ -> (None, rest)
      in
      match rest with
      | TokEq _ :: rest -> Some (target, annotation, rest)
      | _ -> None)

(** Parses one block: TokIndent to matching TokDedent, or the one
    expression written on the header's own line. `header_info` is the
    ':' that opened it. info -> [token] -> info -> ([stmt], [token]) *)
and parse_block eof tokens header_info =
  match tokens with
  | TokIndent _ :: rest ->
      let rec block rest collected =
        match rest with
        | TokDedent _ :: rest -> (List.rev collected, rest)
        | _ ->
            let stmt, rest = parse_statement eof rest in
            (match collected with
            | previous :: _ ->
                check_own_line (stmt_info previous) (stmt_info stmt) "statement"
                  (fun () -> statement_text previous)
                  (fun () -> statement_text stmt);
                check_reachable previous stmt
            | [] -> ());
            block rest (stmt :: collected)
      in
      block rest []
  | _ when on_header_line header_info tokens ->
      (* Exactly one expression statement, and the line ends with it:
         check_own_line catches a second statement written after it,
         check_inline_value anything that is not an expression, and
         check_ends_line a header's own continuation trying to share the
         line. *)
      let stmt, rest = parse_statement eof tokens in
      check_inline_value stmt;
      check_nothing_indented rest;
      ([ stmt ], rest)
  | _ -> raise (Parse_error (here eof tokens, "expected an indented block"))

(** Parses one pattern: literal, wildcard, name, or parenthesized tuple
    pattern. info -> [token] -> (pattern, [token]) *)
and parse_pattern_atom eof tokens =
  match tokens with
  | TokSub i :: TokInt (int_info, v) :: rest ->
      (* A negative integer *literal* pattern (`case -1:`). Only a
         literal: a pattern is matched, never evaluated. *)
      (PInt (combine_info i int_info, -v, 0), rest)
  | TokInt (i, v) :: rest -> (PInt (i, v, 0), rest)
  | TokString (i, s) :: rest -> (PString (i, s, 0), rest)
  | TokTrue i :: rest -> (PBool (i, true, 0), rest)
  | TokFalse i :: rest -> (PBool (i, false, 0), rest)
  | TokIdent (i, "_") :: rest -> (PWildcard (i, 0), rest)
  | TokIdent (i, name) :: rest -> (PCapture (i, name, 0), rest)
  | TokLParen lp :: TokRParen rp :: rest ->
      (PTuple (combine_info lp rp, [], 0), rest)
  | TokLParen lp :: rest -> (
      let first, rest = parse_pattern_concat eof rest in
      match rest with
      | TokComma _ :: TokRParen rp :: rest ->
          (PTuple (combine_info lp rp, [ first ], 0), rest)
      | TokComma _ :: rest ->
          let elements, rp, rest = parse_pattern_paren_tail eof rest in
          (PTuple (combine_info lp rp, first :: elements, 0), rest)
      | TokRParen rp :: rest ->
          (set_pattern_info (combine_info lp rp) first, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in tuple pattern")))
  | TokLBracket lb :: TokRBracket rb :: rest ->
      (PList (combine_info lb rb, [], None, [], 0), rest)
  | TokLBracket lb :: rest ->
      let items, rb, rest = parse_list_pattern_items eof rest in
      let prefix, list_rest, suffix =
        List.fold_left
          (fun (prefix, list_rest, suffix) item ->
            match item with
            | Either.Right marker ->
                if list_rest <> None then
                  raise
                    (Parse_error
                       ( rest_info marker,
                         "a list pattern can have at most one '..' rest" ))
                else (prefix, Some marker, suffix)
            | Either.Left p ->
                if list_rest = None then (prefix @ [ p ], list_rest, suffix)
                else (prefix, list_rest, suffix @ [ p ]))
          ([], None, []) items
      in
      (PList (combine_info lb rb, prefix, list_rest, suffix, 0), rest)
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             "expected a pattern (integer, string, '_', identifier, tuple, \
              or list)" ))

(** Parses comma-separated list-pattern items up to ']' (each a pattern,
    or a `..`/`..name` rest marker), in source order.
    info -> [token] -> ([(pattern, list_rest) Either.t], info, [token]) *)
and parse_list_pattern_items eof tokens =
  match tokens with
  | TokRBracket i :: rest -> ([], i, rest)
  | _ -> (
      let item, rest = parse_list_pattern_item eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let items, rb, rest = parse_list_pattern_items eof rest in
          (item :: items, rb, rest)
      | TokRBracket i :: rest -> ([ item ], i, rest)
      | _ ->
          raise
            (Parse_error (here eof rest, "expected ',' or ']' in list pattern")))

and parse_list_pattern_item eof tokens =
  match tokens with
  | TokDotDot i :: TokIdent (name_info, name) :: rest ->
      (Either.Right (ListRest (combine_info i name_info, Some name, 0)), rest)
  | TokDotDot i :: rest -> (Either.Right (ListRest (i, None, 0)), rest)
  | _ ->
      let pattern, rest = parse_pattern_concat eof tokens in
      (Either.Left pattern, rest)

and parse_pattern_paren_tail eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | _ -> (
      let elem, rest = parse_pattern_concat eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let elems, rp, rest = parse_pattern_paren_tail eof rest in
          (elem :: elems, rp, rest)
      | TokRParen i :: rest -> ([ elem ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in tuple pattern")))

(** Parses patterns joined with `++`, which is how a list or a string is
    split around a name: `[x] ++ xs` is `[x, ..xs]`, and `"ab" ++ rest`
    is the same idea for a string. The chain is folded into one ordinary
    pattern here, so nothing after the parser knows the form exists.
    info -> [token] -> (pattern, [token]) *)
and parse_pattern_concat eof tokens =
  let first, rest = parse_pattern_atom eof tokens in
  let rec segments_from rest collected =
    match rest with
    | TokConcat _ :: after ->
        let segment, rest = parse_pattern_atom eof after in
        segments_from rest (segment :: collected)
    | _ -> (List.rev collected, rest)
  in
  let segments, rest = segments_from rest [ first ] in
  if List.length segments = 1 then (first, rest)
  else (joined_pattern segments, rest)

(** Parses a pattern: one parse_pattern_concat, or a bare
    comma-separated sequence of them.
    info -> [token] -> (pattern, [token]) *)
and parse_pattern eof tokens =
  let first, rest = parse_pattern_concat eof tokens in
  match rest with
  | TokComma _ :: rest ->
      let rec elements_from rest collected =
        let elem, rest = parse_pattern_concat eof rest in
        let collected = elem :: collected in
        match rest with
        | TokComma _ :: rest2 -> elements_from rest2 collected
        | _ -> (List.rev collected, rest)
      in
      let elements, rest = elements_from rest [ first ] in
      let last = List.nth elements (List.length elements - 1) in
      let pattern_info_ =
        combine_info (pattern_info first) (pattern_info last)
      in
      (PTuple (pattern_info_, elements, 0), rest)
  | _ -> (first, rest)

(** Parses one case clause: `case pattern:` and its block, which may be
    the expression on the clause's own line.
    info -> [token] -> (match_case, [token]) *)
and parse_case eof tokens =
  match tokens with
  | TokCase i :: rest -> (
      let pattern, rest = parse_pattern eof rest in
      check_no_duplicate_captures pattern;
      match rest with
      | TokColon colon_info :: rest ->
          let body, rest = parse_block eof rest colon_info in
          let case_info_ = combine_info i (block_end_info i body) in
          (MatchCase (case_info_, pattern, body, 0), rest)
      | _ ->
          raise (Parse_error (here eof rest, "expected ':' after case pattern")))
  | _ -> raise (Parse_error (here eof tokens, "expected a 'case' clause"))

(** Parses the case clauses of a match: an indented block of one or
    more. The list a `match` opens is not a block of statements, so the
    header's own line has nothing to hold.
    info -> [token] -> ([match_case], [token]) *)
and parse_cases eof tokens =
  match tokens with
  | TokIndent _ :: rest ->
      let rec cases_from rest collected =
        match rest with
        | TokDedent _ :: rest ->
            if collected = [] then
              raise
                (Parse_error
                   (here eof rest, "match statement requires at least one case"))
            else (List.rev collected, rest)
        | _ ->
            let case_clause, rest = parse_case eof rest in
            (match collected with
            | previous :: _ ->
                check_own_line (case_info previous) (case_info case_clause)
                  "'case' clause"
                  (fun () -> case_text previous)
                  (fun () -> case_text case_clause)
            | [] -> ());
            cases_from rest (case_clause :: collected)
      in
      cases_from rest []
  | _ ->
      raise
        (Parse_error
           (here eof tokens, "expected an indented block of 'case' clauses"))

(** Parses a match statement, from just after the `match` keyword.
    info -> info -> [token] -> (stmt, [token]) *)
and parse_match_stmt eof match_info tokens =
  let subject, rest = parse_expr eof tokens in
  match rest with
  | TokColon _ :: rest ->
      let cases, rest = parse_cases eof rest in
      let last = List.nth cases (List.length cases - 1) in
      let match_info = combine_info match_info (case_info last) in
      (SMatch (match_info, subject, cases, 0), rest)
  | _ -> raise (Parse_error (here eof rest, "expected ':' after match header"))

(** Parses a loop from just after its `loop` keyword: the accumulator,
    then an optional iteration clause, then the body.
    info -> info -> [token] -> (stmt, [token]) *)
and parse_loop_stmt eof loop_info tokens =
  match tokens with
  | (TokColon _ | TokFor _ | TokWhile _) :: _ ->
      (* `loop:` and `loop for ...:` bind nothing. *)
      parse_loop_tail eof loop_info None None None tokens
  | _ -> (
      match try_parse_assignment_target eof tokens with
      | None ->
          raise
            (Parse_error
               ( here eof tokens,
                 "expected ':' or an accumulator ('loop x = 0:') after 'loop'"
               ))
      | Some (target, annotation, rest) ->
          let init, rest = parse_tuple_or_expr eof rest in
          parse_loop_tail eof loop_info (Some target) annotation (Some init) rest)

(** Parses what follows a loop's accumulator: an optional `for`/`while`
    clause, an optional `result` expression, then the `:` and body.
    Every loop in the language comes through here.
    info -> info -> assign_target option -> typ option -> expr option ->
    [token] -> (stmt, [token]) *)
and parse_loop_tail eof loop_info target annotation init tokens =
  let iterate, rest = parse_loop_iter eof tokens in
  let result, rest = parse_loop_result eof rest iterate in
  match rest with
  | TokColon colon_info :: rest ->
      let body, rest = parse_block eof rest colon_info in
      ( SLoop
          ( combine_info loop_info (block_end_info loop_info body),
            target,
            init,
            annotation,
            iterate,
            result,
            body,
            0 ),
        rest )
  | _ -> raise (Parse_error (here eof rest, "expected ':' after loop header"))

(** Parses a loop's `result` expression, or answers None where none was
    written. `result` is a keyword only here -- between the loop's
    header and its `:`.
    info -> [token] -> loop_iter option -> (expr option, [token]) *)
and parse_loop_result eof tokens iterate =
  match tokens with
  | TokIdent (i, "result") :: rest ->
      if iterate = None then
        raise
          (Parse_error
             ( i,
               "'result' says what a loop is worth when it ends without \
                breaking, and a plain 'loop' can only end by breaking; write \
                'for'/'while', or say it on the 'break'" ))
      else
        let e, rest = parse_expr eof rest in
        (Some e, rest)
  | _ -> (None, tokens)

(** Parses a loop's iteration clause, or answers None where the loop
    takes another turn unconditionally.
    info -> [token] -> (loop_iter option, [token]) *)
and parse_loop_iter eof tokens =
  match tokens with
  | TokFor i :: TokIdent (_, name) :: TokIn _ :: rest ->
      let sequence, rest = parse_expr eof rest in
      (Some (ForIn (combine_info i (expr_info sequence), name, sequence, 0)), rest)
  | TokFor i :: _ ->
      raise (Parse_error (i, "expected `for <name> in <expression>`"))
  | TokWhile i :: rest ->
      let condition, rest = parse_expr eof rest in
      ( Some (WhileTest (combine_info i (expr_info condition), condition, 0)),
        rest )
  | _ -> (None, tokens)

(** Parses the optional operand of a 'break'/'continue': one is present
    only if it starts on the keyword's own line.
    info -> info -> [token] -> (expr option, [token]) *)
and parse_exit_operand eof keyword_info tokens =
  match tokens with
  | first :: _
    when expr_starter first && (token_info first).row1 = keyword_info.row2 ->
      let e, rest = parse_tuple_or_expr eof tokens in
      (Some e, rest)
  | _ -> (None, tokens)

(** Parses the right-hand side of a binding's '=': an expression, or a
    statement in value form -- an if/match, or a loop. May be indented
    onto the next line. info -> [token] -> (bound_value, [token]) *)
and parse_bound_value eof tokens =
  match tokens with
  | TokIndent _ :: rest -> (
      let value, rest = parse_bound_value eof rest in
      match rest with
      | TokDedent _ :: rest -> (value, rest)
      | _ ->
          raise
            (Parse_error
               ( here eof rest,
                 "expected a single value in the indented block after '='" )))
  | TokMatch i :: rest ->
      let stmt, rest = parse_match_stmt eof i rest in
      check_value_stmt stmt;
      (BStmt stmt, rest)
  | (TokFor i | TokWhile i) :: _ ->
      (* A `for`/`while` in value position is the same loop the
         statement form is; what it is *worth* is checked by the type
         checker. *)
      let stmt, rest = parse_loop_tail eof i None None None tokens in
      (BStmt stmt, rest)
  | TokLoop i :: rest ->
      (* A loop needs no check_value_stmt: its value is the accumulator,
         which every loop has. *)
      let stmt, rest = parse_loop_stmt eof i rest in
      (BStmt stmt, rest)
  | TokIf i :: rest -> (
      let cond, rest = parse_expr eof rest in
      match rest with
      | TokColon colon_info :: rest ->
          let stmt, rest = parse_if_stmt_tail eof i cond colon_info rest in
          check_value_stmt stmt;
          (BStmt stmt, rest)
      | TokThen _ :: _ ->
          let e, rest = parse_if_expr_tail eof i cond rest in
          let e, rest = parse_tuple_tail eof e rest in
          (BExpr e, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ':' or 'then' after if condition")))
  | _ ->
      let e, rest = parse_tuple_or_expr eof tokens in
      (BExpr e, rest)

(** Parses one statement. info -> [token] -> (stmt, [token]) *)
and parse_statement eof tokens =
  match tokens with
  | (TokImport i | TokFrom i) :: _ ->
      raise
        (Parse_error
           ( i,
             "an import belongs to the top level of a module, so it cannot \
              be written inside a block" ))
  | TokPublic i :: _ ->
      raise
        (Parse_error
           ( i,
             "only the top level of a module has names to export, so \
              'public' cannot be written inside a block" ))
  | TokDef i :: TokIdent (_, name) :: TokColon _ :: rest ->
      (* `def name : type` -- a signature on a line of its own, for the
         `def name(...)` in this same block. *)
      let type_, rest = parse_type eof rest in
      (SFunctionSig (combine_info i (type_info type_), name, type_, 0, false), rest)
  | TokDef i :: TokIdent (_, name) :: TokLParen _ :: rest -> (
      let params, rest = parse_params eof rest in
      let return_type, rest =
        match rest with
        | TokArrow _ :: rest2 ->
            let t, rest = parse_type eof rest2 in
            (Some t, rest)
        | _ -> (None, rest)
      in
      match rest with
      | TokColon colon_info :: rest ->
          let body, rest = parse_block eof rest colon_info in
          let def_info = combine_info i (block_end_info i body) in
          ( SFunctionDef (def_info, name, params, body, return_type, 0, false),
            rest )
      | _ -> raise (Parse_error (here eof rest, "expected ':' after def header")))
  | TokReturn i :: rest -> (
      (* `return` takes a bound value, not just an expression: the
         value-form `if`/`match` is allowed here as well as after `=`.
         parse_bound_value has already applied check_value_stmt to the
         statement form. *)
      let value, rest = parse_bound_value eof rest in
      match value with
      | BStmt stmt ->
          (SReturnStmt (combine_info i (stmt_info stmt), stmt, 0), rest)
      | BExpr e -> (SReturn (combine_info i (expr_info e), e, 0), rest))
  | (TokFor i | TokWhile i) :: _ ->
      (* A `for` or a `while` is a loop with no accumulator written: the
         same node, and so the same `break`/`continue`. *)
      parse_loop_tail eof i None None None tokens
  | TokLoop i :: rest -> parse_loop_stmt eof i rest
  | TokBreak i :: rest ->
      let operand, rest = parse_exit_operand eof i rest in
      let end_ = match operand with None -> i | Some e -> expr_info e in
      (SBreak (combine_info i end_, operand, 0), rest)
  | TokContinue i :: rest ->
      let operand, rest = parse_exit_operand eof i rest in
      let end_ = match operand with None -> i | Some e -> expr_info e in
      (SContinue (combine_info i end_, operand, 0), rest)
  | TokMatch i :: rest -> parse_match_stmt eof i rest
  (* A statement starting with `if` is either an if *statement*
     (`if cond: block`) or an if *expression* used as an expression
     statement. The two share the whole `"if" , expr` prefix, and that
     expr can be arbitrarily long, so no bounded lookahead tells them
     apart. Rather than backtrack, parse the shared prefix once and then
     dispatch on the single token that follows it. *)
  | TokIf i :: rest -> (
      let cond, rest = parse_expr eof rest in
      match rest with
      | TokColon colon_info :: rest -> parse_if_stmt_tail eof i cond colon_info rest
      | TokThen _ :: _ ->
          let e, rest = parse_if_expr_tail eof i cond rest in
          let e, rest = parse_tuple_tail eof e rest in
          (SExprStmt (expr_info e, e, 0), rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ':' or 'then' after if condition")))
  | TokVar i :: TokIdent (_, name) :: TokEq _ :: rest ->
      let value, rest = parse_bound_value eof rest in
      let e = expect_expr_value value "a 'var' declaration" in
      (SVar (combine_info i (expr_info e), name, e, 0), rest)
  | TokIdent (i, name) :: TokAssign _ :: rest ->
      let value, rest = parse_bound_value eof rest in
      let e = expect_expr_value value "a ':=' mutation" in
      (SMutate (combine_info i (expr_info e), name, e, 0), rest)
  (* `target = expr`, where `target` may destructure a tuple -- tried
     speculatively since, unlike the fixed-prefix cases above, a target
     can be an arbitrarily long comma-separated/nested prefix of tokens;
     if it doesn't pan out this falls through to the plain
     expression-statement case below. *)
  | (TokIdent _ | TokLParen _) :: _ -> (
      match try_parse_assignment_target eof tokens with
      | Some (target, annotation, rest) -> (
          let value, rest = parse_bound_value eof rest in
          match value with
          | BStmt stmt ->
              let let_info =
                combine_info (target_info target) (stmt_info stmt)
              in
              (SLetStmt (let_info, target, stmt, annotation, 0, false), rest)
          | BExpr e ->
              let let_info = combine_info (target_info target) (expr_info e) in
              (SLet (let_info, target, e, annotation, 0, false), rest))
      | None -> parse_expr_statement eof tokens)
  | _ -> parse_expr_statement eof tokens

and parse_expr_statement eof tokens =
  let e, rest = parse_tuple_or_expr eof tokens in
  (SExprStmt (expr_info e, e, 0), rest)

(* --- the rules the grammar cannot state --- *)

(** Raises Parse_error unless value is a plain expression, naming what
    (the position that requires one). bound_value -> string -> expr *)
and expect_expr_value value what =
  match value with
  | BStmt stmt ->
      raise
        (Parse_error
           ( stmt_info stmt,
             what
             ^ " takes an expression; a value-form 'if'/'match'/'loop' can \
                only be bound with '=' or returned with 'return'" ))
  | BExpr e -> e

(** Raises Parse_error unless stmt (an if/match in value form) yields a
    value on every path. stmt -> () *)
and check_value_stmt stmt =
  match stmt with
  | SIf (i, _, then_body, else_body, _) -> (
      match else_body with
      | None ->
          raise (Parse_error (i, "a value-form 'if' must have an 'else' branch"))
      | Some else_body ->
          check_value_block then_body i;
          check_value_block else_body i)
  | SMatch (_, _, cases, _) ->
      List.iter
        (fun c -> check_value_block (case_body c) (case_info c))
        cases
  | _ -> ()

(** Raises Parse_error unless stmts ends in an expression statement or a
    nested if/match that recursively does. [stmt] -> info -> () *)
and check_value_block stmts i =
  let message =
    "every branch of a value-form 'if'/'match' must end in an expression"
  in
  match List.rev stmts with
  | SExprStmt _ :: _ -> ()
  | ((SIf _ | SMatch _) as nested) :: _ -> check_value_stmt nested
  | last :: _ -> raise (Parse_error (stmt_info last, message))
  | [] -> raise (Parse_error (i, message))

(** Every name pattern binds, as (name, info) pairs.
    pattern -> [(string, info)] *)
and pattern_captures pattern =
  match pattern with
  | PCapture (i, name, _) -> [ (name, i) ]
  | PTuple (_, elements, _) -> List.concat_map pattern_captures elements
  | PList (_, prefix, rest, suffix, _) ->
      let caps = List.concat_map pattern_captures prefix in
      let caps =
        match rest with
        | Some (ListRest (i, Some name, _)) -> caps @ [ (name, i) ]
        | _ -> caps
      in
      caps @ List.concat_map pattern_captures suffix
  | _ -> []

(** Raises Parse_error if pattern binds the same name more than once.
    pattern -> () *)
and check_no_duplicate_captures pattern =
  let rec check seen captures =
    match captures with
    | [] -> ()
    | (name, i) :: rest ->
        if StringSet.mem name seen then
          raise
            (Parse_error (i, Printf.sprintf "duplicate binding '%s' in pattern" name))
        else check (StringSet.add name seen) rest
  in
  check StringSet.empty (pattern_captures pattern)

(** The one pattern a `++` chain means. Each segment is either fixed --
    a list with no rest of its own, or a string literal -- or the single
    name the middle binds to. [pattern] -> pattern *)
and joined_pattern segments =
  let first = List.hd segments in
  let last = List.nth segments (List.length segments - 1) in
  let i = combine_info (pattern_info first) (pattern_info last) in
  let before, middle, after =
    List.fold_left
      (fun (before, middle, after) segment ->
        match segment with
        | PCapture _ | PWildcard _ ->
            if middle <> None then
              raise
                (Parse_error
                   ( pattern_info segment,
                     "a '++' pattern takes at most one name: the rest is the \
                      one part whose length is not fixed" ))
            else (before, Some segment, after)
        | _ ->
            if middle = None then (before @ [ segment ], middle, after)
            else (before, middle, after @ [ segment ]))
      ([], None, []) segments
  in
  match middle with
  (* Nothing is left open, so this is just the pieces joined up. *)
  | None -> joined_fixed i before
  | Some middle -> split_pattern i before middle after

(** A `++` chain with no name in it: the segments joined into the one
    pattern they spell out. info -> [pattern] -> pattern *)
and joined_fixed i segments =
  if List.for_all (fun s -> match s with PString _ -> true | _ -> false) segments
  then
    PString
      ( i,
        String.concat ""
          (List.map
             (fun s -> match s with PString (_, v, _) -> v | _ -> "")
             segments),
        0 )
  else if List.for_all fixed_list segments then
    PList (i, List.concat_map list_prefix segments, None, [], 0)
  else raise (Parse_error (i, join_error))

(** A `++` chain around one name: a list pattern with a rest marker, or
    its string counterpart.
    info -> [pattern] -> pattern -> [pattern] -> pattern *)
and split_pattern i before middle after =
  let name = match middle with PCapture (_, n, _) -> Some n | _ -> None in
  let fixed = before @ after in
  let text s = match s with PString (_, v, _) -> v | _ -> "" in
  if List.for_all (fun s -> match s with PString _ -> true | _ -> false) fixed
  then
    PText
      ( i,
        String.concat "" (List.map text before),
        name,
        String.concat "" (List.map text after),
        0 )
  else if List.for_all fixed_list fixed then
    PList
      ( i,
        List.concat_map list_prefix before,
        Some (ListRest (pattern_info middle, name, 0)),
        List.concat_map list_prefix after,
        0 )
  else raise (Parse_error (i, join_error))

(** Whether a `++` segment is a list pattern of a fixed length -- one
    with no rest marker of its own, since two would leave the split
    ambiguous. pattern -> bool *)
and fixed_list pattern =
  match pattern with PList (_, _, None, _, _) -> true | _ -> false

and list_prefix pattern =
  match pattern with PList (_, prefix, _, _, _) -> prefix | _ -> []

(** Whether stmt always leaves the block it is in, so nothing after it
    can run. Only `break`/`continue` count -- a `return` after which
    more is written is legal Pyking. stmt -> bool *)
and always_exits stmt =
  match stmt with
  | SBreak _ | SContinue _ -> true
  | SIf (_, _, then_body, else_body, _) -> (
      match else_body with
      | None -> false
      | Some else_body ->
          then_body <> []
          && always_exits (List.nth then_body (List.length then_body - 1))
          && else_body <> []
          && always_exits (List.nth else_body (List.length else_body - 1)))
  | _ -> false

(** Raises Parse_error if current cannot be reached, previous having
    left the block already. stmt -> stmt -> () *)
and check_reachable previous current =
  if not (always_exits previous) then ()
  else
    raise
      (Parse_error
         ( stmt_info current,
           Printf.sprintf
             "this statement cannot be reached: '%s' has already left the \
              loop, so nothing written after it in the same block runs"
             (statement_text previous) ))

(** Raises Parse_error for a 'break'/'continue' outside a loop body.
    `held` is whether a loop they would belong to is open, and `crossed`
    names the construct that cut them off from it, for the message.
    [stmt] -> bool -> string option -> () *)
and check_loop_context stmts held crossed =
  List.iter
    (fun stmt ->
      match stmt with
      | SBreak (i, _, _) | SContinue (i, _, _) ->
          if not held then no_loop_here stmt i crossed
      | SLoop (_, _, _, _, _, _, body, _) -> check_loop_context body true None
      | SFunctionDef (_, _, _, body, _, _, _) ->
          check_loop_context body false (if held then Some "def" else crossed)
      | SIf (_, _, then_body, else_body, _) ->
          check_loop_context then_body held crossed;
          (match else_body with
          | None -> ()
          | Some body -> check_loop_context body held crossed)
      | SMatch (_, _, cases, _) ->
          List.iter
            (fun c -> check_loop_context (case_body c) held crossed)
            cases
      | SLetStmt (_, _, inner, _, _, _) | SReturnStmt (_, inner, _) ->
          check_loop_context [ inner ] held crossed
      | _ -> ())
    stmts

(** Raises the Parse_error for a 'break'/'continue' with no loop of its
    own. stmt -> info -> string option -> () *)
and no_loop_here stmt i crossed =
  let keyword = match stmt with SBreak _ -> "break" | _ -> "continue" in
  match crossed with
  | None ->
      raise
        (Parse_error
           ( i,
             Printf.sprintf "'%s' may only appear in the body of a 'loop'"
               keyword ))
  | Some crossed ->
      let inside =
        if crossed = "def" then "a function" else Printf.sprintf "a '%s'" crossed
      in
      raise
        (Parse_error
           ( i,
             Printf.sprintf
               "'%s' may only appear in the body of a 'loop', and this one is \
                inside %s, which it may not reach out of"
               keyword inside ))

(** Raises Parse_error if current begins on the same source line
    previous ended on. info -> info -> string -> (() -> string) ->
    (() -> string) -> () *)
and check_own_line previous current what describe_previous describe_current =
  if current.row1 > previous.row2 then ()
  else
    raise
      (Parse_error
         ( current,
           Printf.sprintf
             "each %s must start on a new line. In this case, '%s' and '%s' \
              are seen as two different %ss"
             what (describe_previous ()) (describe_current ()) what ))

(** Raises Parse_error if the next token continues the construct on the
    line its block just ended on. A block written there ends its line,
    so what continues the construct starts the next one.
    [stmt] -> [token] -> string -> () *)
and check_ends_line body tokens keyword =
  match (tokens, List.rev body) with
  | first :: _, last :: _ when (token_info first).row1 = (stmt_info last).row2 ->
      raise
        (Parse_error
           ( token_info first,
             Printf.sprintf
               "'%s' must start on a new line: the block written on the \
                header's own line ends that line"
               keyword ))
  | _ -> ()

(** Raises Parse_error if an indented block follows an inline one: the
    header's line held the whole block, so what is indented under it
    belongs to nothing. [token] -> () *)
and check_nothing_indented tokens =
  match tokens with
  | TokIndent i :: _ ->
      raise
        (Parse_error
           ( i,
             "a block written on its header's own line is the whole block, so \
              nothing may be indented under it" ))
  | _ -> ()

(** Raises Parse_error unless stmt is an expression statement. A block
    written on its header's own line holds one *expression* and nothing
    else. stmt -> () *)
and check_inline_value stmt =
  match stmt with
  | SExprStmt _ -> ()
  | _ ->
      raise
        (Parse_error
           ( stmt_info stmt,
             Printf.sprintf
               "a block written on its header's own line must be one \
                expression, and '%s' is not; write it in an indented block \
                instead"
               (shorten (pprint_stmt default_config stmt 0)) ))

(** Whether what follows a ':' begins on the header's own line, which is
    what makes it the one-statement inline block rather than an indented
    one. The lexer emits no token for a line ending, so this is read off
    the rows the tokens carry. info -> [token] -> bool *)
and on_header_line header_info tokens =
  match tokens with
  | first :: _ -> (token_info first).row1 = header_info.row2
  | [] -> false

(** The Info ending a header+block construct: the last statement's, or
    the header's own if the block is empty. info -> [stmt] -> info *)
and block_end_info header_info body =
  match List.rev body with last :: _ -> stmt_info last | [] -> header_info

(** A statement's own syntax, shortened for an error message.
    stmt -> string *)
and statement_text stmt = shorten (pprint_stmt default_config stmt 0)

(** A case clause's pattern, shortened for an error message.
    match_case -> string *)
and case_text clause =
  shorten ("case " ^ pprint_pattern default_config (case_pattern clause))

(** Truncates text to one line, short enough to quote in a sentence.
    string -> string *)
and shorten text =
  (* How much of a construct an error message quotes before it gives up
     and says "...". Long enough for the whole of a short statement, and
     short enough that two of them and a sentence still fit on a line. *)
  let quote_limit = 32 in
  let first = strip (List.hd (String.split_on_char '\n' text)) in
  if String.length first <= quote_limit then first
  else String.sub first 0 (quote_limit - 3) ^ "..."

(** Whether an identifier in type position names a type variable: one
    starting with a lowercase letter (`Int`, `String` and `Bool` are
    their own tokens). string -> bool *)
and is_type_var name =
  String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z'

(** The tokens an expression can begin with. `break`/`continue` take an
    operand only when one follows on the same line, and this is how
    "something follows" is decided. token -> bool *)
and expr_starter tok =
  match tok with
  | TokInt _ | TokString _ | TokIdent _ | TokTrue _ | TokFalse _ | TokSub _
  | TokLParen _ | TokLBracket _ | TokIf _ ->
      true
  | _ -> false

(* Pyking has no import-all form: a name a module reaches is written
   down, so reading the file says where every name comes from. *)
let no_star =
  "there is no '*' import in Pyking; name the values and functions to \
   import, or import the module itself and reach them through it"

(** Parses the modules of an `import a, b as c` line, one SImport each.
    The fields are left empty: what a qualified name reaches is the
    module's public names, which only the module system knows.
    info -> info -> [token] -> ([stmt], [token]) *)
let rec parse_import eof import_info tokens =
  let stmt, tokens =
    match tokens with
    | TokIdent (_, module_name) :: TokAs _ :: TokIdent (last, alias) :: rest ->
        (SImport (combine_info import_info last, module_name, alias, false, [], 0), rest)
    | TokIdent (last, module_name) :: rest ->
        ( SImport
            (combine_info import_info last, module_name, module_name, false, [], 0),
          rest )
    | TokMul i :: _ -> raise (Parse_error (i, no_star))
    | _ ->
        raise (Parse_error (here eof tokens, "expected a module name after 'import'"))
  in
  match tokens with
  | TokComma _ :: rest ->
      let rest_stmts, rest = parse_import eof import_info rest in
      (stmt :: rest_stmts, rest)
  | _ -> ([ stmt ], tokens)

(** Parses the names a `from` line takes, each paired with the name it is
    known by here. info -> [token] -> ((string * string) list, info, [token]) *)
let rec parse_import_fields eof tokens =
  let field, last, tokens =
    match tokens with
    | TokIdent (_, field) :: TokAs _ :: TokIdent (last, local) :: rest ->
        ((field, local), last, rest)
    | TokIdent (last, field) :: rest -> ((field, field), last, rest)
    | TokMul i :: _ -> raise (Parse_error (i, no_star))
    | _ -> raise (Parse_error (here eof tokens, "expected a name after 'import'"))
  in
  match tokens with
  | TokComma _ :: rest ->
      let fields, last, rest = parse_import_fields eof rest in
      (field :: fields, last, rest)
  | _ -> ([ field ], last, tokens)

(** Parses `from module import name, other as alias`, as one SImport
    naming the module and the fields taken from it.
    info -> info -> [token] -> ([stmt], [token]) *)
let parse_from_import eof from_info tokens =
  match tokens with
  | TokIdent (_, module_name) :: TokImport _ :: rest ->
      let fields, last, rest = parse_import_fields eof rest in
      let i = combine_info from_info last in
      ([ SImport (i, module_name, module_name, true, fields, 0) ], rest)
  | TokIdent (_, _) :: rest ->
      raise
        (Parse_error (here eof rest, "expected 'import' after the module name"))
  | _ ->
      raise (Parse_error (here eof tokens, "expected a module name after 'from'"))

(** One statement with `public` written in front of it. stmt -> info ->
    stmt *)
let made_public stmt public_info =
  let i = combine_info public_info (stmt_info stmt) in
  match stmt with
  | SFunctionDef (_, name, params, body, return_type, sym, _) ->
      SFunctionDef (i, name, params, body, return_type, sym, true)
  | SFunctionSig (_, name, type_, sym, _) ->
      SFunctionSig (i, name, type_, sym, true)
  | SLet (_, (TargetName _ as target), e, annotation, sym, _) ->
      SLet (i, target, e, annotation, sym, true)
  | SLetStmt (_, (TargetName _ as target), inner, annotation, sym, _) ->
      SLetStmt (i, target, inner, annotation, sym, true)
  | SLet (_, _, _, _, _, _) | SLetStmt (_, _, _, _, _, _) ->
      raise
        (Parse_error
           ( stmt_info stmt,
             "a public binding names one value, so it cannot take a tuple \
              apart; bind the parts first and make each public" ))
  | _ ->
      raise
        (Parse_error
           ( i,
             Printf.sprintf
               "'public' says what a module exports, so it goes in front of a \
                'def', a 'def' signature line, or an '=' binding, not '%s'"
               (shorten (statement_text stmt)) ))

(** Parses what a `public` exports: a `def`, a `def name : type`
    signature line, or an `=` binding of one name.
    info -> info -> [token] -> (stmt, [token]) *)
let parse_public eof public_info tokens =
  (match tokens with
  | TokVar i :: _ ->
      raise
        (Parse_error
           ( combine_info public_info i,
             "a 'var' cannot be public: a module exports values and \
              functions, not variables another module could write to" ))
  | [] ->
      raise
        (Parse_error
           ( here eof tokens,
             "expected a definition or a binding after 'public'" ))
  | _ -> ());
  let stmt, rest = parse_statement eof tokens in
  (made_public stmt public_info, rest)

(** Parses one top-level statement, or the several an `import a, b` line
    stands for. The two forms a module is written with -- an import and a
    `public` -- are parsed only here, which is what makes them top
    level: parse_statement, which every block goes through, refuses both.
    info -> [token] -> ([stmt], [token]) *)
let parse_top_statement eof tokens =
  match tokens with
  | TokImport i :: rest -> parse_import eof i rest
  | TokFrom i :: rest -> parse_from_import eof i rest
  | TokPublic i :: rest ->
      let stmt, rest = parse_public eof i rest in
      ([ stmt ], rest)
  | _ ->
      let stmt, rest = parse_statement eof tokens in
      ([ stmt ], rest)

(** Parses a full token stream into a list of top-level statements.
    [token] -> [stmt] *)
let parse tokens =
  let eof =
    match List.rev tokens with
    | last :: _ -> token_info last
    | [] -> { file = "<empty>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
  in
  let rec statements rest collected =
    match rest with
    | [] -> List.rev collected
    | _ ->
        (* A group, because `import a, b` is one line standing for two
           statements; every other line gives a group of one. *)
        let group, rest = parse_top_statement eof rest in
        (match (collected, group) with
        | previous :: _, first :: _ ->
            check_own_line (stmt_info previous) (stmt_info first) "statement"
              (fun () -> statement_text previous)
              (fun () -> statement_text first);
            check_reachable previous first
        | _ -> ());
        statements rest (List.rev_append group collected)
  in
  let stmts = statements tokens [] in
  check_loop_context stmts false None;
  stmts
