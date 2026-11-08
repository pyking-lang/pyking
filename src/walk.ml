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
  | NConstructor of constructor
  | NFieldDecl of field
  | NStmt of stmt

let exprs_of es = List.map (fun e -> NExpr e) es
let stmts_of ss = List.map (fun s -> NStmt s) ss
let option_of wrap = function None -> [] | Some x -> [ wrap x ]

(** One node's immediate children, in the order src/syntax.ml declares
    the fields they came from. node -> [node] *)
let rec children n =
  match n with
  | NExpr e -> (
      match e with
      | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ | EQualified _ -> []
      | EAdd (_, l, r, _)
      | ESub (_, l, r, _)
      | EMul (_, l, r, _)
      | EDiv (_, l, r, _)
      | EConcat (_, l, r, _)
      | ELessThan (_, l, r, _)
      | ELessThanEq (_, l, r, _)
      | EGreatThan (_, l, r, _)
      | EGreatThanEq (_, l, r, _)
      | EEq (_, l, r, _)
      | EBinary (_, _, l, r, _)
      | EIndex (_, l, r, _) ->
          [ NExpr l; NExpr r ]
      | ESlice (_, l, a, b, _) -> NExpr l :: List.map (fun e -> NExpr e) (Option.to_list a @ Option.to_list b)
      | EAddr (_, e, _) | EDeref (_, e, _) -> [ NExpr e ]
      | EUnary (_, _, operand, _) -> [ NExpr operand ]
      | ENeg (_, operand, _) -> [ NExpr operand ]
      | ECall (_, func, args, _) -> NExpr func :: exprs_of (arg_exprs args)
      | EList (_, elements, _) | ETuple (_, elements, _) -> exprs_of elements
      | EIf (_, condition, then_, else_, _) ->
          [ NExpr condition; NExpr then_; NExpr else_ ]
      | EListComp (_, element, clauses, _) ->
          NExpr element :: List.map (fun c -> NCompClause c) clauses
      | ELambda (_, params, body, _) ->
          List.map (fun p -> NParam p) params @ [ NExpr body ]
      | EConstruct (_, _, _, args, _) -> exprs_of (arg_exprs args)
      | ELet (_, target, annotation, value, body, _) ->
          (NTarget target :: option_of (fun t -> NType t) annotation)
          @ [ NExpr value; NExpr body ]
      | EField (_, record, _, _) -> [ NExpr record ]
      | EMethod (_, obj, _, args, _) -> NExpr obj :: exprs_of (arg_exprs args)
      | ESuper (_, _, _, args, _) -> exprs_of (arg_exprs args)
      | EUpcast (_, e, t, _) -> [ NExpr e; NType t ])
  | NType t -> (
      match t with
      | TInt _ | TFloat _ | TString _ | TChar _ | TBool _ | TUnknown _ | TBuiltin _
      | TVar _ ->
          []
      | TList (_, element, _) -> [ NType element ]
      | TTuple (_, elements, _) -> List.map (fun t -> NType t) elements
      | TFunction (_, params, result, _, _, definition, implicits) ->
          List.map (fun t -> NType t) params
          @ List.map (fun (IParam (_, t)) -> NType t) implicits
          @ [ NType result ]
          @ option_of (fun s -> NStmt s) definition
      | TForall (_, _, body, _) -> [ NType body ]
      | TCon (_, _, args, _) -> List.map (fun t -> NType t) args
      | TData (_, Datatype (_, _, constructors, _), _) ->
          List.concat_map
            (fun (_, fields) -> List.map (fun (_, t) -> NType t) fields)
            constructors)
  | NPattern p -> (
      match p with
      | PInt _ | PString _ | PChar _ | PBool _ | PWildcard _ | PCapture _ | PText _ -> []
      | PTuple (_, elements, _) -> List.map (fun p -> NPattern p) elements
      | PList (_, prefix, rest, suffix, _) ->
          List.map (fun p -> NPattern p) prefix
          @ option_of (fun r -> NListRest r) rest
          @ List.map (fun p -> NPattern p) suffix
      | PConstructor (_, _, _, positional, named, _) ->
          List.map (fun p -> NPattern p) (positional @ List.map snd named)
      | POr (_, alternatives, _) -> List.map (fun p -> NPattern p) alternatives
      | PAs (_, inner, _, _) -> [ NPattern inner ]
      | PTyped (_, _, t, _) -> [ NType t ])
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
  | NParam (Param (_, _, annotation, default, _)) ->
      option_of (fun t -> NType t) annotation
      @ option_of (fun e -> NExpr e) default
  | NLoopIter iterate -> (
      match iterate with
      | ForIn (_, _, sequence, _) -> [ NExpr sequence ]
      | WhileTest (_, condition, _) -> [ NExpr condition ])
  | NMatchCase (MatchCase (_, pattern, guard, body, _)) ->
      (NPattern pattern :: option_of (fun e -> NExpr e) guard) @ stmts_of body
  | NConstructor (Constructor (_, _, fields, _)) ->
      List.map (fun f -> NFieldDecl f) fields
  | NFieldDecl (Field (_, _, type_, default, _)) ->
      option_of (fun t -> NType t) type_ @ option_of (fun e -> NExpr e) default
  | NStmt s -> (
      match s with
      | SBreak (_, value, _) | SContinue (_, value, _) ->
          option_of (fun e -> NExpr e) value
      | SImport _ -> []
      | SLet (_, target, e, annotation, _, _, _) ->
          [ NTarget target; NExpr e ] @ option_of (fun t -> NType t) annotation
      | SLetStmt (_, target, inner, annotation, _, _) ->
          [ NTarget target; NStmt inner ]
          @ option_of (fun t -> NType t) annotation
      | SVar (_, _, e, _) | SMutate (_, _, e, _) -> [ NExpr e ]
      | SMutateTuple (_, target, e, _) -> [ NTarget target; NExpr e ]
      | SSetIndex (_, owner, index, value, _) -> [ NExpr owner; NExpr index; NExpr value ]
      | SSetField (_, owner, _, value, _) -> [ NExpr owner; NExpr value ]
      | SSetDeref (_, pointer, value, _) -> [ NExpr pointer; NExpr value ]
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
      | SFunctionDef (_, _, params, body, return_type, _, _, implicits, _) ->
          List.map (fun p -> NParam p) (params @ implicits)
          @ stmts_of body
          @ option_of (fun t -> NType t) return_type
      | SFunctionSig (_, _, t, _, _) -> [ NType t ]
      | SMatch (_, subject, cases, _) ->
          NExpr subject :: List.map (fun c -> NMatchCase c) cases
      | SDatatype (_, _, _, constructors, _, _, _) ->
          List.map (fun c -> NConstructor c) constructors
      | SClass (_, c, _) -> class_children c)

