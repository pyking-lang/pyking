(** Overloading and implicit arguments, removed after the type checker
    and before anything else reads the program. A qualified name is
    renamed to a plain one, the call the checker resolved names that
    definition, and every implicit parameter becomes an ordinary
    argument -- built from a lambda where the value filling it has
    implicit parameters of its own. What comes out is ordinary Pyking,
    so no backend and not the interpreter knows either feature exists.
    See docs/implicits.md.

    Data structures:
      work -- the symbols handed out and the types recorded for them.

    Functions:
      program qmap tmap stmts -- rewrites one module.
      generated_name name -- whether the pass made this name up. *)

open Syntax
open Typesystem

module SSet = Set.Make (String)

(* What every generated lambda parameter is built around. *)
let marker = "__implicit__"

(** Whether this name is one the pass made up rather than one the
    program wrote. String -> Bool *)
let generated_name name =
  let width = String.length marker in
  let rec at i =
    if i + width > String.length name then false
    else if String.sub name i width = marker then true
    else at (i + 1)
  in
  at 0

(** The symbols handed out for the nodes this pass builds, and the types
    recorded for them. The checker does not run again, so every node
    built here is given its type from what `qmap` carried. *)
type work = { next : int; tmap : typ IntMap.t }

(** A symbol nothing else has, and the work that handed it out.
    work -> (int, work) *)
let symbol work = (work.next, { work with next = work.next + 1 })

(** work with a type recorded for a symbol. work -> int -> typ -> work *)
let typed work sym type_ = { work with tmap = IntMap.add sym type_ work.tmap }

(** A symbol of its own, with its type recorded. work -> typ -> (int, work) *)
let node work type_ =
  let sym, work = symbol work in
  (sym, typed work sym type_)

(* --- names --- *)

(** The name a qualified one compiles to. A program that binds both is
    refused: the two would be one name in the output.
    string -> string *)
let plain = Names.renamed

(** Refuses a program that binds both `q::b` and the plain name it
    compiles to. [stmt] -> () *)
let check_no_rename_clash stmts =
  let bound =
    Walk.fold_stmts
      (fun found node ->
        match node with
        | Walk.NStmt (SFunctionDef (info, name, _, _, _, _, _, _, _))
        | Walk.NStmt (SFunctionSig (info, name, _, _, _)) ->
            (name, info) :: found
        | Walk.NTarget (TargetName (info, name, _)) -> (name, info) :: found
        | Walk.NStmt (SVar (info, name, _, _)) -> (name, info) :: found
        | _ -> found)
      [] stmts
  in
  let plain_names =
    List.fold_left
      (fun found (name, _) ->
        if Names.is_qualified name then found else SSet.add name found)
      SSet.empty bound
  in
  List.iter
    (fun (name, info) ->
      if Names.is_qualified name && SSet.mem (plain name) plain_names then
        raise
          (Analyses.Analysis_error
             ( info,
               Printf.sprintf
                 "'%s' and '%s' cannot both be bound in this program: a \
                  qualified name compiles to the plain one, and the two \
                  would be one name"
                 name (plain name) )))
    bound

(* --- the expressions this pass builds --- *)

(** A name as an expression: `EQualified` where it came through a module,
    `EVar` otherwise, with its type recorded.
    info -> work -> string -> typ -> (expr, work) *)
let name_expr info work name type_ =
  let sym, work = node work type_ in
  match String.rindex_opt name '.' with
  | Some i ->
      let module_ = String.sub name 0 i in
      let field = String.sub name (i + 1) (String.length name - i - 1) in
      (EQualified (info, module_, plain field, sym), work)
  | None -> (EVar (info, plain name, sym), work)

(* The type a definition has once its implicit parameters are ordinary
   ones, which is what every later stage sees of it. *)
let folded = Typesystem.without_implicits

(** One resolved implicit argument as an expression.
    info -> work -> argument -> (expr, work) *)
