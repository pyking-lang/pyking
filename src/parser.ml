(** Recursive-descent parser: tokens (from lexer.ml) to the AST defined
    in syntax.ml. Also enforces the handful of grammar rules that cannot
    be expressed in EBNF -- duplicate pattern captures, value-form
    if/match branches, one statement per line, and where a
    'break'/'continue' may stand. See PYKING.md for the grammar.

    The end-of-input position is a value, `eof`, passed to every
    function that can run out of tokens -- the position to blame when
    there is no next token to blame.

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
   in value form -- an if/match, or a loop. The two are told apart by
   the constructor, so no caller has to ask which it got. *)
type bound_value = BExpr of expr | BStmt of stmt

(* --- parser --- *)

let join_error =
  "'+' joins list patterns or string patterns, and the two may not be mixed; \
   every part but one name must have a fixed length"

(* What each spelling Pyking no longer has is answered with. *)
let concat_message =
  "'++' is now written '+': 'a + b' joins two strings or two lists"

let lambda_message = "a lambda is now written 'lam x. x + 1'"

(** Why a reserved word cannot stand where a name would. String -> String *)
let reserved_message word =
  Printf.sprintf
    "'%s' is reserved for a later part of the language, so it cannot be \
     used as a name"
    word


(** Refuses a qualified name where only a plain one may stand. `::` is
    what makes an overloaded definition's name unique, and only a `def`
    with at least one parameter has arguments for a call to resolve it
    by, so nothing else may carry one (PYKING.md, "Static overloading").
    info -> String -> String -> () *)
let rec check_plain_name info name what =
  if Names.is_qualified name then
    raise
      (Parse_error
         ( info,
           Printf.sprintf
             "'%s' cannot be %s: a '::' name belongs to a 'def' that takes \
              at least one argument, which is what resolves which of them \
              a call means"
             name what ));
  check_lowercase info name what

(** Refuses a bound name, or any part of a dotted or `::` one, starting
    with an uppercase letter: that is a type or a constructor (PYKING.md,
    "Names"). info -> String -> String -> () *)
and check_lowercase info name what =
  let parts = String.split_on_char '.' (Names.base name) in
  let parts = match Names.qualifier name with Some q -> q :: parts | None -> parts in
  if List.exists is_constructor_name parts then
    raise
      (Parse_error
         ( info,
           Printf.sprintf
             "'%s' cannot be %s: a name a program binds starts with a \
              lowercase letter, and one starting with an uppercase letter \
              is a type or a constructor"
             name what ))

(** Parses one atom: a literal, name, parenthesized expression, tuple,
    list, or list comprehension. info -> [token] -> (expr, [token]) *)
and parse_atom eof tokens =
  match tokens with
  | TokInt (i, v) :: rest -> parse_call_tail eof (EInt (i, v, 0)) rest
  | TokFloat (i, v) :: rest -> parse_call_tail eof (EFloat (i, v, 0)) rest
  | TokString (i, s) :: rest -> parse_call_tail eof (EString (i, s, 0)) rest
  | TokChar (i, c) :: rest -> parse_call_tail eof (EChar (i, c, 0)) rest
  | TokTrue i :: rest -> parse_call_tail eof (EBool (i, true, 0)) rest
  | TokFalse i :: rest -> parse_call_tail eof (EBool (i, false, 0)) rest
  | TokIdent _ :: TokDot _ :: _ when Option.is_some (constructor_path tokens) ->
      (* `module.Name`: a constructor of a datatype another module
         exports, or of one in a submodule (`shapes.Circle`,
         `hello.shapes.Circle`). *)
      let i, module_name, name_info, name, rest = Option.get (constructor_path tokens) in
      parse_construct eof (combine_info i name_info) (Some module_name) name rest
  | TokIdent (i, name) :: rest when is_constructor_name name ->
      parse_construct eof i None name rest
  | TokIdent (i, module_name) :: TokDot dot :: TokIdent (name_info, name) :: rest
    when dot.row1 = i.row2 && not (Names.is_qualified module_name) ->
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
          (* (e, e, ...): the same shape as a call's arguments, minus
             the `name = ` form, which belongs to a call alone. *)
          let elements, rp, rest = parse_tuple_elements eof rest in
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
  | TokReserved (i, word) :: _ -> raise (Parse_error (i, reserved_message word))
  | t :: _ -> raise (Parse_error (token_info t, "unexpected token in expression"))
  | [] ->
      raise
        (Parse_error (here eof tokens, "unexpected end of input in expression"))

(** Parses a constructor and its arguments, if a `(` follows on the
    constructor's own row; without one it is a constructor of no fields.
    info -> info -> String? -> String -> [token] -> (expr, [token]) *)
and parse_construct eof i module_ name tokens =
  match tokens with
  | TokLParen lp :: rest when lp.row1 = i.row2 ->
      let args, rparen, rest = parse_args eof rest in
      check_argument_shape args;
      parse_call_tail eof
        (EConstruct (combine_info i rparen, module_, name, args, 0))
        rest
  | _ -> parse_call_tail eof (EConstruct (i, module_, name, [], 0)) tokens

(** Parses zero or more call suffixes onto expr, chaining `f(1)(2)`. A
    `(` only extends expr if it starts on the same source row expr ended
    on, so it cannot swallow the next statement's. A `.name` on the same
    row reads a field.
    info -> expr -> [token] -> (expr, [token]) *)
and parse_call_tail eof e tokens =
  match tokens with
  | TokDot dot :: TokIdent (ni, name) :: rest
    when dot.row1 = (expr_info e).row2 && ni.row1 = dot.row2
         && not (is_constructor_name name) ->
      parse_call_tail eof
        (EField (combine_info (expr_info e) ni, e, name, 0))
        rest
  | TokLBracket lb :: rest when lb.row1 = (expr_info e).row2 -> (
      (* `xs[i]`: the `[` is on the row the list ends on, for the reason
         a call's `(` is -- otherwise a list literal starting the next
         line would index this one. *)
      let index, rest = parse_expr eof rest in
      match rest with
      | TokRBracket rb :: rest ->
          parse_call_tail eof (EIndex (combine_info (expr_info e) rb, e, index, 0)) rest
      | _ -> raise (Parse_error (here eof rest, "expected ']' after the index")))
  | TokLParen lp :: rest when lp.row1 = (expr_info e).row2 ->
      let args, rparen, rest = parse_args eof rest in
      let call_info = combine_info (expr_info e) rparen in
      (match List.assoc_opt (Some spread_label) args with
      | Some base ->
          raise
            (Parse_error
               ( expr_info base,
                 "'..' gives a constructor the fields of another value, and \
                  a function has no fields: '..' is written only in a \
                  constructor's arguments" ))
      | None -> ());
      check_argument_shape args;
      parse_call_tail eof (ECall (call_info, e, args, 0)) rest
  | _ -> (e, tokens)

(** Parses comma-separated call arguments up to and including ')'. An
    argument written `name = expr` carries that parameter name, and a
    last one written `..expr` the label Syntax.spread_label.
    info -> [token] -> ([(String?, expr)], info, [token]) *)