(** A class's children: its header fields' types and defaults, its
    supertypes' type and constructor arguments, its body fields, then
    each method's parameters, body and return type. class_decl -> [node] *)
and class_children c =
  let field (MemberField (_, _, t, e, _, _, _)) = option_of (fun t -> NType t) t @ option_of (fun e -> NExpr e) e in
  let ref_ (ClassRef (_, _, _, args, ctor, _)) = List.map (fun t -> NType t) args @ exprs_of (arg_exprs ctor) in
  let method_ (MethodDecl (_, _, params, ret, body, _, _, _)) =
    List.map (fun p -> NParam p) params
    @ (match body with Some b -> stmts_of b | None -> [])
    @ option_of (fun t -> NType t) ret
  in
  List.concat_map field c.c_header
  @ List.concat_map ref_ (Option.to_list c.c_extends @ c.c_implements)
  @ List.concat_map field c.c_fields
  @ List.concat_map method_ c.c_methods

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
  | NParam (Param (_, name, _, _, _)) -> Some name
  | NPattern (PCapture (_, name, _)) -> Some name
  | NPattern (PAs (_, _, name, _)) -> Some name
  | NPattern (PTyped (_, name, _, _)) -> Some name
  | NListRest (ListRest (_, name, _)) -> name
  | NTarget (TargetName (_, name, _)) -> Some name
  | NLoopIter (ForIn (_, name, _, _)) -> Some name
  | NStmt (SVar (_, name, _, _))
  | NStmt (SMutate (_, name, _, _))
  | NStmt (SFunctionDef (_, name, _, _, _, _, _, _, _))
  | NStmt (SFunctionSig (_, name, _, _, _))
  | NStmt (SImport (_, _, name, _, _, _)) ->
      Some name
  | _ -> None

(* --- rewriting every expression ---
   A bottom-up map: each expression's children are rewritten first, and
   the node rebuilt from them is handed to `f`. Statements, patterns and
   types keep their shape; every expression inside them -- class members
   included -- is reached. *)

(** e with every expression in it rewritten by f, innermost first.
    (expr -> expr) -> expr -> expr *)
let rec map_expr f e =
  let go = map_expr f in
  let args a = List.map (fun (n, x) -> (n, go x)) a in
  let rebuilt =
    match e with
    | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ | EQualified _ -> e
    | EAdd (i, l, r, s) -> EAdd (i, go l, go r, s)
    | ESub (i, l, r, s) -> ESub (i, go l, go r, s)
    | EMul (i, l, r, s) -> EMul (i, go l, go r, s)
    | EDiv (i, l, r, s) -> EDiv (i, go l, go r, s)
    | ENeg (i, o, s) -> ENeg (i, go o, s)
    | EConcat (i, l, r, s) -> EConcat (i, go l, go r, s)
    | ELessThan (i, l, r, s) -> ELessThan (i, go l, go r, s)
    | ELessThanEq (i, l, r, s) -> ELessThanEq (i, go l, go r, s)
    | EGreatThan (i, l, r, s) -> EGreatThan (i, go l, go r, s)
    | EGreatThanEq (i, l, r, s) -> EGreatThanEq (i, go l, go r, s)
    | EEq (i, l, r, s) -> EEq (i, go l, go r, s)
    | EBinary (i, op, l, r, s) -> EBinary (i, op, go l, go r, s)
    | EUnary (i, op, o, s) -> EUnary (i, op, go o, s)
    | EIndex (i, l, x, s) -> EIndex (i, go l, go x, s)
    | EAddr (i, x, s) -> EAddr (i, go x, s)
    | EDeref (i, x, s) -> EDeref (i, go x, s)
    | ESlice (i, l, a, b, s) -> ESlice (i, go l, Option.map go a, Option.map go b, s)
    | ECall (i, callee, a, s) -> ECall (i, go callee, args a, s)
    | EList (i, es, s) -> EList (i, List.map go es, s)
    | ETuple (i, es, s) -> ETuple (i, List.map go es, s)
    | EIf (i, c, a, b, s) -> EIf (i, go c, go a, go b, s)
    | EListComp (i, x, clauses, s) ->
        let clause c =
          match c with
          | CompFor (ci, p, seq, cs) -> CompFor (ci, p, go seq, cs)
          | CompIf (ci, cond, cs) -> CompIf (ci, go cond, cs)
        in
        EListComp (i, go x, List.map clause clauses, s)
    | ELambda (i, params, body, s) -> ELambda (i, List.map (map_param f) params, go body, s)
    | ELet (i, t, a, v, b, s) -> ELet (i, t, a, go v, go b, s)
    | EConstruct (i, m, n, a, s) -> EConstruct (i, m, n, args a, s)
    | EField (i, r, n, s) -> EField (i, go r, n, s)
    | EMethod (i, o, n, a, s) -> EMethod (i, go o, n, args a, s)
    | ESuper (i, c, n, a, s) -> ESuper (i, c, n, args a, s)
    | EUpcast (i, x, t, s) -> EUpcast (i, go x, t, s)
  in
  f rebuilt

and map_param f (Param (i, n, t, d, s)) = Param (i, n, t, Option.map (map_expr f) d, s)

(** A statement with every expression in it rewritten by f.
    (expr -> expr) -> stmt -> stmt *)
and map_stmt f st =
  let e = map_expr f in
  let block = List.map (map_stmt f) in
  match st with
  | SLet (i, t, x, a, s, p, im) -> SLet (i, t, e x, a, s, p, im)
  | SLetStmt (i, t, inner, a, s, p) -> SLetStmt (i, t, map_stmt f inner, a, s, p)
  | SVar (i, n, x, s) -> SVar (i, n, e x, s)
  | SMutate (i, n, x, s) -> SMutate (i, n, e x, s)
  | SSetIndex (i, o, x, v, s) -> SSetIndex (i, e o, e x, e v, s)
  | SSetDeref (i, p, v, s) -> SSetDeref (i, e p, e v, s)
  | SSetField (i, o, n, v, s) -> SSetField (i, e o, n, e v, s)
  | SMutateTuple (i, t, x, s) -> SMutateTuple (i, t, e x, s)
  | SReturn (i, x, s) -> SReturn (i, e x, s)
  | SReturnStmt (i, inner, s) -> SReturnStmt (i, map_stmt f inner, s)
  | SExprStmt (i, x, s) -> SExprStmt (i, e x, s)
  | SLoop (i, t, init, a, it, body, s) ->
      let it =
        match it with
        | Some (ForIn (fi, n, seq, fs)) -> Some (ForIn (fi, n, e seq, fs))
        | Some (WhileTest (wi, c, ws)) -> Some (WhileTest (wi, e c, ws))
        | None -> None
      in
      SLoop (i, t, Option.map e init, a, it, block body, s)
  | SBreak (i, v, s) -> SBreak (i, Option.map e v, s)
  | SContinue (i, v, s) -> SContinue (i, Option.map e v, s)
  | SIf (i, c, a, b, s) -> SIf (i, e c, block a, Option.map block b, s)
  | SFunctionDef (i, n, ps, body, r, s, p, imps, im) ->
      SFunctionDef (i, n, List.map (map_param f) ps, block body, r, s, p, List.map (map_param f) imps, im)
  | SFunctionSig _ | SDatatype _ | SImport _ -> st
  | SMatch (i, subject, cases, s) ->
      SMatch
        ( i,
          e subject,
          List.map (fun (MatchCase (ci, p, g, b, cs)) -> MatchCase (ci, p, Option.map e g, block b, cs)) cases,
          s )
  | SClass (i, c, s) -> SClass (i, map_class e block c, s)

(** Statements with every expression in them rewritten by f.
    (expr -> expr) -> [stmt] -> [stmt] *)
let map_stmts f stmts = List.map (map_stmt f) stmts
