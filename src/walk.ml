(** One generic traversal of the AST, for the passes that ask a question
    of a whole subtree rather than of one node kind: which functions can
    print, whether an expression holds a call, whether a name is used as
    a string. The descent is written out once -- in this module --
    instead of once per pass.

    `children` is the whole of it: one node's immediate children, in the
    order src/syntax.ml declares the fields they came from, so a
    pre-order walk reaches a node before anything inside it. Everything
    else here is a fold over that.

    A node kind added to syntax.ml needs a case here, and nothing but a
    pass that would have looked inside it will notice if it is missed.
    See docs/architecture.md.

    Data structures:
      node -- any AST node, whatever its type.

    Functions:
      children n -- one node's immediate children, in field order.
      fold f acc n -- f over every node in a subtree, pre-order.
      exists p n -- whether any node in a subtree satisfies p.
      fold_stmts f acc stmts -- fold over a statement sequence.
      exists_stmts p stmts -- exists over a statement sequence.
      name_field n -- the value of a node's `name` field, if it has one. *)

open Syntax

(** Any AST node, whatever its type: what a traversal that does not care
    which kind of node it is looking at carries. *)
type node =
  | NExpr of expr
  | NType of typ
  | NPattern of pattern
  | NListRest of list_rest
  | NCompClause of comp_clause
  | NTarget of assign_target
  | NParam of param
  | NLoopIter of loop_iter
  | NMatchCase of match_case
  | NStmt of stmt

let exprs_of es = List.map (fun e -> NExpr e) es
let stmts_of ss = List.map (fun s -> NStmt s) ss
let option_of wrap = function None -> [] | Some x -> [ wrap x ]

(** One node's immediate children, in the order src/syntax.ml declares
    the fields they came from. node -> [node] *)
let children n =
  match n with
  | NExpr e -> (
      match e with
      | EInt _ | EFloat _ | EString _ | EBool _ | EVar _ | EQualified _ -> []
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
          [ NExpr l; NExpr r ]
      | ENeg (_, operand, _) -> [ NExpr operand ]
      | ECall (_, func, args, _) -> NExpr func :: exprs_of args
      | EList (_, elements, _) | ETuple (_, elements, _) -> exprs_of elements
      | EIf (_, condition, then_, else_, _) ->
          [ NExpr condition; NExpr then_; NExpr else_ ]
      | EListComp (_, element, clauses, _) ->
          NExpr element :: List.map (fun c -> NCompClause c) clauses)
  | NType t -> (
      match t with
      | TInt _ | TFloat _ | TString _ | TBool _ | TUnknown _ | TBuiltin _
      | TVar _ ->
          []
      | TList (_, element, _) -> [ NType element ]
      | TTuple (_, elements, _) -> List.map (fun t -> NType t) elements
      | TFunction (_, params, result, _, _, definition) ->
          List.map (fun t -> NType t) params
          @ [ NType result ]
          @ option_of (fun s -> NStmt s) definition
      | TForall (_, _, body, _) -> [ NType body ])
  | NPattern p -> (
      match p with
      | PInt _ | PString _ | PBool _ | PWildcard _ | PCapture _ | PText _ -> []
      | PTuple (_, elements, _) -> List.map (fun p -> NPattern p) elements
      | PList (_, prefix, rest, suffix, _) ->
          List.map (fun p -> NPattern p) prefix
          @ option_of (fun r -> NListRest r) rest
          @ List.map (fun p -> NPattern p) suffix)
  | NListRest _ -> []
  | NCompClause c -> (
      match c with
      | CompFor (_, pattern, sequence, _) ->
          [ NPattern pattern; NExpr sequence ]
      | CompIf (_, condition, _) -> [ NExpr condition ])
  | NTarget target -> (
      match target with
      | TargetName _ -> []
      | TargetTuple (_, elements, _) ->
          List.map (fun t -> NTarget t) elements)
  | NParam (Param (_, _, annotation, _)) ->
      option_of (fun t -> NType t) annotation
  | NLoopIter iterate -> (
      match iterate with
      | ForIn (_, _, sequence, _) -> [ NExpr sequence ]
      | WhileTest (_, condition, _) -> [ NExpr condition ])
  | NMatchCase (MatchCase (_, pattern, body, _)) ->
      NPattern pattern :: stmts_of body
  | NStmt s -> (
      match s with
      | SBreak _ | SContinue _ | SImport _ -> []
      | SLet (_, target, e, annotation, _, _) ->
          [ NTarget target; NExpr e ] @ option_of (fun t -> NType t) annotation
      | SLetStmt (_, target, inner, annotation, _, _) ->
          [ NTarget target; NStmt inner ]
          @ option_of (fun t -> NType t) annotation
      | SVar (_, _, e, _) | SMutate (_, _, e, _) -> [ NExpr e ]
      | SReturn (_, e, _) | SExprStmt (_, e, _) -> [ NExpr e ]
      | SReturnStmt (_, inner, _) -> [ NStmt inner ]
      | SLoop (_, target, init, annotation, iterate, body, _) ->
          option_of (fun t -> NTarget t) target
          @ option_of (fun e -> NExpr e) init
          @ option_of (fun t -> NType t) annotation
          @ option_of (fun i -> NLoopIter i) iterate
          @ stmts_of body
      | SIf (_, condition, then_body, else_body, _) ->
          (NExpr condition :: stmts_of then_body)
          @ (match else_body with None -> [] | Some body -> stmts_of body)
      | SFunctionDef (_, _, params, body, return_type, _, _) ->
          List.map (fun p -> NParam p) params
          @ stmts_of body
          @ option_of (fun t -> NType t) return_type
      | SFunctionSig (_, _, t, _, _) -> [ NType t ]
      | SMatch (_, subject, cases, _) ->
          NExpr subject :: List.map (fun c -> NMatchCase c) cases)

(** f over every node in a subtree, the subtree's own root first.
    ('a -> node -> 'a) -> 'a -> node -> 'a *)
let rec fold f acc n = List.fold_left (fold f) (f acc n) (children n)

(** Whether any node in a subtree satisfies p. Stops at the first one.
    (node -> bool) -> node -> bool *)
let rec exists p n = p n || List.exists (exists p) (children n)

(** f over every node in a statement sequence. The sequence itself is
    not a node. ('a -> node -> 'a) -> 'a -> [stmt] -> 'a *)
let fold_stmts f acc stmts =
  List.fold_left (fun acc s -> fold f acc (NStmt s)) acc stmts

(** Whether any node in a statement sequence satisfies p.
    (node -> bool) -> [stmt] -> bool *)
let exists_stmts p stmts = List.exists (fun s -> exists p (NStmt s)) stmts

(** The value of a node's `name` field, where it has one. Fourteen node
    kinds have a field called `name`, and src/opt_tailcall.ml's blunt
    tests for "does this program write this identifier" ask for exactly
    that field. Note what is *not* one: a PText's captured middle is
    called `rest`, and the variables a TForall binds are called `vars`,
    so neither is an identifier by this test.
    node -> string option *)
let name_field n =
  match n with
  | NExpr (EVar (_, name, _)) | NExpr (EQualified (_, _, name, _)) -> Some name
  | NType (TBuiltin (_, name, _)) | NType (TVar (_, name, _, _)) -> Some name
  | NParam (Param (_, name, _, _)) -> Some name
  | NPattern (PCapture (_, name, _)) -> Some name
  | NListRest (ListRest (_, name, _)) -> name
  | NTarget (TargetName (_, name, _)) -> Some name
  | NLoopIter (ForIn (_, name, _, _)) -> Some name
  | NStmt (SVar (_, name, _, _))
  | NStmt (SMutate (_, name, _, _))
  | NStmt (SFunctionDef (_, name, _, _, _, _, _))
  | NStmt (SFunctionSig (_, name, _, _, _))
  | NStmt (SImport (_, _, name, _, _, _)) ->
      Some name
  | _ -> None
