(** Static analyses over the Pyking AST (syntax.ml). So far one:
    symbolizing, which gives every node a unique integer id. It runs
    after parsing and before anything reasons about the program, since
    the type checker's table is keyed by those ids. Translated from the
    corresponding part of src/analyses.py.

    Data structures:
      Analysis_error -- a name/scoping failure, with the source position.

    Functions:
      symbolize stmts -- gives every node a unique integer sym.
      highest_sym stmts -- the largest sym anywhere in a program. *)

open Syntax

(** A name/scoping failure, with the source position. *)
exception Analysis_error of Lexer.info * string

(* --- symbolize ---
   src/analyses.py walks the dataclasses generically, numbering a node's
   fields in declaration order and then the node itself. There is no
   such walk here, so each node type says what its children are -- in
   the order src/syntax.py declares them, which is what makes the two
   implementations hand out the same numbers. The counter is threaded
   through as a value rather than held in a mutable cell. *)

let assign sym counter = if sym = 0 then (counter, counter + 1) else (sym, counter)

let map_fold f counter items =
  let rec go counter done_ items =
    match items with
    | [] -> (List.rev done_, counter)
    | x :: rest ->
        let y, counter = f counter x in
        go counter (y :: done_) rest
  in
  go counter [] items

let map_option f counter item =
  match item with
  | None -> (None, counter)
  | Some x ->
      let y, counter = f counter x in
      (Some y, counter)