let rec argument info work one =
  match one with
  | Direct (name, type_) -> name_expr info work name type_
  | Wrapped (name, type_, passed, inner) ->
      (* What is wanted here and what the value is differ in their
         implicit parameters, so a lambda stands between them: it takes
         what is wanted, hands on the first `passed` of them, and adds
         whatever the value asks for beyond that (docs/implicits.md,
         "The dictionary"). *)
      let params, result =
        match type_ with
        | TFunction (_, params, result, _, _, _, implicits) ->
            (params @ List.map (fun (IParam (_, t)) -> t) implicits, result)
        | other -> ([], other)
      in
      let named, work =
        List.fold_left
          (fun (named, work) param_type ->
            let sym, work = node work param_type in
            let name = Printf.sprintf "%s%d" marker (List.length named + 1) in
            (named @ [ (name, param_type, sym) ], work))
          ([], work) params
      in
      let handed, work =
        List.fold_left
          (fun (handed, work) (name, param_type, _) ->
            let sym, work = node work param_type in
            (handed @ [ EVar (info, name, sym) ], work))
          ([], work)
          (List.filteri (fun at _ -> at < passed) named)
      in
      let supplied, work =
        List.fold_left
          (fun (supplied, work) one ->
            let e, work = argument info work one in
            (supplied @ [ e ], work))
          ([], work) inner
      in
      let callee_type =
        TFunction
          ( info,
            List.filteri (fun at _ -> at < passed) params
            @ List.map (fun e -> expression_type work e) supplied,
            result,
            0,
            0,
            None,
            [] )
      in
      let callee, work = name_expr info work name callee_type in
      let call_sym, work = node work result in
      let call =
        ECall
          ( info,
            callee,
            List.map (fun e -> (None, e)) (handed @ supplied),
            call_sym )
      in
      let lambda_sym, work = node work type_ in
      ( ELambda
          ( info,
            List.map
              (fun (name, param_type, sym) ->
                Param (info, name, Some param_type, None, sym))
              named,
            call,
            lambda_sym ),
        work )

(** The type this pass recorded for an expression it built.
    work -> expr -> typ *)
and expression_type work e =
  match IntMap.find_opt (expr_sym e) work.tmap with
  | Some type_ -> type_
  | None -> TUnknown (expr_info e, 0)

(* --- the walk --- *)

(** One expression with every name renamed and every resolved call
    filled in. expr -> resolution IntMap.t -> work -> (expr, work) *)
let rec expression e qmap work =
  match IntMap.find_opt (expr_sym e) qmap with
  (* An argument whose implicit parameters are not the ones wanted
     stands behind a lambda that makes up the difference -- supplying
     what it asks for, or taking what it does not want and dropping it
     (docs/implicits.md). A call's own entry is a `Call` and is dealt
     with below, where its arguments are. *)
  | Some (Adapted (type_, passed, supplied)) ->
      let inner, work = expression_body e qmap work in
      adapting (expr_info e) work inner type_ passed supplied
  | _ -> (
      let made, work = expression_body e qmap work in
      (* An object seen as a supertype where it stands carries that
         (PYKING.md, "Classes and interfaces"): the upcast the checker
         found, recorded under the symbol negated. *)
      match IntMap.find_opt (-expr_sym e) qmap with
      | Some (Upcast target) ->
          let sym, work = node work target in
          (EUpcast (expr_info e, made, target, sym), work)
      | _ -> (made, work))

(** A copy of a method parameter's default, with symbols of its own: a
    literal, or the call of the def desugar_args made of it.
    expr -> work -> (expr, work) *)
and copied_default e work =
  let again old work = node work (expression_type work old) in
  match e with
  | EInt (i, v, _) -> let s, work = again e work in (EInt (i, v, s), work)
  | EFloat (i, v, _) -> let s, work = again e work in (EFloat (i, v, s), work)
  | EString (i, v, _) -> let s, work = again e work in (EString (i, v, s), work)
  | EChar (i, v, _) -> let s, work = again e work in (EChar (i, v, s), work)
  | EBool (i, v, _) -> let s, work = again e work in (EBool (i, v, s), work)
  | ENeg (i, inner, _) ->
      let inner, work = copied_default inner work in
      let s, work = again e work in
      (ENeg (i, inner, s), work)
  | ECall (i, (EVar (vi, name, _) as callee), [], _) ->
      let vs, work = again callee work in
      let s, work = again e work in
      (ECall (i, EVar (vi, plain name, vs), [], s), work)
  | _ -> (e, work)

(** A method call's arguments, every one in its parameter's position and
    each one left out filled with its default. Where named ones are not
    written in that order, the receiver and the arguments are worked out
    first, in the order written, into temporaries the call then reads.
    info -> expr -> [(String?, expr)] -> [(string * expr?)] -> work ->
    ((string * typ * expr) list * expr * [expr] * work) *)
