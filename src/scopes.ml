(** What the names in a module mean: a walk over its statements that
    binds as analyses.ml does -- every `def` of a block before any of
    it, a module's imports before its first statement -- and records
    each use of a name with the binding it reaches, and which names are
    in scope where. The language server reads hover, definition,
    references and rename out of it, and the debugger the names a
    Watch expression may use. See design/lsp.md.

    Data structures:
      place -- a file and the span of a name in it.
      binding_kind -- a def, an `=`, a `var` or a parameter.
      meaning -- what a name refers to.
      context -- what the walk is told about the module.
      use -- one name used, where, and what it means.
      scope -- the names in scope from one position to another.
      found -- every use and every scope of a module.

    Functions:
      name_span tokens name from -- the span of a name at or after a span.
      export_place unit name -- where a module binds a top-level name.
      target_bindings target / pattern_bindings pattern -- the names an
        assignment target or a pattern binds.
      resolve units unit -- every use and scope of a module.
      use_at found row col -- the use at a position.
      names_at found row col -- the names in scope at a position.
      bindings found -- every binding the module's scopes hold. *)

open Syntax

module SMap = Map.Make (String)

(* Where a name is bound: a file and the name's span in it. *)
type place = { file : string; span : Lexer.info }

(* What kind of binding a name is: a def, an `=`, a `var`, a parameter. *)
type binding_kind = KFunction | KValue | KVariable | KParameter

(* What a name refers to: a binding (its place, symbol and kind), an
   imported module, a builtin, or nothing found. *)
type meaning =
  | Bound of place * int * binding_kind
  | Module_of of string
  | Builtin
  | Unknown

(** The span of the first identifier `name` at or after where a span
    starts, from a module's tokens. [token] -> string -> Lexer.info ->
    Lexer.info *)
let name_span tokens name (from : Lexer.info) =
  let found =
    List.find_opt
      (fun token ->
        match token with
        | Lexer.TokIdent (i, n) -> n = name && compare (i.row1, i.col1) (from.row1, from.col1) >= 0
        | _ -> false)
      tokens
  in
  match found with
  | Some token -> Lexer.token_info token
  | None -> { from with row2 = from.row1; col2 = from.col1 }

(** What resolution is told about the module whose names it resolves. *)
type context = { ctx_path : string; ctx_tokens : Lexer.token list; ctx_units : Module.t list }

(** The unit of a module by its name. context -> string -> Module.t? *)
let unit_named ctx name = List.find_opt (fun (u : Module.t) -> u.name = name) ctx.ctx_units

(** Where a module binds one of its top-level names, and the binding's
    symbol and kind. Module.t -> string -> (place, int, binding_kind)? *)
let export_place (unit : Module.t) name =
  let in_stmts stmts tokens file =
    List.find_map
      (fun stmt ->
        match stmt with
        | SFunctionDef (i, n, _, _, _, s, _, _, _) when n = name ->
            Some ({ file; span = name_span tokens n i }, s, KFunction)
        | SFunctionSig (i, n, _, s, _) when n = name ->
            Some ({ file; span = name_span tokens n i }, s, KFunction)
        | SVar (i, n, _, s) when n = name -> Some ({ file; span = name_span tokens n i }, s, KVariable)
        | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) -> (
            let rec find target =
              match target with
              | TargetName (i, n, s) when n = name -> Some ({ file; span = i }, s, KValue)
              | TargetName _ -> None
              | TargetTuple (_, targets, _) -> List.find_map find targets
            in
            find target)
        | _ -> None)
      stmts
  in
  match in_stmts unit.stmts unit.tokens unit.path with
  | Some found -> Some found
  | None -> in_stmts unit.declarations [] (Option.value ~default:unit.path unit.declaration_path)

(** One name found in a module: where, what it is called and what it
    means. *)
type use = { use_at : Lexer.info; use_name : string; use_meaning : meaning }

(** The names in scope from a row and column to another. *)
type scope = { scope_from : int * int; scope_to : int * int; names : meaning SMap.t }

(** What resolution has found so far. *)
type found = { uses : use list; scopes : scope list }

(** What a name means in an environment. meaning SMap.t -> string -> meaning *)
let lookup env name = Option.value ~default:Unknown (SMap.find_opt name env)

(** The names an assignment target binds, with their spans and symbols.
    assign_target -> [(string, Lexer.info, int)] *)
let rec target_bindings target =
  match target with
  | TargetName (i, n, s) -> [ (n, i, s) ]
  | TargetTuple (_, targets, _) -> List.concat_map target_bindings targets

(** The names a pattern binds, with their spans and symbols.
    pattern -> [(string, Lexer.info, int)] *)
let rec pattern_bindings pattern =
  match pattern with
  | PCapture (i, n, s) -> [ (n, i, s) ]
  | PTuple (_, ps, _) -> List.concat_map pattern_bindings ps
  | PList (_, before, rest, after, _) ->
      List.concat_map pattern_bindings before
      @ (match rest with Some (ListRest (i, Some n, s)) -> [ (n, i, s) ] | _ -> [])
      @ List.concat_map pattern_bindings after
  | PText (i, _, Some n, _, s) -> [ (n, i, s) ]
  | PConstructor (_, _, _, ps, named, _) ->
      List.concat_map pattern_bindings (ps @ List.map snd named)
  | POr (_, first :: _, _) -> pattern_bindings first
  | POr (_, [], _) -> []
  | PAs (i, inner, n, s) -> pattern_bindings inner @ [ (n, i, s) ]
  | PInt _ | PString _ | PChar _ | PBool _ | PWildcard _ | PText _ -> []

(** An environment with names bound at places in the module resolved.
    context -> binding_kind -> meaning SMap.t -> [(string, Lexer.info,
    int)] -> meaning SMap.t *)
let bind_all ctx kind env names =
  List.fold_left
    (fun env (n, span, s) -> SMap.add n (Bound ({ file = ctx.ctx_path; span }, s, kind)) env)
    env names

(** A parameter's binding: its name, the span of the name alone, its
    symbol. param -> (string, Lexer.info, int) *)
let param_binding (Param (i, n, _, _, s)) =
  (n, { i with row2 = i.row1; col2 = i.col1 + String.length n }, s)

(** What an import binds: a module under its local name, or each field
    taken, where its module binds it. context -> meaning SMap.t -> stmt ->
    meaning SMap.t *)
let bind_import ctx env stmt =
  match stmt with
  | SImport (_, module_, name, selected, fields, _) ->
      if not selected then SMap.add name (Module_of module_) env
      else
        List.fold_left
          (fun env (exported, local) ->
            let meaning =
              match Option.bind (unit_named ctx module_) (fun u -> export_place u exported) with
              | Some (place, s, kind) -> Bound (place, s, kind)
              | None -> Unknown
            in
            SMap.add local meaning env)
          env fields
  | _ -> env

(** What `module.name` means, where `module` is bound in env.
    context -> meaning SMap.t -> string -> string -> meaning *)
let qualified ctx env module_ name =
  match lookup env module_ with
  | Module_of real -> (
      match Option.bind (unit_named ctx real) (fun u -> export_place u name) with
      | Some (place, s, kind) -> Bound (place, s, kind)
      | None -> Unknown)
  | _ -> Unknown

(** Every name an expression uses. context -> meaning SMap.t -> expr ->
    found -> found *)
let rec resolve_expr ctx env e found =
  let go = resolve_expr ctx env in
  match e with
  | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ -> found
  | EVar (i, n, _) -> { found with uses = { use_at = i; use_name = n; use_meaning = lookup env n } :: found.uses }
  | EAdd (_, a, b, _) | ESub (_, a, b, _) | EMul (_, a, b, _) | EDiv (_, a, b, _)
  | EConcat (_, a, b, _) | ELessThan (_, a, b, _) | ELessThanEq (_, a, b, _)
  | EGreatThan (_, a, b, _) | EGreatThanEq (_, a, b, _) | EEq (_, a, b, _)
  | EBinary (_, _, a, b, _) | EIndex (_, a, b, _) ->
      go b (go a found)
  | ENeg (_, a, _) | EUnary (_, _, a, _) -> go a found
  | ECall (_, f, args, _) -> List.fold_left (fun found a -> go a found) (go f found) (arg_exprs args)
  | EList (_, es, _) | ETuple (_, es, _) -> List.fold_left (fun found a -> go a found) found es
  | EIf (_, c, a, b, _) -> go b (go a (go c found))
  | EQualified (i, m, n, _) ->
      let module_span = { i with row2 = i.row1; col2 = i.col1 + String.length m } in
      let uses =
        { use_at = { i with row1 = i.row2; col1 = max i.col1 (i.col2 - String.length n) };
          use_name = m ^ "." ^ n; use_meaning = qualified ctx env m n }
        :: { use_at = module_span; use_name = m; use_meaning = lookup env m }
        :: found.uses
      in
      { found with uses }
  | EListComp (_, body, clauses, _) ->
      let env, found =
        List.fold_left
          (fun (env, found) clause ->
            match clause with
            | CompFor (_, pattern, sequence, _) ->
                let found = resolve_expr ctx env sequence found in
                (bind_all ctx KValue env (pattern_bindings pattern), found)
            | CompIf (_, c, _) -> (env, resolve_expr ctx env c found))
          (env, found) clauses
      in
      resolve_expr ctx env body found
  | ELambda (_, params, body, _) ->
      resolve_expr ctx (bind_all ctx KParameter env (List.map param_binding params)) body found
  | ELet (_, target, _, value, body, _) ->
      resolve_expr ctx (bind_all ctx KValue env (target_bindings target)) body (go value found)
  | EConstruct (_, _, _, args, _) ->
      List.fold_left (fun found a -> go a found) found (arg_exprs args)
  | EField (_, record, _, _) -> go record found

(** Every name a block uses, and what is in scope where, with its `def`s
    bound before any of it. context -> meaning SMap.t -> [stmt] -> (int,
    int) -> found -> found *)
and resolve_block ctx env stmts stop found =
  let env =
    List.fold_left
      (fun env stmt ->
        match stmt with
        | SFunctionDef (i, n, _, _, _, s, _, _, _) ->
            SMap.add n (Bound ({ file = ctx.ctx_path; span = name_span ctx.ctx_tokens n i }, s, KFunction)) env
        | _ -> env)
      env stmts
  in
  let _, found =
    List.fold_left
      (fun (env, found) stmt ->
        let i = stmt_info stmt in
        let found = { found with scopes = { scope_from = (i.row1, i.col1); scope_to = stop; names = env } :: found.scopes } in
        let env, found = resolve_stmt ctx env stmt found in
        let found = { found with scopes = { scope_from = (i.row2, i.col2); scope_to = stop; names = env } :: found.scopes } in
        (env, found))
      (env, found) stmts
  in
  found

(** Every name a statement uses, and the environment it leaves.
    context -> meaning SMap.t -> stmt -> found -> (meaning SMap.t, found) *)
and resolve_stmt ctx env stmt found =
  match stmt with
  | SLet (_, target, e, _, _, _, _) ->
      let found = resolve_expr ctx env e found in
      (bind_all ctx KValue env (target_bindings target), found)
  | SLetStmt (_, target, inner, _, _, _) ->
      let _, found = resolve_stmt ctx env inner found in
      (bind_all ctx KValue env (target_bindings target), found)
  | SVar (i, n, e, s) ->
      let found = resolve_expr ctx env e found in
      (SMap.add n (Bound ({ file = ctx.ctx_path; span = name_span ctx.ctx_tokens n i }, s, KVariable)) env, found)
  | SMutate (i, n, e, _) ->
      let found = resolve_expr ctx env e found in
      let use = { use_at = name_span ctx.ctx_tokens n i; use_name = n; use_meaning = lookup env n } in
      (env, { found with uses = use :: found.uses })
  | SReturn (_, e, _) | SExprStmt (_, e, _) -> (env, resolve_expr ctx env e found)
  | SReturnStmt (_, inner, _) -> (env, snd (resolve_stmt ctx env inner found))
  | SLoop (i, target, init, _, iter, body, _) ->
      let found = match init with Some e -> resolve_expr ctx env e found | None -> found in
      let inner =
        match target with Some t -> bind_all ctx KValue env (target_bindings t) | None -> env
      in
      let inner, found =
        match iter with
        | Some (ForIn (fi, n, sequence, _)) ->
            let found = resolve_expr ctx env sequence found in
            (bind_all ctx KValue inner [ (n, name_span ctx.ctx_tokens n fi, 0) ], found)
        | Some (WhileTest (_, c, _)) -> (inner, resolve_expr ctx inner c found)
        | None -> (inner, found)
      in
      (env, resolve_block ctx inner body (i.row2, i.col2) found)
  | SBreak (_, Some e, _) | SContinue (_, Some e, _) -> (env, resolve_expr ctx env e found)
  | SBreak _ | SContinue _ | SFunctionSig _ | SDatatype _ -> (env, found)
  | SIf (i, c, then_, else_, _) ->
      let found = resolve_expr ctx env c found in
      let found = resolve_block ctx env then_ (i.row2, i.col2) found in
      (env, match else_ with Some b -> resolve_block ctx env b (i.row2, i.col2) found | None -> found)
  | SFunctionDef (i, n, params, body, _, s, _, implicits, _) ->
      let found =
        List.fold_left
          (fun found (Param (_, _, _, default, _)) ->
            match default with Some e -> resolve_expr ctx env e found | None -> found)
          found params
      in
      let inner =
        SMap.add n (Bound ({ file = ctx.ctx_path; span = name_span ctx.ctx_tokens n i }, s, KFunction)) env
      in
      let inner = bind_all ctx KParameter inner (List.map param_binding (params @ implicits)) in
      (env, resolve_block ctx inner body (i.row2, i.col2) found)
  | SMatch (_, subject, cases, _) ->
      let found = resolve_expr ctx env subject found in
      ( env,
        List.fold_left
          (fun found (MatchCase (ci, pattern, guard, body, _)) ->
            let inner = bind_all ctx KValue env (pattern_bindings pattern) in
            let found =
              match guard with Some g -> resolve_expr ctx inner g found | None -> found
            in
            resolve_block ctx inner body (ci.row2, ci.col2) found)
          found cases )
  | SImport (i, module_, _, true, fields, _) ->
      (* Each name a `from` line takes is a use of what it names there:
         the first of that name after the line's `import`. *)
      let after =
        List.find_map
          (fun token ->
            match token with
            | Lexer.TokImport t when compare (t.row1, t.col1) (i.row1, i.col1) >= 0 -> Some t
            | _ -> None)
          ctx.ctx_tokens
        |> Option.value ~default:i
      in
      let uses =
        List.filter_map
          (fun (exported, _) ->
            match Option.bind (unit_named ctx module_) (fun u -> export_place u exported) with
            | Some (place, s, kind) ->
                Some
                  {
                    use_at = name_span ctx.ctx_tokens exported after;
                    use_name = exported;
                    use_meaning = Bound (place, s, kind);
                  }
            | None -> None)
          fields
      in
      (bind_import ctx env stmt, { found with uses = uses @ found.uses })
  | SImport _ -> (bind_import ctx env stmt, found)

(** What every name in a module means, and what is in scope where.
    [Module.t] -> Module.t -> found *)
let resolve units (unit : Module.t) =
  let ctx = { ctx_path = unit.path; ctx_tokens = unit.tokens; ctx_units = units } in
  let env = List.fold_left (fun env n -> SMap.add n Builtin env) SMap.empty Builtin.names in
  let env = List.fold_left (bind_import ctx) env unit.stmts in
  let env =
    List.fold_left
      (fun env stmt ->
        match stmt with
        | SFunctionSig (i, n, _, s, _) ->
            SMap.add n (Bound ({ file = Option.value ~default:unit.path unit.declaration_path; span = i }, s, KFunction)) env
        | _ -> env)
      env unit.declarations
  in
  resolve_block ctx env unit.stmts (max_int, max_int) { uses = []; scopes = [] }

(** The smallest use of a name holding a position, or None.
    found -> int -> int -> use? *)
let use_at found row col =
  let contains (i : Lexer.info) =
    compare (i.row1, i.col1) (row, col) <= 0 && compare (row, col) (i.row2, i.col2) <= 0
  in
  let size (i : Lexer.info) = (i.row2 - i.row1, if i.row1 = i.row2 then i.col2 - i.col1 else i.col2) in
  List.fold_left
    (fun best u ->
      if contains u.use_at then
        match best with
        | Some b when compare (size b.use_at) (size u.use_at) <= 0 -> best
        | _ -> Some u
      else best)
    None found.uses

(** The names in scope at a position: those of the scope starting
    latest at or before it that still holds it.
    found -> int -> int -> meaning SMap.t *)
let names_at found row col =
  List.fold_left
    (fun best s ->
      match best with
      | Some b when compare b.scope_from s.scope_from >= 0 -> best
      | _ ->
          if compare s.scope_from (row, col) <= 0 && compare (row, col) s.scope_to <= 0
          then Some s
          else best)
    None found.scopes
  |> Option.map (fun s -> s.names)
  |> Option.value ~default:SMap.empty

(** Every binding the module's scopes hold, each once: its name, place,
    symbol and kind. found -> [(string, place, int, binding_kind)] *)
let bindings found =
  List.fold_left
    (fun out s ->
      SMap.fold
        (fun n meaning out ->
          match meaning with
          | Bound (place, sym, kind)
            when not (List.exists (fun (m, p, _, _) -> m = n && p = place) out) ->
              out @ [ (n, place, sym, kind) ]
          | _ -> out)
        s.names out)
    [] (List.rev found.scopes)
