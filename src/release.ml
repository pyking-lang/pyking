(** Release mode: every call to the builtin `debug` removed, arguments
    and all. Pyking AST in, Pyking AST out, run by `pyk compile
    --release` after the type checker and before the tail-call pass, so
    every backend compiles a program with no `debug` in it and none of
    them knows this pass exists. See docs/release.md.

    A call in value position becomes `()`, the unit it was worth. A call
    written as a statement is dropped, unless it ends a block whose
    value would change without it; there it becomes the statement `()`,
    which every backend compiles to nothing.

    Functions:
      program tmap stmts -- one module with its calls to `debug`
        removed. *)

open Syntax

(** Whether e is a call to the builtin `debug` rather than to a
    definition a program named `debug`: the checker records a type for a
    callee it resolved to a definition, and none for a builtin.
    typ IntMap.t -> expr -> bool *)
let is_debug_call tmap e =
  match e with
  | ECall (_, EVar (_, name, callee), _, _) ->
      Builtin.is_debug name && not (IntMap.mem callee tmap)
  | _ -> false

(** The unit a removed call was worth, under the call's own symbol, so
    the type the checker recorded for it still applies. expr -> expr *)
let unit_for e = ETuple (expr_info e, [], expr_sym e)

(** Whether a statement leaves unit as its block's value, so that a
    removed `debug` after it changes nothing.
    typ IntMap.t -> stmt -> bool *)
let supplies_unit tmap statement =
  match statement with
  | SLet _ | SLetStmt _ | SVar _ | SMutate _ | SFunctionDef _ | SFunctionSig _
  | SImport _ | SDatatype _ ->
      true
  | SExprStmt (_, e, _) -> (
      match IntMap.find_opt (expr_sym e) tmap with
      | Some (TTuple (_, [], _)) -> true
      | _ -> false)
  | SReturn _ | SReturnStmt _ | SLoop _ | SBreak _ | SContinue _ | SIf _
  | SMatch _ ->
      false

(** An expression with every call to `debug` in it replaced by unit.
    typ IntMap.t -> expr -> expr *)
let rec expression tmap e =
  let go = expression tmap in
  if is_debug_call tmap e then unit_for e
  else
    match e with
    | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ | EQualified _ -> e
    | EAdd (i, l, r, s) -> EAdd (i, go l, go r, s)
    | ESub (i, l, r, s) -> ESub (i, go l, go r, s)
    | EMul (i, l, r, s) -> EMul (i, go l, go r, s)
    | EDiv (i, l, r, s) -> EDiv (i, go l, go r, s)
    | ENeg (i, operand, s) -> ENeg (i, go operand, s)
    | EConcat (i, l, r, s) -> EConcat (i, go l, go r, s)
    | ELessThan (i, l, r, s) -> ELessThan (i, go l, go r, s)
    | ELessThanEq (i, l, r, s) -> ELessThanEq (i, go l, go r, s)
    | EGreatThan (i, l, r, s) -> EGreatThan (i, go l, go r, s)
    | EGreatThanEq (i, l, r, s) -> EGreatThanEq (i, go l, go r, s)
    | EEq (i, l, r, s) -> EEq (i, go l, go r, s)
    | EBinary (i, op, l, r, s) -> EBinary (i, op, go l, go r, s)
    | EUnary (i, op, operand, s) -> EUnary (i, op, go operand, s)
    | EIndex (i, l, index, s) -> EIndex (i, go l, go index, s)
    | ECall (i, callee, args, s) ->
        ECall (i, go callee, List.map (fun (name, a) -> (name, go a)) args, s)
    | EList (i, elements, s) -> EList (i, List.map go elements, s)
    | ETuple (i, elements, s) -> ETuple (i, List.map go elements, s)
    | EIf (i, c, a, b, s) -> EIf (i, go c, go a, go b, s)
    | ELambda (i, params, body, s) -> ELambda (i, params, go body, s)
    | ELet (i, target, annotation, value, body, s) ->
        ELet (i, target, annotation, go value, go body, s)
    | EConstruct (i, m, n, args, s) ->
        EConstruct (i, m, n, List.map (fun (name, a) -> (name, go a)) args, s)
    | EField (i, record, n, s) -> EField (i, go record, n, s)
    | EListComp (i, element, clauses, s) ->
        EListComp
          ( i,
            go element,
            List.map
              (fun clause ->
                match clause with
                | CompFor (ci, pattern, sequence, cs) ->
                    CompFor (ci, pattern, go sequence, cs)
                | CompIf (ci, condition, cs) -> CompIf (ci, go condition, cs))
              clauses,
            s )

