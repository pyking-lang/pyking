(** Default parameters and named arguments, removed before anything
    reasons about the program. A default becomes a generated
    zero-argument `def` in the block the definition is written in, and
    an omitted argument becomes a call to it; a named argument is put
    back in its parameter's position. What comes out is ordinary Pyking,
    so no later stage knows the sugar exists.
    See docs/desugar_args.md.

    A constructor is a definition like any other here: its fields are
    its parameters, and a constructor pattern is filled in by the same
    names, with `_` for every field it does not mention.

    Data structures:
      parameter -- one parameter of a definition the pass has seen.
      meta -- what a call needs to know about the definition it reaches.
      signatures -- the same, for every module desugared so far.
      denotation -- what a name means where a call uses it.

    Functions:
      no_signatures -- nothing known yet.
      desugar signatures name stmts -- rewrites one module.
      external_module signatures name -- records a module written in
        another language.
      generated_name name -- whether the pass made this name up. *)

open Syntax

module SMap = Map.Make (String)
module SSet = Set.Make (String)

(* --- what the pass knows --- *)

(** Where a parameter's default comes from. *)
type default =
  | Generated of string (* the name of the generated def holding it *)
  | Literal of expr (* a literal, written at each call that omits it *)

(** One parameter of a definition: its name, and its default, where it
    has one. *)
type parameter = { name : string; default : default option; implicit : bool }

(** What a call needs to know about the definition it reaches: its
    parameters, whether it is exported, and, for a constructor, whether
    it is its datatype's only one. *)
type meta = { parameters : parameter list; exported : bool; sole : bool }

(** One module: its definitions, the other names its top level binds,
    whether it is written in another language, in which case the sugar
    may not reach into it, and the imports it has written so far -- which
    a module extended an entry at a time still has in scope. *)
type module_info = {
  functions : meta SMap.t;
  constructors : meta SMap.t;
  datatypes : string list SMap.t;
  others : SSet.t;
  foreign : bool;
  imports : stmt list;
}

type signatures = module_info SMap.t

(** Nothing known yet. signatures *)
let no_signatures = SMap.empty

(** Records that a module is written in another language, so a call into
    it refuses the sugar by name rather than by absence.
    signatures -> String -> signatures *)
let external_module signatures name =
  SMap.add name
    {
      functions = SMap.empty;
      constructors = SMap.empty;
      datatypes = SMap.empty;
      others = SSet.empty;
      foreign = true;
      imports = [];
    }
    signatures

(** What a name means where a call uses it. *)
type denotation =
  | Definition of meta (* a `def` in scope *)
  | Binding (* anything else a name may be bound to *)
  | Imported of string (* the name an imported module is known by *)
  | Constructs of meta (* a datatype's constructor in scope *)

(* --- the generated names --- *)

(* What every generated name is built around. *)
let marker = "__default__"

(** The name of the def holding one parameter's default.
    String -> String -> String *)
let default_name func param = func ^ marker ^ param

(** The name of the def holding one constructor field's default: one
    starting with a lowercase letter, as a def's name does, which no
    function's default can take. String -> String -> String *)
let field_default_name constructor field =
  "field" ^ marker ^ constructor ^ "__" ^ field

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

(** Raises Analysis_error at info with message. info -> String -> 'a *)
let refuse info message = raise (Analyses.Analysis_error (info, message))

(* --- the definitions of one block --- *)

(** Every name this statement binds at the level it is written on.
    stmt -> [String] *)
let bound_here statement =
  match statement with
  | SFunctionDef (_, name, _, _, _, _, _, _, _) -> [ name ]
  | statement -> List.map fst (Analyses.bound_names statement)

(** The literal a default is, where it is one whose type is the one
    written for its parameter or field, or nothing is written: such a
    default is written at each call rather than generated as a def.
    typ? -> expr -> expr? *)
let inlined annotation default =
  let kind =
    match default with
    | EInt _ | ENeg (_, EInt _, _) -> Some `Int
    | EFloat _ | ENeg (_, EFloat _, _) -> Some `Float
    | EString _ -> Some `String
    | EChar _ -> Some `Char
    | EBool _ -> Some `Bool
    | _ -> None
  in
  match (kind, annotation) with
  | None, _ -> None
  | Some _, None
  | Some `Int, Some (TInt _)
  | Some `Float, Some (TFloat _)
  | Some `String, Some (TString _)
  | Some `Char, Some (TChar _)
  | Some `Bool, Some (TBool _) ->
      Some default
  | Some _, Some _ -> None

(** Where one default comes from, given the name of the def that would
    hold it. String -> typ? -> expr? -> default? *)
let default_of generated annotation default =
  match default with
  | None -> None
  | Some e -> (
      match inlined annotation e with
      | Some literal -> Some (Literal literal)
      | None -> Some (Generated generated))

(** What a definition's parameters are, and where its defaults will
    live. String -> [param] -> [param] -> bool -> meta *)
let meta_of func params implicits exported =
  let one implicit (Param (_, name, annotation, default, _)) =
    { name; default = default_of (default_name func name) annotation default; implicit }
  in
  {
    parameters = List.map (one false) params @ List.map (one true) implicits;
    exported;
    sole = false;
  }

(** The name a constructor's unnamed field is known by here: one no
    program can write, so no argument can name it. int -> String *)
let unnamed_field position = "#" ^ string_of_int (position + 1)

(** What a constructor's fields are, and where its defaults will live.
    bool -> bool -> constructor -> meta *)
let constructor_meta exported sole (Constructor (_, name, fields, _)) =
  {
    parameters =
      List.mapi
        (fun at (Field (_, label, type_, default, _)) ->
          let field = match label with Some n -> n | None -> unnamed_field at in
          {
            name = field;
            default = default_of (field_default_name name field) type_ default;
            implicit = false;
          })
        fields;
    exported;
    sole;
  }

(** Every constructor declared directly in this block, with what a call
    to it needs to know. [stmt] -> (String * meta) list *)
let block_constructors stmts =
  List.concat_map
    (function
      | SDatatype (_, _, _, constructors, _, public) ->
          let sole = List.length constructors = 1 in
          List.map
            (fun (Constructor (_, name, _, _) as c) ->
              (name, constructor_meta public sole c))
            constructors
      | _ -> [])
    stmts

(** Every datatype declared directly in this block, with the names of
    its constructors. [stmt] -> (String * [String]) list *)
let block_datatypes stmts =
  List.filter_map
    (function
      | SDatatype (_, name, _, constructors, _, _) ->
          Some (name, List.map (fun (Constructor (_, n, _, _)) -> n) constructors)
      | _ -> None)
    stmts

(** Every def written directly in this block, with what a call to it
    needs to know. [stmt] -> (String * meta) list *)
let block_definitions stmts =
  List.filter_map
    (function
      | SFunctionDef (_, name, params, _, _, _, public, implicits, _) ->
          Some (name, meta_of name params implicits public)
      | _ -> None)
    stmts

(* --- resolving a callee --- *)

(** The definition this callee reaches, where it reaches one, and the
    name its generated defaults are known by here. A `None` answer means
    the sugar does not apply, which is not in itself an error.
    signatures -> [denotation] -> expr -> (meta * (String -> expr))? *)
let callee_meta signatures scope callee =
  match callee with
  | EVar (info, name, _) -> (
      match SMap.find_opt name scope with
      | Some (Definition meta) ->
          Some (meta, fun generated -> EVar (info, generated, 0))
      | _ -> None)
  | EQualified (info, alias, field, _) -> (
      match SMap.find_opt alias scope with
      | Some (Imported module_) -> (
          match SMap.find_opt module_ signatures with
          | None -> None
          | Some info_ when info_.foreign -> None
          | Some info_ -> (
              match SMap.find_opt field info_.functions with
              | Some meta when meta.exported ->
                  Some
                    (meta, fun generated -> EQualified (info, alias, generated, 0))
              | _ -> None))
      | _ -> None)
  | _ -> None

(** The constructor `[module.]name` reaches, where this pass knows it,
    and how its generated defaults are reached from here.
    signatures -> [denotation] -> String? -> String ->
    (meta * (String -> expr))? *)
let constructor_reached signatures scope info module_ name =
  match module_ with
  | None -> (
      match SMap.find_opt name scope with
      | Some (Constructs meta) ->
          Some (meta, fun generated -> EVar (info, generated, 0))
      | _ -> None)
  | Some alias -> (
      match SMap.find_opt alias scope with
      | Some (Imported module_) -> (
          match SMap.find_opt module_ signatures with
          | Some known when not known.foreign -> (
              match SMap.find_opt name known.constructors with
              | Some meta when meta.exported ->
                  Some
                    (meta, fun generated -> EQualified (info, alias, generated, 0))
              | _ -> None)
          | _ -> None)
      | _ -> None)

(** The `::` definitions an unqualified callee could mean, each with the
    expression its generated defaults are named by here. Which of them a
    call means is the type checker's question, decided by the argument
    *types*; what this pass has to know is which of them the argument
    *count* allows at all, since a default it has already erased is what
    makes a definition take fewer (docs/overloading.md).
    signatures -> [denotation] -> expr
    -> [(String, meta, String -> expr)] *)
let overload_set signatures scope callee =
  match callee with
  | EVar (info, name, _)
    when (not (Names.is_qualified name)) && not (SMap.mem name scope) ->
      SMap.fold
        (fun bound what found ->
          match what with
          | Definition meta
            when Names.is_qualified bound && Names.base bound = name ->
              found @ [ (bound, meta, fun made -> EVar (info, made, 0)) ]
          | _ -> found)
        scope []
  | EQualified (info, alias, field, _) when not (Names.is_qualified field) -> (
      match SMap.find_opt alias scope with
      | Some (Imported module_) -> (
          match SMap.find_opt module_ signatures with
          | Some known when not known.foreign ->
              SMap.fold
                (fun bound meta found ->
                  if
                    meta.exported
                    && Names.is_qualified bound
                    && Names.base bound = field
                  then
                    found
                    @ [
                        ( bound,
                          meta,
                          fun made -> EQualified (info, alias, made, 0) );
                      ]
                  else found)
                known.functions []
          | _ -> [])
      | _ -> [])
  | _ -> []

(** How many arguments one definition takes: the ones it must be given,
    the ones it may be given, and the ones it may be given with every
    implicit argument written out as well. meta -> (int, int, int) *)
let arities meta =
  let explicit = List.filter (fun p -> not p.implicit) meta.parameters in
  let required = List.length (List.filter (fun p -> p.default = None) explicit) in
  ( required,
    List.length explicit,
    List.length explicit + (List.length meta.parameters - List.length explicit) )

(** Whether this definition takes a call of `given` arguments, and
    whether taking it means using a default. meta -> int -> (bool, bool) *)
let takes meta given =
  let required, explicit, with_implicits = arities meta in
  ( (given >= required && given <= explicit) || given = with_implicits,
    given < explicit )

(** Why the sugar cannot be used on this callee, in the words that name
    what was written. signatures -> scope -> expr -> String *)
let sugar_refusal signatures scope callee =
  match callee with
  | EVar (_, name, _) when List.mem name Builtin.names
                           && not (SMap.mem name scope) ->
      Printf.sprintf
        "'%s' is a builtin and has no parameter names, so an argument \
         cannot be named"
        name
  | EVar (_, name, _) ->
      Printf.sprintf
        "'%s' is a binding, not a function definition; default and named \
         arguments are available only when calling a 'def' directly or \
         through 'module.name'"
        name
  | EQualified (_, alias, field, _) -> (
      let foreign =
        match SMap.find_opt alias scope with
        | Some (Imported module_) -> (
            match SMap.find_opt module_ signatures with
            | Some info_ -> info_.foreign
            | None -> false)
        | _ -> false
      in
      match foreign with
      | true ->
          Printf.sprintf
            "'%s.%s' is written in another language, so default and named \
             arguments are not available for it"
            alias field
      | false ->
          Printf.sprintf
            "'%s.%s' is not a function definition this module can see the \
             parameters of"
            alias field)
  | _ ->
      "default and named arguments are available only when calling a 'def' \
       directly or through 'module.name'"

(* --- putting the arguments in order --- *)

(** The position of the parameter this name refers to.
    [parameter] -> String -> int? *)
let position parameters name =
  let rec at i = function
    | [] -> None
    | p :: rest -> if p.name = name then Some i else at (i + 1) rest
  in
  at 0 parameters

(** `body` inside one `let` per binding of `lets`, the first outermost.
    info -> [(String, expr)] -> expr -> expr *)
let let_around info lets body =
  List.fold_right
    (fun (name, value) body -> ELet (info, TargetName (info, name, 0), None, value, body, 0))
    lets body

(** Whether evaluating an expression can be seen: anything but a
    literal, a name, a lambda, or a tuple, list, constructor or field of
    those. expr -> bool *)
let rec pure e =
  match e with
  | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ | EQualified _ | ELambda _ -> true
  | ETuple (_, es, _) | EList (_, es, _) -> List.for_all pure es
  | EConstruct (_, _, _, args, _) -> List.for_all (fun (_, a) -> pure a) args
  | ENeg (_, o, _) -> pure o
  | EField (_, r, _, _) -> pure r
  | _ -> false

(** A literal default as written at a call: at the call's own span, so
    nothing reports it at the definition's, which may be in another file.
    info -> expr -> expr *)
let rec placed info literal =
  match literal with
  | EInt (_, v, s) -> EInt (info, v, s)
  | EFloat (_, v, s) -> EFloat (info, v, s)
  | EString (_, v, s) -> EString (info, v, s)
  | EChar (_, v, s) -> EChar (info, v, s)
  | EBool (_, v, s) -> EBool (info, v, s)
  | ENeg (_, inner, s) -> ENeg (info, placed info inner, s)
  | e -> e

(** The full positional argument list one call supplies, filling every
    omitted parameter with a call to its default. Answers None where the
    call says nothing the sugar has to act on, so it is left as written.
    info -> String -> meta -> (String -> expr) -> [(String?, expr)] ->
    ([(String, expr)], [expr])? *)
let ordered ?(field = false) info shown meta reach args =
  let word = if field then "field" else "parameter" in
  let parameters = meta.parameters in
  let positional = List.filter (fun (name, _) -> name = None) args in
  let named =
    List.filter_map
      (fun (name, e) -> match name with Some n -> Some (n, e) | None -> None)
      args
  in
  let given = List.length positional in
  let explicit =
    List.length (List.filter (fun p -> not p.implicit) parameters)
  in
  (* An implicit parameter is left out at most calls and resolved by the
     type checker instead, so a call that supplies none of them is an
     ordinary call of the explicit arity (docs/implicits.md). *)
  let implicit_names =
    List.filter_map (fun p -> if p.implicit then Some p.name else None)
      parameters
  in
  let supplies_implicit =
    given > explicit
    || List.exists (fun (n, _) -> List.mem n implicit_names) named
  in
  let parameters =
    if supplies_implicit then parameters
    else List.filter (fun p -> not p.implicit) parameters
  in
  let arity = List.length parameters in
  if named = [] && given = arity then None
  else if named = [] && given > arity then None
  else
    (* Every name must be a parameter of this definition, none of them
       one an earlier argument already filled, and they must be written
       in the order the parameters are. *)
    let places =
      List.map
        (fun (name, e) ->
          match position parameters name with
          | None ->
              refuse (expr_info e)
                (Printf.sprintf "'%s' has no %s '%s'" shown word name)
          | Some at ->
              if at < given then
                refuse (expr_info e)
                  (Printf.sprintf
                     "'%s' is already given as argument %d of this call" name
                     (at + 1))
              else (at, e))
        named
    in
    let rec repeated = function
      | (a, _) :: rest -> (
          match List.find_opt (fun (b, _) -> a = b) rest with
          | Some (_, second) ->
              refuse (expr_info second)
                (Printf.sprintf "'%s' is given twice in this call"
                   (List.nth parameters a).name)
          | None -> repeated rest)
      | [] -> ()
    in
    repeated places;
    let rec increasing = function
      | (a, _) :: ((b, _) :: _ as rest) -> a < b && increasing rest
      | _ -> true
    in
    let in_order = increasing places in
    let supplied = List.map snd positional in
    let filled =
      List.mapi
        (fun at parameter ->
          if at < given then Some (List.nth supplied at)
          else
            match List.assoc_opt at places with
            | Some e -> Some e
            | None -> (
                match parameter.default with
                | Some (Generated generated) ->
                    Some (ECall (info, reach generated, [], 0))
                | Some (Literal literal) -> Some (placed info literal)
                | None -> None))
        parameters
    in
    if List.exists (fun slot -> slot = None) filled then
      if named = [] then
        (* Nothing was named, so this is an ordinary arity mistake and
           the type checker has better words for it than this pass. *)
        None
      else
        let missing =
          List.filteri (fun at _ -> List.nth filled at = None) parameters
        in
        let missing = (List.hd missing).name in
        let missing =
          if String.length missing > 0 && missing.[0] = '#' then
            "its field " ^ String.sub missing 1 (String.length missing - 1)
          else "'" ^ missing ^ "'"
        in
        refuse info
          (Printf.sprintf "'%s' needs an argument for %s" shown missing)
    else
      let filled = List.map Option.get filled in
      if in_order then Some ([], filled)
      else
        (* Named arguments out of parameter order are evaluated as
           written, before the defaults of the parameters left out. *)
        let rank at =
          if at < given then at
          else
            match List.find_index (fun (p, _) -> p = at) places with
            | Some k -> given + k
            | None -> given + List.length places + at
        in
        let impure =
          List.filteri (fun at _ -> not (pure (List.nth filled at))) filled
        in
        if List.length impure <= 1 then Some ([], filled)
        else
          let name at =
            let parameter = (List.nth parameters at).name in
            if String.length parameter > 0 && parameter.[0] = '#' then
              "field" ^ String.sub parameter 1 (String.length parameter - 1) ^ "__arg"
            else parameter ^ "__arg"
          in
          let bound =
            List.mapi (fun at e -> (at, e)) filled
            |> List.filter (fun (_, e) -> not (pure e))
            |> List.map (fun (at, e) -> (rank at, (name at, e)))
            |> List.sort (fun (a, _) (b, _) -> compare a b)
            |> List.map snd
          in
          let filled =
            List.mapi
              (fun at e ->
                if pure e then e else EVar (expr_info e, name at, 0))
              filled
          in
          Some (bound, filled)

(** The names an import brings into the module that wrote it, and what
    each one means. signatures -> stmt -> scope -> scope *)
let import_scope signatures statement scope =
  match statement with
  | SImport (_, module_, local, false, _, _) ->
      SMap.add local (Imported module_) scope
  | SImport (_, module_, _, true, fields, _) -> (
      match SMap.find_opt module_ signatures with
      | None ->
          List.fold_left
            (fun scope (_, local) -> SMap.add local Binding scope)
            scope fields
      | Some info_ ->
          List.fold_left
            (fun scope (name, local) ->
              match
                ( SMap.find_opt name info_.functions,
                  SMap.find_opt name info_.constructors )
              with
              | _, Some meta when meta.exported && not info_.foreign ->
                  SMap.add local (Constructs meta) scope
              | Some meta, _ when meta.exported && not info_.foreign ->
                  SMap.add local (Definition meta) scope
              | _ -> SMap.add local Binding scope)
            scope fields)
  | _ -> scope

(* --- the walk --- *)

(** How a callee is written, for a message. expr -> String *)
let shown callee =
  match callee with
  | EVar (_, name, _) -> name
  | EQualified (_, alias, field, _) -> alias ^ "." ^ field
  | _ -> "this call"

(** Rewrites one expression.
    signatures -> [denotation] -> expr -> expr *)
let rec expression signatures scope e =
  let go = expression signatures scope in
  match e with
  | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ -> e
  | EQualified (i, alias, field, s) -> (
      (* `x.field` is read as `module.name` by the parser, which cannot
         know which names are modules; a name bound here is a value, and
         this is its field. *)
      match SMap.find_opt alias scope with
      | Some (Binding | Definition _) ->
          let alias_info =
            { i with row2 = i.row1; col2 = i.col1 + String.length alias }
          in
          EField (i, EVar (alias_info, alias, 0), field, s)
      | _ -> e)
  | EField (i, record, field, s) -> EField (i, go record, field, s)
  | EConstruct (i, module_, name, args, s) -> (
      let args = List.map (fun (n, a) -> (n, go a)) args in
      let shown =
        match module_ with Some m -> m ^ "." ^ name | None -> name
      in
      let reached = constructor_reached signatures scope i module_ name in
      let construct args = constructed i module_ name s shown reached args in
      match List.assoc_opt (Some spread_label) args with
      | Some base ->
          let explicit = List.filter (fun (n, _) -> n <> Some spread_label) args in
          updated i shown reached explicit base construct
      | None -> construct args)
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
  | EList (i, elements, s) -> EList (i, List.map go elements, s)
  | ETuple (i, elements, s) -> ETuple (i, List.map go elements, s)
  | EIf (i, c, a, b, s) -> EIf (i, go c, go a, go b, s)
  | ELambda (i, params, body, s) ->
      (* A lambda's parameters are bindings like any other, and shadow
         whatever a call in its body might otherwise have reached. *)
      let scope =
        List.fold_left
          (fun scope (Param (_, name, _, _, _)) -> SMap.add name Binding scope)
          scope params
      in
      ELambda (i, params, expression signatures scope body, s)
  | ELet (i, target, annotation, value, body, s) ->
      (* What a let binds shadows a definition in its body, as a
         lambda's parameters do. *)
      let scope =
        List.fold_left
          (fun scope (name, _) -> SMap.add name Binding scope)
          scope (Analyses.target_names target)
      in
      ELet (i, target, annotation, go value, expression signatures scope body, s)
  | EListComp (i, element, clauses, s) ->
      (* A comprehension binds its patterns' names over the element and
         the clauses after it, so nothing in there is a definition. *)
      let scope =
        List.fold_left
          (fun scope clause ->
            match clause with
            | CompFor (_, pattern, _, _) ->
                List.fold_left
                  (fun scope (name, _) -> SMap.add name Binding scope)
                  scope
                  (Analyses.pattern_bindings pattern)
            | CompIf _ -> scope)
          scope clauses
      in
      EListComp
        ( i,
          expression signatures scope element,
          List.map
            (fun clause ->
              match clause with
              | CompFor (ci, pattern, sequence, cs) ->
                  CompFor
                    ( ci,
                      pattern_of signatures scope pattern,
                      expression signatures scope sequence,
                      cs )
              | CompIf (ci, condition, cs) ->
                  CompIf (ci, expression signatures scope condition, cs))
            clauses,
          s )
  | ECall (i, callee, args, s) -> (
      let callee = go callee in
      let args = List.map (fun (name, a) -> (name, go a)) args in
      let named = List.exists (fun (name, _) -> name <> None) args in
      match callee_meta signatures scope callee with
      | None -> (
          match overload_set signatures scope callee with
          | _ :: _ as candidates ->
              overloaded i (shown callee) candidates args (fun args ->
                  ECall (i, callee, args, s))
          | [] ->
              (* A name nothing has bound is the type checker's to
                 report, in its own words, so a call on one is left as
                 written. *)
              let unbound =
                match callee with
                | EVar (_, name, _) ->
                    (not (SMap.mem name scope))
                    && not (List.mem name Builtin.names)
                | _ -> false
              in
              if named && not unbound then
                refuse i (sugar_refusal signatures scope callee)
              else ECall (i, callee, args, s))
      | Some (meta, reach) -> (
          match ordered i (shown callee) meta reach args with
          | None -> ECall (i, callee, plain_args (arg_exprs args), s)
          | Some (lets, filled) -> let_around i lets (ECall (i, callee, plain_args filled, s))))

(** One construction, its arguments already rewritten, with every
    argument in its field's position, carrying the field's name where it
    has one -- so a stage after this one that keeps a value's fields by
    name finds the names here.
    info -> String? -> String -> int -> String ->
    (meta * (String -> expr))? -> [(String?, expr)] -> expr *)
and constructed i module_ name s shown reached args =
  let labelled meta values =
    if List.length values <> List.length meta.parameters then
      plain_args values
    else
      List.map2
        (fun parameter value ->
          if String.length parameter.name > 0 && parameter.name.[0] = '#'
          then (None, value)
          else (Some parameter.name, value))
        meta.parameters values
  in
  match reached with
  | None -> EConstruct (i, module_, name, args, s)
  | Some (meta, reach) -> (
      match ordered ~field:true i shown meta reach args with
      | None ->
          if List.exists (fun (n, _) -> n <> None) args then
            EConstruct (i, module_, name, args, s)
          else EConstruct (i, module_, name, labelled meta (arg_exprs args), s)
      | Some (lets, filled) ->
          let_around i lets (EConstruct (i, module_, name, labelled meta filled, s)))

(** A construction written with `..base`, as one giving every field it
    leaves out from `base` by name. What it writes is evaluated as
    written, and `base` after it, once: a base that is not a name is bound
    by a `let`, and so is every argument before it that is not pure.
    `rebuild` makes the construction of the arguments it is handed.
    info -> String -> (meta * (String -> expr))? -> [(String?, expr)] ->
    expr -> ([(String?, expr)] -> expr) -> expr *)
and updated info shown reached explicit base rebuild =
  let meta =
    match reached with
    | Some (meta, _) -> meta
    | None ->
        refuse (expr_info base)
          (Printf.sprintf
             "'..' fills the fields of '%s' by name, and '%s' is not a \
              constructor this module can see the fields of"
             shown shown)
  in
  if not meta.sole then
    refuse (expr_info base)
      (Printf.sprintf
         "'..' takes the fields it fills from a value built by the same \
          constructor, so it is written only for a datatype with one \
          constructor, and '%s' is one of several"
         shown);
  let given = List.length (List.filter (fun (n, _) -> n = None) explicit) in
  let named = List.filter_map fst explicit in
  let missing =
    List.filteri
      (fun at parameter -> at >= given && not (List.mem parameter.name named))
      meta.parameters
  in
  if missing = [] then
    refuse (expr_info base)
      (Printf.sprintf "'..' has no field to fill: every field of '%s' is given"
         shown);
  List.iter
    (fun parameter ->
      if String.length parameter.name > 0 && parameter.name.[0] = '#' then
        refuse (expr_info base)
          (Printf.sprintf
             "'..' fills a field by its name, and %s of '%s' has none: give \
              it before the '..'"
             ("field " ^ String.sub parameter.name 1 (String.length parameter.name - 1))
             shown))
    missing;
  let simple = match base with EVar _ -> true | _ -> false in
  (* The arguments written are evaluated before the base, so where the
     base needs a `let`, each of them that can be seen to run needs one
     before it. *)
  let before, explicit =
    if simple || List.for_all (fun (_, e) -> pure e) explicit then ([], explicit)
    else
      let bound =
        List.mapi
          (fun at (label, e) ->
            if pure e then (None, (label, e))
            else
              let field =
                match label with
                | Some n -> n
                | None ->
                    let p = (List.nth meta.parameters at).name in
                    if String.length p > 0 && p.[0] = '#' then
                      "field" ^ String.sub p 1 (String.length p - 1)
                    else p
              in
              let temp = field ^ "__arg" in
              (Some (temp, e), (label, EVar (expr_info e, temp, 0))))
          explicit
      in
      (List.filter_map fst bound, List.map snd bound)
  in
  let before, reference =
    if simple then (before, base)
    else
      let temp = "update__base" in
      (before @ [ (temp, base) ], EVar (expr_info base, temp, 0))
  in
  let filled =
    List.map
      (fun parameter ->
        ( Some parameter.name,
          EField (expr_info base, reference, parameter.name, 0) ))
      missing
  in
  let_around info before (rebuild (explicit @ filled))

(** A pattern with every constructor pattern's fields in position: the
    positional ones first, then each named one where its field is, and
    `_` for a field not mentioned.
    signatures -> [denotation] -> pattern -> pattern *)
and pattern_of signatures scope p =
  let go = pattern_of signatures scope in
  match p with
  | PInt _ | PString _ | PChar _ | PBool _ | PWildcard _ | PCapture _ | PText _ -> p
  | PTuple (i, elements, s) -> PTuple (i, List.map go elements, s)
  | PList (i, prefix, rest, suffix, s) ->
      PList (i, List.map go prefix, rest, List.map go suffix, s)
  | POr (i, alternatives, s) -> POr (i, List.map go alternatives, s)
  | PAs (i, inner, name, s) -> PAs (i, go inner, name, s)
  | PConstructor (i, module_, name, positional, named, s) -> (
      let positional = List.map go positional in
      let named = List.map (fun (n, q) -> (n, go q)) named in
      let shown =
        match module_ with Some m -> m ^ "." ^ name | None -> name
      in
      match constructor_reached signatures scope i module_ name with
      | None -> PConstructor (i, module_, name, positional, named, s)
      | Some (meta, _) ->
          let fields = meta.parameters in
          let arity = List.length fields in
          if List.length positional > arity then
            refuse i
              (Printf.sprintf "'%s' has %d field%s, and this pattern matches %d"
                 shown arity
                 (if arity = 1 then "" else "s")
                 (List.length positional));
          List.iter
            (fun (n, q) ->
              match position fields n with
              | None ->
                  refuse (pattern_info q)
                    (Printf.sprintf "'%s' has no field '%s'" shown n)
              | Some at when at < List.length positional ->
                  refuse (pattern_info q)
                    (Printf.sprintf
                       "the field '%s' is already matched by position %d" n
                       (at + 1))
              | Some _ -> ())
            named;
          let filled =
            List.mapi
              (fun at field ->
                if at < List.length positional then List.nth positional at
                else
                  match List.assoc_opt field.name named with
                  | Some q -> q
                  | None -> PWildcard (i, 0))
              fields
          in
          PConstructor (i, module_, name, filled, [], s))

(** The first parameter a call of `given` arguments leaves to its
    default. meta -> int -> String *)
and omitted meta given =
  let explicit = List.filter (fun p -> not p.implicit) meta.parameters in
  match List.filteri (fun at _ -> at >= given) explicit with
  | first :: _ -> first.name
  | [] -> ""

(** One call on an overloaded name. The type checker resolves which
    definition it means, from the argument types -- but it sees the
    arguments this pass leaves, and a default erased here is what lets a
    definition take fewer of them. So the *count* is settled here: one
    definition taking the call by using a default has its defaults
    filled in, and two taking it where one of them needs a default is
    refused, since nothing would say which (docs/overloading.md).
    info -> String -> [(String, meta, String -> expr)]
    -> [(String?, expr)] -> ([(String?, expr)] -> expr) -> expr *)
and overloaded info shown candidates args build =
  let given = List.length (List.filter (fun (name, _) -> name = None) args) in
  if List.exists (fun (name, _) -> name <> None) args then
    refuse info
      (Printf.sprintf
         "an argument of this call to '%s' cannot be named: several \
          definitions of it are in scope, and which one is meant is \
          settled by the argument types -- write the qualified name to \
          say which"
         shown);
  let taking =
    List.filter_map
      (fun (name, meta, reach) ->
        let takes, by_default = takes meta given in
        if takes then Some (name, meta, reach, by_default) else None)
      candidates
  in
  let defaulting = List.filter (fun (_, _, _, by_default) -> by_default) taking in
  if List.length taking > 1 && defaulting <> [] then
    refuse info
      (Printf.sprintf
         "this call to '%s' is ambiguous: %s -- write the qualified name to \
          say which is meant"
         shown
         (String.concat " and "
            (List.map
               (fun (name, meta, _, by_default) ->
                 if by_default then
                   Printf.sprintf "'%s' takes them with its default for '%s'"
                     name (omitted meta given)
                 else Printf.sprintf "'%s' takes them as written" name)
               taking)))
  else
    match taking with
    | [ (name, meta, reach, true) ] -> (
        match ordered info name meta reach args with
        | None -> build (plain_args (arg_exprs args))
        | Some (lets, filled) -> let_around info lets (build (plain_args filled)))
    | _ -> build args

(** Rewrites one block: its definitions are visible throughout it, and
    each one's defaults are generated just before it.
    signatures -> [denotation] -> [stmt] -> [stmt] *)
and block signatures scope stmts =
  let scope =
    List.fold_left
      (fun scope (name, meta) -> SMap.add name (Definition meta) scope)
      scope
      (block_definitions stmts)
  in
  let scope =
    List.fold_left
      (fun scope (name, meta) -> SMap.add name (Constructs meta) scope)
      scope
      (block_constructors stmts)
  in
  let taken = List.concat_map bound_here stmts in
  let _, out =
    List.fold_left
      (fun (scope, out) statement ->
        let generated, statement, scope =
          rewrite signatures scope taken statement
        in
        (scope, out @ generated @ [ statement ]))
      (scope, []) stmts
  in
  out

(** Rewrites one statement, answering with the defs generated for it,
    the statement itself, and the scope it leaves behind.
    signatures -> [denotation] -> [String] -> stmt ->
    ([stmt], stmt, [denotation]) *)
and rewrite signatures scope taken statement =
  let go = expression signatures scope in
  let bind scope statement =
    List.fold_left
      (fun scope name -> SMap.add name Binding scope)
      scope (bound_here statement)
  in
  match statement with
  | SLet (i, target, e, t, s, public, implicit) ->
      let statement = SLet (i, target, go e, t, s, public, implicit) in
      ([], statement, bind scope statement)
  | SLetStmt (i, target, inner, t, s, public) ->
      let _, inner, _ = rewrite signatures scope taken inner in
      let statement = SLetStmt (i, target, inner, t, s, public) in
      ([], statement, bind scope statement)
  | SVar (i, name, e, s) ->
      let statement = SVar (i, name, go e, s) in
      ([], statement, bind scope statement)
  | SMutate (i, name, e, s) -> ([], SMutate (i, name, go e, s), scope)
  | SReturn (i, e, s) -> ([], SReturn (i, go e, s), scope)
  | SReturnStmt (i, inner, s) ->
      let _, inner, _ = rewrite signatures scope taken inner in
      ([], SReturnStmt (i, inner, s), scope)
  | SExprStmt (i, e, s) -> ([], SExprStmt (i, go e, s), scope)
  | SBreak _ | SContinue _ | SFunctionSig _ -> ([], statement, scope)
  | SDatatype (i, name, params, constructors, s, public) ->
      (* A field's default is a generated def, exactly as a parameter's
         is, written just before the datatype. *)
      let generated =
        List.concat_map
          (fun (Constructor (_, cname, fields, _)) ->
            List.filter_map
              (fun (Field (fi, label, type_, default, _)) ->
                match (default, label) with
                | Some e, Some field when inlined type_ e = None ->
                    if public && type_ = None then
                      refuse fi
                        (Printf.sprintf
                           "a default for an exported datatype's field needs \
                            a type unless it is a literal: '%s: Int = ...'"
                           field);
                    let generated = field_default_name cname field in
                    if List.mem generated taken then
                      refuse fi
                        (Printf.sprintf
                           "the default for '%s' needs the name '%s', which \
                            this block already binds"
                           field generated);
                    Some
                      (SFunctionDef
                         ( fi,
                           generated,
                           [],
                           [ SExprStmt (expr_info e, go e, 0) ],
                           type_,
                           0,
                           public,
                           [],
                           false ))
                | _ -> None)
              fields)
          constructors
      in
      let constructors =
        List.map
          (fun (Constructor (ci, cname, fields, cs)) ->
            Constructor
              ( ci,
                cname,
                List.map
                  (fun (Field (fi, label, type_, _, fs)) ->
                    Field (fi, label, type_, None, fs))
                  fields,
                cs ))
          constructors
      in
      (generated, SDatatype (i, name, params, constructors, s, public), scope)
  | SLoop (i, target, init, t, iterate, body, s) ->
      let inner =
        match target with
        | None -> scope
        | Some target ->
            List.fold_left
              (fun scope name -> SMap.add name Binding scope)
              scope
              (List.map fst (Analyses.target_names target))
      in
      let inner =
        match iterate with
        | Some (ForIn (_, name, _, _)) -> SMap.add name Binding inner
        | _ -> inner
      in
      let iterate =
        match iterate with
        | Some (ForIn (fi, name, sequence, fs)) ->
            Some (ForIn (fi, name, go sequence, fs))
        | Some (WhileTest (wi, condition, ws)) ->
            Some (WhileTest (wi, expression signatures inner condition, ws))
        | None -> None
      in
      ( [],
        SLoop
          ( i,
            target,
            Option.map go init,
            t,
            iterate,
            block signatures inner body,
            s ),
        scope )
  | SIf (i, condition, then_body, else_body, s) ->
      ( [],
        SIf
          ( i,
            go condition,
            block signatures scope then_body,
            Option.map (block signatures scope) else_body,
            s ),
        scope )
  | SMatch (i, subject, cases, s) ->
      ( [],
        SMatch
          ( i,
            go subject,
            List.map
              (fun (MatchCase (ci, pattern, guard, body, cs)) ->
                let inner =
                  List.fold_left
                    (fun scope (name, _) -> SMap.add name Binding scope)
                    scope
                    (Analyses.pattern_bindings pattern)
                in
                MatchCase
                  ( ci,
                    pattern_of signatures scope pattern,
                    Option.map (expression signatures inner) guard,
                    block signatures inner body,
                    cs ))
              cases,
            s ),
        scope )
  | SImport _ ->
      let statement = imported signatures statement in
      ([], statement, import_scope signatures statement scope)
  | SFunctionDef (i, name, params, body, return_type, s, public, implicits, implicit)
    ->
      let generated =
        List.filter_map
          (fun (Param (pi, param, annotation, default, _)) ->
            if default <> None && public && annotation = None then
              refuse pi
                (Printf.sprintf
                   "a default for an exported function's parameter needs a \
                    type: '%s: Int = ...'"
                   param);
            match default with
            | None -> None
            | Some e when inlined annotation e <> None -> None
            | Some e ->
                let generated = default_name name param in
                if List.mem generated taken then
                  refuse pi
                    (Printf.sprintf
                       "the default for '%s' needs the name '%s', which this \
                        block already binds"
                       param generated);
                Some
                  (SFunctionDef
                     ( pi,
                       generated,
                       [],
                       [ SExprStmt (expr_info e, go e, 0) ],
                       annotation,
                       0,
                       public,
                       [],
                       false )))
          params
      in
      let inner =
        List.fold_left
          (fun scope (Param (_, param, _, _, _)) -> SMap.add param Binding scope)
          scope params
      in
      let statement =
        SFunctionDef
          ( i,
            name,
            List.map
              (fun (Param (pi, param, annotation, _, ps)) ->
                Param (pi, param, annotation, None, ps))
              params,
            block signatures inner body,
            return_type,
            s,
            public,
            implicits,
            implicit )
      in
      (generated, statement, scope)

(** An import of a module whose functions carry defaults also brings in
    the defs holding them, so a `from` line reaches them by name.
    signatures -> stmt -> stmt *)
and imported signatures statement =
  match statement with
  | SImport (i, module_, local, true, fields, s) -> (
      match SMap.find_opt module_ signatures with
      | None -> statement
      | Some info_ ->
          (* A datatype brings its constructors, which are public with
             it, and each constructor the defs holding its defaults. *)
          let constructors =
            List.concat_map
              (fun (name, _) ->
                match SMap.find_opt name info_.datatypes with
                | Some names -> List.filter (fun n -> n <> name) names
                | None -> [])
              fields
          in
          let defaults_of meta =
            List.filter_map
              (fun parameter ->
                match parameter.default with
                | Some (Generated generated) -> Some generated
                | _ -> None)
              meta.parameters
          in
          let extra =
            constructors
            @ List.concat_map
                (fun name ->
                  match
                    ( SMap.find_opt name info_.functions,
                      SMap.find_opt name info_.constructors )
                  with
                  | _, Some meta when meta.exported -> defaults_of meta
                  | Some meta, _ when meta.exported -> defaults_of meta
                  | _ -> [])
                (List.map fst fields @ constructors)
          in
          let extra =
            List.filter (fun name -> not (List.mem_assoc name fields)) extra
          in
          SImport
            ( i,
              module_,
              local,
              true,
              fields @ List.map (fun name -> (name, name)) extra,
              s ))
  | statement -> statement

(* --- the entry point --- *)

(** Rewrites one module's statements, removing every default parameter
    and every named argument, and answers with what the next module may
    then use. signatures -> String -> [stmt] -> ([stmt], signatures) *)
let desugar signatures name stmts =
  (* A module already known under this name is one being extended an
     entry at a time, which is what the prompt does: what it defined
     before is in scope for what it defines now. *)
  let known, known_constructors, known_datatypes, before, imported =
    match SMap.find_opt name signatures with
    | Some info_ ->
        ( info_.functions,
          info_.constructors,
          info_.datatypes,
          info_.others,
          info_.imports )
    | None -> (SMap.empty, SMap.empty, SMap.empty, SSet.empty, [])
  in
  let scope =
    SMap.fold
      (fun name meta scope -> SMap.add name (Definition meta) scope)
      known SMap.empty
  in
  let scope =
    SMap.fold
      (fun name meta scope -> SMap.add name (Constructs meta) scope)
      known_constructors scope
  in
  (* What earlier entries bound to something that is not a definition is
     in scope too, and turns the sugar off for that name exactly as a
     binding written in this one does. *)
  let scope =
    SSet.fold (fun name scope -> SMap.add name Binding scope) before scope
  in
  let scope =
    List.fold_left
      (fun scope statement -> import_scope signatures statement scope)
      scope (imported @ stmts)
  in
  let out = block signatures scope stmts in
  let definitions = block_definitions stmts in
  let functions =
    List.fold_left
      (fun functions (name, meta) -> SMap.add name meta functions)
      known definitions
  in
  let others =
    List.fold_left
      (fun others bound ->
        if List.mem_assoc bound definitions then SSet.remove bound others
        else SSet.add bound others)
      before
      (List.concat_map bound_here stmts)
  in
  (* A name redefined as a `def` is a definition again, and one rebound
     to anything else stops being one. *)
  let functions =
    SMap.filter (fun name _ -> not (SSet.mem name others)) functions
  in
  let imports =
    imported
    @ List.filter (function SImport _ -> true | _ -> false) stmts
  in
  let constructors =
    List.fold_left
      (fun constructors (name, meta) -> SMap.add name meta constructors)
      known_constructors (block_constructors stmts)
  in
  let datatypes =
    List.fold_left
      (fun datatypes (name, names) -> SMap.add name names datatypes)
      known_datatypes (block_datatypes stmts)
  in
  ( out,
    SMap.add name
      { functions; constructors; datatypes; others; foreign = false; imports }
      signatures )
