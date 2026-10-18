(** Static analyses over the Pyking AST (syntax.ml): mutability
    checking, symbolizing (giving every node a unique integer id), and
    which expressions can produce output. The first two run after
    parsing and before any backend; the third is asked for by the
    backends whose host language leaves evaluation order unspecified.
    See PYKING.md, "Names and scoping",
    and docs/analyses.md.

    Names and types are typesystem.ml's, which every mode runs: a name
    that is not in scope is refused there, in this module's words. What
    is left here is the one rule types do not state -- which names may
    be written to with `:=`, and that nothing may shadow one that can
    be.

    Data structures:
      Analysis_error -- a name/scoping failure, with the source position.
      kind -- what kind of binding introduced a name.
      binding -- what the environment records for one name in scope.
      env -- a name's binding, in scope.
      effects -- which calls in a program can end up printing.

    Functions:
      analyze_mutability stmts -- checks a whole program's mutability.
      analyze_stmts stmts env -- analyzes a statement sequence.
      analyze_stmt s env -- analyzes one statement.
      analyze_scope stmts env -- analyzes a nested block.
      bind env name kind info -- extends env with one binding.
      bind_target env target kind -- binds every name in an assign target.
      bind_pattern env pattern -- binds every name a pattern captures.
      pattern_bindings pattern -- the (name, info) pairs a pattern binds.
      bound_names stmt -- the (name, info) pairs a statement binds in
        its block.
      target_names target -- the (name, info) pairs an assign target binds.
      block_functions stmts -- the defs of a block, in source order.
      check_no_function_clash name info functions -- checks no other
        binding in the block shares a def's name.
      symbolize stmts -- gives every node a unique integer sym.
      highest_sym stmts -- the largest sym anywhere in a program.
      apply_signatures stmts -- folds every `def name : type` line onto
        the definition it describes.
      all_functions stmts -- every def in a program, at any depth, by name.
      effects stmts -- which functions in a program can print.
      may_print effects expr -- whether evaluating expr can print. *)

open Syntax

(** A name/scoping failure, with the source position. *)
exception Analysis_error of Lexer.info * string

(* --- kinds of binding --- *)

(** What kind of binding introduced a name. The text is what an error
    message calls it. *)
type kind =
  | Mutable (* var name = ... *)
  | Value (* name = ... *)
  | Parameter (* def f(name) *)
  | Loop_var (* for name in ... / loop name = ... *)
  | Pattern_var (* case ...name...: *)
  | Function (* def name(...) *)
  | Builtin (* see Builtin.names *)
  | Imported (* import m / from m import name *)

(** What an error message calls a kind of binding. kind -> string *)
let kind_name = function
  | Mutable -> "mutable variable"
  | Value -> "binding"
  | Parameter -> "parameter"
  | Loop_var -> "loop variable"
  | Pattern_var -> "pattern variable"
  | Function -> "function"
  | Builtin -> "builtin"
  | Imported -> "imported name"

module SMap = Map.Make (String)
module SSet = Set.Make (String)

(** What the environment records for one name in scope: how it was
    bound, and where -- None for a builtin, which has no source
    position. *)
type binding = { kind : kind; info : Lexer.info option }

type env = binding SMap.t

(** Formats where a binding was declared, for an error message; empty
    for a builtin. info option -> string *)
let where_declared info =
  match info with
  | None -> ""
  | Some (i : Lexer.info) -> Printf.sprintf " (declared on line %d)" i.row1

(** Formats where a binding was declared, for an error message; empty
    for a builtin. binding -> string *)
let where_bound binding = where_declared binding.info

(** Extends env with name bound as kind. Raises Analysis_error if name
    is already bound as a mutable variable.
    env -> string -> kind -> info -> env *)
let bind env name kind info =
  match SMap.find_opt name env with
  | Some existing when existing.kind = Mutable ->
      raise
        (Analysis_error
           ( info,
             Printf.sprintf
               "cannot bind '%s': the mutable variable '%s'%s is in scope, \
                and a mutable variable may not be shadowed (update it with \
                ':=', or choose another name)"
               name name (where_bound existing) ))
  | _ -> SMap.add name { kind; info = Some info } env

(** The names a pattern binds, as (name, info) pairs, in source order.
    pattern -> [(string, info)] *)