and placed_arguments info receiver written params work =
  let positional = List.filter (fun (n, _) -> n = None) written in
  let at name = let rec find k = function [] -> -1 | (p, _) :: rest -> if p = name then k else find (k + 1) rest in find 0 params in
  let order =
    List.mapi (fun k (n, _) -> match n with None -> k | Some n -> at n) written
  in
  let in_order = List.sort compare order = order in
  let temps, receiver, work =
    if in_order then ([], receiver, work)
    else
      let t = expression_type work receiver in
      let vs, work = node work t in
      ([ ("self__arg", t, receiver) ], EVar (info, "self__arg", vs), work)
  in
  let temps, given, work =
    if in_order then (temps, List.map (fun (n, e) -> (n, e)) written, work)
    else
      List.fold_left
        (fun (temps, given, work) (n, e) ->
          let k = match n with Some n -> at n | None -> List.length given in
          let pname = fst (List.nth params k) in
          let t = expression_type work e in
          let temp = pname ^ "__arg" in
          let vs, work = node work t in
          (temps @ [ (temp, t, e) ], given @ [ (n, EVar (info, temp, vs)) ], work))
        (temps, [], work) written
  in
  let positional_count = List.length positional in
  let args, work =
    List.fold_left
      (fun (args, work) (k, (pname, default)) ->
        if k < positional_count then (args @ [ snd (List.nth given k) ], work)
        else
          match List.assoc_opt (Some pname) given with
          | Some e -> (args @ [ e ], work)
          | None -> (
              match default with
              | Some d ->
                  let d, work = copied_default d work in
                  (args @ [ d ], work)
              | None -> (args, work)))
      ([], work)
      (List.mapi (fun k p -> (k, p)) params)
  in
  (temps, receiver, args, work)

(** `let name = value in body` for each temporary, outermost first.
    info -> (string * typ * expr) list -> expr -> work -> (expr, work) *)
and let_temps info temps body work =
  List.fold_right
    (fun (name, t, value) (body, work) ->
      let ts, work = node work t in
      let s, work = node work (expression_type work body) in
      (ELet (info, TargetName (info, name, ts), None, value, body, s), work))
    temps (body, work)

(** The lambda that stands in front of an argument: it takes what the
    parameter wants, hands the first `passed` of them to `inner`, and
    adds the implicit arguments resolved for it.
    info -> work -> expr -> typ -> int -> [argument] -> (expr, work) *)
and adapting info work inner type_ passed supplied =
  let params, result =
    match type_ with
    | TFunction (_, params, result, _, _, _, implicits) ->
        (params @ List.map (fun (IParam (_, t)) -> t) implicits, result)
    | other -> ([], other)
  in
  let named, work =
    List.fold_left
      (fun (named, work) param_type ->
        let sym, work = node work param_type in
        let name = Printf.sprintf "%s%d" marker (List.length named + 1) in
        (named @ [ (name, param_type, sym) ], work))
      ([], work) params
  in
  let handed, work =
    List.fold_left
      (fun (handed, work) (name, param_type, _) ->
        let sym, work = node work param_type in
        (handed @ [ EVar (info, name, sym) ], work))
      ([], work)
      (List.filteri (fun at _ -> at < passed) named)
  in
  let arguments, work =
    List.fold_left
      (fun (out, work) one ->
        let e, work = argument info work one in
        (out @ [ e ], work))
      ([], work) supplied
  in
  let call_sym, work = node work result in
  let call =
    ECall
      ( info,
        inner,
        List.map (fun e -> (None, e)) (handed @ arguments),
        call_sym )
  in
  let lambda_sym, work = node work type_ in
  ( ELambda
      ( info,
        List.map
          (fun (name, param_type, sym) ->
            Param (info, name, Some param_type, None, sym))
          named,
        call,
        lambda_sym ),
    work )

(** One expression the checker recorded no adaptation for.
    expr -> resolution IntMap.t -> work -> (expr, work) *)