(** A block with every call to `debug` removed. A statement that is only
    such a call is dropped, except where it is the last one of a block
    whose value is used and what comes before it would not leave unit;
    there it stays as `()`. bool? -> typ IntMap.t -> [stmt] -> [stmt] *)
and block ?(valued = true) tmap stmts =
  let count = List.length stmts in
  List.rev
    (snd
       (List.fold_left
          (fun (index, kept) statement ->
            let last = index = count - 1 in
            let kept =
              match statement with
              | SExprStmt (i, e, s) when is_debug_call tmap e ->
                  let settled =
                    match kept with
                    | previous :: _ -> supplies_unit tmap previous
                    | [] -> false
                  in
                  if valued && last && not settled then SExprStmt (i, unit_for e, s) :: kept
                  else kept
              | _ -> rewrite tmap statement :: kept
            in
            (index + 1, kept))
          (0, []) stmts))

(** One statement with every call to `debug` in it removed.
    typ IntMap.t -> stmt -> stmt *)
and rewrite tmap statement =
  let go = expression tmap in
  match statement with
  | SLet (i, target, e, t, s, public, implicit) ->
      SLet (i, target, go e, t, s, public, implicit)
  | SLetStmt (i, target, inner, t, s, public) ->
      SLetStmt (i, target, rewrite tmap inner, t, s, public)
  | SVar (i, name, e, s) -> SVar (i, name, go e, s)
  | SMutate (i, name, e, s) -> SMutate (i, name, go e, s)
  | SReturn (i, e, s) -> SReturn (i, go e, s)
  | SReturnStmt (i, inner, s) -> SReturnStmt (i, rewrite tmap inner, s)
  | SExprStmt (i, e, s) -> SExprStmt (i, go e, s)
  | SBreak (i, value, s) -> SBreak (i, Option.map go value, s)
  | SContinue (i, value, s) -> SContinue (i, Option.map go value, s)
  | SFunctionSig _ | SImport _ | SDatatype _ -> statement
  | SLoop (i, target, init, t, iterate, body, s) ->
      let iterate =
        match iterate with
        | Some (ForIn (fi, name, sequence, fs)) ->
            Some (ForIn (fi, name, go sequence, fs))
        | Some (WhileTest (wi, condition, ws)) ->
            Some (WhileTest (wi, go condition, ws))
        | None -> None
      in
      SLoop (i, target, Option.map go init, t, iterate, block tmap body, s)
  | SIf (i, condition, then_body, else_body, s) ->
      SIf
        ( i,
          go condition,
          block tmap then_body,
          Option.map (block tmap) else_body,
          s )
  | SMatch (i, subject, cases, s) ->
      SMatch
        ( i,
          go subject,
          List.map
            (fun (MatchCase (ci, pattern, guard, body, cs)) ->
              MatchCase (ci, pattern, Option.map go guard, block tmap body, cs))
            cases,
          s )
  | SFunctionDef (i, name, params, body, return_type, s, public, implicits, implicit)
    ->
      SFunctionDef
        (i, name, params, block tmap body, return_type, s, public, implicits, implicit)

(** One module with every call to the builtin `debug` removed.
    typ IntMap.t -> [stmt] -> [stmt] *)
let program tmap stmts = block ~valued:false tmap stmts
