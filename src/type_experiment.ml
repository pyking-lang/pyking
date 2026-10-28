(** An alternative type checker, at its beginning: a program is a
    sequence of statements, and the fragment checked here is integer
    literals, variables and `+`. Everything else is refused with
    `Construct is not supported`, which is the floor typesystem.ml keeps
    for whatever it has not reasoned about yet. `pyk --type-experiment`
    is what runs this one instead of typesystem.ml, so it can be grown
    against real programs.

    The shape is typesystem.ml's, and the one to keep as this grows: one function per AST datatype, each taking a node of
    exactly that type; an `env` mapping a name to its type, used
    immutably, so a binding hands what follows it an extended copy; and
    one table, `tmap`, from a node's symbol to the type worked out for
    it, which is the pass's result. See docs/typesystem.md for what
    typesystem.ml does with the rest of the language.

    Data structures:
      Type_error -- a type failure, with the source position.
      env -- a name's type, in scope.
      tmap -- symbol -> the type inferred for that node.

    Functions:
      type_check stmts -- checks a whole program; answers its tmap.
      check_stmts env tmap stmts -- checks a statement sequence.
      check_stmt env tmap stmt -- checks one statement.
      check_expr env tmap expr -- the type of one expression.
      same_type a b -- whether two types are the same type. *)

open Lexer
open Syntax

(** A type failure, with the source position. *)
exception Type_error of info * string

module Env = Map.Make (String)

type env = typ Env.t
type tmap = typ IntMap.t

(* What a construct nothing here has reasoned about is refused with.
   typesystem.ml keeps the same floor, in the same words. *)
let unsupported = "Construct is not supported"

(** Whether two types are the same type. Compared here rather than with
    structural equality, since a type carries a source span and a symbol
    that say nothing about which type it is. typ -> typ -> bool *)
let rec same_type a b =
  match (a, b) with
  | TInt _, TInt _ -> true
  | TString _, TString _ -> true
  | TChar _, TChar _ -> true
  | TBool _, TBool _ -> true
  | TList (_, x, _), TList (_, y, _) -> same_type x y
  | TTuple (_, xs, _), TTuple (_, ys, _) ->
      List.length xs = List.length ys && List.for_all2 same_type xs ys
  | TVar (_, x, _, _), TVar (_, y, _, _) -> x = y
  | _ -> false

(** The type of one expression, and the table with it recorded.
    env -> tmap -> expr -> (typ, tmap) *)
let rec check_expr (env : env) tmap e =
  let type_, tmap = expr_type env tmap e in
  (type_, IntMap.add (expr_sym e) type_ tmap)

(** The rules: what each expression this checker reaches is worth.
    env -> tmap -> expr -> (typ, tmap) *)
and expr_type env tmap e =
  match e with
  | EInt (i, _, _) -> (TInt (i, 0), tmap)
  | EVar (i, name, _) -> (
      match Env.find_opt name env with
      | Some t -> (t, tmap)
      | None ->
          (* A name nothing bound is a name error, in the words
             analyses.ml uses for it: which pass caught it is not
             something the message should turn on. *)
          raise
            (Analyses.Analysis_error
               (i, Printf.sprintf "unbound name '%s'" name)))
  | EAdd (i, left, right, _) ->
      let left_type, tmap = check_expr env tmap left in
      let right_type, tmap = check_expr env tmap right in
      if same_type left_type (TInt (i, 0)) && same_type right_type (TInt (i, 0))
      then (TInt (i, 0), tmap)
      else
        raise
          (Type_error
             ( i,
               Printf.sprintf
                 "`+` cannot be applied to %s and %s; it accepts Int + Int"
                 (pprint_type default_config left_type)
                 (pprint_type default_config right_type) ))
  | _ -> raise (Type_error (expr_info e, unsupported))

(** Checks one statement, answering the environment it leaves behind.
    env -> tmap -> stmt -> (env, tmap) *)
and check_stmt env tmap s =
  match s with
  | SLet (_, TargetName (_, name, _), e, annotation, sym, _, _) ->
      let type_, tmap = check_expr env tmap e in
      check_annotation annotation type_;
      (Env.add name type_ env, IntMap.add sym type_ tmap)
  | SExprStmt (_, e, _) ->
      let _, tmap = check_expr env tmap e in
      (env, tmap)
  | _ -> raise (Type_error (stmt_info s, unsupported))

(** Checks a written annotation against the type the right-hand side
    turned out to have: an annotation is a claim about the program, and
    verifying it is the difference between an annotation and a comment.
    typ option -> typ -> () *)
and check_annotation annotation type_ =
  match annotation with
  | None -> ()
  | Some written ->
      if same_type written type_ then ()
      else
        raise
          (Type_error
             ( type_info written,
               Printf.sprintf "this binding is %s, and the annotation says %s"
                 (pprint_type default_config type_)
                 (pprint_type default_config written) ))

(** Checks a statement sequence, each in the environment the one before
    it left. env -> tmap -> [stmt] -> (env, tmap) *)
and check_stmts env tmap stmts =
  List.fold_left
    (fun (env, tmap) s -> check_stmt env tmap s)
    (env, tmap) stmts

(** Checks a whole program and answers the types it worked out.
    [stmt] -> tmap *)
let type_check stmts =
  let _, tmap = check_stmts Env.empty IntMap.empty stmts in
  tmap