and expression_body e qmap work =
  let go e work = expression e qmap work in
  let each es work =
    List.fold_left
      (fun (out, work) one ->
        let one, work = go one work in
        (out @ [ one ], work))
      ([], work) es
  in
  match e with
  | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ -> (e, work)
  | EVar (i, name, s) -> (EVar (i, plain name, s), work)
  | EQualified (i, module_, name, s) ->
      (EQualified (i, module_, plain name, s), work)
  | EAdd (i, l, r, s) -> (
      let l, work = go l work in
      let r, work = go r work in
      (* `+` on two strings or two lists joins them: the checker said
         which, and every backend has always compiled a join as its own
         node. *)
      match IntMap.find_opt s work.tmap with
      | Some (TString _ | TList _) -> (EConcat (i, l, r, s), work)
      | _ -> (EAdd (i, l, r, s), work))
  | ESub (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (ESub (i, l, r, s), work)
  | EMul (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (EMul (i, l, r, s), work)
  | EDiv (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (EDiv (i, l, r, s), work)
  | EConcat (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (EConcat (i, l, r, s), work)
  | ELessThan (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (ELessThan (i, l, r, s), work)
  | ELessThanEq (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (ELessThanEq (i, l, r, s), work)
  | EGreatThan (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (EGreatThan (i, l, r, s), work)
  | EGreatThanEq (i, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (EGreatThanEq (i, l, r, s), work)
  | EEq (i, l, r, s) -> (
      let l, work = go l work in
      let r, work = go r work in
      match IntMap.find_opt s qmap with
      | Some (Object_eq _) -> (EMethod (i, l, "eq", [ (None, r) ], s), work)
      | _ -> (EEq (i, l, r, s), work))
  | ENeg (i, operand, s) ->
      let operand, work = go operand work in
      (ENeg (i, operand, s), work)
  | EBinary (i, BNeq, l, r, s) when (match IntMap.find_opt s qmap with Some (Object_eq _) -> true | _ -> false) ->
      let l, work = go l work in
      let r, work = go r work in
      let call_sym, work = node work (TBool (i, 0)) in
      (EUnary (i, UNot Word, EMethod (i, l, "eq", [ (None, r) ], call_sym), s), work)
  | EBinary (i, op, l, r, s) ->
      let l, work = go l work in
      let r, work = go r work in
      (* `and` and `or` on two Ints are bitwise, and `xor` on two Bools
         is logical; the spelling stays, so the program still prints as
         it was written. *)
      let op =
        match (op, IntMap.find_opt s work.tmap) with
        | BAnd Word, Some (TInt _) -> BBitAnd Word
        | BOr Word, Some (TInt _) -> BBitOr Word
        | BXor, Some (TBool _) -> BBoolXor
        | _ -> op
      in
      (EBinary (i, op, l, r, s), work)
  | EUnary (i, op, operand, s) ->
      let operand, work = go operand work in
      let op =
        match (op, IntMap.find_opt s work.tmap) with
        | UNot Word, Some (TInt _) -> UBitNot Word
        | _ -> op
      in
      (EUnary (i, op, operand, s), work)
  | EIndex (i, l, index, s) ->
      let l, work = go l work in
      let index, work = go index work in
      (EIndex (i, l, index, s), work)
  | EAddr (i, e, s) ->
      let e, work = go e work in
      (EAddr (i, e, s), work)
  | EDeref (i, e, s) ->
      let e, work = go e work in
      (EDeref (i, e, s), work)
  | ESlice (i, l, a, b, s) ->
      let l, work = go l work in
      let bound b work = match b with Some e -> let e, work = go e work in (Some e, work) | None -> (None, work) in
      let a, work = bound a work in
      let b, work = bound b work in
      (ESlice (i, l, a, b, s), work)
  | EList (i, elements, s) ->
      let elements, work = each elements work in
      (EList (i, elements, s), work)
  | ETuple (i, elements, s) ->
      let elements, work = each elements work in
      (ETuple (i, elements, s), work)
  | EIf (i, c, t, f, s) ->
      let c, work = go c work in
      let t, work = go t work in
      let f, work = go f work in
      (EIf (i, c, t, f, s), work)
  | EListComp (i, element, clauses, s) ->
      let clauses, work =
        List.fold_left
          (fun (out, work) clause ->
            match clause with
            | CompFor (ci, pattern, sequence, cs) ->
                let sequence, work = go sequence work in
                (out @ [ CompFor (ci, pattern, sequence, cs) ], work)
            | CompIf (ci, condition, cs) ->
                let condition, work = go condition work in
                (out @ [ CompIf (ci, condition, cs) ], work))
          ([], work) clauses
      in
      let element, work = go element work in
      (EListComp (i, element, clauses, s), work)
  | ELambda (i, params, body, s) ->
      let body, work = go body work in
      (ELambda (i, params, body, s), work)
  | ELet (i, target, type_, value, body, s) ->
      let value, work = go value work in
      let body, work = go body work in
      (ELet (i, target, type_, value, body, s), work)
  | EConstruct (i, module_, name, args, s) ->
      let names = List.map fst args in
      let given, work = each (arg_exprs args) work in
      (EConstruct (i, module_, name, List.combine names given, s), work)
  | EField (i, record, name, s) -> (
      let record, work = go record work in
      match IntMap.find_opt s qmap with
      | Some (Method_value _) -> (
          (* `obj.m` as a value: the object worked out once, and a lambda
             calling the method on it. *)
          match IntMap.find_opt s work.tmap with
          | Some (TFunction (_, params, result, _, _, _, _) as ft) ->
              let rt = expression_type work record in
              let rs, work = node work rt in
              let receiver = EVar (i, "method__self", rs) in
              let named, work =
                List.fold_left
                  (fun (out, work) t ->
                    let ps, work = node work t in
                    (out @ [ (Printf.sprintf "method__arg%d" (List.length out + 1), t, ps) ], work))
                  ([], work) params
              in
              let uses, work =
                List.fold_left
                  (fun (out, work) (n, t, _) ->
                    let us, work = node work t in
                    (out @ [ (None, EVar (i, n, us)) ], work))
                  ([], work) named
              in
              let call_sym, work = node work result in
              let lambda_sym, work = node work ft in
              let lambda =
                ELambda
                  ( i,
                    List.map (fun (n, t, ps) -> Param (i, n, Some t, None, ps)) named,
                    EMethod (i, receiver, name, uses, call_sym),
                    lambda_sym )
              in
              let_temps i [ ("method__self", rt, record) ] lambda work
          | _ -> (EField (i, record, name, s), work))
      | _ -> (EField (i, record, name, s), work))
  | EMethod (i, obj, name, args, s) ->
      let obj, work = go obj work in
      let names = List.map fst args in
      let given, work = each (arg_exprs args) work in
      (EMethod (i, obj, name, List.combine names given, s), work)
  | EUpcast (i, inner, t, s) ->
      let inner, work = go inner work in
      (EUpcast (i, inner, t, s), work)
  | ESuper (i, owner, name, args, s) -> (
      let names = List.map fst args in
      let given, work = each (arg_exprs args) work in
      let written = List.combine names given in
      match IntMap.find_opt s qmap with
      | Some (Super_owner (owner, params)) ->
          let self_type = expression_type work (EVar (i, "self", 0)) in
          let temps, _, args, work = placed_arguments i (EVar (i, "self", 0)) written params work in
          let temps = List.filter (fun (n, _, _) -> n <> "self__arg") temps in
          ignore self_type;
          let_temps i temps (ESuper (i, owner, name, List.map (fun e -> (None, e)) args, s)) work
      | _ -> (ESuper (i, owner, name, written, s), work))
  | ECall (i, (EField (_, obj, name, _) as callee), args, s)
    when (match IntMap.find_opt s qmap with Some (Method_call _) -> true | _ -> false) ->
      (* A method call: every argument in place, defaults filled in. *)
      ignore callee;
      let params = match IntMap.find_opt s qmap with Some (Method_call (_, ps)) -> ps | _ -> [] in
      let obj, work = go obj work in
      let names = List.map fst args in
      let given, work = each (arg_exprs args) work in
      let temps, receiver, args, work = placed_arguments i obj (List.combine names given) params work in
      let_temps i temps (EMethod (i, receiver, name, List.map (fun e -> (None, e)) args, s)) work
  | ECall (i, func, args, s) -> (
      let names = List.map fst args in
      let given, work = each (arg_exprs args) work in
      match IntMap.find_opt s qmap with
      | Some (Call (target, appended)) ->
          (* The checker settled what this call means: the name overload
             resolution chose for it, and one argument per implicit
             parameter (docs/implicits.md). *)
          let func, work =
            match target with
            | None -> go func work
            | Some (name, type_) ->
                let sym = expr_sym func in
                let work = typed work sym (folded type_) in
                let renamed =
                  match String.rindex_opt name '.' with
                  | Some at ->
                      let module_ = String.sub name 0 at in
                      let field =
                        String.sub name (at + 1) (String.length name - at - 1)
                      in
                      EQualified (expr_info func, module_, plain field, sym)
                  | None -> EVar (expr_info func, plain name, sym)
                in
                (renamed, work)
          in
          let supplied, work =
            List.fold_left
              (fun (out, work) one ->
                let e, work = argument i work one in
                (out @ [ e ], work))
              ([], work) appended
          in
          ( ECall
              ( i,
                func,
                List.combine names given
                @ List.map (fun e -> (None, e)) supplied,
                s ),
            work )
      | _ ->
          let func, work = go func work in
          (ECall (i, func, List.combine names given, s), work))

(** One parameter with its own expressions rewritten.
    param -> resolution IntMap.t -> work -> (param, work) *)
and parameter (Param (i, name, type_, default, s)) qmap work =
  match default with
  | None -> (Param (i, name, type_, None, s), work)
  | Some e ->
      let e, work = expression e qmap work in
      (Param (i, name, type_, Some e, s), work)

(** One statement, with every qualified name renamed, every implicit
    parameter made ordinary and every resolved call filled in.
    stmt -> resolution IntMap.t -> work -> (stmt, work) *)
and statement s qmap work =
  let go e work = expression e qmap work in
  let jump_value value work =
    match value with
    | None -> (None, work)
    | Some e ->
        let e, work = go e work in
        (Some e, work)
  in
  let block stmts work = statements stmts qmap work in
  match s with
  | SLet (i, target, e, type_, sym, public, _) ->
      let e, work = go e work in
      (SLet (i, target, e, type_, sym, public, false), work)
  | SLetStmt (i, target, inner, type_, sym, public) ->
      let inner, work = statement inner qmap work in
      (SLetStmt (i, target, inner, type_, sym, public), work)
  | SVar (i, name, e, sym) ->
      let e, work = go e work in
      (SVar (i, name, e, sym), work)
  | SMutateTuple _ -> after_desugar "elaborate"
  | SSetIndex (i, owner, index, value, sym) ->
      let owner, work = go owner work in
      let index, work = go index work in
      let value, work = go value work in
      (SSetIndex (i, owner, index, value, sym), work)
  | SSetField (i, owner, field, value, sym) ->
      let owner, work = go owner work in
      let value, work = go value work in
      (SSetField (i, owner, field, value, sym), work)
  | SSetDeref (i, pointer, value, sym) ->
      let pointer, work = go pointer work in
      let value, work = go value work in
      (SSetDeref (i, pointer, value, sym), work)
  | SMutate (i, name, e, sym) ->
      let e, work = go e work in
      (SMutate (i, name, e, sym), work)
  | SReturn (i, e, sym) ->
      let e, work = go e work in
      (SReturn (i, e, sym), work)
  | SReturnStmt (i, inner, sym) ->
      let inner, work = statement inner qmap work in
      (SReturnStmt (i, inner, sym), work)
  | SExprStmt (i, e, sym) ->
      let e, work = go e work in
      (SExprStmt (i, e, sym), work)
  | SBreak (i, value, sym) ->
      let value, work = jump_value value work in
      (SBreak (i, value, sym), work)
  | SContinue (i, value, sym) ->
      let value, work = jump_value value work in
      (SContinue (i, value, sym), work)
  | SDatatype _ -> (s, work)
  | SClass (i, c, sym) ->
      let one_field (MemberField (fi, n, t, v, var, private_, fs)) work =
        match v with
        | None -> (MemberField (fi, n, t, None, var, private_, fs), work)
        | Some e ->
            let e, work = go e work in
            (MemberField (fi, n, t, Some e, var, private_, fs), work)
      in
      let fields work list =
        List.fold_left
          (fun (out, work) f ->
            let f, work = one_field f work in
            (out @ [ f ], work))
          ([], work) list
      in
      let header, work = fields work c.c_header in
      let body_fields, work = fields work c.c_fields in
      let extends, work =
        match c.c_extends with
        | None -> (None, work)
        | Some (ClassRef (ri, m, n, ts, args, rs)) ->
            let names = List.map fst args in
            let given, work =
              List.fold_left
                (fun (out, work) e ->
                  let e, work = go e work in
                  (out @ [ e ], work))
                ([], work) (arg_exprs args)
            in
            (Some (ClassRef (ri, m, n, ts, List.combine names given, rs)), work)
      in
      let methods, work =
        List.fold_left
          (fun (out, work) (MethodDecl (mi, n, params, ret, body, override, private_, ms)) ->
            let params, work =
              List.fold_left
                (fun (out, work) param ->
                  let param, work = parameter param qmap work in
                  (out @ [ param ], work))
                ([], work) params
            in
            let body, work =
              match body with
              | None -> (None, work)
              | Some b ->
                  let b, work = block b work in
                  (Some b, work)
            in
            (out @ [ MethodDecl (mi, n, params, ret, body, override, private_, ms) ], work))
          ([], work) c.c_methods
      in
      ( SClass (i, { c with c_header = header; c_fields = body_fields; c_extends = extends; c_methods = methods }, sym),
        work )
  | SImport (i, module_, name, selected, fields, sym) ->
      (* What a module exports is renamed with everything else, and an
         import names it by the name the output uses. *)
      ( SImport
          ( i,
            module_,
            name,
            selected,
            List.map (fun (field, local) -> (plain field, plain local)) fields,
            sym ),
        work )
  | SLoop (i, target, init, type_, iterate, body, sym) ->
      let init, work =
        match init with
        | None -> (None, work)
        | Some e ->
            let e, work = go e work in
            (Some e, work)
      in
      let iterate, work =
        match iterate with
        | None -> (None, work)
        | Some (ForIn (li, name, sequence, ls)) ->
            let sequence, work = go sequence work in
            (Some (ForIn (li, name, sequence, ls)), work)
        | Some (WhileTest (li, condition, ls)) ->
            let condition, work = go condition work in
            (Some (WhileTest (li, condition, ls)), work)
      in
      let body, work = block body work in
      (SLoop (i, target, init, type_, iterate, body, sym), work)
  | SIf (i, condition, then_body, else_body, sym) ->
      let condition, work = go condition work in
      let then_body, work = block then_body work in
      let else_body, work =
        match else_body with
        | None -> (None, work)
        | Some body ->
            let body, work = block body work in
            (Some body, work)
      in
      (SIf (i, condition, then_body, else_body, sym), work)
  | SMatch (i, subject, cases, sym) ->
      let subject, work = go subject work in
      let cases, work =
        List.fold_left
          (fun (out, work) (MatchCase (ci, pattern, guard, body, cs)) ->
            let guard, work =
              match guard with
              | None -> (None, work)
              | Some g ->
                  let g, work = go g work in
                  (Some g, work)
            in
            let body, work = block body work in
            (out @ [ MatchCase (ci, pattern, guard, body, cs) ], work))
          ([], work) cases
      in
      (SMatch (i, subject, cases, sym), work)
  | SFunctionSig (i, name, type_, sym, public) ->
      (SFunctionSig (i, plain name, folded type_, sym, public), work)
  | SFunctionDef (i, name, params, body, return_type, sym, public, implicits, _)
    ->
      (* An implicit parameter becomes an ordinary one, in the order it
         was written: they are trailing, so a call that supplies them
         appends its arguments. *)
      let params, work =
        List.fold_left
          (fun (out, work) param ->
            let param, work = parameter param qmap work in
            (out @ [ param ], work))
          ([], work) (params @ implicits)
      in
      let body, work = block body work in
      ( SFunctionDef
          (i, plain name, params, body, return_type, sym, public, [], false),
        work )

(** One block. [stmt] -> resolution IntMap.t -> work -> ([stmt], work) *)
and statements stmts qmap work =
  List.fold_left
    (fun (out, work) s ->
      let s, work = statement s qmap work in
      (out @ [ s ], work))
    ([], work) stmts

(** One module with overloading and implicits removed, and the types of
    the nodes this pass built added to tmap. The checker does not run
    again: every type recorded here is one it worked out and carried in
    `qmap` (docs/implicits.md, "Why one check is enough").
    resolution IntMap.t -> typ IntMap.t -> [stmt] -> ([stmt], typ IntMap.t) *)
let program qmap tmap stmts =
  check_no_rename_clash stmts;
  let work = { next = Analyses.highest_sym stmts + 1; tmap } in
  let stmts, work = statements stmts qmap work in
  (stmts, work.tmap)