let rec sym_expr counter e =
  match e with
  | EInt (i, v, s) ->
      let s, counter = assign s counter in
      (EInt (i, v, s), counter)
  | EString (i, v, s) ->
      let s, counter = assign s counter in
      (EString (i, v, s), counter)
  | EBool (i, v, s) ->
      let s, counter = assign s counter in
      (EBool (i, v, s), counter)
  | EVar (i, n, s) ->
      let s, counter = assign s counter in
      (EVar (i, n, s), counter)
  | EAdd (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EAdd (i, l, r, s), counter)
  | ESub (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (ESub (i, l, r, s), counter)
  | EMul (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EMul (i, l, r, s), counter)
  | EDiv (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EDiv (i, l, r, s), counter)
  | ENeg (i, o, s) ->
      let o, counter = sym_expr counter o in
      let s, counter = assign s counter in
      (ENeg (i, o, s), counter)
  | EConcat (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EConcat (i, l, r, s), counter)
  | ELessThan (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (ELessThan (i, l, r, s), counter)
  | ELessThanEq (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (ELessThanEq (i, l, r, s), counter)
  | EGreatThan (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EGreatThan (i, l, r, s), counter)
  | EGreatThanEq (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EGreatThanEq (i, l, r, s), counter)
  | EEq (i, l, r, s) ->
      let l, counter = sym_expr counter l in
      let r, counter = sym_expr counter r in
      let s, counter = assign s counter in
      (EEq (i, l, r, s), counter)
  | ECall (i, f, args, s) ->
      let f, counter = sym_expr counter f in
      let args, counter = map_fold sym_expr counter args in
      let s, counter = assign s counter in
      (ECall (i, f, args, s), counter)
  | EList (i, elements, s) ->
      let elements, counter = map_fold sym_expr counter elements in
      let s, counter = assign s counter in
      (EList (i, elements, s), counter)
  | ETuple (i, elements, s) ->
      let elements, counter = map_fold sym_expr counter elements in
      let s, counter = assign s counter in
      (ETuple (i, elements, s), counter)
  | EIf (i, c, t, e2, s) ->
      let c, counter = sym_expr counter c in
      let t, counter = sym_expr counter t in
      let e2, counter = sym_expr counter e2 in
      let s, counter = assign s counter in
      (EIf (i, c, t, e2, s), counter)
  | EListComp (i, e2, clauses, s) ->
      let e2, counter = sym_expr counter e2 in
      let clauses, counter = map_fold sym_comp_clause counter clauses in
      let s, counter = assign s counter in
      (EListComp (i, e2, clauses, s), counter)
  | EQualified (i, module_name, name, s) ->
      let s, counter = assign s counter in
      (EQualified (i, module_name, name, s), counter)

and sym_type counter t =
  match t with
  | TInt (i, s) ->
      let s, counter = assign s counter in
      (TInt (i, s), counter)
  | TString (i, s) ->
      let s, counter = assign s counter in
      (TString (i, s), counter)
  | TBool (i, s) ->
      let s, counter = assign s counter in
      (TBool (i, s), counter)
  | TList (i, element, s) ->
      let element, counter = sym_type counter element in
      let s, counter = assign s counter in
      (TList (i, element, s), counter)
  | TTuple (i, elements, s) ->
      let elements, counter = map_fold sym_type counter elements in
      let s, counter = assign s counter in
      (TTuple (i, elements, s), counter)
  | TUnknown (i, s) ->
      let s, counter = assign s counter in
      (TUnknown (i, s), counter)
  | TBuiltin (i, n, s) ->
      let s, counter = assign s counter in
      (TBuiltin (i, n, s), counter)
  | TFunction (i, params, result, s, tmsym, definition) ->
      let params, counter = map_fold sym_type counter params in
      let result, counter = sym_type counter result in
      let definition, counter = map_option sym_stmt counter definition in
      let s, counter = assign s counter in
      (TFunction (i, params, result, s, tmsym, definition), counter)
  | TVar (i, n, s, rigid) ->
      let s, counter = assign s counter in
      (TVar (i, n, s, rigid), counter)
  | TForall (i, vars, body, s) ->
      let body, counter = sym_type counter body in
      let s, counter = assign s counter in
      (TForall (i, vars, body, s), counter)

and sym_pattern counter p =
  match p with
  | PInt (i, v, s) ->
      let s, counter = assign s counter in
      (PInt (i, v, s), counter)
  | PString (i, v, s) ->
      let s, counter = assign s counter in
      (PString (i, v, s), counter)
  | PBool (i, v, s) ->
      let s, counter = assign s counter in
      (PBool (i, v, s), counter)
  | PWildcard (i, s) ->
      let s, counter = assign s counter in
      (PWildcard (i, s), counter)
  | PCapture (i, n, s) ->
      let s, counter = assign s counter in
      (PCapture (i, n, s), counter)
  | PTuple (i, elements, s) ->
      let elements, counter = map_fold sym_pattern counter elements in
      let s, counter = assign s counter in
      (PTuple (i, elements, s), counter)
  | PList (i, prefix, rest, suffix, s) ->
      let prefix, counter = map_fold sym_pattern counter prefix in
      let rest, counter = map_option sym_list_rest counter rest in
      let suffix, counter = map_fold sym_pattern counter suffix in
      let s, counter = assign s counter in
      (PList (i, prefix, rest, suffix, s), counter)
  | PText (i, prefix, rest, suffix, s) ->
      let s, counter = assign s counter in
      (PText (i, prefix, rest, suffix, s), counter)

and sym_list_rest counter (ListRest (i, name, s)) =
  let s, counter = assign s counter in
  (ListRest (i, name, s), counter)

and sym_comp_clause counter c =
  match c with
  | CompFor (i, pattern, sequence, s) ->
      let pattern, counter = sym_pattern counter pattern in
      let sequence, counter = sym_expr counter sequence in
      let s, counter = assign s counter in
      (CompFor (i, pattern, sequence, s), counter)
  | CompIf (i, condition, s) ->
      let condition, counter = sym_expr counter condition in
      let s, counter = assign s counter in
      (CompIf (i, condition, s), counter)

and sym_target counter t =
  match t with
  | TargetName (i, n, s) ->
      let s, counter = assign s counter in
      (TargetName (i, n, s), counter)
  | TargetTuple (i, elements, s) ->
      let elements, counter = map_fold sym_target counter elements in
      let s, counter = assign s counter in
      (TargetTuple (i, elements, s), counter)

and sym_param counter (Param (i, name, type_, s)) =
  let type_, counter = map_option sym_type counter type_ in
  let s, counter = assign s counter in
  (Param (i, name, type_, s), counter)

and sym_loop_iter counter it =
  match it with
  | ForIn (i, name, sequence, s) ->
      let sequence, counter = sym_expr counter sequence in
      let s, counter = assign s counter in
      (ForIn (i, name, sequence, s), counter)
  | WhileTest (i, condition, s) ->
      let condition, counter = sym_expr counter condition in
      let s, counter = assign s counter in
      (WhileTest (i, condition, s), counter)

and sym_case counter (MatchCase (i, pattern, body, s)) =
  let pattern, counter = sym_pattern counter pattern in
  let body, counter = map_fold sym_stmt counter body in
  let s, counter = assign s counter in
  (MatchCase (i, pattern, body, s), counter)

and sym_stmt counter st =
  match st with
  | SLet (i, target, expr, type_, s, public) ->
      let target, counter = sym_target counter target in
      let expr, counter = sym_expr counter expr in
      let type_, counter = map_option sym_type counter type_ in
      let s, counter = assign s counter in
      (SLet (i, target, expr, type_, s, public), counter)
  | SLetStmt (i, target, stmt, type_, s, public) ->
      let target, counter = sym_target counter target in
      let stmt, counter = sym_stmt counter stmt in
      let type_, counter = map_option sym_type counter type_ in
      let s, counter = assign s counter in
      (SLetStmt (i, target, stmt, type_, s, public), counter)
  | SVar (i, name, expr, s) ->
      let expr, counter = sym_expr counter expr in
      let s, counter = assign s counter in
      (SVar (i, name, expr, s), counter)
  | SMutate (i, name, expr, s) ->
      let expr, counter = sym_expr counter expr in
      let s, counter = assign s counter in
      (SMutate (i, name, expr, s), counter)
  | SReturn (i, expr, s) ->
      let expr, counter = sym_expr counter expr in
      let s, counter = assign s counter in
      (SReturn (i, expr, s), counter)
  | SReturnStmt (i, stmt, s) ->
      let stmt, counter = sym_stmt counter stmt in
      let s, counter = assign s counter in
      (SReturnStmt (i, stmt, s), counter)
  | SExprStmt (i, expr, s) ->
      let expr, counter = sym_expr counter expr in
      let s, counter = assign s counter in
      (SExprStmt (i, expr, s), counter)
  | SLoop (i, target, init, type_, iterate, result, body, s) ->
      let target, counter = map_option sym_target counter target in
      let init, counter = map_option sym_expr counter init in
      let type_, counter = map_option sym_type counter type_ in
      let iterate, counter = map_option sym_loop_iter counter iterate in
      let result, counter = map_option sym_expr counter result in
      let body, counter = map_fold sym_stmt counter body in
      let s, counter = assign s counter in
      (SLoop (i, target, init, type_, iterate, result, body, s), counter)
  | SBreak (i, expr, s) ->
      let expr, counter = map_option sym_expr counter expr in
      let s, counter = assign s counter in
      (SBreak (i, expr, s), counter)
  | SContinue (i, expr, s) ->
      let expr, counter = map_option sym_expr counter expr in
      let s, counter = assign s counter in
      (SContinue (i, expr, s), counter)
  | SIf (i, cond, then_body, else_body, s) ->
      let cond, counter = sym_expr counter cond in
      let then_body, counter = map_fold sym_stmt counter then_body in
      let else_body, counter =
        map_option (fun counter body -> map_fold sym_stmt counter body) counter
          else_body
      in
      let s, counter = assign s counter in
      (SIf (i, cond, then_body, else_body, s), counter)
  | SFunctionDef (i, name, params, body, return_type, s, public) ->
      let params, counter = map_fold sym_param counter params in
      let body, counter = map_fold sym_stmt counter body in
      let return_type, counter = map_option sym_type counter return_type in
      let s, counter = assign s counter in
      (SFunctionDef (i, name, params, body, return_type, s, public), counter)
  | SFunctionSig (i, name, type_, s, public) ->
      let type_, counter = sym_type counter type_ in
      let s, counter = assign s counter in
      (SFunctionSig (i, name, type_, s, public), counter)
  | SMatch (i, subject, cases, s) ->
      let subject, counter = sym_expr counter subject in
      let cases, counter = map_fold sym_case counter cases in
      let s, counter = assign s counter in
      (SMatch (i, subject, cases, s), counter)
  | SImport (i, module_name, name, selected, fields, s) ->
      (* The strings an import holds are not nodes, so the statement's
         own symbol is all it has. *)
      let s, counter = assign s counter in
      (SImport (i, module_name, name, selected, fields, s), counter)

(* --- the largest symbol already handed out ---
   A tree that has been symbolized once keeps the numbers it has, and
   new ones continue past the highest, so running symbolize again is
   safe. *)

let high_list f items = List.fold_left (fun acc x -> max acc (f x)) 0 items

let high_option f item = match item with None -> 0 | Some x -> f x

let rec high_expr e =
  let children =
    match e with
    | EInt _ | EString _ | EBool _ | EVar _ | EQualified _ -> 0
    | EAdd (_, l, r, _)
    | ESub (_, l, r, _)
    | EMul (_, l, r, _)
    | EDiv (_, l, r, _)
    | EConcat (_, l, r, _)
    | ELessThan (_, l, r, _)
    | ELessThanEq (_, l, r, _)
    | EGreatThan (_, l, r, _)
    | EGreatThanEq (_, l, r, _)
    | EEq (_, l, r, _) ->
        max (high_expr l) (high_expr r)
    | ENeg (_, o, _) -> high_expr o
    | ECall (_, f, args, _) -> max (high_expr f) (high_list high_expr args)
    | EList (_, es, _) | ETuple (_, es, _) -> high_list high_expr es
    | EIf (_, c, t, e2, _) ->
        max (high_expr c) (max (high_expr t) (high_expr e2))
    | EListComp (_, e2, clauses, _) ->
        max (high_expr e2) (high_list high_comp_clause clauses)
  in
  max (expr_sym e) children

and high_type t =
  let children =
    match t with
    | TInt _ | TString _ | TBool _ | TUnknown _ | TBuiltin _ | TVar _ -> 0
    | TList (_, element, _) -> high_type element
    | TTuple (_, elements, _) -> high_list high_type elements
    | TFunction (_, params, result, _, _, definition) ->
        max
          (max (high_list high_type params) (high_type result))
          (high_option high_stmt definition)
    | TForall (_, _, body, _) -> high_type body
  in
  max (type_sym t) children

and high_pattern p =
  let children =
    match p with
    | PInt _ | PString _ | PBool _ | PWildcard _ | PCapture _ | PText _ -> 0
    | PTuple (_, elements, _) -> high_list high_pattern elements
    | PList (_, prefix, rest, suffix, _) ->
        max
          (max (high_list high_pattern prefix) (high_list high_pattern suffix))
          (high_option (fun (ListRest (_, _, s)) -> s) rest)
  in
  max (pattern_sym p) children

and high_comp_clause c =
  let children =
    match c with
    | CompFor (_, pattern, sequence, _) ->
        max (high_pattern pattern) (high_expr sequence)
    | CompIf (_, condition, _) -> high_expr condition
  in
  max (comp_sym c) children

and high_target t =
  let children =
    match t with
    | TargetName _ -> 0
    | TargetTuple (_, elements, _) -> high_list high_target elements
  in
  max (target_sym t) children

and high_param (Param (_, _, type_, s)) = max s (high_option high_type type_)

and high_loop_iter it =
  match it with
  | ForIn (_, _, sequence, s) -> max s (high_expr sequence)
  | WhileTest (_, condition, s) -> max s (high_expr condition)

and high_case (MatchCase (_, pattern, body, s)) =
  max s (max (high_pattern pattern) (high_list high_stmt body))

and high_stmt st =
  let children =
    match st with
    | SLet (_, target, expr, type_, _, _) ->
        max
          (max (high_target target) (high_expr expr))
          (high_option high_type type_)
    | SLetStmt (_, target, stmt, type_, _, _) ->
        max
          (max (high_target target) (high_stmt stmt))
          (high_option high_type type_)
    | SVar (_, _, expr, _) | SMutate (_, _, expr, _) | SReturn (_, expr, _)
    | SExprStmt (_, expr, _) ->
        high_expr expr
    | SReturnStmt (_, stmt, _) -> high_stmt stmt
    | SLoop (_, target, init, type_, iterate, result, body, _) ->
        List.fold_left max 0
          [
            high_option high_target target;
            high_option high_expr init;
            high_option high_type type_;
            high_option high_loop_iter iterate;
            high_option high_expr result;
            high_list high_stmt body;
          ]
    | SBreak (_, expr, _) | SContinue (_, expr, _) -> high_option high_expr expr
    | SIf (_, cond, then_body, else_body, _) ->
        List.fold_left max 0
          [
            high_expr cond;
            high_list high_stmt then_body;
            high_option (high_list high_stmt) else_body;
          ]
    | SFunctionDef (_, _, params, body, return_type, _, _) ->
        List.fold_left max 0
          [
            high_list high_param params;
            high_list high_stmt body;
            high_option high_type return_type;
          ]
    | SFunctionSig (_, _, type_, _, _) -> high_type type_
    | SMatch (_, subject, cases, _) ->
        max (high_expr subject) (high_list high_case cases)
    | SImport _ -> 0
  in
  max (stmt_sym st) children

(** The largest sym anywhere in a program, or 0 if none is symbolized.
    [stmt] -> int *)
let highest_sym stmts = high_list high_stmt stmts

(** Rebuilds stmts so every node has a unique sym, numbered post-order
    starting at 1 (0 means "not symbolized"). A node that already has a
    symbol keeps it; safe to run more than once. [stmt] -> [stmt] *)
let symbolize stmts =
  let stmts, _ = map_fold sym_stmt (highest_sym stmts + 1) stmts in
  stmts