and parse_args eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | TokDotDot _ :: rest -> (
      let base, rest = parse_expr eof rest in
      match rest with
      | TokRParen i :: rest -> ([ (Some spread_label, base) ], i, rest)
      | _ ->
          raise
            (Parse_error
               ( here eof rest,
                 "'..' gives the fields not written before it, so it is the \
                  last argument: expected ')'" )))
  | _ -> (
      let name, tokens =
        match tokens with
        | TokIdent (_, name) :: TokEq _ :: rest -> (Some name, rest)
        | _ -> (None, tokens)
      in
      let arg, rest = parse_expr eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let args, rparen, rest = parse_args eof rest in
          ((name, arg) :: args, rparen, rest)
      | TokRParen i :: rest -> ([ (name, arg) ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in call arguments")))

(** Parses comma-separated tuple elements up to and including ')'.
    info -> [token] -> ([expr], info, [token]) *)
and parse_tuple_elements eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | _ -> (
      let element, rest = parse_expr eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let elements, rparen, rest = parse_tuple_elements eof rest in
          (element :: elements, rparen, rest)
      | TokRParen i :: rest -> ([ element ], i, rest)
      | _ -> raise (Parse_error (here eof rest, "expected ',' or ')'")))

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

(** Parses a prefix operator -- unary minus, `!` or `~` -- or falls
    through to a power. All three bind tighter than `*` and looser than
    `^`, so `-2 ^ 2` is `-(2 ^ 2)`. info -> [token] -> (expr, [token]) *)
and parse_unary eof tokens =
  let prefix i make rest =
    let operand, rest = parse_unary eof rest in
    (make (combine_info i (expr_info operand)) operand, rest)
  in
  match tokens with
  | TokSub i :: rest -> prefix i (fun info o -> ENeg (info, o, 0)) rest
  | TokBang i :: rest -> prefix i (fun info o -> EUnary (info, UNot Symbol, o, 0)) rest
  | TokTilde i :: rest -> prefix i (fun info o -> EUnary (info, UBitNot Symbol, o, 0)) rest
  | _ -> parse_power eof tokens

(** Parses `atom ^ unary`. `^` associates to the right -- its right
    operand is another unary, which may itself be a power -- and `**`,
    Python's spelling, is refused with the one Pyking uses.
    info -> [token] -> (expr, [token]) *)
and parse_power eof tokens =
  let base, rest = parse_atom eof tokens in
  match rest with
  | TokCaret _ :: rest ->
      let exponent, rest = parse_unary eof rest in
      (EBinary (combine_info (expr_info base) (expr_info exponent), BPow, base, exponent, 0), rest)
  | TokStarStar i :: _ ->
      raise (Parse_error (i, "a power is written with '^', as in 'a ^ b'"))
  | _ -> (base, rest)

(** Parses a left-associative chain of binary operators over `operand`,
    each token mapped to the node it builds by `operator`.
    (info -> [token] -> (expr, [token])) -> (token -> (expr -> expr -> info -> expr) option)
    -> info -> [token] -> (expr, [token]) *)
and parse_chain operand operator eof tokens =
  let left, rest = operand eof tokens in
  let rec more left rest =
    match rest with
    | t :: rest2 -> (
        match operator t with
        | Some make ->
            let right, rest2 = operand eof rest2 in
            more (make left right (combine_info (expr_info left) (expr_info right))) rest2
        | None -> (left, rest))
    | [] -> (left, rest)
  in
  more left rest

(** Parses `*`/`/`/`%`, left-associative. info -> [token] -> (expr, [token]) *)
and parse_multiplicative eof tokens =
  parse_chain parse_unary
    (function
      | TokMul _ -> Some (fun l r i -> EMul (i, l, r, 0))
      | TokDiv _ -> Some (fun l r i -> EDiv (i, l, r, 0))
      | TokPercent _ -> Some (fun l r i -> EBinary (i, BMod, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `+`/`-`, left-associative. `+` both adds and joins; the
    checker says which. `++`, which used to join, is refused where it
    stands. info -> [token] -> (expr, [token]) *)
and parse_additive eof tokens =
  parse_chain parse_multiplicative
    (function
      | TokAdd _ -> Some (fun l r i -> EAdd (i, l, r, 0))
      | TokSub _ -> Some (fun l r i -> ESub (i, l, r, 0))
      | TokConcat i -> raise (Parse_error (i, concat_message))
      | _ -> None)
    eof tokens

(** Parses `<<`/`>>`, left-associative. info -> [token] -> (expr, [token]) *)
and parse_shift eof tokens =
  parse_chain parse_additive
    (function
      | TokShiftLeft _ -> Some (fun l r i -> EBinary (i, BShiftLeft, l, r, 0))
      | TokShiftRight _ -> Some (fun l r i -> EBinary (i, BShiftRight, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `&`, left-associative. info -> [token] -> (expr, [token]) *)
and parse_bit_and eof tokens =
  parse_chain parse_shift
    (function
      | TokAmp _ -> Some (fun l r i -> EBinary (i, BBitAnd Symbol, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `xor`, left-associative. info -> [token] -> (expr, [token]) *)
and parse_xor eof tokens =
  parse_chain parse_bit_and
    (function
      | TokXor _ -> Some (fun l r i -> EBinary (i, BXor, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `|`, left-associative. The bitwise operators bind tighter
    than a comparison, as Python's do, so `flags & 4 == 4` is
    `(flags & 4) == 4`. info -> [token] -> (expr, [token]) *)
and parse_bit_or eof tokens =
  parse_chain parse_xor
    (function
      | TokBar _ -> Some (fun l r i -> EBinary (i, BBitOr Symbol, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `not`, which binds as loosely as Python's: `not a == b` is
    `not (a == b)`. info -> [token] -> (expr, [token]) *)
and parse_not eof tokens =
  match tokens with
  | TokNot i :: rest ->
      let operand, rest = parse_not eof rest in
      (EUnary (combine_info i (expr_info operand), UNot Word, operand, 0), rest)
  | _ -> parse_comparison eof tokens

(** Parses `and`/`&&`, left-associative, keeping which was written.
    info -> [token] -> (expr, [token]) *)
and parse_and eof tokens =
  parse_chain parse_not
    (function
      | TokAnd _ -> Some (fun l r i -> EBinary (i, BAnd Word, l, r, 0))
      | TokAmpAmp _ -> Some (fun l r i -> EBinary (i, BAnd Symbol, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses `or`/`||`, left-associative, keeping which was written.
    info -> [token] -> (expr, [token]) *)
and parse_or eof tokens =
  parse_chain parse_and
    (function
      | TokOr _ -> Some (fun l r i -> EBinary (i, BOr Word, l, r, 0))
      | TokBarBar _ -> Some (fun l r i -> EBinary (i, BOr Symbol, l, r, 0))
      | _ -> None)
    eof tokens

(** Parses the lowest-precedence expression level: a lambda, an if
    expression, a let expression or an `or`. A `=>` after it is the
    lambda syntax Pyking had before `lam`, and is refused by name.
    info -> [token] -> (expr, [token]) *)
and parse_expr eof tokens =
  let e, rest =
    match tokens with
    | TokIf i :: rest ->
        let cond, rest = parse_expr eof rest in
        parse_if_expr_tail eof i cond rest
    | TokLet i :: rest -> parse_let eof i rest
    | TokLam i :: rest -> parse_lambda eof i rest
    | _ -> parse_or eof tokens
  in
  match rest with
  | TokFatArrow i :: _ -> raise (Parse_error (i, lambda_message))
  | _ -> (e, rest)

(** Parses one lambda after its `lam`: one parameter with no type, or a
    parenthesized list of them, then a `.` and the body. The body is
    `parse_expr`, so a lambda takes everything to its right that one
    expression can hold: `lam x. lam y. e` is curried, and `lam x. a, b`
    is a pair whose first element is the lambda, as a comma binds looser
    than any expression.

    A typed parameter is always in parentheses: a type may hold a `.`
    of its own (`geo.Point`, `all a. a`), and in parentheses it ends at
    the `)`, so the next `.` can only be the lambda's.
    info -> info -> [token] -> (expr, [token]) *)
and parse_lambda eof lam_info tokens =
  let body_after params rest =
    match rest with
    | TokDot _ :: rest ->
        let body, rest = parse_expr eof rest in
        (ELambda (combine_info lam_info (expr_info body), params, body, 0), rest)
    | _ ->
        raise
          (Parse_error
             (here eof rest, "expected '.' after the parameters of a lambda, as in 'lam x. x + 1'"))
  in
  match tokens with
  | TokIdent (i, name) :: TokColon _ :: _ ->
      raise
        (Parse_error
           ( i,
             Printf.sprintf
               "a lambda parameter with a type is written in parentheses, \
                as in 'lam (%s: Int). ...'"
               name ))
  | TokIdent (i, name) :: TokComma _ :: _ ->
      raise
        (Parse_error
           ( i,
             Printf.sprintf
               "a lambda's parameters are written in parentheses when there \
                are several, as in 'lam (%s, y). ...'"
               name ))
  | TokIdent (i, name) :: rest ->
      check_plain_name i name "a parameter";
      body_after [ Param (i, name, None, None, 0) ] rest
  | TokLParen _ :: after ->
      let params, implicits, rest = parse_params eof after in
      List.iter check_no_lambda_default params;
      (match implicits with
      | Param (info, name, _, _, _) :: _ ->
          raise
            (Parse_error
               ( info,
                 Printf.sprintf
                   "the lambda parameter '%s' may not be implicit: an \
                    implicit parameter is part of a function's type, and \
                    only a 'def' writes one down"
                   name ))
      | [] -> ());
      body_after params rest
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             "expected a parameter or '(' after 'lam', as in 'lam x. x + 1'" ))

(** A lambda parameter may not carry a default: a default is evaluated
    where the definition is written, and a lambda is an expression that
    is written wherever it stands. param -> () *)
and check_no_lambda_default (Param (info, name, _, default, _)) =
  match default with
  | None -> ()
  | Some _ ->
      raise
        (Parse_error
           ( info,
             Printf.sprintf
               "the lambda parameter '%s' may not have a default value; only \
                a 'def' parameter may"
               name ))

(** Parses `target[: type] = value in body`, given the already-parsed
    `let`. info -> info -> [token] -> (expr, [token]) *)
and parse_let eof let_info tokens =
  let target, rest = parse_target eof tokens in
  let annotation, rest =
    match rest with
    | TokColon _ :: rest ->
        let type_, rest = parse_type eof rest in
        (Some type_, rest)
    | _ -> (None, rest)
  in
  match rest with
  | TokEq _ :: rest -> (
      check_let_target target;
      let value, rest = parse_expr eof rest in
      match rest with
      | TokIn _ :: rest ->
          let body, rest = parse_expr eof rest in
          ( ELet (combine_info let_info (expr_info body), target, annotation, value, body, 0),
            rest )
      | _ -> raise (Parse_error (here eof rest, "expected 'in' after the value of a 'let'")))
  | _ -> raise (Parse_error (here eof rest, "expected '=' after the name a 'let' binds"))

(** Refuses a qualified name in a let's target, and a name bound twice
    there. assign_target -> () *)
and check_let_target target =
  let rec names target =
    match target with
    | TargetName (info, name, _) ->
        check_plain_name info name "bound with 'let'";
        [ (info, name) ]
    | TargetTuple (_, elements, _) -> List.concat_map names elements
  in
  ignore
    (List.fold_left
       (fun seen (info, name) ->
         if List.mem name seen then
           raise (Parse_error (info, Printf.sprintf "duplicate binding '%s' in 'let'" name))
         else name :: seen)
       [] (names target))

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
  let left, rest = parse_bit_or eof tokens in
  let span right = combine_info (expr_info left) (expr_info right) in
  let operand rest = parse_bit_or eof rest in
  let built, rest =
    match rest with
    | TokLessThan _ :: rest ->
        let right, rest = operand rest in
        (ELessThan (span right, left, right, 0), rest)
    | TokLessThanEq _ :: rest ->
        let right, rest = operand rest in
        (ELessThanEq (span right, left, right, 0), rest)
    | TokGreatThan _ :: rest ->
        let right, rest = operand rest in
        (EGreatThan (span right, left, right, 0), rest)
    | TokGreatThanEq _ :: rest ->
        let right, rest = operand rest in
        (EGreatThanEq (span right, left, right, 0), rest)
    | TokEqEq _ :: rest ->
        let right, rest = operand rest in
        (EEq (span right, left, right, 0), rest)
    | TokNotEq _ :: rest ->
        let right, rest = operand rest in
        (EBinary (span right, BNeq, left, right, 0), rest)
    | _ -> (left, rest)
  in
  (* Comparisons do not chain; a second one is refused with what to
     write instead. *)
  match (built, rest) with
  | (ELessThan _ | ELessThanEq _ | EGreatThan _ | EGreatThanEq _ | EEq _
    | EBinary (_, BNeq, _, _, _)),
    (( TokLessThan i | TokLessThanEq i | TokGreatThan i | TokGreatThanEq i
     | TokEqEq i | TokNotEq i ) :: _) ->
      raise
        (Parse_error
           ( i,
             "comparisons do not chain: write 'a < b and b < c' rather than \
              'a < b < c'" ))
  | _ -> (built, rest)

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
            None,
            [] ),
        rest )
  | _ -> (atom, rest)

(** Parses one type that is not an unparenthesized `->`.
    info -> [token] -> (typ, [token]) *)
and parse_type_atom eof tokens =
  match tokens with
  | TokTypeInt i :: rest -> (TInt (i, 0), rest)
  | TokTypeFloat i :: rest -> (TFloat (i, 0), rest)
  | TokTypeString i :: rest -> (TString (i, 0), rest)
  | TokTypeChar i :: rest -> (TChar (i, 0), rest)
  | TokTypeBool i :: rest -> (TBool (i, 0), rest)
  | TokIdent (i, "all") :: rest ->
      (* `all a b. T`. `all` is reserved in type position, so it is
         never itself a variable name. *)
      let names, rest = parse_type_vars eof rest in
      let body, rest = parse_type eof rest in
      (TForall (combine_info i (type_info body), names, body, 0), rest)
  | TokIdent _ :: TokDot _ :: _ when Option.is_some (constructor_path tokens) ->
      let i, module_, ni, name, rest = Option.get (constructor_path tokens) in
      parse_type_application eof (combine_info i ni) (module_ ^ "." ^ name) rest
  | TokIdent (i, name) :: rest when is_constructor_name name ->
      parse_type_application eof i name rest
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
      let elements, implicits, trailing, rp, rest =
        parse_type_elements eof rest
      in
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
                None,
                implicits ),
            rest )
      | _ ->
          if implicits <> [] then
            raise
              (Parse_error
                 ( lp,
                   "only a function type has implicit parameters, and this \
                    one has no '->' after its ')'" ))
          else if List.length elements = 1 && not trailing then
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

(** Parses a datatype's name and the types it is applied to, if a `(`
    follows on the name's own row. info -> String -> [token] ->
    (typ, [token]) *)
and parse_type_application eof i name tokens =
  match tokens with
  | TokLParen lp :: rest when lp.row1 = i.row2 ->
      let elements, implicits, _, rp, rest = parse_type_elements eof rest in
      if implicits <> [] then
        raise
          (Parse_error
             (lp, "a datatype is applied to types, not implicit parameters"))
      else (TCon (combine_info i rp, name, elements, 0), rest)
  | _ -> (TCon (i, name, [], 0), tokens)

(** Parses comma-separated types up to and including ')', also saying
    whether a comma came just before that ')' -- which is the whole of
    what tells the singleton tuple `(T,)` from the grouping `(T)`.
    An `implicit name: type` entry is a function type's implicit
    parameter, which is trailing and part of the type by name as well as
    by type (PYKING.md, "Implicits"); a tuple type has none.
    info -> [token] -> ([typ], [implicit_param], bool, info, [token]) *)
and parse_type_elements eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], [], false, i, rest)
  | TokImplicit _ :: _ ->
      let implicits, rp, rest = parse_implicit_type_params eof tokens in
      ([], implicits, false, rp, rest)
  | _ -> (
      let elem, rest = parse_type eof tokens in
      match rest with
      | TokComma _ :: TokRParen i :: rest -> ([ elem ], [], true, i, rest)
      | TokComma _ :: rest ->
          let elems, implicits, trailing, rp, rest =
            parse_type_elements eof rest
          in
          (elem :: elems, implicits, trailing, rp, rest)
      | TokRParen i :: rest -> ([ elem ], [], false, i, rest)
      | _ ->
          raise
            (Parse_error (here eof rest, "expected ',' or ')' in tuple type")))

(** Parses the `implicit name: type` entries that end a function type,
    up to and including the ')'.
    info -> [token] -> ([implicit_param], info, [token]) *)
and parse_implicit_type_params eof tokens =
  match tokens with
  | TokImplicit _ :: TokIdent (i, name) :: TokColon _ :: rest -> (
      check_plain_name i name "an implicit parameter";
      let type_, rest = parse_type eof rest in
      let one = IParam (name, type_) in
      match rest with
      | TokComma _ :: rest ->
          let rest_params, rp, rest = parse_implicit_type_params eof rest in
          (one :: rest_params, rp, rest)
      | TokRParen rp :: rest -> ([ one ], rp, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in a function type")))
  | TokImplicit i :: _ ->
      raise
        (Parse_error
           ( i,
             "an implicit parameter is written 'implicit name: type': it \
              needs both a name and a type, since that pair is what \
              resolves it" ))
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             "an implicit parameter comes after every ordinary one, so \
              nothing may follow it but another implicit parameter" ))

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

(** Parses one parameter, `name`, `name: type`, or either followed by
    `= default`. info -> [token] -> (param, [token]) *)
and parse_param eof tokens =
  let named, type_, i, rest =
    match tokens with
    | TokIdent (i, name) :: TokColon _ :: rest ->
        check_plain_name i name "a parameter";
        let type_, rest = parse_type eof rest in
        (name, Some type_, combine_info i (type_info type_), rest)
    | TokIdent (i, name) :: rest ->
        check_plain_name i name "a parameter";
        (name, None, i, rest)
    | _ -> raise (Parse_error (here eof tokens, "expected a parameter"))
  in
  match rest with
  | TokEq _ :: rest ->
      let default, rest = parse_expr eof rest in
      ( Param (combine_info i (expr_info default), named, type_, Some default, 0),
        rest )
  | _ -> (Param (i, named, type_, None, 0), rest)

(** Parses comma-separated parameters up to and including ')', answering
    the ordinary ones and the implicit ones apart. Implicit parameters
    are trailing, so once one is seen nothing but another may follow
    (PYKING.md, "Implicits").
    info -> [token] -> ([param], [param], [token]) *)
and parse_params eof tokens =
  match tokens with
  | TokRParen _ :: rest -> ([], [], rest)
  | TokImplicit _ :: _ ->
      let implicits, rest = parse_implicit_params eof tokens in
      ([], implicits, rest)
  | _ -> (
      let param, rest = parse_param eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let params, implicits, rest = parse_params eof rest in
          check_trailing_defaults param params;
          (param :: params, implicits, rest)
      | TokRParen _ :: rest -> ([ param ], [], rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in parameter list")))

(** Parses the `implicit name: type` parameters that end a parameter
    list, up to and including the ')'. Each needs its type written: the
    name and the type together are what resolve it at a call.
    info -> [token] -> ([param], [token]) *)
and parse_implicit_params eof tokens =
  match tokens with
  | TokImplicit start :: TokIdent (i, name) :: TokColon _ :: rest -> (
      check_plain_name i name "an implicit parameter";
      let type_, rest = parse_type eof rest in
      let one =
        Param (combine_info start (type_info type_), name, Some type_, None, 0)
      in
      match rest with
      | TokEq _ :: _ ->
          raise
            (Parse_error
               ( combine_info start (type_info type_),
                 Printf.sprintf
                   "the implicit parameter '%s' may not have a default \
                    value: an omitted implicit argument is resolved from \
                    the calling context, which is what makes it implicit"
                   name ))
      | TokComma _ :: rest ->
          let rest_params, rest = parse_implicit_params eof rest in
          (one :: rest_params, rest)
      | TokRParen _ :: rest -> ([ one ], rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in parameter list")))
  | TokImplicit i :: _ ->
      raise
        (Parse_error
           ( i,
             "an implicit parameter is written 'implicit name: type': it \
              needs both a name and a type, since that pair is what \
              resolves it" ))
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             "an implicit parameter comes after every ordinary one, so \
              nothing may follow it but another implicit parameter" ))

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
      | TokEq _ :: rest ->
          (* Committed: only now is a qualified name in the target a
             mistake rather than a reason to read these tokens as an
             expression instead. *)
          check_plain_target target;
          Some (target, annotation, rest)
      | _ -> None)

(** Refuses a qualified name anywhere in a binding's target.
    assign_target -> () *)
and check_plain_target target =
  match target with
  | TargetName (info, name, _) -> check_plain_name info name "bound with '='"
  | TargetTuple (_, elements, _) -> List.iter check_plain_target elements

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
  | TokChar (i, c) :: rest -> (PChar (i, c, 0), rest)
  | TokTrue i :: rest -> (PBool (i, true, 0), rest)
  | TokFalse i :: rest -> (PBool (i, false, 0), rest)
  | TokIdent (i, "_") :: rest -> (PWildcard (i, 0), rest)
  | TokIdent _ :: TokDot _ :: _ when Option.is_some (constructor_path tokens) ->
      let i, module_, ni, name, rest = Option.get (constructor_path tokens) in
      parse_constructor_pattern eof (combine_info i ni) (Some module_) name rest
  | TokIdent (i, name) :: rest when is_constructor_name name ->
      parse_constructor_pattern eof i None name rest
  | TokIdent (i, name) :: rest ->
      check_plain_name i name "bound by a pattern";
      (PCapture (i, name, 0), rest)
  | TokLParen lp :: TokRParen rp :: rest ->
      (PTuple (combine_info lp rp, [], 0), rest)
  | TokLParen lp :: rest -> (
      let first, rest = parse_pattern_as eof rest in
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
             "expected a pattern (integer, string, '_', identifier, \
              constructor, tuple, or list)" ))

(** Parses a constructor pattern after its name: its fields in
    parentheses, positional ones first and then `name = pattern` ones,
    where a `(` follows on the name's own row.
    info -> info -> String? -> String -> [token] -> (pattern, [token]) *)
and parse_constructor_pattern eof i module_ name tokens =
  match tokens with
  | TokLParen lp :: rest when lp.row1 = i.row2 ->
      let rec fields rest positional named =
        match rest with
        | TokRParen rp :: rest -> (List.rev positional, List.rev named, rp, rest)
        | _ -> (
            let positional, named, rest =
              match rest with
              | TokIdent (ni, field) :: TokEq _ :: rest ->
                  let p, rest = parse_pattern_as eof rest in
                  if List.mem_assoc field named then
                    raise
                      (Parse_error
                         ( ni,
                           Printf.sprintf "the field '%s' is matched twice"
                             field ));
                  (positional, (field, p) :: named, rest)
              | _ ->
                  let p, rest = parse_pattern_as eof rest in
                  if named <> [] then
                    raise
                      (Parse_error
                         ( pattern_info p,
                           "a positional field pattern comes before every \
                            named one" ));
                  (p :: positional, named, rest)
            in
            match rest with
            | TokComma _ :: rest -> fields rest positional named
            | TokRParen rp :: rest ->
                (List.rev positional, List.rev named, rp, rest)
            | _ ->
                raise
                  (Parse_error
                     (here eof rest, "expected ',' or ')' in a constructor pattern"))
            )
      in
      let positional, named, rp, rest = fields rest [] [] in
      (PConstructor (combine_info i rp, module_, name, positional, named, 0), rest)
  | _ -> (PConstructor (i, module_, name, [], [], 0), tokens)

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
      check_plain_name name_info name "bound by a pattern";
      (Either.Right (ListRest (combine_info i name_info, Some name, 0)), rest)
  | TokDotDot i :: rest -> (Either.Right (ListRest (i, None, 0)), rest)
  | _ ->
      let pattern, rest = parse_pattern_as eof tokens in
      (Either.Left pattern, rest)

and parse_pattern_paren_tail eof tokens =
  match tokens with
  | TokRParen i :: rest -> ([], i, rest)
  | _ -> (
      let elem, rest = parse_pattern_as eof tokens in
      match rest with
      | TokComma _ :: rest ->
          let elems, rp, rest = parse_pattern_paren_tail eof rest in
          (elem :: elems, rp, rest)
      | TokRParen i :: rest -> ([ elem ], i, rest)
      | _ ->
          raise
            (Parse_error
               (here eof rest, "expected ',' or ')' in tuple pattern")))

(** Parses patterns joined with `+`, which is how a list or a string is
    split around a name: `[x] + xs` is `[x, ..xs]`, and `"ab" + rest`
    is the same idea for a string. The chain is folded into one ordinary
    pattern here, so nothing after the parser knows the form exists.
    info -> [token] -> (pattern, [token]) *)
and parse_pattern_concat eof tokens =
  let first, rest = parse_pattern_atom eof tokens in
  let rec segments_from rest collected =
    match rest with
    | TokAdd _ :: after ->
        let segment, rest = parse_pattern_atom eof after in
        segments_from rest (segment :: collected)
    | TokConcat i :: _ -> raise (Parse_error (i, concat_message))
    | _ -> (List.rev collected, rest)
  in
  let segments, rest = segments_from rest [ first ] in
  if List.length segments = 1 then (first, rest)
  else (joined_pattern segments, rest)

(** Parses patterns joined with `|`: an or-pattern, which matches what
    any of its alternatives matches. info -> [token] -> (pattern, [token]) *)
and parse_pattern_or eof tokens =
  let first, rest = parse_pattern_concat eof tokens in
  let rec alternatives rest collected =
    match rest with
    | TokBar _ :: after ->
        let next, rest = parse_pattern_concat eof after in
        alternatives rest (next :: collected)
    | TokBarBar i :: _ ->
        raise
          (Parse_error
             (i, "alternatives in a pattern are separated by '|', not '||'"))
    | _ -> (List.rev collected, rest)
  in
  match alternatives rest [ first ] with
  | [ single ], rest -> (single, rest)
  | many, rest ->
      let last = List.nth many (List.length many - 1) in
      (POr (combine_info (pattern_info first) (pattern_info last), many, 0), rest)

(** Parses an or-pattern, optionally followed by `as name`, which binds
    the whole value matched as well. info -> [token] -> (pattern, [token]) *)
and parse_pattern_as eof tokens =
  let inner, rest = parse_pattern_or eof tokens in
  match rest with
  | TokAs _ :: TokIdent (ni, name) :: rest ->
      check_plain_name ni name "bound by a pattern";
      (PAs (combine_info (pattern_info inner) ni, inner, name, 0), rest)
  | TokAs a :: _ ->
      raise (Parse_error (a, "expected a name after 'as' in a pattern"))
  | _ -> (inner, rest)

(** Parses a pattern: one parse_pattern_as, or a bare comma-separated
    sequence of them. info -> [token] -> (pattern, [token]) *)
and parse_pattern eof tokens =
  let first, rest = parse_pattern_as eof tokens in
  match rest with
  | TokComma _ :: rest ->
      let rec elements_from rest collected =
        let elem, rest = parse_pattern_as eof rest in
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
      let guard, rest =
        match rest with
        | TokIf _ :: rest ->
            let g, rest = parse_expr eof rest in
            (Some g, rest)
        | _ -> (None, rest)
      in
      match rest with
      | TokColon colon_info :: rest ->
          let body, rest = parse_block eof rest colon_info in
          let case_info_ = combine_info i (block_end_info i body) in
          (MatchCase (case_info_, pattern, guard, body, 0), rest)
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
    clause, then the `:` and body. Every loop in the language comes
    through here.
    info -> info -> assign_target option -> typ option -> expr option ->
    [token] -> (stmt, [token]) *)
and parse_loop_tail eof loop_info target annotation init tokens =
  let iterate, rest = parse_loop_iter eof tokens in
  match rest with
  | TokColon colon_info :: rest ->
      let body, rest = parse_block eof rest colon_info in
      ( SLoop
          ( combine_info loop_info (block_end_info loop_info body),
            target,
            init,
            annotation,
            iterate,
            body,
            0 ),
        rest )
  | _ -> raise (Parse_error (here eof rest, "expected ':' after loop header"))

(** Parses a loop's iteration clause, or answers None where the loop
    takes another turn unconditionally.
    info -> [token] -> (loop_iter option, [token]) *)
and parse_loop_iter eof tokens =
  match tokens with
  | TokFor i :: TokIdent (_, name) :: TokIn _ :: rest ->
      let sequence, rest = parse_expr eof rest in
      check_plain_name i name "a loop variable";
      (Some (ForIn (combine_info i (expr_info sequence), name, sequence, 0)), rest)
  | TokFor i :: _ ->
      raise (Parse_error (i, "expected `for <name> in <expression>`"))
  | TokWhile i :: rest ->
      let condition, rest = parse_expr eof rest in
      ( Some (WhileTest (combine_info i (expr_info condition), condition, 0)),
        rest )
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
  | TokUse i :: _ ->
      raise
        (Parse_error
           ( i,
             "'use' turns on a feature for the whole module, so it is \
              written before anything else" ))
  | TokReserved (i, word) :: _ -> raise (Parse_error (i, reserved_message word))
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
  | TokDef _ :: TokIdent (i, _) :: TokDot _ :: _
  | TokDatatype _ :: TokIdent (i, _) :: TokDot _ :: _
  | TokStruct _ :: TokIdent (i, _) :: TokDot _ :: _
  | TokIdent (i, _) :: TokDot _ :: TokIdent _ :: (TokEq _ | TokColon _) :: _ ->
      raise
        (Parse_error
           ( i,
             "a dotted name defines a name in a submodule, which belongs to \
              the top level of a module, so it cannot be written inside a \
              block" ))
  | TokImplicit i :: rest ->
      (* `implicit` belongs to a block like any other statement: a
         definition written inside a function is implicit there and
         nowhere else. *)
      let stmt, rest = parse_statement eof rest in
      (made_implicit stmt i, rest)
  | TokDef i :: TokIdent (ni, name) :: TokColon _ :: rest ->
      (* `def name : type` -- a signature on a line of its own, for the
         `def name(...)` in this same block. *)
      check_lowercase ni name "the name of a 'def'";
      let type_, rest = parse_type eof rest in
      (SFunctionSig (combine_info i (type_info type_), name, type_, 0, false), rest)
  | TokDef i :: TokIdent (ni, name) :: TokLParen _ :: rest -> (
      check_lowercase ni name "the name of a 'def'";
      let params, implicits, rest = parse_params eof rest in
      if Names.is_qualified name && params = [] then
        raise
          (Parse_error
             ( ni,
               Printf.sprintf
                 "'%s' takes no argument, so nothing could say which \
                  definition of '%s' a call means; a '::' name belongs to \
                  a 'def' that takes at least one"
                 name (Names.base name) ));
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
          ( SFunctionDef
              ( def_info,
                name,
                params,
                body,
                return_type,
                0,
                false,
                implicits,
                false ),
            rest )
      | _ -> (
          (* `def name(p: T, ...) -> R` with no body: the signature
             `def name : (T, ...) -> R`, its parameters named. *)
          let ends_line result =
            match rest with
            | [] -> true
            | next :: _ -> (token_info next).row1 > (type_info result).row2
          in
          match return_type with
          | Some result when implicits = [] && ends_line result ->
              let typed (Param (pi, pname, ptype, default, _)) =
                match (ptype, default) with
                | Some t, None -> t
                | _ ->
                    raise
                      (Parse_error
                         ( pi,
                           Printf.sprintf
                             "'%s' is a parameter of a 'def' with no body, \
                              which gives every parameter a type and no \
                              default"
                             pname ))
              in
              let info = combine_info i (type_info result) in
              ( SFunctionSig
                  ( info,
                    name,
                    TFunction (info, List.map typed params, result, 0, 0, None, []),
                    0,
                    false ),
                rest )
          | _ -> raise (Parse_error (here eof rest, "expected ':' after def header"))))
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
  | TokBreak i :: rest -> (SBreak (i, 0), rest)
  | TokContinue i :: rest -> (SContinue (i, 0), rest)
  | TokMatch i :: rest -> parse_match_stmt eof i rest
  | TokDatatype i :: _ ->
      raise
        (Parse_error
           ( i,
             "a datatype belongs to the top level of a module, so it cannot \
              be declared inside a block" ))
  | TokStruct i :: _ ->
      raise
        (Parse_error
           ( i,
             "a struct belongs to the top level of a module, so it cannot be \
              declared inside a block" ))
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
      check_plain_name i name "declared with 'var'";
      (SVar (combine_info i (expr_info e), name, e, 0), rest)
  | TokIdent (i, name) :: TokAssign _ :: rest ->
      let value, rest = parse_bound_value eof rest in
      let e = expect_expr_value value "a ':=' mutation" in
      check_plain_name i name "updated with ':='";
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
              (SLet (let_info, target, e, annotation, 0, false, false), rest))
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
  | PText (i, _, Some name, _, _) -> [ (name, i) ]
  | PConstructor (_, _, _, positional, named, _) ->
      List.concat_map pattern_captures (positional @ List.map snd named)
  | POr (_, first :: _, _) -> pattern_captures first
  | PAs (i, inner, name, _) -> pattern_captures inner @ [ (name, i) ]
  | _ -> []

(** Raises Parse_error if pattern binds the same name more than once, or
    if the alternatives of an or-pattern bind different names.
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
  check StringSet.empty (pattern_captures pattern);
  check_alternatives pattern

(** Raises Parse_error where two alternatives of one or-pattern bind
    different names, anywhere in pattern. pattern -> () *)
and check_alternatives pattern =
  let names p =
    List.sort_uniq compare (List.map fst (pattern_captures p))
  in
  match pattern with
  | POr (_, alternatives, _) ->
      List.iter check_no_duplicate_captures alternatives;
      let first = names (List.hd alternatives) in
      List.iter
        (fun alternative ->
          let these = names alternative in
          if these <> first then
            let missing =
              List.filter (fun n -> not (List.mem n these)) first
              @ List.filter (fun n -> not (List.mem n first)) these
            in
            raise
              (Parse_error
                 ( pattern_info alternative,
                   Printf.sprintf
                     "every alternative of '|' binds the same names, and \
                      '%s' is bound in one of them but not in this one"
                     (List.hd missing) )))
        (List.tl alternatives)
  | PTuple (_, ps, _) -> List.iter check_alternatives ps
  | PList (_, prefix, _, suffix, _) -> List.iter check_alternatives (prefix @ suffix)
  | PConstructor (_, _, _, positional, named, _) ->
      List.iter check_alternatives (positional @ List.map snd named)
  | PAs (_, inner, _, _) -> check_alternatives inner
  | _ -> ()

(** Raises Parse_error if a parameter with a default is followed by one
    without: every parameter after the first default must have one too.
    param -> [param] -> () *)
and check_trailing_defaults param params =
  match param with
  | Param (_, name, _, Some _, _) -> (
      match
        List.find_opt (fun (Param (_, _, _, d, _)) -> d = None) params
      with
      | None -> ()
      | Some (Param (i, later, _, _, _)) ->
          raise
            (Parse_error
               ( i,
                 Printf.sprintf
                   "parameter '%s' needs a default, because '%s' before it \
                    has one"
                   later name )))
  | _ -> ()

(** Raises Parse_error if a call's arguments are misshapen: a positional
    argument after a named one, or the same name written twice.
    [(String?, expr)] -> () *)
and check_argument_shape args =
  let rec check named seen args =
    match args with
    | [] -> ()
    | (None, e) :: rest ->
        if named then
          raise
            (Parse_error
               ( expr_info e,
                 "a positional argument may not follow a named one" ))
        else check false seen rest
    | (Some name, e) :: rest ->
        if StringSet.mem name seen then
          raise
            (Parse_error
               ( expr_info e,
                 Printf.sprintf "duplicate argument '%s'" name ))
        else check true (StringSet.add name seen) rest
  in
  check false StringSet.empty args

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
      | SBreak (i, _) | SContinue (i, _) ->
          if not held then no_loop_here stmt i crossed
      | SLoop (_, _, _, _, _, body, _) -> check_loop_context body true None
      | SFunctionDef (_, _, _, body, _, _, _, _, _) ->
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

(** One statement with `implicit` written in front of it. Only a `def`
    and an `=` binding of a name may carry it: resolving an implicit
    argument means finding a name of a type, and nothing else here has
    both. stmt -> info -> stmt *)
and made_implicit stmt implicit_info =
  let i = combine_info implicit_info (stmt_info stmt) in
  match stmt with
  | SFunctionDef (_, name, params, body, return_type, sym, public, implicits, _)
    ->
      SFunctionDef
        (i, name, params, body, return_type, sym, public, implicits, true)
  | SLet (_, (TargetName _ as target), e, annotation, sym, public, _) ->
      SLet (i, target, e, annotation, sym, public, true)
  | other ->
      raise
        (Parse_error
           ( stmt_info other,
             "'implicit' marks a 'def' or an '=' binding of one name, and \
              nothing else: an implicit argument is resolved by name and \
              type, so there has to be a name to find" ))

(** Whether an identifier in type position names a type variable: one
    starting with a lowercase letter (`Int`, `String` and `Bool` are
    their own tokens). string -> bool *)
and is_type_var name =
  String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z'

(** Whether an identifier names a datatype or a constructor: one
    starting with an uppercase letter. string -> bool *)
and is_constructor_name name =
  String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'

(** A datatype or a constructor reached through a path, `m.Name` or
    `hello.shapes.Name`: where it starts, the lowercase names before it
    joined by dots, the name's own span, the name, and what follows. Each
    dot is on the row the name before it ended on.
    [token] -> (info, string, info, string, [token])? *)
and constructor_path tokens =
  let rec go start parts last tokens =
    match tokens with
    | TokDot dot :: TokIdent (ni, name) :: rest when dot.row1 = last.row2 ->
        if is_constructor_name name then
          Some (start, String.concat "." (List.rev parts), ni, name, rest)
        else if is_type_var name && not (Names.is_qualified name) then
          go start (name :: parts) ni rest
        else None
    | _ -> None
  in
  match tokens with
  | TokIdent (i, first) :: rest
    when is_type_var first && not (Names.is_qualified first) ->
      go i [ first ] i rest
  | _ -> None

(** Refuses a qualified name where a module name or an import alias
    stands; either may start with an uppercase letter, since an import
    may take a datatype. info -> String -> String -> () *)
and check_import_name info name what =
  if Names.is_qualified name then
    raise
      (Parse_error
         ( info,
           Printf.sprintf
             "'%s' cannot be %s: a '::' name belongs to a 'def' that takes \
              at least one argument, which is what resolves which of them \
              a call means"
             name what ));
  check_lowercase info name what

(* Pyking has no import-all form: a name a module reaches is written
   down, so reading the file says where every name comes from. *)
let no_star =
  "there is no '*' import in Pyking; name the values and functions to \
   import, or import the module itself and reach them through it"

(** A dotted name, `mymod.foo` or `a.b.c`, joined into one identifier:
    a definition's name in a submodule, or the module path an import
    names. Each dot is on the row the name before it ended on, and a name
    with no dot comes back as it was. [token] -> [token] *)
let rec merge_name tokens =
  match tokens with
  | TokIdent (i, a) :: TokDot dot :: TokIdent (j, b) :: rest
    when dot.row1 = i.row2 && j.row1 = dot.row2 ->
      merge_name (TokIdent (combine_info i j, a ^ "." ^ b) :: rest)
  | _ -> tokens

(** A top-level statement's tokens with the name it defines joined, where
    that name is dotted: after `def`, `datatype` and `struct`, and at the start of
    an `=` binding. A dotted name used rather than defined is left as it
    was. [token] -> [token] *)
let rec dotted_definition tokens =
  match tokens with
  | (TokPublic _ as t) :: rest | (TokImplicit _ as t) :: rest ->
      t :: dotted_definition rest
  | (TokDef _ as t) :: rest | (TokDatatype _ as t) :: rest
  | (TokStruct _ as t) :: rest ->
      t :: merge_name rest
  | TokIdent _ :: TokDot _ :: _ -> (
      match merge_name tokens with
      | (TokIdent _ as name) :: ((TokEq _ | TokColon _) :: _ as rest) -> name :: rest
      | _ -> tokens)
  | _ -> tokens

(** Parses the modules of an `import a, b as c` line, one SImport each.
    The fields are left empty: what a qualified name reaches is the
    module's public names, which only the module system knows.
    info -> info -> [token] -> ([stmt], [token]) *)
let rec parse_import eof import_info tokens =
  let stmt, tokens =
    match merge_name tokens with
    | TokIdent (mi, module_name) :: TokAs _ :: TokIdent (last, alias) :: rest ->
        check_import_name mi module_name "a module name";
        check_import_name last alias "an import alias";
        (SImport (combine_info import_info last, module_name, alias, false, [], 0), rest)
    | TokIdent (last, module_name) :: rest ->
        check_import_name last module_name "a module name";
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
        if is_constructor_name field then (
          if not (is_constructor_name local) then
            raise
              (Parse_error
                 ( last,
                   Printf.sprintf
                     "'%s' cannot be the alias of '%s': a type or a \
                      constructor is known by a name starting with an \
                      uppercase letter"
                     local field )))
        else check_import_name last local "an import alias";
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
  match merge_name tokens with
  | TokIdent (mi, module_name) :: TokImport _ :: rest ->
      check_import_name mi module_name "a module name";
      let fields, last, rest = parse_import_fields eof rest in
      let i = combine_info from_info last in
      ([ SImport (i, module_name, module_name, true, fields, 0) ], rest)
  | TokIdent (_, _) :: rest ->
      raise
        (Parse_error (here eof rest, "expected 'import' after the module name"))
  | _ ->
      raise (Parse_error (here eof tokens, "expected a module name after 'from'"))

(** The type a field's literal default has, which is the field's type
    where none is written. expr -> typ? *)
let literal_type default =
  match default with
  | EInt (i, _, _) | ENeg (i, EInt _, _) -> Some (TInt (i, 0))
  | EFloat (i, _, _) | ENeg (i, EFloat _, _) -> Some (TFloat (i, 0))
  | EString (i, _, _) -> Some (TString (i, 0))
  | EBool (i, _, _) -> Some (TBool (i, 0))
  | _ -> None

(** Parses one field of a constructor: a type, `name: Type`, `name =
    default` or `name: Type = default`. A default with no type gives the
    field the literal's type where it is a literal, and no written type
    otherwise. info -> [token] -> (field, [token]) *)
let parse_field eof tokens =
  let default_after i label type_ rest =
    match rest with
    | TokEq _ :: rest ->
        let default, rest = parse_expr eof rest in
        let type_ =
          match type_ with Some t -> Some t | None -> literal_type default
        in
        ( Field (combine_info i (expr_info default), label, type_, Some default, 0),
          rest )
    | _ -> (
        match type_ with
        | Some t -> (Field (combine_info i (type_info t), label, Some t, None, 0), rest)
        | None -> raise (Parse_error (here eof rest, "expected ':' or '=' after a field name")))
  in
  match tokens with
  | TokIdent (i, name) :: TokColon _ :: rest when not (is_constructor_name name) ->
      check_plain_name i name "a field name";
      let t, rest = parse_type eof rest in
      default_after i (Some name) (Some t) rest
  | TokIdent (i, name) :: (TokEq _ :: _ as rest) when not (is_constructor_name name) ->
      check_plain_name i name "a field name";
      default_after i (Some name) None rest
  | _ ->
      let t, rest = parse_type eof tokens in
      (Field (type_info t, None, Some t, None, 0), rest)

(** Raises Parse_error where a constructor's fields are misshapen: an
    unnamed field after a named one, a field without a default after one
    with, or one name used twice. [field] -> () *)
let check_fields fields =
  ignore
    (List.fold_left
       (fun (named, defaulted, seen) (Field (i, label, _, default, _)) ->
         (match label with
         | None when named ->
             raise
               (Parse_error
                  (i, "an unnamed field comes before every named one"))
         | Some n when List.mem n seen ->
             raise (Parse_error (i, Printf.sprintf "duplicate field '%s'" n))
         | _ -> ());
         if defaulted && default = None then
           raise
             (Parse_error
                ( i,
                  "this field needs a default, because a field before it has \
                   one" ));
         ( named || label <> None,
           defaulted || default <> None,
           match label with Some n -> n :: seen | None -> seen ))
       (false, false, []) fields)

(** Parses comma-separated fields up to and including ')'.
    info -> [token] -> ([field], info, [token]) *)
let parse_fields eof tokens =
  let rec fields rest collected =
    match rest with
    | TokRParen rp :: rest -> (List.rev collected, rp, rest)
    | _ -> (
        let f, rest = parse_field eof rest in
        match rest with
        | TokComma _ :: rest -> fields rest (f :: collected)
        | TokRParen rp :: rest -> (List.rev (f :: collected), rp, rest)
        | _ ->
            raise
              (Parse_error (here eof rest, "expected ',' or ')' after a field")))
  in
  fields tokens []

(** Parses one constructor line: a name, and its fields in parentheses
    where it has any. info -> [token] -> (constructor, [token]) *)
let parse_constructor eof tokens =
  match tokens with
  | TokIdent (i, name) :: TokLParen lp :: rest
    when is_constructor_name name && lp.row1 = i.row2 ->
      let fields, rp, rest = parse_fields eof rest in
      check_fields fields;
      (Constructor (combine_info i rp, name, fields, 0), rest)
  | TokIdent (i, name) :: rest when is_constructor_name name ->
      (Constructor (i, name, [], 0), rest)
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             "expected a constructor: a name starting with an uppercase \
              letter, with its fields in parentheses where it has any" ))

(** Parses the name a `datatype` or a `struct` declares, whose last part
    starts with an uppercase letter: `shapes.Shape` is `Shape` in the
    submodule `shapes`. info -> String -> [token] -> (info, String, [token]) *)
let parse_type_name eof what tokens =
  match tokens with
  | TokIdent (i, name) :: rest
    when is_constructor_name (List.hd (List.rev (String.split_on_char '.' name))) ->
      (i, name, rest)
  | _ ->
      raise
        (Parse_error
           ( here eof tokens,
             Printf.sprintf
               "expected the %s's name, starting with an uppercase letter" what
           ))

(** Parses a declaration's type parameters from just after its `(` up to
    and including the `)`. info -> String -> [token] -> ([String], [token]) *)
let parse_type_params eof what tokens =
  let rec vars rest collected =
    match rest with
    | TokIdent (vi, v) :: rest when is_type_var v ->
        if List.mem v collected then
          raise
            (Parse_error
               (vi, Printf.sprintf "duplicate type parameter '%s'" v));
        (match rest with
        | TokComma _ :: rest -> vars rest (v :: collected)
        | TokRParen _ :: rest -> (List.rev (v :: collected), rest)
        | _ ->
            raise
              (Parse_error
                 (here eof rest, "expected ',' or ')' after a type parameter")))
    | _ ->
        raise
          (Parse_error
             ( here eof rest,
               Printf.sprintf
                 "a %s's parameters are type variables: names starting with \
                  a lowercase letter"
                 what ))
  in
  vars tokens []

(** Parses a datatype declaration from just after `datatype`: its name,
    its parameters, and its constructors: comma-separated on the header's
    line, on indented lines, or both.
    info -> info -> [token] -> (stmt, [token]) *)
let parse_datatype eof datatype_info tokens =
  let name_info, name, rest = parse_type_name eof "datatype" tokens in
  let params, rest =
    match rest with
    | TokLParen lp :: rest when lp.row1 = name_info.row2 ->
        parse_type_params eof "datatype" rest
    | _ -> ([], rest)
  in
  (* One line of constructors, separated by commas; the line before it,
     if any, ended where `collected` starts. *)
  let constructor_line rest collected =
    let add c collected =
      let (Constructor (ci, cname, _, _)) = c in
      if List.exists (fun (Constructor (_, n, _, _)) -> n = cname) collected then
        raise
          (Parse_error
             (ci, Printf.sprintf "'%s' is already a constructor of '%s'" cname name));
      c :: collected
    in
    let first, rest = parse_constructor eof rest in
    let (Constructor (ci, _, _, _)) = first in
    (match collected with
    | Constructor (pi, _, _, _) :: _ when pi.row2 >= ci.row1 ->
        raise
          (Parse_error
             ( ci,
               "a line of constructors starts a line of its own; write a ',' \
                between two constructors on one line" ))
    | _ -> ());
    let rec more rest collected =
      match rest with
      | TokComma _ :: rest ->
          let c, rest = parse_constructor eof rest in
          more rest (add c collected)
      | _ -> (collected, rest)
    in
    more rest (add first collected)
  in
  let rec indented rest collected =
    match rest with
    | TokDedent _ :: rest -> (collected, rest)
    | _ ->
        let collected, rest = constructor_line rest collected in
        indented rest collected
  in
  let finish collected rest =
    let constructors = List.rev collected in
    let (Constructor (last, _, _, _)) = List.hd collected in
    ( SDatatype
        (combine_info datatype_info last, name, params, constructors, 0, false),
      rest )
  in
  match rest with
  | TokColon _ :: TokIndent _ :: rest ->
      let collected, rest = indented rest [] in
      finish collected rest
  | TokColon c :: (TokIdent (i, _) :: _ as rest) when i.row1 = c.row2 -> (
      (* Constructors on the header's own line, and perhaps more on the
         indented lines under it. *)
      let collected, rest = constructor_line rest [] in
      match rest with
      | TokIndent _ :: rest ->
          let collected, rest = indented rest collected in
          finish collected rest
      | _ -> finish collected rest)
  | [ TokColon c ] ->
      raise
        (Parse_error
           ( c,
             "unexpected end of input: a datatype's constructors follow it, \
              on its line or on indented lines" ))
  | TokColon c :: _ ->
      raise
        (Parse_error
           ( c,
             "a datatype's constructors are written after its ':', or on \
              indented lines under it" ))
  | _ -> raise (Parse_error (here eof rest, "expected ':' after the datatype's name"))

(** The span of one field. field -> info *)
let field_info (Field (i, _, _, _, _)) = i

(** The type variables a type names, in order of first appearance,
    leaving out those an `all` inside it binds. typ -> [String] *)
let type_variables t =
  let rec go bound found node =
    match node with
    | Walk.NType (TVar (_, v, _, _)) ->
        if List.mem v bound || List.mem v found then found else found @ [ v ]
    | Walk.NType (TForall (_, vars, body, _)) -> go (vars @ bound) found (Walk.NType body)
    | node -> List.fold_left (go bound) found (Walk.children node)
  in
  go [] [] (Walk.NType t)

(** Whether the `(` that starts these tokens is closed by a `)` followed
    by a `:`, which is what makes it a struct's type parameters rather
    than its fields. [token] -> bool *)
let params_follow tokens =
  let rec scan depth tokens =
    match tokens with
    | (TokLParen _ | TokLBracket _) :: rest -> scan (depth + 1) rest
    | TokRParen _ :: rest when depth = 1 -> (
        match rest with TokColon _ :: _ -> true | _ -> false)
    | (TokRParen _ | TokRBracket _) :: rest -> scan (depth - 1) rest
    | _ :: rest -> scan depth rest
    | [] -> false
  in
  scan 0 tokens

(** Parses a struct from just after `struct`: a datatype of one
    constructor, named as the type is. Its fields are in parentheses on
    the header's line, with every type variable they name a parameter, or
    on indented lines under a `:`, after the parameters written in
    parentheses before it. info -> info -> [token] -> (stmt, [token]) *)
let parse_struct eof struct_info tokens =
  let name_info, name, rest = parse_type_name eof "struct" tokens in
  let cname = List.hd (List.rev (String.split_on_char '.' name)) in
  (* One indented line of fields, separated by commas, starting a line of
     its own. *)
  let rec field_lines rest collected =
    match rest with
    | TokDedent _ :: rest -> (List.rev collected, rest)
    | _ ->
        let first, rest = parse_field eof rest in
        (match collected with
        | Field (pi, _, _, _, _) :: _
          when let (Field (fi, _, _, _, _)) = first in
               pi.row2 >= fi.row1 ->
            raise
              (Parse_error
                 ( field_info first,
                   "a line of fields starts a line of its own; write a ',' \
                    between two fields on one line" ))
        | _ -> ());
        let rec more rest collected =
          match rest with
          | TokComma _ :: rest ->
              let f, rest = parse_field eof rest in
              more rest (f :: collected)
          | _ -> (collected, rest)
        in
        let collected, rest = more rest (first :: collected) in
        field_lines rest collected
  in
  let block rest =
    match rest with
    | TokColon _ :: TokIndent _ :: rest ->
        let fields, rest = field_lines rest [] in
        (fields, Some (field_info (List.nth fields (List.length fields - 1))), rest)
    | [ TokColon c ] ->
        raise
          (Parse_error
             ( c,
               "unexpected end of input: a struct's fields follow it, on \
                indented lines" ))
    | TokColon c :: _ ->
        raise
          (Parse_error
             ( c,
               "a struct's fields are written in parentheses after its name, \
                or on indented lines under its ':'" ))
    | _ -> raise (Parse_error (here eof rest, "expected ':' after the struct's parameters"))
  in
  let params, fields, last, rest =
    match rest with
    | TokLParen lp :: after when lp.row1 = name_info.row2 && params_follow rest ->
        let params, rest = parse_type_params eof "struct" after in
        let fields, last, rest = block rest in
        (params, fields, last, rest)
    | TokLParen lp :: after when lp.row1 = name_info.row2 ->
        let fields, rp, rest = parse_fields eof after in
        let params =
          List.fold_left
            (fun found (Field (_, _, type_, _, _)) ->
              match type_ with
              | None -> found
              | Some t ->
                  found
                  @ List.filter (fun v -> not (List.mem v found)) (type_variables t))
            [] fields
        in
        (params, fields, Some rp, rest)
    | TokColon _ :: _ ->
        let fields, last, rest = block rest in
        ([], fields, last, rest)
    | _ -> ([], [], None, rest)
  in
  check_fields fields;
  let last = Option.value last ~default:name_info in
  ( SDatatype
      ( combine_info struct_info last,
        name,
        params,
        [ Constructor (combine_info name_info last, cname, fields, 0) ],
        0,
        false ),
    rest )

(** One statement with `public` written in front of it. stmt -> info ->
    stmt *)
let made_public stmt public_info =
  let i = combine_info public_info (stmt_info stmt) in
  match stmt with
  | SFunctionDef (_, name, params, body, return_type, sym, _, implicits, implicit)
    ->
      SFunctionDef
        (i, name, params, body, return_type, sym, true, implicits, implicit)
  | SFunctionSig (_, name, type_, sym, _) ->
      SFunctionSig (i, name, type_, sym, true)
  | SDatatype (_, name, params, constructors, sym, _) ->
      SDatatype (i, name, params, constructors, sym, true)
  | SLet (_, (TargetName _ as target), e, annotation, sym, _, implicit) ->
      SLet (i, target, e, annotation, sym, true, implicit)
  | SLetStmt (_, (TargetName _ as target), inner, annotation, sym, _) ->
      SLetStmt (i, target, inner, annotation, sym, true)
  | SLet (_, _, _, _, _, _, _) | SLetStmt (_, _, _, _, _, _) ->
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
                'def', a 'def' signature line, a 'datatype', a 'struct', or \
                an '=' \
                binding, not '%s'"
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
  let stmt, rest =
    match tokens with
    | TokDatatype i :: rest -> parse_datatype eof i rest
    | TokStruct i :: rest -> parse_struct eof i rest
    | _ -> parse_statement eof tokens
  in
  (made_public stmt public_info, rest)

(** Parses one top-level statement, or the several an `import a, b` line
    stands for. The two forms a module is written with -- an import and a
    `public` -- are parsed only here, which is what makes them top
    level: parse_statement, which every block goes through, refuses both.
    info -> [token] -> ([stmt], [token]) *)
let parse_top_statement eof tokens =
  let tokens = dotted_definition tokens in
  match tokens with
  | TokImport i :: rest -> parse_import eof i rest
  | TokFrom i :: rest -> parse_from_import eof i rest
  | TokPublic i :: rest ->
      let stmt, rest = parse_public eof i rest in
      ([ stmt ], rest)
  | TokDatatype i :: rest ->
      let stmt, rest = parse_datatype eof i rest in
      ([ stmt ], rest)
  | TokStruct i :: rest ->
      let stmt, rest = parse_struct eof i rest in
      ([ stmt ], rest)
  | _ ->
      let stmt, rest = parse_statement eof tokens in
      ([ stmt ], rest)

(* --- features turned on with `use` --- *)

(** Every feature a `use` line may name (design/steps.md, step 1).
    [string] *)
let features = [ "mutation"; "objects" ]

(** Reads the `use` lines a module starts with: the features they name,
    each with where it was written, and the tokens after them. A feature
    no `use` knows, or one named twice, is refused.
    info -> [token] -> ([(string, info)], [token]) *)
let parse_uses eof tokens =
  let rec names rest found =
    match rest with
    | TokIdent (i, name) :: rest -> (
        if not (List.mem name features) then
          raise
            (Parse_error
               ( i,
                 Printf.sprintf "there is no feature '%s'; the features are %s"
                   name
                   (String.concat " and " features) ));
        if List.mem_assoc name found then
          raise (Parse_error (i, Printf.sprintf "'use %s' is written twice" name));
        let found = found @ [ (name, i) ] in
        match rest with
        | TokComma _ :: rest -> names rest found
        | _ -> (found, rest))
    | _ ->
        raise
          (Parse_error
             ( here eof rest,
               Printf.sprintf "expected the name of a feature after 'use': %s"
                 (String.concat " or " features) ))
  in
  let rec lines rest found last =
    match rest with
    | TokUse i :: after ->
        (match last with
        | Some previous when previous.row2 >= i.row1 ->
            raise (Parse_error (i, "each 'use' starts a line of its own"))
        | _ -> ());
        let found, after = names after found in
        let last = Some (snd (List.nth found (List.length found - 1))) in
        lines after found last
    | next :: _ -> (
        match last with
        | Some previous when previous.row2 >= (token_info next).row1 ->
            raise
              (Parse_error
                 ( token_info next,
                   "each statement must start on a new line, and this one \
                    follows a 'use' on the same line" ))
        | _ -> (found, rest))
    | [] -> (found, rest)
  in
  lines tokens [] None

(** The features a module's `use` lines turn on, read from its tokens
    alone -- what `-t pyking` writes back above the program, since the
    statements do not hold them. [token] -> [string] *)
let uses tokens =
  match List.rev tokens with
  | [] -> []
  | last :: _ -> (
      try List.map fst (fst (parse_uses (token_info last) tokens))
      with Parse_error _ -> [])

(** The `use` lines a module's tokens start with, as `-t pyking` writes
    them above the program: one line per feature. [token] -> string *)
let use_lines tokens =
  String.concat "" (List.map (fun feature -> "use " ^ feature ^ "\n") (uses tokens))

(** Refuses every construct of a feature these statements' module has
    not turned on. They are parsed like everything else -- one parser
    reads every module -- and refused here, as a syntax error that names
    the `use` line which would allow them. [string] -> [stmt] -> () *)
let check_features enabled stmts =
  if not (List.mem "mutation" enabled) then
    Walk.fold_stmts
      (fun () node ->
        match node with
        | Walk.NStmt (SVar (i, _, _, _)) ->
            raise
              (Parse_error
                 ( { i with row2 = i.row1; col2 = i.col1 + 3 },
                   "'var' declares a mutable variable, which needs 'use \
                    mutation' at the top of this module" ))
        | Walk.NStmt (SMutate (i, name, _, _)) ->
            raise
              (Parse_error
                 ( i,
                   Printf.sprintf
                     "':=' changes the mutable variable '%s', which needs \
                      'use mutation' at the top of this module"
                     name ))
        | _ -> ())
      () stmts

(** Parses a module's tokens with some features already on -- a REPL
    session's, which an earlier entry turned on -- answering the features
    its own `use` lines turn on, and its statements.
    [string] -> [token] -> ([string], [stmt]) *)
let parse_with enabled tokens =
  let eof =
    match List.rev tokens with
    | last :: _ -> token_info last
    | [] -> { file = "<empty>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
  in
  (* A reserved word means nothing yet, so it is refused wherever it
     stands -- a name, a parameter, a pattern -- with the same message. *)
  (match List.find_opt (function TokReserved _ -> true | _ -> false) tokens with
  | Some (TokReserved (i, word)) -> raise (Parse_error (i, reserved_message word))
  | _ -> ());
  let own, tokens = parse_uses eof tokens in
  let own = List.map fst own in
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
  check_features (enabled @ own) stmts;
  (own, stmts)

(** Parses a full token stream into a list of top-level statements.
    [token] -> [stmt] *)
let parse tokens = snd (parse_with [] tokens)