let rec pattern_bindings pattern =
  match pattern with
  | PCapture (info, name, _) -> [ (name, info) ]
  | PTuple (_, elements, _) -> List.concat_map pattern_bindings elements
  | PText (info, _, name, _, _) -> (
      match name with None -> [] | Some name -> [ (name, info) ])
  | PList (_, prefix, rest, suffix, _) ->
      let middle =
        match rest with
        | Some (ListRest (info, Some name, _)) -> [ (name, info) ]
        | _ -> []
      in
      List.concat_map pattern_bindings prefix
      @ middle
      @ List.concat_map pattern_bindings suffix
  | PConstructor (_, _, _, positional, named, _) ->
      List.concat_map pattern_bindings (positional @ List.map snd named)
  | POr (_, first :: _, _) -> pattern_bindings first
  | POr (_, [], _) -> []
  | PAs (info, inner, name, _) -> pattern_bindings inner @ [ (name, info) ]
  | PInt _ | PString _ | PBool _ | PWildcard _ -> []

(** Extends env with everything pattern binds. env -> pattern -> env *)
let bind_pattern env pattern =
  List.fold_left
    (fun env (name, info) -> bind env name Pattern_var info)
    env (pattern_bindings pattern)

(** The (name, info) pairs an assignment target binds.
    assign_target -> [(string, info)] *)
let rec target_names target =
  match target with
  | TargetName (info, name, _) -> [ (name, info) ]
  | TargetTuple (_, elements, _) -> List.concat_map target_names elements

(** Extends env with every name in an assignment target (which may
    destructure a tuple, `a, b = ...`).
    env -> assign_target -> kind -> env *)
let bind_target env target kind =
  List.fold_left
    (fun env (name, info) -> bind env name kind info)
    env (target_names target)

(* --- mutability ---

   The one rule types cannot state: `:=` writes to a name, and only a
   `var` may be written to. Everything else about a name -- that it is
   in scope where it is used, and what it holds -- typesystem.ml
   settles, so this walk never descends into an expression: no
   expression mutates anything. *)

(** The names a statement binds in the block it is written in (excludes
    for/pattern/parameter names, and a def's own name), as (name, info)
    pairs. stmt -> [(string, info)] *)
let bound_names stmt =
  match stmt with
  | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
      target_names target
  | SVar (info, name, _, _) -> [ (name, info) ]
  | SImport (info, _, name, selected, fields, _) ->
      (* The plain form binds the module's own local name; the `from`
         form binds each field under the name it is known by here. Both
         are top-level bindings like any other. *)
      if selected then List.map (fun (_, local) -> (local, info)) fields
      else [ (name, info) ]
  | _ -> []

(** Raises Analysis_error if name is one of functions' names.
    string -> info -> [(string, stmt)] -> () *)
let check_no_function_clash name info functions =
  match List.assoc_opt name functions with
  | None -> ()
  | Some clash ->
      raise
        (Analysis_error
           ( info,
             Printf.sprintf
               "cannot bind '%s': a function '%s' is defined in this block%s, \
                and a function's name may not also be bound there (a nested \
                block may shadow it)"
               name name
               (where_declared (Some (stmt_info clash))) ))

(** The function definitions written in a block, in source order.
    Raises Analysis_error if two defs in the block share a name, or if
    any other binding in the block shares a def's name.
    [stmt] -> [(string, stmt)] *)
let block_functions stmts =
  let add functions stmt =
    match stmt with
    | SFunctionDef (info, name, _, _, _, _, _, _, _) -> (
        match List.assoc_opt name functions with
        | Some earlier ->
            raise
              (Analysis_error
                 ( info,
                   Printf.sprintf
                     "'%s' is already defined as a function in this block%s; \
                      a function name may be defined once per block (a nested \
                      block may shadow it)"
                     name
                     (where_declared (Some (stmt_info earlier))) ))
        | None -> functions @ [ (name, stmt) ])
    | _ -> functions
  in
  let functions = List.fold_left add [] stmts in
  List.iter
    (fun stmt ->
      List.iter
        (fun (name, info) -> check_no_function_clash name info functions)
        (bound_names stmt))
    stmts;
  functions

(** Analyzes a statement sequence in env, threading the environment from
    one statement to the next; every def in the sequence is bound first.
    Answers the environment left after the last statement.
    [stmt] -> env -> env *)
let rec analyze_stmts stmts env =
  let env =
    List.fold_left
      (fun env (name, stmt) -> bind env name Function (stmt_info stmt))
      env (block_functions stmts)
  in
  List.fold_left (fun env stmt -> analyze_stmt stmt env) env stmts

(** Analyzes a nested block in env; whatever it binds is not visible
    outside it. [stmt] -> env -> () *)
and analyze_scope stmts env = ignore (analyze_stmts stmts env)

(** Binds the parameters of every lambda written in one statement's own
    expressions, so the no-shadowing-a-`var` rule reaches inside one.
    A nested block is not followed: it is analyzed in its own scope,
    with its own bindings, by whichever arm owns it. Nothing else here
    looks at an expression, because no expression mutates anything.
    env -> Walk.node -> () *)
and analyze_lambdas env node =
  match node with
  | Walk.NStmt _ -> ()
  | Walk.NExpr (ELambda (_, params, body, _)) ->
      let inner =
        List.fold_left
          (fun inner (Param (info, name, _, _, _)) ->
            bind inner name Parameter info)
          env params
      in
      analyze_lambdas inner (Walk.NExpr body)
  | node -> List.iter (analyze_lambdas env) (Walk.children node)

(** The lambdas written in one statement's own expressions.
    stmt -> env -> () *)
and analyze_own_exprs s env =
  List.iter (analyze_lambdas env) (Walk.children (Walk.NStmt s))

(** Analyzes a value-form if/match/loop (the right-hand side of a
    binding); does not bind the target itself. stmt -> env -> () *)
and analyze_value_stmt stmt env =
  match stmt with
  | SLoop _ ->
      (* A loop in value position is analyzed exactly as one written on
         its own: it binds its accumulator in its own body and nothing
         in the block around it. *)
      ignore (analyze_stmt stmt env)
  | SIf (_, _, then_body, else_body, _) ->
      analyze_own_exprs stmt env;
      analyze_scope then_body env;
      analyze_scope (Option.value else_body ~default:[]) env
  | SMatch (_, _, cases, _) ->
      analyze_own_exprs stmt env;
      List.iter (fun case_clause -> analyze_case case_clause env) cases
  | _ -> ()

(** Analyzes one case clause; the pattern's variables are bound in the
    arm's own scope. match_case -> env -> () *)
and analyze_case (MatchCase (_, pattern, _, body, _)) env =
  analyze_scope body (bind_pattern env pattern)

(** Analyzes one statement in env. Answers the environment the
    statements after it should see. stmt -> env -> env *)
and analyze_stmt s env =
  analyze_own_exprs s env;
  match s with
  | SLet (_, target, _, _, _, _, _) -> bind_target env target Value
  | SLetStmt (_, target, stmt, _, _, _) ->
      analyze_value_stmt stmt env;
      bind_target env target Value
  | SVar (info, name, _, _) -> bind env name Mutable info
  | SImport _ ->
      (* An import binds names like anything else, so the
         no-shadowing-a-`var` rule reaches it too. There is nothing
         inside one to walk. *)
      List.fold_left
        (fun env (name, info) -> bind env name Imported info)
        env (bound_names s)
  | SMutate (info, name, _, _) -> (
      match SMap.find_opt name env with
      | Some existing when existing.kind = Mutable -> env
      | existing ->
          (* The type checker has already refused a name in no scope at
             all, so a name missing here is one bound where this walk
             does not follow; either way it is not a `var`. *)
          let what =
            match existing with
            | None -> "not a mutable variable"
            | Some existing ->
                Printf.sprintf "a %s%s, not a mutable variable"
                  (kind_name existing.kind) (where_bound existing)
          in
          raise
            (Analysis_error
               ( info,
                 Printf.sprintf
                   "cannot update '%s' with ':=': it is %s (declare it with \
                    'var' to make it one)"
                   name what )))
  | SReturn _ | SExprStmt _ | SBreak _ | SContinue _ -> env
  | SReturnStmt (_, stmt, _) ->
      (* `return if c:` / `return match e:` -- the branches are ordinary
         nested scopes, exactly as in `SLetStmt`, and nothing is bound
         in the enclosing one. *)
      analyze_value_stmt stmt env;
      env
  | SLoop (_, target, _, _, iterate, body, _) ->
      (* The accumulator is bound for the body only, exactly as an `=`
         binding's target is bound for what follows it. *)
      let inner =
        match target with
        | None -> env
        | Some target -> bind_target env target Loop_var
      in
      (match iterate with
      | Some (ForIn (info, name, _, _)) ->
          analyze_scope body (bind inner name Loop_var info)
      | _ -> analyze_scope body inner);
      env
  | SIf (_, _, then_body, else_body, _) ->
      analyze_scope then_body env;
      (match else_body with
      | None -> ()
      | Some else_body -> analyze_scope else_body env);
      env
  | SMatch (_, _, cases, _) ->
      List.iter (fun case_clause -> analyze_case case_clause env) cases;
      env
  | SDatatype _ ->
      (* A datatype binds no value name: its own name and its
         constructors' start with an uppercase letter, which no binding
         may. *)
      env
  | SFunctionSig _ ->
      (* A signature says what a `def` in this block is; it binds no
         name of its own and mentions none, so there is nothing here for
         this walk to check. typesystem.ml is what pairs it with its
         definition. *)
      env
  | SFunctionDef (info, name, params, body, _, _, _, implicits, _) ->
      (* The function's own name is bound before its body is walked, so
         a function may call itself; the parameters then bind in the
         body's scope, shadowing anything but a mutable variable. An
         implicit parameter is one of them. *)
      let env = bind env name Function info in
      let body_env =
        List.fold_left
          (fun body_env (Param (pinfo, pname, _, _, _)) ->
            bind body_env pname Parameter pinfo)
          env (params @ implicits)
      in
      analyze_scope body body_env;
      env

(** Checks that every `:=` names a `var`, and that nothing shadows one.
    Raises Analysis_error on the first problem; never rewrites the AST.
    [stmt] -> () *)
let analyze_mutability stmts =
  let env =
    List.fold_left
      (fun env name -> SMap.add name { kind = Builtin; info = None } env)
      SMap.empty Builtin.names
  in
  ignore (analyze_stmts stmts env)

(* --- symbolize ---
   Each node type says what its children are, in the order src/syntax.ml
   declares them, and is numbered after them. The counter is threaded
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
  | EFloat (i, v, s) ->
      let s, counter = assign s counter in
      (EFloat (i, v, s), counter)
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
      let names = List.map fst args in
      let args, counter = map_fold sym_expr counter (arg_exprs args) in
      let args = List.combine names args in
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
  | ELambda (i, params, body, s) ->
      let params, counter = map_fold sym_param counter params in
      let body, counter = sym_expr counter body in
      let s, counter = assign s counter in
      (ELambda (i, params, body, s), counter)
  | ELet (i, bindings, body, s) ->
      let names = List.map fst bindings in
      let values, counter = map_fold sym_expr counter (List.map snd bindings) in
      let body, counter = sym_expr counter body in
      let s, counter = assign s counter in
      (ELet (i, List.combine names values, body, s), counter)
  | EQualified (i, module_name, name, s) ->
      let s, counter = assign s counter in
      (EQualified (i, module_name, name, s), counter)
  | EConstruct (i, module_, name, args, s) ->
      let names = List.map fst args in
      let args, counter = map_fold sym_expr counter (arg_exprs args) in
      let args = List.combine names args in
      let s, counter = assign s counter in
      (EConstruct (i, module_, name, args, s), counter)
  | EField (i, record, name, s) ->
      let record, counter = sym_expr counter record in
      let s, counter = assign s counter in
      (EField (i, record, name, s), counter)

and sym_type counter t =
  match t with
  | TInt (i, s) ->
      let s, counter = assign s counter in
      (TInt (i, s), counter)
  | TFloat (i, s) ->
      let s, counter = assign s counter in
      (TFloat (i, s), counter)
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
  | TFunction (i, params, result, s, tmsym, definition, implicits) ->
      let params, counter = map_fold sym_type counter params in
      let implicits, counter =
        map_fold
          (fun counter (IParam (n, t)) ->
            let t, counter = sym_type counter t in
            (IParam (n, t), counter))
          counter implicits
      in
      let result, counter = sym_type counter result in
      let definition, counter = map_option sym_stmt counter definition in
      let s, counter = assign s counter in
      (TFunction (i, params, result, s, tmsym, definition, implicits), counter)
  | TVar (i, n, s, rigid) ->
      let s, counter = assign s counter in
      (TVar (i, n, s, rigid), counter)
  | TForall (i, vars, body, s) ->
      let body, counter = sym_type counter body in
      let s, counter = assign s counter in
      (TForall (i, vars, body, s), counter)
  | TCon (i, name, args, s) ->
      let args, counter = map_fold sym_type counter args in
      let s, counter = assign s counter in
      (TCon (i, name, args, s), counter)
  | TData (i, d, s) ->
      let s, counter = assign s counter in
      (TData (i, d, s), counter)

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
  | PConstructor (i, module_, name, positional, named, s) ->
      let positional, counter = map_fold sym_pattern counter positional in
      let named, counter =
        map_fold
          (fun counter (n, p) ->
            let p, counter = sym_pattern counter p in
            ((n, p), counter))
          counter named
      in
      let s, counter = assign s counter in
      (PConstructor (i, module_, name, positional, named, s), counter)
  | POr (i, alternatives, s) ->
      let alternatives, counter = map_fold sym_pattern counter alternatives in
      let s, counter = assign s counter in
      (POr (i, alternatives, s), counter)
  | PAs (i, inner, name, s) ->
      let inner, counter = sym_pattern counter inner in
      let s, counter = assign s counter in
      (PAs (i, inner, name, s), counter)

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

and sym_param counter (Param (i, name, type_, default, s)) =
  let type_, counter = map_option sym_type counter type_ in
  let default, counter = map_option sym_expr counter default in
  let s, counter = assign s counter in
  (Param (i, name, type_, default, s), counter)

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

and sym_case counter (MatchCase (i, pattern, guard, body, s)) =
  let pattern, counter = sym_pattern counter pattern in
  let guard, counter = map_option sym_expr counter guard in
  let body, counter = map_fold sym_stmt counter body in
  let s, counter = assign s counter in
  (MatchCase (i, pattern, guard, body, s), counter)

and sym_constructor counter (Constructor (i, name, fields, s)) =
  let fields, counter = map_fold sym_field counter fields in
  let s, counter = assign s counter in
  (Constructor (i, name, fields, s), counter)

and sym_field counter (Field (i, label, type_, default, s)) =
  let type_, counter = sym_type counter type_ in
  let default, counter = map_option sym_expr counter default in
  let s, counter = assign s counter in
  (Field (i, label, type_, default, s), counter)

and sym_stmt counter st =
  match st with
  | SLet (i, target, expr, type_, s, public, implicit) ->
      let target, counter = sym_target counter target in
      let expr, counter = sym_expr counter expr in
      let type_, counter = map_option sym_type counter type_ in
      let s, counter = assign s counter in
      (SLet (i, target, expr, type_, s, public, implicit), counter)
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
  | SLoop (i, target, init, type_, iterate, body, s) ->
      let target, counter = map_option sym_target counter target in
      let init, counter = map_option sym_expr counter init in
      let type_, counter = map_option sym_type counter type_ in
      let iterate, counter = map_option sym_loop_iter counter iterate in
      let body, counter = map_fold sym_stmt counter body in
      let s, counter = assign s counter in
      (SLoop (i, target, init, type_, iterate, body, s), counter)
  | SBreak (i, s) ->
      let s, counter = assign s counter in
      (SBreak (i, s), counter)
  | SContinue (i, s) ->
      let s, counter = assign s counter in
      (SContinue (i, s), counter)
  | SIf (i, cond, then_body, else_body, s) ->
      let cond, counter = sym_expr counter cond in
      let then_body, counter = map_fold sym_stmt counter then_body in
      let else_body, counter =
        map_option (fun counter body -> map_fold sym_stmt counter body) counter
          else_body
      in
      let s, counter = assign s counter in
      (SIf (i, cond, then_body, else_body, s), counter)
  | SFunctionDef (i, name, params, body, return_type, s, public, implicits, implicit)
    ->
      let params, counter = map_fold sym_param counter params in
      let implicits, counter = map_fold sym_param counter implicits in
      let body, counter = map_fold sym_stmt counter body in
      let return_type, counter = map_option sym_type counter return_type in
      let s, counter = assign s counter in
      ( SFunctionDef
          (i, name, params, body, return_type, s, public, implicits, implicit),
        counter )
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
  | SDatatype (i, name, params, constructors, s, public) ->
      let constructors, counter = map_fold sym_constructor counter constructors in
      let s, counter = assign s counter in
      (SDatatype (i, name, params, constructors, s, public), counter)

(* --- the largest symbol already handed out ---
   A tree that has been symbolized once keeps the numbers it has, and
   new ones continue past the highest, so running symbolize again is
   safe. *)

let high_list f items = List.fold_left (fun acc x -> max acc (f x)) 0 items

let high_option f item = match item with None -> 0 | Some x -> f x

let rec high_expr e =
  let children =
    match e with
    | EInt _ | EFloat _ | EString _ | EBool _ | EVar _ | EQualified _ -> 0
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
    | ECall (_, f, args, _) ->
        max (high_expr f) (high_list high_expr (arg_exprs args))
    | EList (_, es, _) | ETuple (_, es, _) -> high_list high_expr es
    | EIf (_, c, t, e2, _) ->
        max (high_expr c) (max (high_expr t) (high_expr e2))
    | EListComp (_, e2, clauses, _) ->
        max (high_expr e2) (high_list high_comp_clause clauses)
    | ELambda (_, params, body, _) ->
        max (high_list high_param params) (high_expr body)
    | ELet (_, bindings, body, _) ->
        max (high_list high_expr (List.map snd bindings)) (high_expr body)
    | EConstruct (_, _, _, args, _) -> high_list high_expr (arg_exprs args)
    | EField (_, record, _, _) -> high_expr record
  in
  max (expr_sym e) children

and high_type t =
  let children =
    match t with
    | TInt _ | TFloat _ | TString _ | TBool _ | TUnknown _ | TBuiltin _
    | TVar _ ->
        0
    | TList (_, element, _) -> high_type element
    | TTuple (_, elements, _) -> high_list high_type elements
    | TFunction (_, params, result, _, _, definition, _) ->
        max
          (max (high_list high_type params) (high_type result))
          (high_option high_stmt definition)
    | TForall (_, _, body, _) -> high_type body
    | TCon (_, _, args, _) -> high_list high_type args
    | TData _ -> 0
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
    | PConstructor (_, _, _, positional, named, _) ->
        high_list high_pattern (positional @ List.map snd named)
    | POr (_, alternatives, _) -> high_list high_pattern alternatives
    | PAs (_, inner, _, _) -> high_pattern inner
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

and high_param (Param (_, _, type_, default, s)) =
  max s (max (high_option high_type type_) (high_option high_expr default))

and high_loop_iter it =
  match it with
  | ForIn (_, _, sequence, s) -> max s (high_expr sequence)
  | WhileTest (_, condition, s) -> max s (high_expr condition)

and high_case (MatchCase (_, pattern, guard, body, s)) =
  max s
    (max
       (max (high_pattern pattern) (high_option high_expr guard))
       (high_list high_stmt body))

and high_constructor (Constructor (_, _, fields, s)) =
  max s
    (high_list
       (fun (Field (_, _, type_, default, fs)) ->
         max fs (max (high_type type_) (high_option high_expr default)))
       fields)

and high_stmt st =
  let children =
    match st with
    | SLet (_, target, expr, type_, _, _, _) ->
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
    | SLoop (_, target, init, type_, iterate, body, _) ->
        List.fold_left max 0
          [
            high_option high_target target;
            high_option high_expr init;
            high_option high_type type_;
            high_option high_loop_iter iterate;
            high_list high_stmt body;
          ]
    | SBreak (_, _) | SContinue (_, _) -> 0
    | SIf (_, cond, then_body, else_body, _) ->
        List.fold_left max 0
          [
            high_expr cond;
            high_list high_stmt then_body;
            high_option (high_list high_stmt) else_body;
          ]
    | SFunctionDef (_, _, params, body, return_type, _, _, implicits, _) ->
        List.fold_left max 0
          [
            high_list high_param params;
            high_list high_param implicits;
            high_list high_stmt body;
            high_option high_type return_type;
          ]
    | SFunctionSig (_, _, type_, _, _) -> high_type type_
    | SMatch (_, subject, cases, _) ->
        max (high_expr subject) (high_list high_case cases)
    | SImport _ -> 0
    | SDatatype (_, _, _, constructors, _, _) ->
        high_list high_constructor constructors
  in
  max (stmt_sym st) children

(** The largest sym anywhere in a program, or 0 if none is symbolized.
    [stmt] -> int *)
let highest_sym stmts = high_list high_stmt stmts

(** Rebuilds stmts so every node has a unique sym, numbered post-order
    starting after `start` (0 means "not symbolized"). A node that
    already has a symbol keeps it; safe to run more than once. A program
    of several modules passes each module the highest symbol the one
    before it reached, so no two nodes in it share a symbol -- which is
    what lets one call-free table and one type table span the whole
    program. int -> [stmt] -> [stmt] *)
let symbolize ?(start = 0) stmts =
  let stmts, _ =
    map_fold sym_stmt (max (highest_sym stmts) start + 1) stmts
  in
  stmts

(* --- signatures --- *)

(** A definition carrying the types its signature gave it. The
    quantifier is dropped: the parts written on a header are quantified
    again wherever they are read. Only a well-formed pairing is folded;
    a signature of the wrong arity is left for typesystem.ml to refuse
    in its own words. stmt -> typ -> stmt *)
let annotated definition signature =
  let written =
    match signature with TForall (_, _, body, _) -> body | t -> t
  in
  match (written, definition) with
  | ( TFunction (_, written_params, result, _, _, _, _),
      SFunctionDef (info, name, params, body, _, sym, public, implicits, implicit)
    )
    when List.length written_params = List.length params ->
      SFunctionDef
        ( info,
          name,
          List.map2
            (fun (Param (pinfo, pname, _, default, psym)) t ->
              Param (pinfo, pname, Some t, default, psym))
            params written_params,
          body,
          Some result,
          sym,
          public,
          implicits,
          implicit )
  | _ -> definition

(** stmts with every `def name : type` line folded into the definition
    it describes and then removed, wherever one is written.

    A signature is another way of writing the annotations a `def` header
    could have carried, so moving them onto the header leaves one shape
    for every later stage to read: a backend that refuses a type it
    cannot represent, or infers from the ones it is given, needs to know
    nothing about signatures at all. A signature belongs to a statement
    sequence, so this recurses through the statements that hold one and
    no further. [stmt] -> [stmt] *)
let rec apply_signatures stmts =
  (* A dict in the Python, so the *last* signature of a name is the one
     that counts; reversing makes `assoc` answer with that one. *)
  let signatures =
    List.rev
      (List.filter_map
         (function
           | SFunctionSig (_, name, type_, _, public) -> Some (name, (type_, public))
           | _ -> None)
         stmts)
  in
  let fold stmt =
    match stmt with
    | SFunctionSig _ -> None
    | SFunctionDef (_, name, _, _, _, _, public, _, _) -> (
        match List.assoc_opt name signatures with
        | None -> Some (apply_in_stmt stmt)
        | Some (type_, signature_public) ->
            let stmt = annotated stmt type_ in
            (* `public` on either line exports the definition, so the
               one on the signature comes with the types. *)
            let stmt =
              match stmt with
              | SFunctionDef
                  ( info,
                    name,
                    params,
                    body,
                    return_type,
                    sym,
                    _,
                    implicits,
                    implicit )
                when signature_public && not public ->
                  SFunctionDef
                    ( info,
                      name,
                      params,
                      body,
                      return_type,
                      sym,
                      true,
                      implicits,
                      implicit )
              | stmt -> stmt
            in
            Some (apply_in_stmt stmt))
    | stmt -> Some (apply_in_stmt stmt)
  in
  List.filter_map fold stmts

(** One statement with every signature in the blocks inside it folded
    onto its definition. stmt -> stmt *)
and apply_in_stmt stmt =
  match stmt with
  | SLetStmt (info, target, inner, annotation, sym, public) ->
      SLetStmt (info, target, apply_in_stmt inner, annotation, sym, public)
  | SReturnStmt (info, inner, sym) ->
      SReturnStmt (info, apply_in_stmt inner, sym)
  | SLoop (info, target, init, annotation, iterate, body, sym) ->
      SLoop (info, target, init, annotation, iterate, apply_signatures body, sym)
  | SIf (info, condition, then_body, else_body, sym) ->
      SIf
        ( info,
          condition,
          apply_signatures then_body,
          Option.map apply_signatures else_body,
          sym )
  | SFunctionDef (info, name, params, body, return_type, sym, public, implicits, implicit)
    ->
      SFunctionDef
        ( info,
          name,
          params,
          apply_signatures body,
          return_type,
          sym,
          public,
          implicits,
          implicit )
  | SMatch (info, subject, cases, sym) ->
      SMatch
        ( info,
          subject,
          List.map
            (fun (MatchCase (info, pattern, guard, body, sym)) ->
              MatchCase (info, pattern, guard, apply_signatures body, sym))
            cases,
          sym )
  | stmt -> stmt

(* --- effects ---

   Says which expressions can produce output, since that is the only
   thing a host language's unspecified evaluation order can make
   observably different from Pyking's left-to-right. Deliberately
   conservative: overestimating who prints costs a temporary, and
   underestimating prints in the wrong order. Used by the backends whose
   host does not fix the order (docs/target_ocaml.md and
   docs/target_c.md, "Evaluation order"). *)

(** Every def in a program, at any depth, by name. A name defined twice
    at different depths answers with the last one walked, as the
    Python's dict does. [stmt] -> stmt SMap.t *)
let all_functions stmts =
  Walk.fold_stmts
    (fun functions node ->
      match node with
      | Walk.NStmt (SFunctionDef (_, name, _, _, _, _, _, _, _) as definition) ->
          SMap.add name definition functions
      | _ -> functions)
    SMap.empty stmts

(** Which calls in a program can end up printing. A call whose target is
    not a known def is treated as printing if any function in the
    program does, and a call into another module always is: this walk
    sees one module. *)
type effects = {
  functions : stmt SMap.t;
  printing : SSet.t;
  unknown_prints : bool;
}

(** Whether one call may print, given what is known so far.
    effects -> expr -> bool *)
let call_prints effects call =
  match call with
  | ECall (_, func, _, _) -> (
      match func with
      | EVar (_, name, _) ->
          if Builtin.crosses_host name then true
          else if List.mem name Builtin.names then false
          else if SMap.mem name effects.functions then
            SSet.mem name effects.printing
          else effects.unknown_prints
      | EQualified _ ->
          (* Another module's, and this walk sees only this one -- so
             the conservative answer, which is what this gives wherever
             it cannot see a body. *)
          true
      | _ -> effects.unknown_prints)
  | _ -> false

(** Whether a subtree holds a call that may print.
    effects -> Walk.node -> bool *)
let subtree_prints effects node =
  (* The walk stops at a lambda: building a closure prints nothing,
     whatever its body holds, and the call that runs that body is an
     ordinary call wherever it is written. *)
  let rec go node =
    match node with
    | Walk.NExpr (ELambda _) -> false
    | Walk.NExpr (ECall _ as call) when call_prints effects call -> true
    | node -> List.exists go (Walk.children node)
  in
  go node

(** Which functions in a program can print, by a fixed-point walk of the
    call graph. [stmt] -> effects *)
let effects stmts =
  let rec settle effects =
    let printing, changed =
      SMap.fold
        (fun name definition (printing, changed) ->
          if
            (not (SSet.mem name printing))
            && subtree_prints { effects with printing } (Walk.NStmt definition)
          then (SSet.add name printing, true)
          else (printing, changed))
        effects.functions
        (effects.printing, false)
    in
    let effects = { effects with printing } in
    if (not (SSet.is_empty printing)) && not effects.unknown_prints then
      settle { effects with unknown_prints = true }
    else if changed then settle effects
    else effects
  in
  settle
    {
      functions = all_functions stmts;
      printing = SSet.empty;
      unknown_prints = false;
    }

(** Whether evaluating an expression can produce output.
    effects -> expr -> bool *)
let may_print effects expr = subtree_prints effects (Walk.NExpr expr)
