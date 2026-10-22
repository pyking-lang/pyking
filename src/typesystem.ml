(** The type checker, in a functional style, over one module -- or a
    whole one-file program, which is the same thing. A function whose
    type was not written down is worked out the first time something
    calls it, from its own body: its parameters go in as metavariables
    and the body's demands solve them, which is Hindley-Milner's rule
    reached without a constraint solver. See docs/typesystem.md and
    docs/type_inference.md.

    `type_check stmts sigmaps` is the entry point: it answers the table
    mapping each node's symbol to the type worked out for it, and raises
    Type_error for the first thing that does not check out.

    One function per AST datatype -- `check_stmts`, `check_stmt`,
    `check_expr`, `check_param`, `same_type` -- each taking a node of
    exactly that type and answering exactly one kind of answer. No
    function here dispatches on which *sort* of node it was handed.

    Nothing in this module changes anything. An environment, a store, a
    type: each is handed on, extended by being rebuilt, and left alone
    by whoever passed it. `tmap`, the pass's result, is a field of the
    store, which is threaded and handed back everywhere already -- so
    "a function given a store returns one" covers the result as well.

    Data structures:
      Type_error -- a type failure, with the source position.
      env -- a name's type, in scope; a name not in it is not in scope.
      sigmap -- what one module exports, and at what type.
      given -- one `return`, or the value a body ends in.
      frame -- what the current inference has gathered.
      expected -- what a `return` is checked against.
      store -- everything inference has worked out, threaded as a value.

    Functions:
      type_check stmts sigmaps -- checks a whole module; answers its tmap.
      check_stmts / check_stmt / check_expr / check_param -- one per
        AST datatype.
      same_type a b / accepts expected actual -- type comparison.
      unify one other store -- the store in which two types are one.
      declare_functions stmts env store -- binds every def of a block.
      declare_datatypes stmts store -- the datatypes a module declares
        and imports.
      check_matches stmts store -- refuses a non-exhaustive `match`.
      builtin_env () -- the environment a program starts in.
      available module info store -- what a module exports, or a refusal.
      check_exports stmts store -- refuses an export whose type the
        source does not write down.
      zonk type_ store -- a type read back through what was solved. *)

open Lexer
open Syntax

(** A type-check failure, or a refusal of an unsupported construct, with
    the source position. *)
exception Type_error of info * string

module SMap = Map.Make (String)

(* What a name denotes: its type, and whether the binding was written
   `implicit` -- which is what an implicit argument may be resolved to
   and what an ordinary name never is (PYKING.md, "Implicits"). *)
type binding = { btype : typ; bimplicit : bool }

(* `env` maps a name to what it denotes, and to nothing else: a name it
   does not hold is a name that is not in scope. The host operations are
   in it under TBuiltin, which is a type like any other here -- see
   `check_builtin_call`, which is what a call to one is checked by. *)
type env = binding SMap.t

(** What one module exports, at what type, and whether it is implicit --
    all of it another module sees (Module.make_sigmap). *)
type sigmap = (string * typ * bool) list

(** What one node denotes once overloading and implicits are resolved. *)
type resolution =
  | Call of (string * typ) option * argument list
      (* a call: the name overload resolution chose for it and that
         definition's type (None where the source named it outright),
         and one argument per implicit parameter, in order *)
  | Adapted of typ * int * argument list
      (* an argument whose implicit parameters are not the ones wanted:
         a lambda of that type stands in its place, passing the first
         `int` of its own parameters to what was written and then these
         (docs/implicits.md) *)

and argument =
  | Direct of string * typ
      (* a name in scope, used at this type *)
  | Wrapped of string * typ * int * argument list
      (* a lambda of that function type, passing the first `int` of its
         own parameters to the name and then these -- what a function
         whose implicit parameters are not the ones wanted needs, in
         either direction (docs/implicits.md) *)

(* --- building types ---
   The Python leaves the symbol, and a function type's two inference
   fields, to the dataclass defaults. These say the same thing once. *)

let t_int info = TInt (info, 0)
let t_float info = TFloat (info, 0)
let t_string info = TString (info, 0)
let t_bool info = TBool (info, 0)
let t_list info element = TList (info, element, 0)
let t_tuple info elements = TTuple (info, elements, 0)
let t_unknown info = TUnknown (info, 0)
let t_builtin info name = TBuiltin (info, name, 0)
let t_var info name = TVar (info, name, 0, true)
let t_meta info name = TVar (info, name, 0, false)
let t_function ?(implicits = []) info params result =
  TFunction (info, params, result, 0, 0, None, implicits)
let t_forall info vars body = TForall (info, vars, body, 0)

(** The type a definition has once its implicit parameters are ordinary
    ones: what every stage after `elaborate.ml` sees of it. typ -> typ *)
let rec without_implicits type_ =
  match type_ with
  | TForall (info, vars, body, sym) ->
      TForall (info, vars, without_implicits body, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          params @ List.map (fun (IParam (_, t)) -> t) implicits,
          result,
          sym,
          tmsym,
          definition,
          [] )
  | type_ -> type_

(** How many parameters a function type takes, counting an implicit one
    like any other; 0 for anything that is not a function. typ -> int *)
let arity type_ =
  match type_ with
  | TFunction (_, params, _, _, _, _, implicits) ->
      List.length params + List.length implicits
  | _ -> 0

(** The types of a list of implicit parameters, in order.
    [implicit_param] -> [typ] *)
let implicit_types implicits = List.map (fun (IParam (_, t)) -> t) implicits

(** The names of a list of implicit parameters, in order.
    [implicit_param] -> [string] *)
let implicit_names implicits = List.map (fun (IParam (n, _)) -> n) implicits

(** implicits with each type replaced by f of it.
    (typ -> typ) -> [implicit_param] -> [implicit_param] *)
let map_implicits f implicits =
  List.map (fun (IParam (n, t)) -> IParam (n, f t)) implicits

(** The unit type, (), an empty tuple type. info -> typ *)
let unit_type info = t_tuple info []

(** Whether t is the unit type. typ -> bool *)
let is_unit t = match t with TTuple (_, [], _) -> true | _ -> false

(* The source position a TBuiltin carries, since a builtin is written in
   no file. *)
let builtin_info = { file = "<builtin>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(* Where a block with no statements at all is said to be. *)
let empty_info = { file = "<empty>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** One `return` in the body being inferred, or the value its body ends
    in: where it is written, and what it gives. *)
type given = { given_info : info; given_type : typ }

(** What the current inference has gathered: the `return`s the body
    being worked out has shown so far. *)
type frame = { returns : given list }

(** What a `return` is checked against: the declared type of the
    function whose body is being checked, `Inferring` while one is being
    worked out, and `No_function` at the top level, where a `return` has
    nothing to return from. *)
type expected = No_function | Inferring | Declared of typ

(** Everything inference has worked out, threaded through the pass as a
    value.

    environments -- where each definition was written, by its symbol; a
      deferred body is checked in its own scope, never the call site's.
    instances -- what each definition was worked out to be. A cache, and
      what makes mutual recursion terminate.
    checking -- the definitions whose bodies are being checked right
      now, which is what stops the walk going round for ever.
    frame -- what this inference has gathered.
    signatures -- a `def`'s type where the source wrote it on a line of
      its own (`def foo : (a) -> a`), keyed by the definition's symbol.
      Given rather than worked out, and here so that reaching it costs
      no new parameter on every function that might need it.
    fresh -- how many metavariables have been handed out.
    solutions -- what each metavariable was worked out to be, or nothing
      where it is still open. One is never re-solved, so this only
      grows.
    groups -- the `def`s of the block each definition was written in,
      keyed by its symbol. They may name each other, so they are worked
      out together and generalised together. Given, like signatures.
    captured -- metavariables a definition could not generalise because
      the scope it was written in already held them. One left open at
      the end is a type Pyking cannot write down, so it prints as none
      at all rather than as a variable claiming to be anyone's to
      choose.
    modules -- the signature of every module this one imports: the whole
      of what one module can see of another. Given, like signatures.
    tmap -- symbol -> the type worked out for that node: the pass's
      result.
    qmap -- a call's symbol -> what that call denotes, once overloading
      and implicits are resolved: the pass's other result, and what
      elaborate.ml rewrites the program by.
    types -- each datatype name in scope, as the source spells it
      (`Tree`, `m.Tree`), and the canonical name the checker's types use.
    datatypes -- every datatype this module can see, by canonical name,
      with its parameters and its constructors' field types.
    constructors -- each constructor in scope, as the source spells it,
      and the canonical name of the datatype it builds.
    field_defaults -- each field written with no type, by the name of the
      def holding its default: the metavariable standing for its type
      until that def is reached, and the field's name. *)
type store = {
  environments : env IntMap.t;
  instances : typ IntMap.t;
  checking : IntSet.t;
  frame : frame;
  signatures : typ IntMap.t;
  fresh : int;
  solutions : typ SMap.t;
  groups : stmt list IntMap.t;
  captured : StringSet.t;
  modules : (string * sigmap) list;
  tmap : typ IntMap.t;
  qmap : resolution IntMap.t;
  types : string SMap.t;
  datatypes : datatype SMap.t;
  constructors : string SMap.t;
  field_defaults : (typ * string) SMap.t;
}

(** The store a program starts checking in, holding the signature of
    every module it imports. [(string, sigmap)] -> store *)
let empty_store sigmaps =
  {
    environments = IntMap.empty;
    instances = IntMap.empty;
    checking = IntSet.empty;
    frame = { returns = [] };
    signatures = IntMap.empty;
    fresh = 0;
    solutions = SMap.empty;
    groups = IntMap.empty;
    captured = StringSet.empty;
    modules = sigmaps;
    tmap = IntMap.empty;
    qmap = IntMap.empty;
    types = SMap.empty;
    datatypes = SMap.empty;
    constructors = SMap.empty;
    field_defaults = SMap.empty;
  }

(* The names a generalised variable is given, in order: a, b, ... z,
   a1, ... *)
let letters = "abcdefghijklmnopqrstuvwxyz"

(* What a construct nothing here has reasoned about is refused with. *)
let unsupported_message = "Construct is not supported"

(** Raises Type_error refusing a node at this position. info -> 'a *)
let unsupported info = raise (Type_error (info, unsupported_message))

(** A type as an error message names it, with nothing left to solve.
    typ -> string *)
let printed type_ = pprint_type default_config type_

(** A type as an error message names it, parenthesised where a bare
    function type would read wrongly beside other text. typ -> string *)
let printed_nested type_ = pprint_type_nested default_config type_

(* --- metavariables ---

   A metavariable is a type the checker has not worked out yet, and is
   `TVar` with `rigid = false` -- the same node a written `a` uses, told
   apart by that one field. The two are exact opposites, which is why
   one constructor serves both: a rigid variable is a type the *caller*
   chose, so a body may assume nothing about it; a metavariable is a
   type *this* check is still choosing, so anything may still be assumed
   of it.

   Its name is `?n`, unwritable in source, and its solution lives in
   `store.solutions` rather than in the node -- so a type is a value
   like every other type here, and what has been worked out is one more
   thing the store carries. `zonk` is what reads a solution back. *)

(** A metavariable nothing has solved, and the store that handed it out.
    info -> store -> (typ, store) *)
let fresh_meta info store =
  ( t_meta info (Printf.sprintf "?%d" store.fresh),
    { store with fresh = store.fresh + 1 } )

(** `count` metavariables, and the store that handed them out.
    int -> info -> store -> ([typ], store) *)
let fresh_metas count info store =
  let rec go n made store =
    if n = 0 then (List.rev made, store)
    else
      let one, store = fresh_meta info store in
      go (n - 1) (one :: made) store
  in
  go count [] store

(** When a metavariable was handed out, from its name. Older is smaller.
    string -> int *)
let meta_age name = int_of_string (String.sub name 1 (String.length name - 1))

(** Whether this type is a metavariable -- something this check is still
    choosing, as against a rigid variable its caller chose.
    typ -> bool *)
let is_meta type_ =
  match type_ with TVar (_, _, _, rigid) -> not rigid | _ -> false

(** store with the metavariable `name` solved to type_. Nothing is ever
    re-solved: `unify` looks through a solved variable rather than
    binding it again. store -> string -> typ -> store *)
let solving store name type_ =
  { store with solutions = SMap.add name type_ store.solutions }

(** type_ with its *outermost* constructor settled: a metavariable that
    has been solved is replaced by its solution, as far as that goes.
    Cheap, and enough for deciding which case a type is.
    typ -> store -> typ *)
let prune type_ store =
  let rec go type_ seen =
    match type_ with
    | TVar (_, name, _, false) ->
        if StringSet.mem name seen then type_
        else (
          match SMap.find_opt name store.solutions with
          | None -> type_
          | Some answer -> go answer (StringSet.add name seen))
    | type_ -> type_
  in
  go type_ StringSet.empty

(** type_ with every metavariable in it replaced by what it was solved
    to, as deep as the solutions go. This is what turns a type the
    checker was still working on into one it can report.
    typ -> store -> typ *)
let rec zonk type_ store =
  let type_ = prune type_ store in
  match type_ with
  | TList (info, element, sym) -> TList (info, zonk element store, sym)
  | TTuple (info, elements, sym) ->
      TTuple (info, List.map (fun e -> zonk e store) elements, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          List.map (fun p -> zonk p store) params,
          zonk result store,
          sym,
          tmsym,
          definition,
          map_implicits (fun t -> zonk t store) implicits )
  | TForall (info, vars, body, sym) ->
      (* A variable this scheme binds may share its name with one a
         solution inside it brings in -- an enclosing definition's,
         generalised after this one was -- which would then be read as
         this scheme's own. Such a variable is renamed first. *)
      let arriving = solution_names body store in
      let taken = StringSet.union arriving (rigid_names body) in
      let renamed, _ =
        List.fold_left
          (fun (renamed, taken) v ->
            if not (StringSet.mem v arriving) then (renamed @ [ (v, v) ], taken)
            else
              let rec pick n =
                let candidate = v ^ string_of_int n in
                if StringSet.mem candidate taken then pick (n + 1) else candidate
              in
              let fresh = pick 2 in
              (renamed @ [ (v, fresh) ], StringSet.add fresh taken))
          ([], taken) vars
      in
      let body =
        if List.for_all (fun (v, w) -> v = w) renamed then body
        else rename_rigid body renamed
      in
      TForall (info, List.map snd renamed, zonk body store, sym)
  | TCon (info, name, args, sym) ->
      TCon (info, name, List.map (fun a -> zonk a store) args, sym)
  | TData (info, Datatype (name, params, constructors), sym) ->
      (* A field written with no type is a metavariable its default
         solves. *)
      TData
        ( info,
          Datatype
            ( name,
              params,
              List.map
                (fun (cname, fields) ->
                  (cname, List.map (fun (label, t) -> (label, zonk t store)) fields))
                constructors ),
          sym )
  | type_ -> type_

(** The rigid variables named in a type, solutions not looked through.
    typ -> StringSet.t *)
and rigid_names type_ =
  match type_ with
  | TVar (_, name, _, true) -> StringSet.singleton name
  | TList (_, e, _) -> rigid_names e
  | TTuple (_, es, _) | TCon (_, _, es, _) ->
      List.fold_left (fun s e -> StringSet.union s (rigid_names e)) StringSet.empty es
  | TFunction (_, ps, r, _, _, _, _) ->
      List.fold_left (fun s e -> StringSet.union s (rigid_names e)) (rigid_names r) ps
  | TForall (_, _, b, _) -> rigid_names b
  | _ -> StringSet.empty

(** The rigid variables the solutions of a type's metavariables bring in.
    typ -> store -> StringSet.t *)
and solution_names type_ store =
  let rec walk seen t =
    match t with
    | TVar (_, name, _, false) -> (
        if StringSet.mem name seen then StringSet.empty
        else
          match SMap.find_opt name store.solutions with
          | None -> StringSet.empty
          | Some answer ->
              StringSet.union (rigid_names answer) (walk (StringSet.add name seen) answer))
    | TList (_, e, _) -> walk seen e
    | TTuple (_, es, _) | TCon (_, _, es, _) ->
        List.fold_left (fun s e -> StringSet.union s (walk seen e)) StringSet.empty es
    | TFunction (_, ps, r, _, _, _, _) ->
        List.fold_left (fun s e -> StringSet.union s (walk seen e)) (walk seen r) ps
    | TForall (_, _, b, _) -> walk seen b
    | _ -> StringSet.empty
  in
  walk StringSet.empty type_

(** type_ with each rigid variable `renamed` names given its new name.
    typ -> [(string, string)] -> typ *)
and rename_rigid type_ renamed =
  match type_ with
  | TVar (info, name, sym, true) -> (
      match List.assoc_opt name renamed with
      | Some fresh -> TVar (info, fresh, sym, true)
      | None -> type_)
  | TList (i, e, s) -> TList (i, rename_rigid e renamed, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (fun e -> rename_rigid e renamed) es, s)
  | TCon (i, c, es, s) -> TCon (i, c, List.map (fun e -> rename_rigid e renamed) es, s)
  | TFunction (i, ps, r, a, b, c, d) ->
      TFunction (i, List.map (fun e -> rename_rigid e renamed) ps, rename_rigid r renamed, a, b, c, d)
  | TForall (i, vs, b, s) ->
      let inner = List.filter (fun (v, _) -> not (List.mem v vs)) renamed in
      TForall (i, vs, rename_rigid b inner, s)
  | type_ -> type_

(** Every metavariable name left unsolved in type_, in the order met and
    without repeats. typ -> store -> [string] *)
let metas_in type_ store =
  let rec walk found t =
    match prune t store with
    | TVar (_, name, _, false) ->
        if List.mem name found then found else found @ [ name ]
    | TList (_, element, _) -> walk found element
    | TTuple (_, elements, _) -> List.fold_left walk found elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk
          (List.fold_left walk found (params @ implicit_types implicits))
          result
    | TForall (_, _, body, _) -> walk found body
    | TCon (_, _, args, _) -> List.fold_left walk found args
    | _ -> found
  in
  walk [] type_

(** Whether the metavariable `name` appears inside type_. Solving it to a
    type that mentions it would build an infinite type, which is what
    this refuses. string -> typ -> store -> bool *)
let occurs name type_ store = List.mem name (metas_in type_ store)

(** The variables type_ leaves free, in the order written and without
    repeats. typ -> [string] *)
let free_vars_under type_ bound =
  let rec walk found bound t =
    match t with
    | TVar (_, name, _, _) ->
        if StringSet.mem name bound || List.mem name found then found
        else found @ [ name ]
    | TForall (_, vars, body, _) ->
        walk found
          (List.fold_left (fun b v -> StringSet.add v b) bound vars)
          body
    | TList (_, element, _) -> walk found bound element
    | TTuple (_, elements, _) ->
        List.fold_left (fun found e -> walk found bound e) found elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk
          (List.fold_left
             (fun found p -> walk found bound p)
             found
             (params @ implicit_types implicits))
          bound result
    | TCon (_, _, args, _) ->
        List.fold_left (fun found a -> walk found bound a) found args
    | _ -> found
  in
  walk [] bound type_

let free_vars type_ = free_vars_under type_ StringSet.empty

(** type_ with each variable `mapping` names replaced. A nested `all`
    shadows what it binds. typ -> [(string, typ)] -> typ *)
let rec substitute type_ mapping =
  match type_ with
  | TVar (_, name, _, _) -> (
      match List.assoc_opt name mapping with
      | Some replacement -> replacement
      | None -> type_)
  | TForall (info, vars, body, sym) ->
      let inner = List.filter (fun (k, _) -> not (List.mem k vars)) mapping in
      TForall (info, vars, substitute body inner, sym)
  | TList (info, element, sym) -> TList (info, substitute element mapping, sym)
  | TTuple (info, elements, sym) ->
      TTuple (info, List.map (fun e -> substitute e mapping) elements, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          List.map (fun p -> substitute p mapping) params,
          substitute result mapping,
          sym,
          tmsym,
          definition,
          map_implicits (fun t -> substitute t mapping) implicits )
  | TCon (info, name, args, sym) ->
      TCon (info, name, List.map (fun a -> substitute a mapping) args, sym)
  | type_ -> type_

(** type_ with the variables `vars` renamed to their positions, so that
    two types differing only in the names they bind compare equal.
    typ -> [string] -> typ *)
let canonical type_ vars =
  let info = type_info type_ in
  substitute type_
    (List.mapi (fun i name -> (name, t_var info (Printf.sprintf "%%%d" i))) vars)

(** Every type-variable name written anywhere in type_, bound or free. A
    name a new variable picks has to avoid all of them, not just the free
    ones: reusing one an inner `all` binds would shadow it, and the
    printed signature would read as saying something else.
    typ -> StringSet.t *)
let rec names_in type_ =
  match type_ with
  | TVar (_, name, _, _) -> StringSet.singleton name
  | TForall (_, vars, body, _) ->
      List.fold_left (fun s v -> StringSet.add v s) (names_in body) vars
  | TList (_, element, _) -> names_in element
  | TTuple (_, elements, _) ->
      List.fold_left
        (fun s e -> StringSet.union s (names_in e))
        StringSet.empty elements
  | TFunction (_, params, result, _, _, _, _) ->
      List.fold_left
        (fun s p -> StringSet.union s (names_in p))
        (names_in result) params
  | TCon (_, _, args, _) ->
      List.fold_left
        (fun s a -> StringSet.union s (names_in a))
        StringSet.empty args
  | _ -> StringSet.empty

(** The index'th type-variable name that is not already spoken for.
    int -> StringSet.t -> string *)
let rec next_name index taken =
  let name =
    Printf.sprintf "%c%s"
      letters.[index mod 26]
      (if index < 26 then "" else string_of_int (index / 26))
  in
  if StringSet.mem name taken then next_name (index + 1) taken else name

(** A type's quantified variables and its body; a type with no `all` on
    it answers ([], itself). typ -> ([string], typ) *)
let instantiated type_ =
  match type_ with TForall (_, vars, body, _) -> (vars, body) | _ -> ([], type_)

(** A written type with its free variables quantified, or the type
    itself when it has none. typ -> typ *)
let generalize type_ =
  match free_vars type_ with
  | [] -> type_
  | variables -> t_forall (type_info type_) variables type_

(** One use of a polymorphic type: its outermost `all` stripped and every
    variable it bound replaced by a fresh metavariable. A type with no
    `all` on it is its own only use.

    This is where a definition serves two callers at two types, and it is
    also what stops inference ever producing a higher rank: an argument
    arrives here as its instances rather than as the `all` itself, so no
    `all` can be carried into a parameter type the checker is working
    out. typ -> store -> (typ, store) *)
let instantiate type_ store =
  match type_ with
  | TForall (info, vars, body, _) ->
      let metas, store = fresh_metas (List.length vars) info store in
      (substitute body (List.combine vars metas), store)
  | type_ -> (type_, store)

(** type_ with the metavariables nothing solved named `a`, `b`, ... A
    metavariable is not a type anyone can write, but one left open
    stands for a type nothing decided -- which is what a variable says,
    and which is what `[]` on its own is worth. typ -> store -> typ *)
let displayed type_ store =
  match metas_in type_ store with
  | [] -> type_
  | open_metas ->
      let taken = names_in type_ in
      let _, chosen =
        List.fold_left
          (fun (names, chosen) meta ->
            if StringSet.mem meta store.captured then
              (* An enclosing scope's, so not this type's to name: `?`,
                 which prints as no annotation at all rather than as a
                 variable claiming to be anyone's to choose. *)
              (names, chosen @ [ (meta, t_unknown (type_info type_)) ])
            else
              let name =
                next_name (List.length names)
                  (List.fold_left
                     (fun s n -> StringSet.add n s)
                     taken names)
              in
              ( names @ [ name ],
                chosen @ [ (meta, t_meta (type_info type_) name) ] ))
          ([], []) open_metas
      in
      substitute type_ chosen

(** type_ as an error message should name it: solved as far as the store
    goes, with anything still open named `a`, `b`, ... A metavariable's
    own name is bookkeeping and must never reach a message.
    typ -> store -> string *)
let shown type_ store = printed (displayed (zonk type_ store) store)

(** `shown`, parenthesised where a bare function type would read wrongly
    beside other text. typ -> store -> string *)
let shown_nested type_ store =
  printed_nested (displayed (zonk type_ store) store)

(* --- comparing types --- *)

(** Whether two types are the same type, structurally -- never OCaml's
    own equality, since a type node carries an info and a symbol that
    also differ. typ -> typ -> bool *)
let rec same_type a b =
  match (a, b) with
  | TInt _, TInt _
  | TFloat _, TFloat _
  | TString _, TString _
  | TBool _, TBool _ ->
      true
  | TBuiltin (_, x, _), TBuiltin (_, y, _) ->
      (* Each host operation is its own type, and no two of them are the
         same one. *)
      x = y
  | TUnknown _, TUnknown _ ->
      (* Two types nothing has decided are the same lack of a decision. *)
      true
  | TList (_, x, _), TList (_, y, _) -> same_type x y
  | TTuple (_, xs, _), TTuple (_, ys, _) ->
      List.length xs = List.length ys && List.for_all2 same_type xs ys
  | TFunction (_, ps, r, _, _, _, mine), TFunction (_, qs, s, _, _, _, theirs)
    ->
      (* A function *is* its parameters and its result. The other two
         fields -- the symbol of the definition it came from and that
         definition -- say what is left to do about it, which is not part
         of what it means. Its implicit parameters are: they are matched
         by name as well as by type, since the name is half of what
         resolves one (PYKING.md, "Implicits"). *)
      List.length ps = List.length qs
      && List.for_all2 same_type ps qs
      && same_implicits mine theirs
      && same_type r s
  | TVar (_, x, _, true), TVar (_, y, _, true) ->
      (* A variable is rigid: inside a body it stands for a type the
         caller picked, so it is the same type as itself and nothing
         else. That is the whole of what makes a polymorphic body
         honest -- no substitution is needed to enforce it. *)
      x = y
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) ->
      (* A flexible one is not named by the source, so what tells two
         apart is which handing-out made them. A flexible and a rigid
         variable are never the same type, whatever they are called. *)
      mine = theirs
  | TForall (_, mine, my_body, _), TForall (_, theirs, their_body, _) ->
      (* Two polytypes are one type when they differ only in the names
         they bind, so both are renamed by position first. *)
      List.length mine = List.length theirs
      && same_type (canonical my_body mine) (canonical their_body theirs)
  | TCon (_, x, xs, _), TCon (_, y, ys, _) ->
      (* A datatype is its name, which the checker has made canonical,
         applied to its parameters. *)
      x = y && List.length xs = List.length ys && List.for_all2 same_type xs ys
  | _ -> false

(** Whether two lists of implicit parameters are the same, name by name
    and type by type. [implicit_param] -> [implicit_param] -> Bool *)
and same_implicits mine theirs =
  List.length mine = List.length theirs
  && List.for_all2
       (fun (IParam (a, x)) (IParam (b, y)) -> a = b && same_type x y)
       mine theirs

let is_forall type_ = match type_ with TForall _ -> true | _ -> false

(** Whether a value of type actual may be used where expected is wanted,
    deciding nothing: this is `same_type` plus the one place a scheme is
    used at an instance of itself.

    Where a type is still open, `unify` is what answers instead --
    `accepts` is for the two places nothing may be solved: an annotation
    the source wrote, and `verified`'s re-check with the variables
    rigid. typ -> typ -> bool *)
let rec accepts expected actual =
  match (expected, actual) with
  | TForall (_, _, body, _), _ when not (is_forall actual) ->
      (* The outermost `all` of a written annotation says the type is
         polymorphic; whether a value is, is decided by the body with
         its variables rigid. *)
      accepts body actual
  | _, TForall (_, vars, body, _) when not (is_forall expected) ->
      (* The other way round: a polymorphic value stands wherever one of
         its instances is wanted, since every instance of it exists. *)
      instance_for body expected
        (List.fold_left (fun s v -> StringSet.add v s) StringSet.empty vars)
        []
      <> None
  | _ -> same_type expected actual

(** The bindings that make `general` -- the body of a polymorphic type --
    into `wanted`, or None where no instantiation of it does. One way and
    with no solver, exactly as a call is decided: a variable is settled
    the first time it is met and has to agree with every later meeting. A
    `?` in `wanted` is a demand nothing has made yet, so it decides
    nothing and refuses nothing.
    typ -> typ -> StringSet.t -> [(string, typ)] -> [(string, typ)] option *)
and instance_for general wanted quantified chosen =
  let each mine theirs chosen =
    List.fold_left2
      (fun answer one other ->
        match answer with
        | None -> None
        | Some chosen -> instance_for one other quantified chosen)
      (Some chosen) mine theirs
  in
  match wanted with
  | TUnknown _ -> Some chosen
  | _ -> (
      match (general, wanted) with
      | TVar (_, name, _, _), _ when StringSet.mem name quantified -> (
          match List.assoc_opt name chosen with
          | None -> Some ((name, wanted) :: chosen)
          | Some earlier ->
              if same_type earlier wanted then Some chosen else None)
      | TList (_, element, _), TList (_, other, _) ->
          instance_for element other quantified chosen
      | TTuple (_, mine, _), TTuple (_, theirs, _)
        when List.length mine = List.length theirs ->
          each mine theirs chosen
      | TCon (_, x, mine, _), TCon (_, y, theirs, _)
        when x = y && List.length mine = List.length theirs ->
          each mine theirs chosen
      | ( TFunction (_, mine, my_result, _, _, _, my_implicits),
          TFunction (_, theirs, their_result, _, _, _, their_implicits) )
        when List.length mine = List.length theirs
             && implicit_names my_implicits = implicit_names their_implicits
        -> (
          match
            each
              (mine @ implicit_types my_implicits)
              (theirs @ implicit_types their_implicits)
              chosen
          with
          | None -> None
          | Some chosen ->
              instance_for my_result their_result quantified chosen)
      | _ -> if accepts general wanted then Some chosen else None)

(* --- unification --- *)

(** The store in which these two types are the same type, or None where
    no solution makes them so.

    First-order and eager: it is called at the places a type is demanded
    -- a call's arguments, an operator's operands, two branches -- and it
    answers there and then. Nothing is remembered for later, which is
    what keeps it local (docs/type_inference.md, "Unification, and how
    little of it there is"). typ -> typ -> store -> store option *)
let rec unify one other store =
  let one, other = (prune one store, prune other store) in
  match (one, other) with
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) when mine = theirs ->
      Some store
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) ->
      (* Two metavariables, one type: the *younger* is solved to the
         older. Which way round matters, and only here. A metavariable
         handed out earlier may belong to an enclosing scope, and solving
         that one to a fresh inner variable would lose exactly the fact
         that stops a nested `def` generalising its enclosing function's
         parameter (see `generalise`). Names count upwards, so the order
         they were handed out in is the order of their names. *)
      if meta_age mine <= meta_age theirs then Some (solving store theirs one)
      else Some (solving store mine other)
  | TVar (_, name, _, false), _ ->
      if occurs name other store then None else Some (solving store name other)
  | _, TVar (_, name, _, false) ->
      if occurs name one store then None else Some (solving store name one)
  | TList (_, mine, _), TList (_, theirs, _) -> unify mine theirs store
  | TTuple (_, mine, _), TTuple (_, theirs, _)
    when List.length mine = List.length theirs ->
      unify_each mine theirs store
  | TCon (_, x, mine, _), TCon (_, y, theirs, _)
    when x = y && List.length mine = List.length theirs ->
      unify_each mine theirs store
  | ( TFunction (_, mine, my_result, _, _, _, my_implicits),
      TFunction (_, theirs, their_result, _, _, _, their_implicits) )
    when List.length mine = List.length theirs
         && implicit_names my_implicits = implicit_names their_implicits -> (
      match unify_each mine theirs store with
      | None -> None
      | Some store -> (
          match
            unify_each
              (implicit_types my_implicits)
              (implicit_types their_implicits)
              store
          with
          | None -> None
          | Some store -> unify my_result their_result store))
  | TForall (_, mine, my_body, _), TForall (_, theirs, their_body, _)
    when List.length mine = List.length theirs ->
      unify_under mine my_body theirs their_body store
  (* Everything else -- two ground types, two rigid variables -- is
     decided by `same_type`: there is nothing to solve, so either they
     already are one type or no solution makes them one. *)
  | _ -> if same_type one other then Some store else None

(** The store in which each of these types is the one beside it, or None
    where no solution makes them so.
    [typ] -> [typ] -> store -> store option *)
and unify_each mine theirs store =
  List.fold_left2
    (fun answer x y ->
      match answer with None -> None | Some store -> unify x y store)
    (Some store) mine theirs

(** The store in which two schemes are one scheme: both binders are
    renamed to the same fresh rigid variables and the bodies unified, so
    a metavariable inside either is solved rather than compared. None
    where no solution makes them one, or where one would let a bound
    variable escape (docs/type_inference.md, "Unifying under a
    quantifier").
    [string] -> typ -> [string] -> typ -> store -> store option *)
and unify_under mine my_body theirs their_body store =
  let free =
    List.fold_left
      (fun s name -> StringSet.add name s)
      (List.fold_left
         (fun s name -> StringSet.add name s)
         StringSet.empty (metas_in my_body store))
      (metas_in their_body store)
  in
  let info = type_info my_body in
  (* `!` is unwritable in source, so these collide with no name a
     program could have chosen. *)
  let shared_names =
    List.init (List.length mine) (fun i ->
        Printf.sprintf "!%d" (store.fresh + i))
  in
  let shared = List.map (fun name -> t_var info name) shared_names in
  let store = { store with fresh = store.fresh + List.length mine } in
  match
    unify
      (substitute my_body (List.combine mine shared))
      (substitute their_body (List.combine theirs shared))
      store
  with
  | None -> None
  | Some answer ->
      (* A metavariable free before the two met belongs to a scope where
         these variables mean nothing, so one solved to a type naming
         them would name a type nobody there can name. *)
      let bound =
        List.fold_left (fun s name -> StringSet.add name s) StringSet.empty
          shared_names
      in
      if
        StringSet.exists
          (fun meta ->
            List.exists
              (fun loose -> StringSet.mem loose bound)
              (free_vars (zonk (t_meta info meta) answer)))
          free
      then None
      else Some answer

(** The store in which `actual` is `wanted`, or a Type_error saying what
    wanted it. This is how a construct asks for a type: `unify` where the
    answer is still open, an ordinary comparison where it is not, and one
    message either way. typ -> typ -> info -> string -> store -> store *)
let demand actual wanted info what store =
  match unify wanted actual store with
  | Some answer -> answer
  | None ->
      raise
        (Type_error
           ( info,
             Printf.sprintf "%s must be %s, not %s" what (shown wanted store)
               (shown actual store) ))

(** The store in which `actual` is a list, and the type of its elements.
    typ -> info -> string -> store -> (typ, store) *)
let demand_list actual info what store =
  let element, store = fresh_meta info store in
  (element, demand actual (t_list info element) info what store)

(* --- what the store records --- *)

(** store recording where the definition tmsym was written.
    store -> int -> env -> store *)
let with_environment store tmsym env =
  { store with environments = IntMap.add tmsym env store.environments }

(** Where tmsym was written, or None. store -> int -> env option *)
let environment_of store tmsym = IntMap.find_opt tmsym store.environments

(** What tmsym was worked out to be, or None if nothing has called it
    yet. A definition is worked out once, so there is at most one.
    store -> int -> typ option *)
let instance_of store tmsym = IntMap.find_opt tmsym store.instances

(** store with tmsym's worked-out type recorded.
    store -> int -> typ -> store *)
let remembering store tmsym type_ =
  { store with instances = IntMap.add tmsym type_ store.instances }

(** store with tmsym's body marked as being checked.
    store -> int -> store *)
let checking_now store tmsym =
  { store with checking = IntSet.add tmsym store.checking }

(** store recording the type a `def name : type` line gave the definition
    sym. store -> int -> typ -> store *)
let with_signature store sym type_ =
  { store with signatures = IntMap.add sym type_ store.signatures }

(** store gathering into a different frame. store -> frame -> store *)
let with_frame store frame = { store with frame }

(** store whose frame has seen a `return` at info giving type_.
    store -> info -> typ -> store *)
let returning store info type_ =
  with_frame store
    { returns = store.frame.returns @ [ { given_info = info; given_type = type_ } ] }

(** store with what an inner check found out (environments, instances,
    solutions, and the result tables) merged in; frame and checking stay
    store's own. A solution is knowledge like the others: a metavariable
    is handed out once, so no two checks can disagree about one.
    store -> store -> store *)
let learned store inner =
  {
    store with
    environments = inner.environments;
    instances = inner.instances;
    fresh = inner.fresh;
    solutions = inner.solutions;
    groups = inner.groups;
    captured = StringSet.union store.captured inner.captured;
    tmap = inner.tmap;
    (* `qmap` is a result exactly as `tmap` is, so it comes back for the
       same reason: a call resolved while a deferred definition's body
       was being worked out is resolved once, and dropping it here would
       leave `elaborate.ml` with nothing to rewrite that call by. *)
    qmap = inner.qmap;
  }

(** store with what this call denotes recorded under its symbol. Like
    `record` it overwrites: a generalisable body is checked twice, and
    `verified`'s pass is the one that counts.
    store -> int -> resolution -> store *)
let record_resolution store sym answer =
  { store with qmap = IntMap.add sym answer store.qmap }

(* How deep a chain of implicits resolving implicits may go before it is
   called a mistake rather than a program. *)
let max_implicit_depth = 32

(** store with a node's type recorded, with every metavariable in it
    replaced by what it was solved to. Overwrites: a body checked twice
    -- once to work it out and once to verify -- reports the second
    answer. store -> int -> typ -> store *)
let record store sym type_ =
  { store with tmap = IntMap.add sym (zonk type_ store) store.tmap }

(* --- ground types, and the tables that name them --- *)

(** The ground types the operator and builtin tables name. *)
type kind = KInt | KFloat | KString | KBool | KList | KTuple | KData

(** Whether a type is of this kind, deciding nothing.
    kind -> typ -> bool *)
let kind_matches kind type_ =
  match (kind, type_) with
  | KInt, TInt _
  | KFloat, TFloat _
  | KString, TString _
  | KBool, TBool _
  | KList, TList _
  | KTuple, TTuple _
  | KData, TCon _ ->
      true
  | _ -> false

(** The type a kind names. Only the atoms are ever built: KList and
    KTuple appear in the builtins' rules, which compare rather than
    construct. kind -> info -> typ *)
let kind_type kind info =
  match kind with
  | KInt -> t_int info
  | KFloat -> t_float info
  | KString -> t_string info
  | KBool -> t_bool info
  | KList -> t_list info (t_unknown info)
  | KTuple -> t_tuple info []
  | KData -> t_tuple info []

(** Whether type_ is one of kinds. A flexible variable counts as any of
    them, since no value of it arrives. typ -> [kind] -> bool *)
let every type_ kinds =
  List.exists (fun kind -> kind_matches kind type_) kinds || is_meta type_

(* One row per operand type an operator accepts, paired with what it is
   then worth. PYKING.md, "Operators", is the table this implements. *)

(** The rows `+ - * /` share. Int comes first, and being first is what
    decides an operand nothing else has: see docs/type_inference.md,
    "Two numeric types, no type classes". [(kind, kind)] *)
let arithmetic = [ (KInt, KInt); (KFloat, KFloat) ]

(** The rows `< <= > >=` share. Both answer Bool, so an operand nothing
    has decided is left open rather than defaulted -- which is what `==`
    already does. [(kind, kind)] *)
let ordering = [ (KInt, KBool); (KFloat, KBool) ]

(** An operator's spelling and its rows, or None for an expression that
    is not one. expr -> (string, [(kind, kind)]) option *)
let operator_of expr =
  match expr with
  | EAdd _ -> Some ("+", arithmetic)
  | EConcat _ -> Some ("++", [ (KString, KString) ])
  | ESub _ -> Some ("-", arithmetic)
  | EMul _ -> Some ("*", arithmetic)
  | EDiv _ -> Some ("/", arithmetic)
  | ELessThan _ -> Some ("<", ordering)
  | ELessThanEq _ -> Some ("<=", ordering)
  | EGreatThan _ -> Some (">", ordering)
  | EGreatThanEq _ -> Some (">=", ordering)
  | EEq _ ->
      Some
        ( "==",
          [ (KInt, KBool); (KFloat, KBool); (KString, KBool); (KBool, KBool) ] )
  | _ -> None

(** The two operands of a binary operator application.
    expr -> (expr, expr) option *)
let binary_operands expr =
  match expr with
  | EAdd (_, left, right, _)
  | EConcat (_, left, right, _)
  | ESub (_, left, right, _)
  | EMul (_, left, right, _)
  | EDiv (_, left, right, _)
  | ELessThan (_, left, right, _)
  | ELessThanEq (_, left, right, _)
  | EGreatThan (_, left, right, _)
  | EGreatThanEq (_, left, right, _)
  | EEq (_, left, right, _) ->
      Some (left, right)
  | _ -> None

(* The two operators that are easy to write for one another: `+` adds
   and `++` joins, and neither accepts what the other does. Each names
   the other when a mismatch is exactly the swap -- and only then, so
   `1 + 'a'`, which no operator would take, is not offered a
   suggestion. *)

(** The "did you mean" clause for an operator written where its
    look-alike belongs, or "" when there is nothing to suggest.
    expr -> typ -> typ -> string *)
let alternative expr left_type right_type =
  let suggest rows description =
    if
      List.exists
        (fun (operand, _) ->
          kind_matches operand left_type && kind_matches operand right_type)
        rows
    then Printf.sprintf ". Did you mean %s?" description
    else ""
  in
  let mixed_numbers =
    (kind_matches KInt left_type && kind_matches KFloat right_type)
    || (kind_matches KFloat left_type && kind_matches KInt right_type)
  in
  if mixed_numbers then
    ". Pyking mixes no numbers on its own: `float(n)` makes an Int a Float, \
     and `int(x)` truncates a Float to an Int"
  else
    match expr with
    | EAdd _ ->
        suggest [ (KString, KString) ] "`++`, the concatenation operator"
    | EConcat _ -> suggest [ (KInt, KInt) ] "`+`"
    | _ -> ""

(** The Type_error for an operator applied to what it does not accept,
    naming what it does.
    expr -> string -> [(kind, kind)] -> typ -> typ -> store -> exn *)
let operator_error expr spelling rows left_type right_type store =
  let info = expr_info expr in
  let accepted =
    String.concat " or "
      (List.map
         (fun (operand, _) ->
           let name = printed (kind_type operand info) in
           Printf.sprintf "%s %s %s" name spelling name)
         rows)
  in
  let accepted =
    match expr with
    | EConcat _ -> accepted ^ " or two lists of one type"
    | _ -> accepted
  in
  let together =
    displayed
      (t_tuple info [ zonk left_type store; zonk right_type store ])
      store
  in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (left_type, right_type)
  in
  Type_error
    ( info,
      Printf.sprintf "`%s` cannot be applied to %s and %s; it accepts %s%s"
        spelling (printed mine) (printed theirs) accepted
        (alternative expr (zonk left_type store) (zonk right_type store)) )

(* --- agreement --- *)

(** The one type two branches both have, and the store that makes it so,
    or (None, store) where nothing does.

    Two branches of one `if` yield one value, so they are the same type
    -- which `unify` decides, and which is also what settles a base case
    returning `[]` against a branch returning `[1]`: the empty list's
    element is a metavariable, and being one type with `Int` solves it. A
    branch that never falls through is written None and leaves the answer
    to the other one. typ option -> typ option -> store -> (typ option, store) *)
let agree first second store =
  match (first, second) with
  | None, _ -> (second, store)
  | _, None -> (first, store)
  | Some first, Some second -> (
      match unify first second store with
      | None -> (None, store)
      | Some answer -> (Some (zonk first answer), answer))

(** The store in which `actual` supplies what `expected` wants, or None.
    `unify` first -- anything still open is settled by the demand -- and
    `accepts` after it, for the one thing unification does not do: use a
    scheme at an instance of itself.
    typ -> typ option -> store -> store option *)
let satisfies expected actual store =
  match actual with
  (* The statement supplying this never falls through, so no value
     arrives and there is none to be wrong. *)
  | None -> Some store
  | Some actual -> (
      match unify expected actual store with
      | Some answer -> Some answer
      | None ->
          if accepts (zonk expected store) (zonk actual store) then Some store
          else None)

(** Raises Type_error if an if yields one of two different unannotated
    functions (see docs/type_inference.md). typ option -> typ option ->
    info -> () *)
let check_not_conflated then_type else_type info =
  let definition type_ =
    match type_ with
    | Some (TFunction (_, _, _, _, _, Some (SFunctionDef _ as node), _)) ->
        Some node
    | _ -> None
  in
  match (definition then_type, definition else_type) with
  | ( Some (SFunctionDef (_, my_name, _, _, _, my_sym, _, _, _)),
      Some (SFunctionDef (_, their_name, _, _, _, their_sym, _, _, _)) )
    when my_sym <> their_sym ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this 'if' yields one of two functions -- '%s' and '%s' -- and \
                neither says what its type is, so there is no telling which \
                one a later call would be checking. Annotate them, or call \
                them where they are chosen"
               my_name their_name ))
  | _ -> ()

(** The message for a loop body that does not end in the accumulator the
    next turn carries. typ -> typ -> store -> string *)
let carry_error acc_type actual store =
  let together = displayed (t_tuple builtin_info [ acc_type; actual ]) store in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (acc_type, actual)
  in
  Printf.sprintf "this loop carries %s, but its body ends in %s" (printed mine)
    (printed theirs)

(* --- where a block is left --- *)

(** Whether one statement says what happens next on every path through
    it. stmt -> bool *)
let rec ends_here statement =
  match statement with
  | SContinue _ | SBreak _ | SReturn _ | SReturnStmt _ -> true
  | SIf (_, _, then_body, else_body, _) -> (
      match else_body with
      | None -> false
      | Some else_body ->
          ends_every_path then_body && ends_every_path else_body)
  | SMatch (_, _, cases, _) ->
      (* Every `match` matches every value: exhaustive.ml refuses one
         that does not. *)
      List.for_all
        (fun (MatchCase (_, _, _, body, _)) -> ends_every_path body)
        cases
  | _ -> false

(** Whether every path through a loop body says what happens next --
    `continue`, `break` or `return`, or a branching statement whose every
    branch does. An `if` with no `else` has a path that runs neither, so
    it does not. [stmt] -> bool *)
and ends_every_path stmts =
  match List.rev stmts with [] -> false | last :: _ -> ends_here last

(* --- the environment --- *)

(** env with name bound to type_. A fresh map, so shadowing works by
    construction. `implicit` marks a binding an implicit argument may be
    resolved to; every ordinary binding form leaves it alone.
    env -> string -> typ -> env *)
let bind ?(implicit = false) env name type_ =
  SMap.add name { btype = type_; bimplicit = implicit } env

(** The type a name denotes, or None where it is not in scope.
    env -> string -> typ? *)
let type_of env name =
  match SMap.find_opt name env with
  | Some binding -> Some binding.btype
  | None -> None


(* --- datatypes --- *)

(** The part of a canonical datatype name after its module, which is
    what its own module calls it. string -> string *)
let base_name canonical =
  match String.rindex_opt canonical '.' with
  | Some at -> String.sub canonical (at + 1) (String.length canonical - at - 1)
  | None -> canonical

(** A written type with every datatype name in it replaced by the
    canonical one the checker's types use, refusing a name that is not a
    datatype in scope and one applied to the wrong number of types.
    Inside a datatype's own declaration `params` are the only type
    variables there may be. [string]? -> store -> typ -> typ *)
let rec resolved ?params store type_ =
  let go = resolved ?params store in
  match type_ with
  | TCon (info, spelled, args, sym) -> (
      match SMap.find_opt spelled store.types with
      | None ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "unknown type '%s': a type starting with an uppercase \
                    letter is a datatype, and none of that name is declared \
                    or imported here"
                   spelled ))
      | Some canonical ->
          let wanted =
            match SMap.find_opt canonical store.datatypes with
            | Some (Datatype (_, wanted, _)) -> List.length wanted
            | None -> List.length args
          in
          if List.length args <> wanted then
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "'%s' takes %d type parameter%s, but is given %d" spelled
                     wanted
                     (if wanted = 1 then "" else "s")
                     (List.length args) ));
          TCon (info, canonical, List.map go args, sym))
  | TVar (info, name, _, true) -> (
      match params with
      | Some (owner, names) when not (List.mem name names) ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'%s' is not a parameter of '%s': a field's type may name \
                    only the datatype's own type parameters, written \
                    'datatype %s(%s)'"
                   name owner owner
                   (String.concat ", " (names @ [ name ])) ))
      | _ -> type_)
  | TList (info, element, sym) -> TList (info, go element, sym)
  | TTuple (info, elements, sym) -> TTuple (info, List.map go elements, sym)
  | TFunction (info, ps, result, sym, tmsym, definition, implicits) ->
      TFunction
        (info, List.map go ps, go result, sym, tmsym, definition, map_implicits go implicits)
  | TForall (info, vars, body, sym) ->
      let params =
        match params with
        | Some (owner, names) -> Some (owner, names @ vars)
        | None -> None
      in
      TForall (info, vars, resolved ?params store body, sym)
  | _ -> type_

(** A written annotation with its datatype names resolved, where there
    is one. store -> typ? -> typ? *)
let resolved_option store annotation = Option.map (resolved store) annotation

(** store knowing the datatypes these statements declare and the ones
    their imports bring in: every name spelled as the source may spell
    it, every constructor, and each field's type. A datatype's own name
    is in scope throughout the module, so datatypes may name each other
    in any order. [stmt] -> store -> store *)
let declare_datatypes stmts store =
  let add_imported store (exported, local) (Datatype (canonical, _, constructors) as d) =
    let store = { store with datatypes = SMap.add canonical d store.datatypes } in
    let store =
      if base_name canonical = exported then
        { store with types = SMap.add local canonical store.types }
      else store
    in
    if List.mem_assoc exported constructors then
      { store with constructors = SMap.add local canonical store.constructors }
    else store
  in
  let store =
    List.fold_left
      (fun store statement ->
        match statement with
        | SImport (_, module_, alias, selected, fields, _) -> (
            match List.assoc_opt module_ store.modules with
            | None -> store
            | Some sigmap ->
                let entries =
                  List.filter_map
                    (fun (n, t, _) ->
                      match t with TData (_, d, _) -> Some (n, d) | _ -> None)
                    sigmap
                in
                if selected then
                  List.fold_left
                    (fun store (exported, local) ->
                      match List.assoc_opt exported entries with
                      | Some d -> add_imported store (exported, local) d
                      | None -> store)
                    store fields
                else
                  List.fold_left
                    (fun store (exported, d) ->
                      add_imported store (exported, alias ^ "." ^ exported) d)
                    store entries)
        | _ -> store)
      store stmts
  in
  let own =
    List.filter_map
      (function
        | SDatatype (info, name, params, constructors, sym, _) ->
            Some (info, name, params, constructors, sym)
        | _ -> None)
      stmts
  in
  (* The names first, so a field may name any datatype of the module. *)
  let store =
    List.fold_left
      (fun store (info, name, params, _, _) ->
        if SMap.mem name store.types then
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "the datatype '%s' is already declared; a datatype is \
                    declared once"
                   name ));
        {
          store with
          types = SMap.add name name store.types;
          datatypes = SMap.add name (Datatype (name, params, [])) store.datatypes;
        })
      store own
  in
  let store =
    List.fold_left
      (fun store (_, name, _, constructors, _) ->
        List.fold_left
          (fun store (Constructor (ci, cname, _, _)) ->
            (match SMap.find_opt cname store.constructors with
            | Some owner ->
                raise
                  (Type_error
                     ( ci,
                       Printf.sprintf
                         "'%s' is already a constructor of '%s'; a \
                          constructor belongs to one datatype"
                         cname (base_name owner) ))
            | None -> ());
            { store with constructors = SMap.add cname name store.constructors })
          store constructors)
      store own
  in
  List.fold_left
    (fun store (info, name, params, constructors, sym) ->
      let store, typed =
        List.fold_left
          (fun (store, typed) (Constructor (_, cname, fields, csym)) ->
            let store, fields =
              List.fold_left
                (fun (store, fields) (Field (fi, label, type_, _, fsym)) ->
                  let t, store =
                    match (type_, label) with
                    | Some type_, _ -> (resolved ~params:(name, params) store type_, store)
                    | None, Some field ->
                        (* Its default decides it, where its def is
                           written (`check_stmt`). *)
                        let meta, store = fresh_meta fi store in
                        ( meta,
                          {
                            store with
                            field_defaults =
                              SMap.add
                                (Desugar_args.field_default_name cname field)
                                (meta, field) store.field_defaults;
                          } )
                    | None, None -> (t_unknown fi, store)
                  in
                  (record store fsym t, fields @ [ (label, t) ]))
                (store, []) fields
            in
            let store =
              record store csym
                (TCon (info, name, List.map (t_var info) params, 0))
            in
            (store, typed @ [ (cname, fields) ]))
          (store, []) constructors
      in
      let d = Datatype (name, params, typed) in
      let store = { store with datatypes = SMap.add name d store.datatypes } in
      record store sym (TData (info, d, 0)))
    store own

(** What a constructor builds, from how the source spells it: the
    canonical datatype, the constructor's field types and the type of
    the value it makes, with a fresh metavariable for each of the
    datatype's parameters. info -> String -> String -> store ->
    (string, [(String?, typ)], typ, store) *)
let constructor_use info spelled name store =
  match SMap.find_opt spelled store.constructors with
  | None ->
      raise
        (Analyses.Analysis_error
           ( info,
             Printf.sprintf
               "unknown constructor '%s': a name starting with an uppercase \
                letter is a constructor, and no datatype declared or imported \
                here has one of that name"
               spelled ))
  | Some canonical ->
      let (Datatype (_, params, constructors)) =
        SMap.find canonical store.datatypes
      in
      let fields = List.assoc name constructors in
      let metas, store = fresh_metas (List.length params) info store in
      let mapping = List.combine params metas in
      ( canonical,
        List.map (fun (label, t) -> (label, substitute t mapping)) fields,
        TCon (info, canonical, metas, 0),
        store )

(** How a field of a constructor is named in a message: by its name
    where it has one, by its position otherwise.
    String -> int -> String? -> String *)
let field_named constructor position label =
  match label with
  | Some n -> Printf.sprintf "the field '%s' of '%s'" n constructor
  | None -> Printf.sprintf "field %d of '%s'" (position + 1) constructor

(** The environment a program starts in: every name in
    Builtin.names, at its TBuiltin type. Its own function so
    src/repl.ml can reuse it when checking a session one entry at a
    time. () -> env *)
let builtin_env () =
  List.fold_left
    (fun env name -> bind env name (t_builtin builtin_info name))
    SMap.empty Builtin.names

(** What a module exports, or a refusal saying it cannot be reached from
    here at all -- which is what a file checked on its own gets, since no
    module system ran to find it. string -> info -> store -> sigmap *)
let available module_ info store =
  match List.assoc_opt module_ store.modules with
  | Some sigmap -> sigmap
  | None ->
      raise
        (Analyses.Analysis_error
           ( info,
             Printf.sprintf
               "module '%s' cannot be imported here: an import needs the \
                whole program, and this is one file on its own"
               module_ ))

(** env extended with everything a module's imports bring into scope: a
    selected name under the name it is known by here, and a field of a
    plain import under `alias.field`, which is the spelling `EQualified`
    looks up. An import is a declaration of the module rather than a
    statement in its sequence -- like a `def`, all of them are in scope
    throughout it, which is what lets a definition written above an
    import still name what it brings in.
    [stmt] -> env -> store -> env *)
let import_env stmts env store =
  List.fold_left
    (fun env statement ->
      match statement with
      | SImport (info, module_, name, selected, fields, _) ->
          let sigmap = available module_ info store in
          List.fold_left
            (fun env (exported, local) ->
              let _, type_, implicit =
                List.find (fun (n, _, _) -> n = exported) sigmap
              in
              let bound =
                if selected then local else Printf.sprintf "%s.%s" name exported
              in
              match type_ with
              (* A datatype and its constructors are not values; the
                 store's own tables hold them (`declare_datatypes`). *)
              | TData _ -> env
              | _ ->
              (* A public implicit is found by an unqualified call as
                 well, and automatically -- an ordering a module defines
                 is usable in the file that imports it without being
                 named (PYKING.md, "Modules"). It is bound under the one
                 spelling either way, so a resolution always names the
                 module it came from. *)
              bind ~implicit env bound type_)
            env fields
      | _ -> env)
    env stmts

(** Why `module.name` names nothing: either no module is in scope under
    that name, or the one that is does not export it.
    string -> string -> env -> string *)
let unreachable_name module_ name env =
  let prefix = module_ ^ "." in
  let known =
    SMap.exists
      (fun bound _ ->
        String.length bound >= String.length prefix
        && String.sub bound 0 (String.length prefix) = prefix)
      env
  in
  if not known then
    Printf.sprintf
      "unbound name '%s.%s': no module is imported under the name '%s'" module_
      name module_
  else Printf.sprintf "module '%s' does not export '%s'" module_ name

(* --- what a definition says about itself --- *)

(** The type a `def name : type` line gave this definition, already
    quantified, or None where the source wrote none.
    stmt -> store -> typ option *)
let signature_of node store = IntMap.find_opt (stmt_sym node) store.signatures

(** Whether a function definition has its complete type annotated, either
    by a signature line of its own or by an annotation on every parameter
    and the return type. stmt -> store -> bool *)
let fully_annotated node store =
  match signature_of node store with
  | Some _ -> true
  | None -> (
      match node with
      | SFunctionDef (_, _, params, _, return_type, _, _, _, _) ->
          return_type <> None
          && List.for_all (fun (Param (_, _, t, _, _)) -> t <> None) params
      | _ -> false)

(** Refuses a definition that carries implicit parameters, or is itself
    implicit, without writing its whole type down. Resolving an implicit
    argument is a question about types, so there has to be a type to ask
    it of (PYKING.md, "Implicits"). stmt -> store -> () *)
let check_implicit_annotated node store =
  match node with
  | SFunctionDef (info, name, _, _, _, _, _, implicits, implicit)
    when (implicits <> [] || implicit) && not (fully_annotated node store) ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "'%s' is %s, so it needs its whole type written down: \
                annotate every parameter and the return type, or give it a \
                'def %s : ...' signature line"
               name
               (if implicit then "implicit" else "a function with an implicit parameter")
               name ))
  | _ -> ()

(** Refuses a module that exports a name whose type the source does not
    write down.

    A module says what it exports here, in the file that exports it,
    rather than leaving the module that imports it to find out. A `def`
    says its whole type on its own header or on a signature line of its
    own, and an `=` binding says it on its name; what the checker would
    have worked out on its own is not enough, because what crosses the
    boundary is what the source promised.
    [stmt] -> store -> () *)
let check_exports stmts store =
  let incomplete name how =
    Printf.sprintf
      "'%s' is public, and a public function or value needs a complete \
       annotated type signature: %s"
      name how
  in
  List.iter
    (fun statement ->
      match statement with
      | SFunctionDef (info, name, _, _, _, _, true, _, _)
        when not (fully_annotated statement store) ->
          raise
            (Type_error
               ( info,
                 incomplete name
                   (Printf.sprintf
                      "annotate every parameter and the return type, or give \
                       it a 'def %s : ...' signature line."
                      name) ))
      | SLet (info, TargetName (_, name, _), _, None, _, true, _)
      | SLetStmt (info, TargetName (_, name, _), _, None, _, true) ->
          raise
            (Type_error
               ( info,
                 incomplete name
                   (Printf.sprintf "write its type on its name, '%s: Int = \
                                    ...'."
                      name) ))
      | _ -> ())
    stmts

(** Refuses a public definition, binding or datatype whose type names
    one of this module's datatypes that is not public: another module
    could hold such a value but never name its type.
    [stmt] -> store -> () *)
let check_exported_datatypes stmts store =
  let public_types =
    List.filter_map
      (function SDatatype (_, name, _, _, _, true) -> Some name | _ -> None)
      stmts
  in
  let own =
    List.filter_map
      (function SDatatype (_, name, _, _, _, _) -> Some name | _ -> None)
      stmts
  in
  let rec hidden t =
    match t with
    | TCon (_, n, args, _) ->
        if List.mem n own && not (List.mem n public_types) then Some n
        else List.find_map hidden args
    | TList (_, e, _) -> hidden e
    | TTuple (_, es, _) -> List.find_map hidden es
    | TFunction (_, ps, r, _, _, _, ips) ->
        List.find_map hidden (ps @ implicit_types ips @ [ r ])
    | TForall (_, _, b, _) -> hidden b
    | TData (_, Datatype (_, _, constructors), _) ->
        List.find_map
          (fun (_, fields) -> List.find_map (fun (_, t) -> hidden t) fields)
          constructors
    | _ -> None
  in
  List.iter
    (fun statement ->
      let exported =
        match statement with
        | SFunctionDef (info, name, _, _, _, sym, true, _, _)
        | SLet (info, TargetName (_, name, _), _, _, sym, true, _)
        | SLetStmt (info, TargetName (_, name, _), _, _, sym, true)
        | SDatatype (info, name, _, _, sym, true) ->
            Option.map (fun t -> (info, name, t)) (IntMap.find_opt sym store.tmap)
        | _ -> None
      in
      match exported with
      | Some (info, name, t) -> (
          match hidden (zonk t store) with
          | Some datatype ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' is public, and its type names the datatype '%s', \
                        which is not: make '%s' public too, so that a module \
                        holding the value can name its type"
                       name datatype datatype ))
          | None -> ())
      | None -> ())
    stmts

(** node's type, from the signature line that named it or from the
    annotations on its own header, quantified over the type variables it
    leaves free. Raises Type_error if neither says the whole type.
    stmt -> store -> typ *)
let function_type node store =
  match signature_of node store with
  | Some written -> written
  | None -> (
      match node with
      | SFunctionDef (info, name, params, _, return_type, _, _, implicits, _) ->
          let unannotated =
            List.filter_map
              (function Param (_, n, None, _, _) -> Some n | _ -> None)
              params
          in
          if unannotated <> [] || return_type = None then
            let missing =
              String.concat ", "
                (List.map (Printf.sprintf "parameter '%s'") unannotated
                @ if return_type = None then [ "the return type" ] else [])
            in
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "'%s' can only be checked when every parameter and the \
                      return type is annotated; %s is not"
                     name missing ))
          else
            generalize
              (t_function
                 ~implicits:
                   (List.map
                      (fun (Param (_, n, t, _, _)) ->
                        IParam (n, resolved store (Option.get t)))
                      implicits)
                 info
                 (List.map
                    (fun (Param (_, _, t, _, _)) -> resolved store (Option.get t))
                    params)
                 (resolved store (Option.get return_type)))
      | _ -> unsupported (stmt_info node))

(** The type a def has: its annotated types, or TUnknown for the missing
    parts, in which case it carries its own definition so that a call can
    work it out. stmt -> store -> typ *)
let declared_type node store =
  if fully_annotated node store then function_type node store
  else
    match node with
    | SFunctionDef (info, _, params, _, return_type, sym, _, implicits, _) ->
        TFunction
          ( info,
            List.map
              (fun (Param (pinfo, _, t, _, _)) ->
                match t with Some t -> resolved store t | None -> t_unknown pinfo)
              params,
            (match return_type with
            | Some t -> resolved store t
            | None -> t_unknown info),
            0,
            sym,
            Some node,
            List.map
              (fun (Param (pinfo, pname, t, _, _)) ->
                IParam
                  ( pname,
                    match t with
                    | Some t -> resolved store t
                    | None -> t_unknown pinfo ))
              implicits )
    | _ -> unsupported (stmt_info node)

(** Pairs each `def name : type` line of a block with the definition of
    that name in the same block, and records the type it gives it.
    Refuses a signature that names no definition here, a second one for
    one definition, and one whose definition also annotates itself -- a
    `def` says its type in one place or the other, never both.
    [stmt] -> [(string, stmt)] -> store -> store *)
let declare_signatures stmts defined store =
  let _, store =
    List.fold_left
      (fun (seen, store) statement ->
        match statement with
        | SFunctionSig (info, name, written, _, _) -> (
            match List.assoc_opt name defined with
            | None ->
                raise
                  (Type_error
                     ( info,
                       Printf.sprintf
                         "there is no 'def %s' in this block for this \
                          signature to describe"
                         name ))
            | Some node ->
                if List.mem name seen then
                  raise
                    (Type_error
                       ( info,
                         Printf.sprintf
                           "'%s' already has a signature in this block" name ));
                let node_params, node_return =
                  match node with
                  | SFunctionDef (_, _, params, _, return_type, _, _, _, _) ->
                      (params, return_type)
                  | _ -> ([], None)
                in
                let annotated =
                  List.filter_map
                    (function Param (_, n, Some _, _, _) -> Some n | _ -> None)
                    node_params
                in
                if annotated <> [] || node_return <> None then
                  raise
                    (Type_error
                       ( stmt_info node,
                         Printf.sprintf
                           "'%s' has a signature of its own, so its \
                            definition writes no annotations; remove the ones \
                            on %s"
                           name
                           (if annotated <> [] then String.concat ", " annotated
                            else "its return type") ));
                let type_ = generalize (resolved store written) in
                let _, written_type = instantiated type_ in
                (match written_type with
                | TFunction (_, _, _, _, _, _, (IParam (implicit, _) :: _)) ->
                    (* An implicit parameter is written on the `def`
                       header, where the body can name it. A signature
                       line says a type and binds nothing, so one here
                       would name a parameter that does not exist
                       (docs/implicits.md). *)
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "'%s' cannot take the implicit parameter '%s' \
                              on a signature line: an implicit parameter is \
                              written on the 'def' itself, where its body \
                              can name it"
                             name implicit ))
                | TFunction (_, written_params, _, _, _, _, _) ->
                    if List.length written_params <> List.length node_params
                    then
                      raise
                        (Type_error
                           ( info,
                             Printf.sprintf
                               "this signature gives '%s' %d parameter%s, but \
                                its definition takes %d"
                               name (List.length written_params)
                               (if List.length written_params = 1 then ""
                                else "s")
                               (List.length node_params) ))
                | _ ->
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "the signature of '%s' is %s, which is not a \
                              function type"
                             name (printed type_) )));
                (seen @ [ name ], with_signature store (stmt_sym node) type_))
        | _ -> (seen, store))
      ([], store) stmts
  in
  store

(** env with every def of a block bound, and the store recording where
    each deferred one was written. Not recursive: a def inside a branch
    is declared when that branch's block is checked.
    [stmt] -> env -> store -> (env, store) *)
let declare_functions stmts env store =
  let defined = Analyses.block_functions stmts in
  let store = declare_signatures stmts defined store in
  let functions = List.map snd defined in
  let env =
    List.fold_left
      (fun env function_ ->
        match function_ with
        | SFunctionDef (_, name, _, _, _, _, _, _, implicit) ->
            bind ~implicit env name (declared_type function_ store)
        | _ -> env)
      env functions
  in
  let deferred =
    List.filter (fun f -> not (fully_annotated f store)) functions
  in
  let store =
    List.fold_left
      (fun store function_ ->
        let sym = stmt_sym function_ in
        (* Record this environment, so a body reached from a call is
           checked where it was written. And which definitions it is
           worked out *with*: the ones it may name, which is every `def`
           of its own block. See `infer_call`. *)
        let store = with_environment store sym env in
        { store with groups = IntMap.add sym deferred store.groups })
      store deferred
  in
  (env, store)

(* --- the arity and the argument types of a builtin call --- *)

(** Raises Type_error if a call does not pass as many arguments as the
    builtin takes. The bounds are Builtin's, so a variadic one has no
    upper bound and never refuses. string -> info -> int -> () *)
let check_builtin_arity name info given =
  match Builtin.lookup name with
  | None -> ()
  | Some builtin ->
      let low = builtin.Builtin.min_args and high = builtin.Builtin.max_args in
      if low <= given && match high with None -> true | Some h -> given <= h
      then ()
      else
        let expected =
          match high with
          | None -> Printf.sprintf "at least %d" low
          | Some h when h = low -> string_of_int low
          | Some h -> Printf.sprintf "%d to %d" low h
        in
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' takes %s argument%s, but %d %s given" name
                 expected
                 (if high = Some 1 then "" else "s")
                 given
                 (if given = 1 then "was" else "were") ))

(** The Type_error for a builtin argument of the wrong type.
    string -> expr -> typ -> string -> exn *)
let builtin_argument_error name argument actual accepted =
  Type_error
    ( expr_info argument,
      Printf.sprintf "'%s' cannot be applied to %s; it accepts %s" name
        (printed actual) accepted )

(** The Type_error for an argument that does not match the declared
    parameter type. The two are named together, so a variable standing in
    both reads as the same letter in both.
    int -> typ -> typ -> expr -> store -> exn *)
let argument_error position actual expected arg store =
  let info = expr_info arg in
  let together =
    displayed (t_tuple info [ zonk actual store; zonk expected store ]) store
  in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (actual, expected)
  in
  Type_error
    ( info,
      Printf.sprintf "argument %d has type %s, but %s was expected" position
        (printed_nested mine) (printed_nested theirs) )

(** The single type every way out of a body gives, and the store that
    makes them one. Each is unified with the ones before it, so a base
    case returning `[]` settles against a branch returning `[Int]`; two
    that cannot be one type are refused at the later one. At least one is
    required. [given] -> string -> store -> (typ, store) *)
let one_type given name store =
  match given with
  | [] -> invalid_arg "one_type: nothing given"
  | first :: rest ->
      List.fold_left
        (fun (worth, store) later ->
          match agree (Some worth) (Some later.given_type) store with
          | Some both, store -> (both, store)
          | None, store ->
              raise
                (Type_error
                   ( later.given_info,
                     Printf.sprintf
                       "'%s' gives %s on one path, but %s on this one; a \
                        function has one return type"
                       name (shown worth store)
                       (shown later.given_type store) )))
        (first.given_type, store) rest

(** Every metavariable still open in the types an environment binds.
    These are the ones a definition written there may *not* generalise:
    they belong to something enclosing it, which has already been given
    them by its own caller. env -> store -> StringSet.t *)
let free_metas env store =
  (* A field whose type its default has not decided yet belongs to the
     whole module, as a name the environment binds does. *)
  let fields =
    SMap.fold
      (fun _ (type_, _) found ->
        List.fold_left
          (fun found meta -> StringSet.add meta found)
          found (metas_in type_ store))
      store.field_defaults StringSet.empty
  in
  SMap.fold
    (fun _ binding found ->
      List.fold_left
        (fun found meta -> StringSet.add meta found)
        found (metas_in binding.btype store))
    env fields

(** The scheme a definition has: its worked-out type, with every
    metavariable the body left unsolved bound by one `all` at the top.

    Unsolved means the body never had to decide it, which is exactly what
    a type variable stands for -- so this is Hindley-Milner's
    generalisation step, and what it produces is the principal type.

    Except for `outer`, the metavariables the scope it was written in
    already holds. A `def` inside another `def` may not generalise the
    enclosing function's parameter: whoever called *that* chose it, and a
    scheme promising otherwise would be a promise the body cannot keep.
    This is Hindley-Milner's "not free in the environment" side
    condition, and it is the one place generalisation is unsound without
    a rule rather than merely imprecise.

    Only at the top: a metavariable is a type, never a scheme, so no
    `all` can appear inside one of these.
    stmt -> typ -> StringSet.t -> store -> typ *)
let generalise ?(avoid = StringSet.empty) node mono outer store =
  let settled = zonk mono store in
  let open_metas =
    List.filter
      (fun meta -> not (StringSet.mem meta outer))
      (metas_in settled store)
  in
  if open_metas = [] then settled
  else
    let taken = StringSet.union avoid (names_in settled) in
    let info = stmt_info node in
    let names, chosen =
      List.fold_left
        (fun (names, chosen) meta ->
          let name =
            next_name (List.length names)
              (List.fold_left (fun s n -> StringSet.add n s) taken names)
          in
          (names @ [ name ], chosen @ [ (meta, t_var info name) ]))
        ([], []) open_metas
    in
    t_forall info names (substitute settled chosen)

(** One `(?a, ?b, ...) -> ?r` per definition in the group, all of whose
    variables are fresh. These are what the group's names mean while its
    bodies are checked. [stmt] -> store -> ([typ], store) *)
let monotypes_for group store =
  List.fold_left
    (fun (monotypes, store) node ->
      match node with
      | SFunctionDef (info, _, params, _, return_type, _, _, _, _) ->
          (* A parameter the source annotated means what it says: a
             metavariable stands only where nothing was written. *)
          let params, store =
            List.fold_left
              (fun (types, store) param ->
                match param with
                | Param (_, _, Some written, _, _) ->
                    (types @ [ resolved store written ], store)
                | Param (at, _, None, _, _) ->
                    let metas, store = fresh_metas 1 at store in
                    (types @ metas, store))
              ([], store) params
          in
          let result, store =
            match return_type with
            | Some written -> (resolved store written, store)
            | None ->
                let metas, store = fresh_metas 1 info store in
                (match metas with [ meta ] -> (meta, store) | _ -> (t_unknown info, store))
          in
          (monotypes @ [ t_function info params result ], store)
      | _ -> (monotypes, store))
    ([], store) group

(** store in which the body of node supplies `wanted`. Raises Type_error
    where nothing makes it so -- which, since `wanted` is this
    inference's own metavariable, means the body's own ways out
    disagreed. store -> typ -> typ option -> stmt -> store *)
let required store wanted supplied node =
  match supplied with
  (* Nothing ever comes out of this body: every way through it is a
     `break`, a `continue`, or a loop that never ends. Whatever the
     caller wants of it is fine. *)
  | None -> store
  | Some supplied -> (
      match unify wanted supplied store with
      | Some answer -> answer
      | None ->
          let name =
            match node with
            | SFunctionDef (_, name, _, _, _, _, _, _, _) -> name
            | _ -> "?"
          in
          raise
            (Type_error
               ( stmt_info node,
                 Printf.sprintf
                   "'%s' has to return %s, but its body ends in a value of \
                    type %s"
                   name (shown wanted store) (shown supplied store) )))

(** Every name a body reads. Used to find which definitions of a block
    name each other, so only those are worked out as one.
    [stmt] -> StringSet.t *)
let names_used body =
  Walk.fold_stmts
    (fun names node ->
      match node with
      | Walk.NExpr (EVar (_, name, _)) -> StringSet.add name names
      | _ -> names)
    StringSet.empty body

(** The definitions worked out together with node: the ones in its block
    that it and they mutually depend on -- its strongly connected
    component in the block's call graph.

    Only those. A sibling node merely *calls* is worked out and
    generalised first, on demand, so it is polymorphic by the time this
    body uses it; grouping it in here instead would hold it to one type
    for the whole group, which is the difference between `let`-bound and
    lambda-bound in Hindley-Milner and the reason `id` may serve two
    types inside one caller. stmt -> store -> [stmt] *)
let inference_group node store =
  let sym = stmt_sym node in
  let block =
    match IntMap.find_opt sym store.groups with
    | Some group -> group
    | None -> [ node ]
  in
  let siblings =
    List.filter
      (fun other ->
        instance_of store (stmt_sym other) = None
        && not (IntSet.mem (stmt_sym other) store.checking))
      block
  in
  if not (List.exists (fun other -> stmt_sym other = sym) siblings) then [ node ]
  else
    let name_of other =
      match other with
      | SFunctionDef (_, name, _, _, _, _, _, _, _) -> name
      | _ -> ""
    in
    let body_of other =
      match other with
      | SFunctionDef (_, _, _, body, _, _, _, _, _) -> body
      | _ -> []
    in
    let calls =
      List.map
        (fun other ->
          let used = names_used (body_of other) in
          ( stmt_sym other,
            List.filter_map
              (fun sibling ->
                if StringSet.mem (name_of sibling) used then
                  Some (stmt_sym sibling)
                else None)
              siblings ))
        siblings
    in
    let reaches start =
      let rec go seen waiting =
        match waiting with
        | [] -> seen
        | one :: rest ->
            let next =
              match List.assoc_opt one calls with Some ns -> ns | None -> []
            in
            let fresh_ones =
              List.filter (fun n -> not (IntSet.mem n seen)) next
            in
            go
              (List.fold_left (fun s n -> IntSet.add n s) seen fresh_ones)
              (fresh_ones @ rest)
      in
      go IntSet.empty [ start ]
    in
    let forward = IntSet.add sym (reaches sym) in
    List.filter
      (fun other ->
        let theirs = stmt_sym other in
        IntSet.mem theirs forward
        && IntSet.mem sym (IntSet.add theirs (reaches theirs)))
      siblings

(** What a deferred function turned out to be, once something has worked
    it out. A definition is worked out once, so from the second call on
    it is an ordinary scheme, read back through whatever has since been
    solved.

    The type is pruned first, so a definition reached through a
    metavariable that has since been solved to it -- a function put in a
    list and taken out again -- is seen for what it is rather than for
    the variable it arrived in. typ -> store -> typ *)
let settled_type func_type store =
  let func_type = prune func_type store in
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _), _) -> (
      match instance_of store tmsym with
      | Some instance -> zonk instance store
      | None -> func_type)
  | _ -> func_type

(* --- reading a definition's parts ---
   The Python reaches these as dataclass attributes. A definition is
   always an SFunctionDef where these are used; the other cases are
   unreachable and answer with nothing. *)

let def_name node =
  match node with SFunctionDef (_, name, _, _, _, _, _, _, _) -> name | _ -> ""

(** The implicit parameters of a definition, or none for anything else.
    stmt -> [param] *)
let def_implicits node =
  match node with
  | SFunctionDef (_, _, _, _, _, _, _, implicits, _) -> implicits
  | _ -> []

let def_params node =
  match node with SFunctionDef (_, _, params, _, _, _, _, _, _) -> params | _ -> []

let def_body node =
  match node with SFunctionDef (_, _, _, body, _, _, _, _, _) -> body | _ -> []

let param_name (Param (_, name, _, _, _)) = name
let param_sym (Param (_, _, _, _, sym)) = sym

(** Checks a written annotation, if any, against its right-hand side's
    actual type, and answers the store that makes them one. An annotation
    is a *demand*, so a right-hand side still open is settled by it --
    `xs: [Int] = []` says what the empty list holds. The annotation is
    quantified first, since a written type is quantified wherever one is
    written. Raises Type_error at the annotation on a mismatch.
    typ option -> typ -> store -> store *)
let check_annotation annotation actual store =
  match annotation with
  | None -> store
  | Some annotation -> (
      let annotation = generalize (resolved store annotation) in
      match unify annotation (zonk actual store) store with
      | Some answer -> answer
      | None ->
          if accepts annotation (zonk actual store) then store
          else
            raise
              (Type_error
                 ( type_info annotation,
                   Printf.sprintf
                     "this binding is annotated %s, but its value has type %s"
                     (printed_nested annotation) (shown_nested actual store) )))

(** Checks a return's type against return_type, or -- while one is being
    worked out -- collects it into store's frame.
    typ option -> expected -> info -> store -> store *)
let check_return actual return_type info store =
  match actual with
  (* `return loop: continue` -- the statement never falls through, so no
     value is ever returned here. *)
  | None -> store
  | Some actual -> (
      match return_type with
      | Inferring -> returning store info actual
      | No_function -> store
      | Declared declared -> (
          match unify declared actual store with
          | Some answer -> answer
          | None ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "this function returns %s, but this 'return' gives %s"
                       (shown declared store) (shown actual store) ))))

(** The store in which what a pattern matches has the shape the pattern
    looks at. typ -> typ -> info -> store -> store *)
let pattern_shape wanted type_ info store =
  match unify wanted type_ store with
  | Some answer -> answer
  | None ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this pattern matches %s, but it is matched against %s"
               (printed wanted) (shown type_ store) ))

(** What an operator is worth over two operands of type `common`, and the
    store that says so -- (None, store) where the operator does not
    accept it. expr -> typ -> [(kind, kind)] -> store -> (typ option, store) *)
let operator_result expr common rows store =
  let info = expr_info expr in
  match expr with
  | EConcat _ ->
      (* `++` is the one whose result the table cannot state: String ++
         String is String and [a] ++ [a] is [a], so either way it is what
         both operands are -- which is also the answer while nothing has
         decided which of the two this is. *)
      if
        (match common with TString _ | TList _ -> true | _ -> false)
        || is_meta common
      then (Some (zonk common store), store)
      else (None, store)
  | _ ->
      let results =
        List.fold_left
          (fun seen (_, result) ->
            if List.mem result seen then seen else seen @ [ result ])
          [] rows
      in
      if is_meta common then
        match (rows, results) with
        (* One row, so the operands have to be what it says. *)
        | [ (operand, result) ], _ -> (
            match unify (kind_type operand info) common store with
            | Some after -> (Some (kind_type result info), after)
            | None -> (None, store))
        (* Several rows agreeing on the result -- `==` -- so this is
           worth that whichever row it turns out to be, and nothing here
           has to decide which. *)
        | _, [ result ] -> (Some (kind_type result info), store)
        (* Several rows disagreeing about the result -- the arithmetic
           operators, once Float joined them. Nothing here has decided
           the operand, so the table's first row does: an unannotated
           `a + b` is Int arithmetic, and a Float one says so. *)
        | (operand, result) :: _, _ -> (
            match unify (kind_type operand info) common store with
            | Some after -> (Some (kind_type result info), after)
            | None -> (None, store))
        | [], _ -> (None, store)
      else
        match
          List.find_opt (fun (operand, _) -> kind_matches operand common) rows
        with
        | Some (_, result) -> (Some (kind_type result info), store)
        | None -> (None, store)

(* --- the checker itself --- *)

(** Checks a list of statements, either at the top level or as a block.
    `return_type` is what a `return` written in it is checked against and
    `acc_type` what the loop a `break`/`continue` belongs to carries;
    the answer is what the block supplies, which is None for a block that
    does not fall through.
    [stmt] -> env -> expected -> typ option -> store -> (typ option, store) *)
let rec check_stmts stmts env return_type acc_type store =
  (* Bind every function definition of the block first, so that they may
     name each other and themselves. *)
  let env, store = declare_functions stmts env store in
  let start =
    Some
      (unit_type
         (match stmts with [] -> empty_info | first :: _ -> stmt_info first))
  in
  (* A statement extends the environment for the ones after it, so the
     environment is threaded through the sequence as well. *)
  let result, _, _, store, _ =
    List.fold_left
      (fun (result, left, env, store, rest) statement ->
        let rest = match rest with _ :: rest -> rest | [] -> [] in
        let before = env in
        let supplied, env, store =
          check_stmt statement env return_type acc_type store
        in
        let store = if env == before then store else sharpened rest env store in
        if left then
          (* Everything from here on is unreachable: something above said
             what happens next on every path through it. It is still
             checked -- unreachable code is code -- but what the block is
             worth was settled where the block was left. *)
          (result, left, env, store, rest)
        else (supplied, ends_here statement, env, store, rest))
      (start, false, env, store, stmts) stmts
  in
  (result, store)

(** store with every unannotated `def` among `rest` recorded as written
    in `env`: what a body worked out before its `def` is reached sees
    the bindings above it. [stmt] -> env -> store -> store *)
and sharpened rest env store =
  List.fold_left
    (fun store statement ->
      match statement with
      | SFunctionDef _ when environment_of store (stmt_sym statement) <> None ->
          with_environment store (stmt_sym statement) env
      | _ -> store)
    store rest

(** Checks one statement. Answers what it supplies, the environment the
    statements after it should see, and the store.
    stmt -> env -> expected -> typ option -> store -> (typ option, env, store) *)
and check_stmt statement env return_type acc_type store =
  match statement with
  | SLet (info, target, e, annotation, sym, _, implicit) ->
      (* The binding's symbol records what its right-hand side turned out
         to be; the binding *itself* is a statement, so it has unit
         type. *)
      let expr_type_, store = check_expr e env store in
      let store = check_annotation annotation expr_type_ store in
      let expr_type_ = zonk expr_type_ store in
      let store = record store sym expr_type_ in
      let env, store = check_target ~implicit target expr_type_ env store in
      (Some (unit_type info), env, store)
  | SLetStmt (info, target, inner, annotation, sym, _) ->
      (* `x = if c: ...` binds what the branch that runs yields, so the
         bound statement's own type is the binding's type -- and the
         branches having agreed on one is what the `SIf` case below has
         already established. `x = loop ...` binds the accumulator the
         loop stopped with, for the same reason. *)
      let bound_type, _, store =
        check_stmt inner env return_type acc_type store
      in
      let bound_type, store =
        match bound_type with
        | Some bound_type -> (bound_type, store)
        (* Nothing ever arrives here -- a `loop:` with no `break` is the
           only way to write it -- so the name stands for a value of no
           particular type. *)
        | None -> fresh_meta info store
      in
      let store = check_annotation annotation bound_type store in
      let bound_type = zonk bound_type store in
      let store = record store sym bound_type in
      let env, store = check_target target bound_type env store in
      (Some (unit_type info), env, store)
  | SImport (info, module_, _, _, _, _) ->
      (* What an import brings in was settled before the first statement
         was checked (see `import_env`), so there is nothing left to do
         here and nothing it is worth. Asking again is how a caller that
         checks statements one at a time -- the REPL -- is told there is
         no module system running. *)
      ignore (available module_ info store);
      (Some (unit_type info), env, store)
  | SVar (info, name, e, sym) ->
      (* A mutable variable's type is its value's, with no mark of
         mutability on it: a `var` Int is read as an ordinary Int and
         stands wherever one does. Whether this name may be bound here at
         all, and whether a `:=` may name it, is analyses.ml's rule
         rather than a type. *)
      let var_type, store = check_expr e env store in
      let var_type = zonk var_type store in
      let store = record store sym var_type in
      (Some (unit_type info), bind env name var_type, store)
  | SMutate (info, name, e, sym) -> (
      (* A mutation binds nothing and is worth nothing: the name keeps
         the type it was declared with, and the value written into it
         must fit that type. *)
      match type_of env name with
      | None ->
          raise
            (Analyses.Analysis_error
               (info, Printf.sprintf "unbound name '%s'" name))
      | Some declared -> (
          let actual, store = check_expr e env store in
          match satisfies declared (Some actual) store with
          | None ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf "'%s' is %s, but this ':=' gives %s" name
                       (shown declared store) (shown actual store) ))
          | Some store ->
              let store = record store sym declared in
              (Some (unit_type info), env, store)))
  | SExprStmt (_, e, _) ->
      (* An expression statement has its expression's type. That is what
         lets a block yield a value, and so what makes the two branches
         of an `if` comparable. *)
      let type_, store = check_expr e env store in
      (Some type_, env, store)
  | SIf (info, cond, then_body, else_body, _) -> (
      let cond_type, store = check_expr cond env store in
      let store =
        demand cond_type (t_bool (expr_info cond)) (expr_info cond)
          "the condition of an 'if'" store
      in
      let then_type, then_store =
        check_stmts then_body env return_type acc_type store
      in
      match else_body with
      (* With no `else` there is a way through this statement that runs
         no branch at all, so the `if` supplies nothing whatever the one
         branch it has ends in. A body that needed that value is caught
         where the value was needed -- `check_function` -- rather than
         here. *)
      | None -> (Some (unit_type info), env, then_store)
      | Some else_body ->
          (* The `else` is checked against what the `then` *found out*,
             not against the store they both started from: only one of
             them runs, but both were checked, and what either worked out
             is true whichever way the program goes. *)
          let else_type, else_store =
            check_stmts else_body env return_type acc_type then_store
          in
          if then_type = None && else_type = None then
            (* Neither way through this `if` falls out of it, so neither
               does the `if`. *)
            (None, env, else_store)
          else
            (* A branch that cannot finish -- a loop with no `break` in
               it, or one ending in `break`/`continue` -- leaves the type
               of the `if` to the other one, which is what `agree` does
               with a None side. *)
            let both, else_store = agree then_type else_type else_store in
            if both = None then
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "the branches of this 'if' have different types: %s and \
                        %s"
                       (shown (Option.get then_type) else_store)
                       (shown (Option.get else_type) else_store) ));
            check_not_conflated then_type else_type info;
            (both, env, else_store))
  | SReturn (info, e, _) ->
      (* A `return` supplies the function's value explicitly, so that
         value is what this statement supplies -- which is exactly what
         PYKING.md's tail-position table says of it, and what lets a
         branch that returns sit beside one that ends in an expression
         without either being a special case. *)
      if return_type = No_function then
        raise (Type_error (info, "'return' outside a function"));
      let actual, store = check_expr e env store in
      ( Some actual,
        env,
        check_return (Some actual) return_type (expr_info e) store )
  | SReturnStmt (info, inner, _) ->
      (* `return if c: ...` -- the same rule, against whatever the branch
         that runs yields. *)
      if return_type = No_function then
        raise (Type_error (info, "'return' outside a function"));
      let actual, _, store = check_stmt inner env return_type acc_type store in
      (actual, env, check_return actual return_type info store)
  | SLoop (info, target, init, annotation, iterate, body, sym) ->
      (* The accumulator is what the initializer turned out to be, and
         the loop carries exactly that from turn to turn -- and is worth
         exactly that when it stops, however it stops. A loop with none
         written carries unit and is worth unit. *)
      let accumulator, body_env, store =
        match target with
        | None -> (unit_type info, env, store)
        | Some target ->
            let init =
              match init with Some init -> init | None -> unsupported info
            in
            let accumulator, store = check_expr init env store in
            let store = check_annotation annotation accumulator store in
            let accumulator = zonk accumulator store in
            let body_env, store = check_target target accumulator env store in
            (accumulator, body_env, store)
      in
      let store = record store sym accumulator in
      let turn_env, store = check_iteration iterate env body_env store in
      let supplied, store =
        check_turn body turn_env return_type accumulator store
      in
      (* What the body ends in is what the next turn carries, so it is
         held to the accumulator's type -- unless the body always jumps,
         and then nothing arrives at the end of it to be held to
         anything. A loop carrying nothing asks nothing of its body:
         there is no next accumulator for it to give. An accumulator that
         starts as `[]` starts as `[?e]`, and what the body ends in is
         what solves it. *)
      let store =
        match (target, supplied) with
        | Some _, Some supplied_type_ ->
            let last = List.nth body (List.length body - 1) in
            let both, store = agree (Some accumulator) supplied store in
            if both = None then
              raise
                (Type_error
                   ( stmt_info last,
                     carry_error (zonk accumulator store)
                       (zonk supplied_type_ store) store ));
            store
        | _ -> store
      in
      (Some (zonk accumulator store), env, store)
  | SBreak (info, _) ->
      (* A `break` ends the loop, which is then worth the accumulator
         this turn started with -- so there is nothing to check. The
         statement supplies *nothing*: it never falls through, so no
         value arrives after it. That is None rather than a type, and it
         is what lets a branch that breaks sit beside one that ends in
         the next accumulator: `agree` keeps the other branch's
         answer. *)
      if acc_type = None then
        raise (Type_error (info, "'break' outside a loop"));
      (None, env, store)
  | SContinue (info, _) ->
      (* `continue` starts the next turn with the accumulator unchanged,
         which is that type whatever it is. Nothing arrives after it
         either, so it supplies nothing too. *)
      if acc_type = None then
        raise (Type_error (info, "'continue' outside a loop"));
      (None, env, store)
  | SMatch (info, subject, cases, sym) ->
      (* Every arm is a branch, and they must agree on one type the way
         an `if`'s two do -- one value leaves a `match` however many ways
         in there are. Each arm is checked in the environment its own
         pattern binds, and against what the arms before it worked
         out. *)
      let subject_type, store = check_expr subject env store in
      let yielded, seen, store =
        List.fold_left
          (fun (yielded, seen, store)
               (MatchCase (case_info, pattern, guard, body, _)) ->
            let inner, store = check_pattern pattern subject_type env store in
            (* A guard is asked once the pattern has matched, so it sees
               what the pattern binds. *)
            let store =
              match guard with
              | None -> store
              | Some g ->
                  let g_type, store = check_expr g inner store in
                  demand g_type (t_bool (expr_info g)) (expr_info g)
                    "the guard of a 'case'" store
            in
            let arm_type, store =
              check_stmts body inner return_type acc_type store
            in
            if not seen then (arm_type, true, store)
            else if yielded = None || arm_type = None then
              (* An arm that never falls through leaves what the `match`
                 is worth to the arms that do. *)
              let yielded, store = agree yielded arm_type store in
              (yielded, seen, store)
            else
              let both, store = agree yielded arm_type store in
              if both = None then
                raise
                  (Type_error
                     ( case_info,
                       Printf.sprintf
                         "the arms of this 'match' have different types: %s \
                          and %s"
                         (shown (Option.get yielded) store)
                         (shown (Option.get arm_type) store) ));
              check_not_conflated yielded arm_type case_info;
              (both, seen, store))
          (None, false, store) cases
      in
      if not seen then (* No arms at all. *)
        (Some (unit_type info), env, store)
      else if yielded = None then
        (* No arm falls through, so neither does the `match`. *)
        (None, env, store)
      else
        let store = record store sym (Option.get yielded) in
        (* Every `match` matches every value -- exhaustive.ml refuses one
           that does not -- so it supplies what its arms do. *)
        (yielded, env, store)
  | SDatatype (info, _, _, _, _, _) ->
      (* What a datatype declares was settled before the first statement
         was checked (`declare_datatypes`), since every datatype of the
         module is in scope throughout it. *)
      (Some (unit_type info), env, store)
  | SFunctionSig (info, _, _, _, _) ->
      (* The signature was paired with its definition before this block
         was checked (`declare_signatures`); on its own it says nothing
         and produces nothing. *)
      (Some (unit_type info), env, store)
  | SFunctionDef (info, name, _, _, _, sym, _, _, implicit) ->
      check_implicit_annotated statement store;
      if fully_annotated statement store then
        (* Checked against its annotations here; visible under its own
           name only to the statements that follow. *)
        let supplied, store = check_function statement env store in
        ( supplied,
          bind ~implicit env name (function_type statement store),
          store )
      else
        (* Not fully annotated: there is nothing to check yet, because
           what an unannotated parameter is depends on what is passed to
           it. All this statement does is fix *where* the function was
           written, since that is the scope its body belongs to however
           far away it is eventually called from. The name is already
           bound, by `declare_functions`, and the binding names the
           definition by symbol -- so recording the environment here is
           what every holder of that name sees. *)
        let store = with_environment store sym env in
        match SMap.find_opt name store.field_defaults with
        | None -> (Some (unit_type info), env, store)
        | Some (field_type, field) ->
            (Some (unit_type info), env, field_default info name field_type field env store)

(** The store in which the field whose default the def `name` holds has
    that default's type. Raises Type_error where the default does not
    decide a type of its own. info -> String -> typ -> String -> env ->
    store -> store *)
and field_default info name field_type field env store =
  let call = ECall (info, EVar (info, name, 0), [], 0) in
  let given, after = expr_type call env store in
  let after =
    { after with tmap = IntMap.remove 0 after.tmap; qmap = IntMap.remove 0 after.qmap }
  in
  let given = zonk given after in
  if metas_in given after <> [] then
    raise
      (Type_error
         ( info,
           Printf.sprintf
             "the default of the field '%s' does not decide its type (it is \
              %s); write the type: '%s: T = ...'"
             field (shown given after) field ));
  demand given field_type info
    (Printf.sprintf "the field '%s', used before its default is reached," field)
    after

(** One pass over a loop body: what it supplies -- the accumulator the
    next turn carries -- and the store. A `return` written in the body
    leaves the enclosing *function*, so what it gives stays in the frame,
    exactly as one written outside the loop would.
    [stmt] -> env -> expected -> typ -> store -> (typ option, store) *)
and check_turn body turn_env return_type accumulator store =
  check_stmts body turn_env return_type (Some accumulator) store

(** The environment a loop's body runs in, once its iteration clause is
    checked. A `for` walks a list and binds its element over the body; a
    `while` is a Bool test, asked where the accumulator is in scope.
    loop_iter option -> env -> env -> store -> (env, store) *)
and check_iteration iterate env body_env store =
  match iterate with
  | Some (ForIn (info, name, sequence, _)) ->
      let sequence_type, store = check_expr sequence env store in
      let element, store =
        demand_list sequence_type info
          "a 'for' loop walks a list, but this one" store
      in
      (bind body_env name element, store)
  | Some (WhileTest (info, condition, _)) ->
      let condition_type, store = check_expr condition body_env store in
      ( body_env,
        demand condition_type (t_bool info) info "the condition of a 'while'"
          store )
  | None -> (body_env, store)

(** env with every name in an assignment target bound to its part of
    type_, recording each part under the target's own symbol, and the
    store that makes the value the right shape.

    A destructuring target is a *demand* for a tuple of that many parts,
    so a value nothing has decided yet is settled by it -- which is what
    lets `n, s = pair` say what `pair` is inside a body being worked out.
    assign_target -> typ -> env -> store -> (env, store) *)
and check_target ?(implicit = false) target type_ env store =
  match target with
  | TargetName (_, name, sym) ->
      let store = record store sym type_ in
      (bind ~implicit env name type_, store)
  | TargetTuple (info, elements, sym) -> (
      let parts, store = fresh_metas (List.length elements) info store in
      match unify (t_tuple info parts) type_ store with
      | None ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "this binding takes %d values apart, but its value has \
                    type %s"
                   (List.length elements) (shown type_ store) ))
      | Some store ->
          let store = record store sym (zonk type_ store) in
          List.fold_left2
            (fun (env, store) element part ->
              check_target element part env store)
            (env, store) elements parts)

(** The type of one expression, recorded in the store's table under its
    symbol. expr -> env -> store -> (typ, store) *)
and check_expr e env store =
  let type_, store = expr_type e env store in
  (type_, record store (expr_sym e) type_)

(** The rules: what each expression is worth, without recording it.
    expr -> env -> store -> (typ, store) *)
and expr_type e env store =
  match e with
  | EInt (info, _, _) -> (t_int info, store)
  | EFloat (info, _, _) -> (t_float info, store)
  | EString (info, _, _) -> (t_string info, store)
  | EBool (info, _, _) -> (t_bool info, store)
  | ETuple (info, elements, _) ->
      (* A tuple of the element types, in order -- and `()`, with no
         elements, is the unit type, which is the same thing said of
         nothing. *)
      let types, store = check_each elements env store in
      (t_tuple info types, store)
  | EVar (info, name, _) -> (
      (* Two different questions, asked in order. Is the name in scope at
         all -- a question about *names*, answered the way analyses.ml
         answers it and reported the same way? And then: does this
         checker know a type for it? *)
      match type_of env name with
      | None -> (
          match candidates_for e env with
          | Some (_, candidates) ->
              (* Several `::` definitions and no plain one: the arguments
                 of a call are what say which is meant, and there are
                 none here (docs/overloading.md). *)
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' names %d definitions (%s), so it can be called \
                        but not used as a value; write the one that is meant"
                       name (List.length candidates)
                       (String.concat ", "
                          (List.map (fun (n, _) -> "'" ^ n ^ "'") candidates))
                   ))
          | None ->
              raise
                (Analyses.Analysis_error
                   (info, Printf.sprintf "unbound name '%s'" name)))
      | Some (TBuiltin (_, builtin, _)) ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'%s' is a builtin operation: it can be called, but not \
                    used as a value"
                   builtin ))
      | Some type_ ->
          (* A name standing for a definition something has already
             worked out means the scheme it turned out to be, not the
             promise it was declared as. One nothing has worked out yet
             is worked out here: handing a definition somewhere is a
             demand on its type as surely as calling it is, and its body
             would otherwise never be checked at all. *)
          let store = work_out type_ store in
          (settled_type type_ store, store))
  | EQualified (info, module_, name, _) -> (
      (* A public name of an imported module. `import_env` put it in the
         environment under this very spelling, so the lookup is `EVar`'s
         -- and the type is the one the module's own check worked out,
         read out of its sigmap. *)
      let qualified = Printf.sprintf "%s.%s" module_ name in
      match type_of env qualified with
      | None ->
          raise
            (Analyses.Analysis_error
               (info, unreachable_name module_ name env))
      | Some type_ -> (settled_type type_ store, store))
  | EIf (info, cond, then_expr, else_expr, _) ->
      (* The `if` *expression*, whose `else` is mandatory -- so unlike
         the statement it always yields a value, and its branches must
         agree on what. *)
      let cond_type, store = check_expr cond env store in
      let store =
        demand cond_type (t_bool (expr_info cond)) (expr_info cond)
          "the condition of an 'if'" store
      in
      (* Both branches yield the value this expression is worth, so they
         are one type. *)
      let then_type, then_store = check_expr then_expr env store in
      let else_type, else_store = check_expr else_expr env then_store in
      let both, else_store =
        agree (Some then_type) (Some else_type) else_store
      in
      if both = None then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "the branches of this 'if' have different types: %s and %s"
                 (shown then_type else_store) (shown else_type else_store) ));
      check_not_conflated (Some then_type) (Some else_type) info;
      (Option.get both, else_store)
  | ENeg (info, operand, _) -> (
      (* Negation follows the arithmetic table: a Float negates to a
         Float, and an operand nothing has decided is an Int, which is
         the table's first row. *)
      let operand_type, store = check_expr operand env store in
      let settled = prune operand_type store in
      match
        if is_meta settled then unify (t_int info) settled store
        else if kind_matches KInt settled || kind_matches KFloat settled then
          Some store
        else None
      with
      | Some answer -> (zonk (prune operand_type answer) answer, answer)
      | None ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "`-` cannot be applied to %s; it negates an Int or a Float"
                   (shown operand_type store) )))
  | EList (info, elements, _) ->
      (* Every element is one of the same list, so they agree on one type
         -- the rule the branches of an `if` obey, for the same reason.
         An empty list has no element to say what it holds, and is worth
         `[a]` for a variable nothing has constrained: no element of it
         ever arrives, so it fits wherever any list is wanted. *)
      let types, store = check_each elements env store in
      (match types with
      | [] ->
          let element, store = fresh_meta info store in
          (t_list info element, store)
      | first :: rest ->
          let element, store =
            List.fold_left
              (fun (element, store) other ->
                let both, store = agree (Some element) (Some other) store in
                match both with
                | Some both -> (both, store)
                | None ->
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "the elements of this list have different types: \
                              %s and %s"
                             (shown element store) (shown other store) )))
              (first, store) rest
          in
          (t_list info element, store))
  | EListComp (info, element, clauses, _) ->
      let inner, store = check_clauses clauses env store in
      let element_type, store = check_expr element inner store in
      (t_list info element_type, store)
  | ELambda (info, params, body, _) -> check_lambda info params body env store
  | ELet (_, target, annotation, value, body, _) ->
      (* As an `=` binding: the value is checked where the `let` is
         written, and only the body sees what it binds. *)
      let value_type, store = check_expr value env store in
      let store = check_annotation annotation value_type store in
      let value_type = zonk value_type store in
      let inner, store = check_target target value_type env store in
      check_expr body inner store
  | EConstruct (info, module_, name, args, _) ->
      (* A constructor is applied to every one of its fields -- the sugar
         has filled in the defaults and put the named ones in place --
         and builds a value of its datatype at whatever the fields say
         the parameters are. *)
      let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
      let _, fields, result, store = constructor_use info spelled name store in
      let given = arg_exprs args in
      if List.length given <> List.length fields then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "'%s' has %d field%s, but %d %s given%s" spelled
                 (List.length fields)
                 (if List.length fields = 1 then "" else "s")
                 (List.length given)
                 (if List.length given = 1 then "was" else "were")
                 (if given = [] then
                    "; a constructor is not a value, so one with fields is \
                     always applied to them"
                  else "") ));
      let store, _ =
        List.fold_left2
          (fun (store, position) argument (label, wanted) ->
            let actual, store = check_expr argument env store in
            let store =
              demand actual wanted (expr_info argument)
                (field_named spelled position label)
                store
            in
            (store, position + 1))
          (store, 0) given fields
      in
      (zonk result store, store)
  | EField (info, record, field, _) -> (
      (* A field is read the same way whichever constructor built the
         value, so every constructor of the datatype has to have it, at
         one type. *)
      let record_type, store = check_expr record env store in
      match prune record_type store with
      | TCon (_, canonical, args, _) -> (
          let (Datatype (_, params, constructors)) =
            SMap.find canonical store.datatypes
          in
          let mapping = List.combine params args in
          let found =
            List.map
              (fun (cname, fields) ->
                ( cname,
                  Option.map
                    (fun (_, t) -> substitute t mapping)
                    (List.find_opt (fun (label, _) -> label = Some field) fields) ))
              constructors
          in
          match List.find_opt (fun (_, t) -> t = None) found with
          | Some (cname, _) ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' has no field '%s' in every constructor: '%s' has \
                        none, so a value built by it has nothing to read"
                       (base_name canonical) field cname ))
          | None -> (
              match List.map (fun (_, t) -> Option.get t) found with
              | [] ->
                  raise
                    (Type_error
                       ( info,
                         Printf.sprintf "'%s' has no constructors" canonical ))
              | first :: rest ->
                  let store =
                    List.fold_left
                      (fun store other ->
                        match unify first other store with
                        | Some store -> store
                        | None ->
                            raise
                              (Type_error
                                 ( info,
                                   Printf.sprintf
                                     "the field '%s' of '%s' has a different \
                                      type in different constructors (%s and \
                                      %s), so reading it has no one type"
                                     field (base_name canonical)
                                     (shown first store) (shown other store) )))
                      store rest
                  in
                  (zonk first store, store)))
      | settled when is_meta settled ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "nothing here says what datatype this value is, so there \
                    is no telling which field '%s' is meant; annotate it"
                   field ))
      | settled ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'.%s' reads a field of a datatype, but this value is %s"
                   field (shown settled store) )))
  | ECall _ -> check_call e env store
  | EAdd _ | EConcat _ | ESub _ | EMul _ | EDiv _ | ELessThan _
  | ELessThanEq _ | EGreatThan _ | EGreatThanEq _ | EEq _ ->
      check_binary e env store

(** One lambda: the function type it is worth.

    A lambda is **lambda-bound and so monomorphic**, whatever it is
    bound to afterwards -- `def` is how a polymorphic function is
    written (PYKING.md, "Lambdas"). A parameter with no annotation is a
    metavariable the body and the uses settle between them; a type
    variable *written* in one is a metavariable too, and one shared by
    every parameter that names it, since there is nothing here to
    quantify it. The body is checked in the environment the lambda
    stands in, extended with the parameters -- what it captures is what
    is bound where it is written.
    info -> [param] -> expr -> env -> store -> (typ, store) *)
and check_lambda info params body env store =
  let written =
    List.filter_map
      (fun (Param (_, _, type_, _, _)) -> resolved_option store type_)
      params
  in
  let mapping, store =
    List.fold_left
      (fun (mapping, store) name ->
        if List.mem_assoc name mapping then (mapping, store)
        else
          let meta, store = fresh_meta info store in
          (mapping @ [ (name, meta) ], store))
      ([], store)
      (List.concat_map free_vars written)
  in
  let param_types, store =
    List.fold_left
      (fun (types, store) (Param (param_info, _, type_, _, _)) ->
        match resolved_option store type_ with
        | Some written -> (types @ [ substitute written mapping ], store)
        | None ->
            let meta, store = fresh_meta param_info store in
            (types @ [ meta ], store))
      ([], store) params
  in
  let store =
    List.fold_left2
      (fun store param type_ ->
        let _, store = check_param param type_ store in
        store)
      store params param_types
  in
  let body_env =
    List.fold_left2
      (fun body_env param type_ -> bind body_env (param_name param) type_)
      env params param_types
  in
  let result, store = check_expr body body_env store in
  (t_function info param_types result, store)

(** Checks every expression left to right (Pyking's evaluation order) and
    answers their types. [expr] -> env -> store -> ([typ], store) *)
and check_each exprs env store =
  match exprs with
  | [] -> ([], store)
  | first :: rest ->
      let type_, store = check_expr first env store in
      let types, store = check_each rest env store in
      (type_ :: types, store)

(** The type of a binary operator application, from the operator table.

    **Every operator Pyking has takes two operands of one type**, so they
    are unified first and the table is then asked about that one type.
    Doing it the other way round -- trying each row against each operand
    -- would pick the first row a still-open operand happened to fit, and
    pin two types that had said nothing to whichever row the table lists
    first. expr -> env -> store -> (typ, store) *)
and check_binary e env store =
  let spelling, rows =
    match operator_of e with Some pair -> pair | None -> unsupported (expr_info e)
  in
  let left, right =
    match binary_operands e with
    | Some pair -> pair
    | None -> unsupported (expr_info e)
  in
  let left_type, store = check_expr left env store in
  let right_type, store = check_expr right env store in
  let answer =
    match unify left_type right_type store with
    | None -> None
    | Some together -> (
        let common = prune left_type together in
        match operator_result e common rows together with
        | Some type_, after -> Some (type_, after)
        | None, _ -> None)
  in
  match answer with
  | Some pair -> pair
  | None -> raise (operator_error e spelling rows left_type right_type store)

(** Type-checks a function call. expr -> env -> store -> (typ, store) *)
and check_call call env store =
  let func, args =
    match call with
    | ECall (_, func, args, _) -> (func, arg_exprs args)
    | _ -> unsupported (expr_info call)
  in
  let builtin =
    match func with
    | EVar (_, name, _) -> (
        match type_of env name with
        | Some (TBuiltin (_, builtin, _)) -> Some builtin
        | _ -> None)
    | _ -> None
  in
  match builtin with
  | Some builtin -> check_builtin_call builtin call env store
  | None -> (
      match candidates_for func env with
      | Some (spelling, candidates) ->
          (* A name that is not bound but has `::` definitions in scope
             is an overloaded call: the arguments say which of them is
             meant (docs/overloading.md). *)
          resolve_overload call spelling candidates args env store
      | None -> (
          let func_type, store = check_expr func env store in
          match settled_type func_type store with
          | TFunction (_, _, _, _, _, Some (SFunctionDef _), _) as deferred ->
              (* Nothing has worked this definition out yet, so this call
                 is what makes it happen. Its body decides its type, and
                 this call is then checked against that like any other. *)
              infer_call deferred call env store
          | settled -> called_at settled call args env store))

(** The overload set a callee names, where it names one: the spelling
    the source wrote, and every `::` definition in scope whose base name
    is that one. A name that *is* bound means itself and nothing else --
    a plain `def` is not a member of any set (docs/overloading.md).
    expr -> env -> (string, [(string, typ)]) option *)
and candidates_for func env =
  let gather spelling fits =
    let found =
      SMap.fold
        (fun bound binding found ->
          if fits bound binding then found @ [ (bound, binding.btype) ]
          else found)
        env []
    in
    if found = [] then None else Some (spelling, found)
  in
  match func with
  | EVar (_, name, _) when not (SMap.mem name env) ->
      if Names.is_qualified name then
        (* `int::leq` written with no module in front, reaching one an
           import brought in: only a public *implicit* arrives that way
           (PYKING.md, "Modules"). *)
        gather name (fun bound binding ->
            binding.bimplicit && imported bound && Names.field bound = name)
      else
        gather name (fun bound binding ->
            let field = Names.field bound in
            Names.is_qualified field
            && Names.base field = name
            && ((not (imported bound)) || binding.bimplicit))
  | EQualified (_, module_, name, _)
    when (not (SMap.mem (module_ ^ "." ^ name) env))
         && not (Names.is_qualified name) ->
      let prefix = module_ ^ "." in
      gather (prefix ^ name) (fun bound _ ->
          imported bound
          && String.length bound > String.length prefix
          && String.sub bound 0 (String.length prefix) = prefix
          && Names.is_qualified (Names.field bound)
          && Names.base (Names.field bound) = name)
  | _ -> None

(** Whether this environment key names something reached through a
    module -- `alias.field` -- rather than one of this file's own.
    string -> Bool *)
and imported bound = String.contains bound '.'

(** One overloaded call. The arguments are checked **once**, and each
    candidate is then tried against the types they turned out to be, in
    a store of its own: the store is a value, so a trial that does not
    fit is discarded by not being kept. Exactly one candidate fitting
    resolves the call; none and several are both errors naming what was
    in scope (docs/overloading.md).
    expr -> string -> [(string, typ)] -> [expr] -> env -> store
    -> (typ, store) *)
and resolve_overload call spelling candidates args env store =
  let info = expr_info call in
  let given, store = check_each args env store in
  let fitting =
    List.filter_map
      (fun (name, scheme) ->
        let used, trial = instantiate scheme store in
        match prune used trial with
        | TFunction (_, params, result, _, _, _, implicits)
          when List.length params = List.length given -> (
            match unify_each given params trial with
            | None -> None
            | Some trial -> Some (name, result, implicits, trial))
        | _ -> None)
      candidates
  in
  match fitting with
  | [ (name, result, implicits, trial) ] ->
      let implicits = map_implicits (fun t -> prune t trial) implicits in
      let supplied, store = discharge info implicits env trial 0 in
      let store =
        record_resolution store (expr_sym call)
          (Call (Some (name, t_function info given (zonk result store)), supplied))
      in
      (result, store)
  | [] -> raise (no_candidate info spelling candidates given store)
  | several -> raise (several_candidates info spelling several given store)

(** Why no definition of an overloaded name fits these arguments.
    info -> string -> [(string, typ)] -> [typ] -> store -> exn *)
and no_candidate info spelling candidates given store =
  Type_error
    ( info,
      Printf.sprintf
        "no definition of '%s' takes (%s); the ones in scope are %s"
        spelling
        (String.concat ", " (List.map (fun t -> shown t store) given))
        (String.concat ", "
           (List.map
              (fun (name, scheme) ->
                Printf.sprintf "'%s' of type %s" name (shown scheme store))
              candidates)) )

(** Why several definitions of an overloaded name fit. An argument type
    nothing has decided fits every candidate, and saying *that* is worth
    more than listing them (docs/overloading.md).
    info -> string -> [(string, typ, [implicit_param], store)] -> [typ]
    -> store -> exn *)
and several_candidates info spelling fitting given store =
  let named =
    String.concat " and "
      (List.map (fun (name, _, _, _) -> Printf.sprintf "'%s'" name) fitting)
  in
  let undecided =
    List.exists (fun type_ -> is_meta (prune type_ store)) given
  in
  Type_error
    ( info,
      if undecided then
        Printf.sprintf
          "nothing here decides which '%s' is meant: %s all take these \
           arguments, and the type of at least one of them is still open. \
           Annotate it, or take the definition as an implicit parameter"
          spelling named
      else
        Printf.sprintf
          "this call to '%s' is ambiguous: %s all take these arguments, so \
           write the one that is meant"
          spelling named )

(** The arguments one call's implicit parameters resolve to, in order.
    info -> [implicit_param] -> env -> store -> int
    -> ([argument], store) *)
and discharge info implicits env store depth =
  List.fold_left
    (fun (found, store) (IParam (name, wanted)) ->
      let one, store = resolve_implicit info name wanted env store depth in
      (found @ [ one ], store))
    ([], store) implicits

(** The one implicit binding in scope that fits this parameter, and the
    store in which it does.

    The search is by name and by type: every *implicit* binding whose
    base name is this one is tried, and its own implicit parameters --
    which it does not carry across -- become obligations discharged here,
    in the scope of the call (docs/implicits.md). A non-implicit binding
    is never considered, which is what keeps a value from being captured
    by accident.
    info -> string -> typ -> env -> store -> int -> (argument, store) *)
and resolve_implicit info name wanted env store depth =
  if depth > max_implicit_depth then
    raise
      (Type_error
         ( info,
           Printf.sprintf
             "resolving the implicit '%s' went %d deep and did not stop; \
              an implicit that needs one of its own kind cannot go round \
              for ever"
             name max_implicit_depth ));
  let wanted = zonk wanted store in
  let fitting =
    SMap.fold
      (fun bound binding found ->
        if binding.bimplicit && Names.base (Names.field bound) = name then
          let used, trial = instantiate binding.btype store in
          let stripped, obligations =
            match prune used trial with
            | TFunction (i, params, result, sym, tmsym, definition, implicits)
              when implicits <> [] ->
                ( TFunction (i, params, result, sym, tmsym, definition, []),
                  implicits )
            | other -> (other, [])
          in
          match unify stripped wanted trial with
          | None -> found
          | Some trial -> found @ [ (bound, obligations, trial) ]
        else found)
      env []
  in
  match fitting with
  | [ (bound, [], store) ] -> (Direct (bound, zonk wanted store), store)
  | [ (bound, obligations, store) ] ->
      (* The candidate takes implicit arguments of its own and is being
         passed where a plain function type is wanted, so what is passed
         is a lambda that supplies them -- the dictionary, built here
         and emitted by elaborate.ml. *)
      let obligations = map_implicits (fun t -> prune t store) obligations in
      let inner, store = discharge info obligations env store (depth + 1) in
      let wanted = zonk wanted store in
      (Wrapped (bound, wanted, arity wanted, inner), store)
  | [] -> raise (no_implicit info name wanted env store)
  | several ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "the implicit '%s' of type %s is ambiguous here: %s all fit"
               name (shown wanted store)
               (String.concat " and "
                  (List.map
                     (fun (bound, _, _) -> Printf.sprintf "'%s'" bound)
                     several)) ))

(** Why no implicit binding fits. Names a binding of the right name that
    is not implicit, since that is the mistake worth pointing at.
    info -> string -> typ -> env -> store -> exn *)
and no_implicit info name wanted env store =
  let shadowing =
    SMap.exists
      (fun bound binding ->
        (not binding.bimplicit) && Names.base (Names.field bound) = name)
      env
  in
  Type_error
    ( info,
      Printf.sprintf "no implicit '%s' of type %s is in scope here%s" name
        (shown wanted store)
        (if shadowing then
           Printf.sprintf
             "; there is a '%s', but it is not declared 'implicit', and only \
              an implicit definition may be resolved to"
             name
         else "") )

(** A call to a builtin -- print, string, len, range or a conversion --
    checked by its own rule since
    none of them has a TFunction type (PYKING.md, "Builtins").
    string -> expr -> env -> store -> (typ, store) *)
and check_builtin_call name call env store =
  let info, args = match call with
    | ECall (info, _, args, _) -> (info, arg_exprs args)
    | _ -> (expr_info call, [])
  in
  let types, store = check_each args env store in
  let types = List.map (fun t -> zonk t store) types in
  let given = List.length args in
  match (name, types) with
  | ("print" | "debug"), _ -> (unit_type info, store)
  | "string", [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KInt; KFloat; KString; KBool; KList; KTuple; KData ])
      then
        raise
          (builtin_argument_error name (List.hd args) value
             "Int, Float, String, Bool, a list, a tuple or a datatype");
      (t_string info, store)
  | ("int" | "float" | "bool"), [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KInt; KFloat; KString; KBool ]) then
        raise
          (builtin_argument_error name (List.hd args) value
             "Int, Float, String or Bool");
      ( (match name with
        | "int" -> t_int info
        | "float" -> t_float info
        | _ -> t_bool info),
        store )
  | "len", [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KList; KString ]) then
        raise
          (builtin_argument_error name (List.hd args) value
             "a list or a String");
      (t_int info, store)
  | "range", _ ->
      check_builtin_arity name info given;
      List.iter2
        (fun argument actual ->
          if not (every actual [ KInt ]) then
            raise (builtin_argument_error name argument actual "Int"))
        args types;
      (t_list info (t_int info), store)
  | _ ->
      (* A builtin with the wrong number of arguments reaches here for
         `string`, `len` and the conversions, whose cases ask for exactly
         one; the arity check says which and how many. *)
      check_builtin_arity name info given;
      unsupported info

(** One call to something of known type: the type it is worth, and the
    store in which the arguments fit its parameters.

    The scheme is *instantiated* first, so a polymorphic function is used
    at one of its instances and each call picks its own -- which is what
    lets one definition serve two callers at two types. Each argument is
    then unified with its parameter, left to right, so the first mistake
    is the one reported.
    typ -> expr -> [expr] -> env -> store -> (typ, store) *)
and called_at scheme call args env store =
  let info = expr_info call in
  let used, store = instantiate scheme store in
  let used = prune used store in
  let used, store =
    if is_meta used then
      (* Calling something nothing has decided is what decides it: it is
         a function of this many arguments, and the arguments and the
         result say the rest. This is the one place a type is *built* by
         a demand rather than compared against one. *)
      let made, store = fresh_metas (List.length args + 1) info store in
      let rec split seen = function
        | [ last ] -> (List.rev seen, last)
        | one :: rest -> split (one :: seen) rest
        | [] -> ([], t_unknown info)
      in
      let params, result = split [] made in
      let built = t_function info params result in
      let store =
        match unify (prune scheme store) built store with
        | Some store -> store
        | None -> store
      in
      (built, store)
    else (used, store)
  in
  match used with
  | TFunction (_, params, result, _, _, _, implicits)
    when implicits <> []
         && List.length args = List.length params + List.length implicits ->
      (* Every implicit argument written out at the call: nothing is
         resolved and nothing is inserted, since they are already where
         they belong (PYKING.md, "Implicits"). *)
      (result, check_arguments args (params @ implicit_types implicits) env store 1)
  | TFunction (_, params, result, _, _, _, implicits) ->
      if List.length args <> List.length params then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "this function takes %d argument%s, but %d %s given"
                 (List.length params)
                 (if List.length params = 1 then "" else "s")
                 (List.length args)
                 (if List.length args = 1 then "was" else "were") ));
      let store = check_arguments args params env store 1 in
      (* Whatever was called -- a definition, a parameter holding one,
         a binding -- its implicit parameters are resolved here, where
         the call is written. That is what lets a function carrying one
         be passed as a value and called somewhere else (PYKING.md,
         "Implicits"). *)
      if implicits = [] then (result, store)
      else
        let implicits = map_implicits (fun t -> prune t store) implicits in
        let supplied, store = discharge info implicits env store 0 in
        (result, record_resolution store (expr_sym call) (Call (None, supplied)))
  | _ ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this call applies something of type %s, which is not a \
                function"
               (shown used store) ))

(** Checks each argument against its parameter, left to right (so the
    first mistake is the one reported), and answers the store in which
    they fit. [expr] -> [typ] -> env -> store -> int -> store *)
and check_arguments args declared env store position =
  match (args, declared) with
  | [], _ -> store
  | arg :: rest, expected :: rest_declared ->
      let actual, store = check_expr arg env store in
      let store = fitted expected actual arg position env store in
      check_arguments rest rest_declared env store (position + 1)
  | _ :: _, [] -> store

(** The store in which one argument fits one parameter, or a Type_error
    naming both.

    An argument that is itself polymorphic is *instantiated* wherever the
    parameter is not written polymorphic: every instance of it exists, so
    it stands where one of them is wanted, and it is the instance that
    has to fit. Where the parameter *is* written `(all a. ...)` the
    argument has to be that scheme whole, which is first-class
    polymorphism and the one place the two are compared as schemes.
    typ -> typ -> expr -> int -> store -> store *)
and fitted expected actual arg position env store =
  let settled = prune expected store in
  let store = work_out actual store in
  let actual = settled_type actual store in
  let actual, store =
    if is_forall settled then (actual, store) else instantiate actual store
  in
  match unify settled actual store with
  | Some answer -> answer
  | None -> (
      match adapted arg actual settled env store with
      | Some answer -> answer
      | None -> raise (argument_error position actual settled arg store))

(** The store in which an argument carrying implicit parameters fits a
    parameter that has none, by supplying them *here*.

    A function whose type says `implicit my` is called with `my`
    resolved where the call is written; handing it somewhere that wants
    an ordinary function is the same demand one step earlier, so the
    implicits are resolved at this position and what is passed is a
    lambda that supplies them -- the same adaptation
    `resolve_implicit` makes for an implicit argument
    (docs/implicits.md, "The dictionary"). None where this argument is
    not that case, and the caller then reports the mismatch it has.
    expr -> typ -> typ -> env -> store -> store? *)
and adapted arg actual wanted env store =
  match (prune actual store, prune wanted store) with
  | ( TFunction (info, params, result, sym, tmsym, definition, implicits),
      TFunction (_, wanted_params, _, _, _, _, []) )
    when implicits <> [] && List.length params = List.length wanted_params -> (
      (* More implicit parameters than are wanted: they are supplied
         here, and the lambda hands on everything it is given. *)
      let stripped =
        TFunction (info, params, result, sym, tmsym, definition, [])
      in
      match unify (prune wanted store) stripped store with
      | None -> None
      | Some store ->
          let implicits = map_implicits (fun t -> prune t store) implicits in
          let supplied, store =
            try discharge (expr_info arg) implicits env store 0
            with Type_error (where, message) ->
              raise (Type_error (where, resolved_here message arg))
          in
          let wanted = zonk (prune wanted store) store in
          Some
            (record_resolution store (expr_sym arg)
               (Adapted (wanted, arity wanted, supplied))))
  | ( TFunction (info, params, result, sym, tmsym, definition, []),
      TFunction (_, wanted_params, _, _, _, _, (_ :: _ as wanted_implicits)) )
    when List.length params = List.length wanted_params -> (
      (* Fewer: the value does not ask for what is offered, so the
         lambda takes the implicit arguments and hands on only the
         explicit ones. A function that needs less stands wherever one
         that needs more is wanted. *)
      let filled =
        TFunction (info, params, result, sym, tmsym, definition, wanted_implicits)
      in
      match unify (prune wanted store) filled store with
      | None -> None
      | Some store ->
          let wanted = zonk (prune wanted store) store in
          Some
            (record_resolution store (expr_sym arg)
               (Adapted (wanted, List.length wanted_params, []))))
  | _ -> None

(** Why an implicit an adapted argument needs could not be found, said
    where the mistake usually is: the parameter it is passed to has no
    implicit of its own, so the search happened here rather than
    wherever that parameter is called (docs/implicits.md).
    String -> expr -> String *)
and resolved_here message arg =
  let what =
    match arg with
    | EVar (_, name, _) -> Printf.sprintf "'%s'" name
    | EQualified (_, module_, field, _) ->
        Printf.sprintf "'%s.%s'" module_ field
    | _ -> "this argument"
  in
  Printf.sprintf
    "%s. %s takes it implicitly and the parameter it is passed to does \
     not, so it is resolved here rather than where that parameter is \
     called; write the implicit into that parameter's own type to have it \
     resolved there instead"
    message what

(** The store in which this definition has a scheme: `infer_call` without
    the call. What makes it happen is usually a call, but a definition
    handed somewhere a type is written down is worked out there instead --
    the body receiving it will not reach it again, so that is the only
    place the two can be compared for real. typ -> store -> store *)
and work_out func_type store =
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _), _)
    when instance_of store tmsym = None
         && not (IntSet.mem tmsym store.checking) ->
      let _, store = infer_definition func_type store in
      store
  | _ -> store

(** The type this call is worth, working the definition out first.
    typ -> expr -> env -> store -> (typ, store) *)
and infer_call func_type call env store =
  let args =
    match call with ECall (_, _, args, _) -> arg_exprs args | _ -> []
  in
  let _, store = infer_definition func_type store in
  called_at (settled_type func_type store) call args env store

(** The scheme an unannotated function has, worked out from its body the
    first time something calls it and remembered afterward.

    The body decides it, not this call: every parameter goes in as a
    metavariable and the body's own demands are what solve them. So the
    answer is the definition's principal type, and this call is then
    checked against it like a call to anything else.
    typ -> store -> (typ, store) *)
and infer_definition func_type store =
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _ as node), _) ->
      (* The environment the function was *written* in -- not this
         call's. `declare_functions` always records it, and the `def`
         statement sharpens it to the position; the fallback is for a
         caller that somehow checked a call before the definition was
         declared, where the builtins are at least in scope. *)
      let body_env =
        match environment_of store tmsym with
        | Some written -> written
        | None -> builtin_env ()
      in
      (* Every `def` of the block this one is in is worked out together,
         because they may name each other: each is bound to a *monotype*
         while the group's bodies are checked, and generalised only once
         all of them are done. That is the whole of recursion here -- a
         recursive call is an ordinary call to a type already in scope --
         and it is the rule Hindley-Milner applies to a `let rec`
         group. *)
      let group = inference_group node store in
      let monotypes, inner = monotypes_for group store in
      let inner = with_frame inner { returns = [] } in
      let inner =
        List.fold_left
          (fun inner other -> checking_now inner (stmt_sym other))
          inner group
      in
      let inner =
        List.fold_left2
          (fun inner other mono ->
            (* In the scope *it* was written in, never the group's or the
               caller's: what a body captures is what was bound where it
               stands (PYKING.md, "Names and scoping"). *)
            let group_env =
              match environment_of store (stmt_sym other) with
              | Some written -> written
              | None -> body_env
            in
            let group_env =
              List.fold_left2
                (fun group_env sibling sibling_mono ->
                  bind group_env (def_name sibling) sibling_mono)
                group_env group monotypes
            in
            let mono_params =
              match mono with
              | TFunction (_, params, _, _, _, _, _) -> params
              | _ -> []
            in
            let group_env =
              List.fold_left2
                (fun group_env param type_ ->
                  bind group_env (param_name param) type_)
                group_env (def_params other) mono_params
            in
            let supplied, inner = body_result other group_env inner in
            let mono_result =
              match mono with
              | TFunction (_, _, result, _, _, _, _) -> result
              | _ -> mono
            in
            required inner mono_result supplied other)
          inner group monotypes
      in
      let store = learned store inner in
      (* Generalise the whole group and remember every scheme *before*
         verifying any of them: a body re-checked while a name it calls
         is still unworked would work that one out all over again, which
         for two functions that call each other never ends. *)
      let store, schemes =
        List.fold_left2
          (fun (store, schemes) other mono ->
            let outer =
              free_metas
                (match environment_of store (stmt_sym other) with
                | Some written -> written
                | None -> body_env)
                store
            in
            (* What this definition may not generalise, remembered so the
               printed output does not claim it did. *)
            let store =
              {
                store with
                captured =
                  StringSet.union store.captured
                    (StringSet.inter outer
                       (List.fold_left
                          (fun s m -> StringSet.add m s)
                          StringSet.empty (metas_in mono store)));
              }
            in
            (* A def written inside this one that holds this one's
               variables has already named its own, and its type then
               names both. *)
            let own = metas_in (zonk mono store) store in
            let avoid =
              Walk.fold_stmts
                (fun found node ->
                  match node with
                  | Walk.NStmt (SFunctionDef (_, _, _, _, _, sym, _, _, _)) -> (
                      match IntMap.find_opt sym store.instances with
                      | Some (TForall (_, vars, body, _))
                        when List.exists (fun m -> List.mem m own) (metas_in body store) ->
                          List.fold_left (fun s v -> StringSet.add v s) found vars
                      | _ -> found)
                  | _ -> found)
                StringSet.empty (def_body other)
            in
            ( store,
              schemes @ [ (generalise ~avoid other (zonk mono store) outer store, outer) ] ))
          (store, []) group monotypes
      in
      let outers = List.map snd schemes in
      let schemes = List.map fst schemes in
      let store =
        List.fold_left2
          (fun store other scheme -> remembering store (stmt_sym other) scheme)
          store group schemes
      in
      let store =
        List.fold_left2
          (fun store ((other, scheme), outer) mono ->
            let settled, store = verifying other scheme mono store in
            (* A scheme the body holds to is what the body's own types
               mean: each variable it generalised is that variable from
               here on, so a type recorded inside the body -- a nested
               def's among them -- reads back in the scheme's own
               variables rather than as one nothing settled. *)
            let store =
              match settled with
              | TForall (_, names, _, _) when settled == scheme ->
                  let open_metas =
                    List.filter
                      (fun meta -> not (StringSet.mem meta outer))
                      (metas_in (zonk mono store) store)
                  in
                  if List.length open_metas <> List.length names then store
                  else
                    List.fold_left2
                      (fun store meta name ->
                        if SMap.mem meta store.solutions then store
                        else
                          (* One a definition inside could not generalise
                             is still written `?` where that definition's
                             own types are printed. *)
                          let marked = if StringSet.mem meta store.captured then -1 else 0 in
                          solving store meta (TVar (stmt_info other, name, marked, true)))
                      store open_metas names
              | _ -> store
            in
            let store = remembering store (stmt_sym other) settled in
            let store = record store (stmt_sym other) settled in
            match instantiated settled with
            | _, TFunction (_, params, _, _, _, _, _) ->
                List.fold_left2
                  (fun store param type_ ->
                    record store (param_sym param) type_)
                  store (def_params other) params
            | _ -> store)
          store
          (List.combine (List.combine group schemes) outers)
          monotypes
      in
      (settled_type func_type store, store)
  | _ -> (func_type, store)

(** What a function's body supplies: every `return` in it and the value it
    ends in, which have to be one type.
    stmt -> env -> store -> (typ option, store) *)
and body_result node env store =
  let started = with_frame store { returns = [] } in
  let supplied, ended = supplied_type node env Inferring started in
  let collected = ended.frame.returns in
  let collected =
    match supplied with
    | None -> collected
    (* The body's tail position supplies a value too, and it answers the
       same question a `return` does (PYKING.md, "Tail position"). *)
    | Some supplied ->
        let body = def_body node in
        let last = List.nth body (List.length body - 1) in
        collected
        @ [ { given_info = stmt_info last; given_type = supplied } ]
  in
  let restored = with_frame ended { returns = store.frame.returns } in
  if collected = [] then (None, restored)
  else
    let type_, store = one_type collected (def_name node) restored in
    (Some type_, store)

(** What a function body supplies: its last statement's value.
    stmt -> env -> expected -> store -> (typ option, store) *)
and supplied_type node env return_type store =
  (* A body is checked with no enclosing loop: a `break` may not cross a
     `def`, so one written here belongs to nothing. *)
  check_stmts (def_body node) env return_type None store

(** Whether a body really does have the scheme that was worked out for
    it, decided by checking it again with the variables **rigid** --
    which is the check an annotated polymorphic function gets, so what
    this accepts is exactly what the checker enforces. Answers the table
    that check filled, so the scheme is what the body's own nodes are
    reported as, or None where it does not hold.

    Unification is sound, so this should never refuse anything; it is
    kept because it costs one pass and it makes "a type this checker
    reports is one it enforces" true by construction rather than by
    argument (docs/type_inference.md, "Verification").
    stmt -> typ -> store -> typ IntMap.t option *)
and verified node scheme store =
  let _, written = instantiated scheme in
  match written with
  | TFunction (_, written_params, result, _, _, _, _)
    when List.length written_params = List.length (def_params node) -> (
      let env =
        match environment_of store (stmt_sym node) with
        | Some written_in -> written_in
        | None -> builtin_env ()
      in
      (* Its own name means the scheme while its body is checked, so a
         recursive call is an ordinary call to a polymorphic function. *)
      let env = bind env (def_name node) scheme in
      let env =
        List.fold_left2
          (fun env param type_ -> bind env (param_name param) type_)
          env (def_params node) written_params
      in
      (* The table this check fills is its own, and so is everything else
         it works out: only the table is kept. *)
      let probe_store = { store with tmap = IntMap.empty } in
      match
        try Some (supplied_type node env (Declared result) probe_store)
        with Type_error _ | Analyses.Analysis_error _ -> None
      with
      | None -> None
      | Some (supplied, after) ->
          if satisfies result supplied after = None then None
          else
            (* Read back through the check's own solutions: those are
               dropped with the rest of what it worked out, and a
               metavariable left in the table would later be read as one
               a different check solved under the same number. *)
            let probe =
              List.fold_left2
                (fun probe param type_ ->
                  IntMap.add (param_sym param) type_ probe)
                (IntMap.map (fun t -> zonk t after) after.tmap)
                (def_params node) written_params
            in
            Some (IntMap.add (stmt_sym node) scheme probe))
  | _ -> None

(** node's scheme, once checking its body against it has said so, or the
    scheme with its variables left as the metavariables they came from
    where the check does not hold.

    That fallback is not a failure but the one thing unification cannot
    express: a body whose demands are *ad-hoc* rather than parametric --
    `string(x)`, which accepts six types and no one type -- generalises to
    a promise it cannot keep, the re-check with `x` rigid says so, and
    the definition stays open for its first call to settle
    (docs/type_inference.md, "What is left of ad-hoc polymorphism").
    stmt -> typ -> typ -> store -> (typ, store) *)
and verifying node scheme mono store =
  match verified node scheme store with
  | None -> (zonk mono store, store)
  | Some probe ->
      (* A def nested in this body is only declared by the re-check, not
         worked out again: what the first check worked out stands. *)
      let rec unknown t =
        match t with
        | TUnknown _ -> true
        | TList (_, e, _) -> unknown e
        | TTuple (_, es, _) | TCon (_, _, es, _) -> List.exists unknown es
        | TFunction (_, ps, r, _, _, _, _) -> List.exists unknown ps || unknown r
        | TForall (_, _, b, _) -> unknown b
        | _ -> false
      in
      let merged =
        IntMap.union
          (fun _ probed first -> if unknown probed then Some first else Some probed)
          probe store.tmap
      in
      (scheme, { store with tmap = merged })

(** Checks a fully annotated def's body against its declared types.
    Always yields unit, whatever the function's own type is: a def is a
    statement. stmt -> env -> store -> (typ option, store) *)
and check_function node env store =
  let ftype = function_type node store in
  (* The body is checked at the *quantified* variables themselves, not at
     anything they might be instantiated to: a TVar is `same_type` only
     with itself, so a body that assumes `a` is an Int is refused here
     rather than at some call. That is the whole of skolemization. *)
  let _, written = instantiated ftype in
  let param_types, result_type, written_implicits =
    match written with
    | TFunction (_, params, result, _, _, _, implicits) ->
        (params, result, implicits)
    | _ -> ([], written, [])
  in
  let store =
    List.fold_left2
      (fun store param type_ ->
        let _, store = check_param param type_ store in
        store)
      store (def_params node) param_types
  in
  let store = record store (stmt_sym node) ftype in
  (* env already binds every def of this block (`declare_functions`); the
     parameters shadow over that, as analyses.ml binds them. *)
  let body_env =
    List.fold_left2
      (fun body_env param type_ -> bind body_env (param_name param) type_)
      env (def_params node) param_types
  in
  (* An implicit parameter is an implicit binding in the body, which is
     what lets a definition discharge its own recursive call's implicit
     against the one it was given (docs/implicits.md). *)
  let body_env, store =
    List.fold_left2
      (fun (body_env, store) param (IParam (_, type_)) ->
        let _, store = check_param param type_ store in
        (bind ~implicit:true body_env (param_name param) type_, store))
      (body_env, store) (def_implicits node) written_implicits
  in
  (* The body's last statement is in tail position; `check_stmt` already
     answers what it supplies, by return or by value (PYKING.md). *)
  let supplied, store =
    check_stmts (def_body node) body_env (Declared result_type) None store
  in
  match satisfies result_type supplied store with
  | Some answer -> (Some (unit_type (stmt_info node)), answer)
  | None -> (
      match supplied with
      | Some supplied when is_unit supplied ->
          raise
            (Type_error
               ( stmt_info node,
                 Printf.sprintf
                   "'%s' returns %s, so its body must return on every path, \
                    or end in an expression of that type"
                   (def_name node) (shown result_type store) ))
      | _ ->
          let body = def_body node in
          let last = List.nth body (List.length body - 1) in
          raise
            (Type_error
               ( stmt_info last,
                 Printf.sprintf
                   "'%s' returns %s, but its body ends in a value of type %s"
                   (def_name node) (shown result_type store)
                   (shown (Option.get supplied) store) )))

(** A parameter's declared type, recorded under its symbol. The type is
    passed in rather than read off the node, since a `def` with a
    signature line writes no annotation on the parameter itself.
    param -> typ -> store -> (typ, store) *)
and check_param param type_ store = (type_, record store (param_sym param) type_)

(** The environment a comprehension's clauses leave for its element
    expression. Each `for` binds over the elements of its sequence and
    the ones after it see those bindings; each `if` is checked in
    whatever is in scope by then.
    [comp_clause] -> env -> store -> (env, store) *)
and check_clauses clauses env store =
  List.fold_left
    (fun (env, store) clause ->
      match clause with
      | CompFor (info, pattern, sequence, _) ->
          let sequence_type, store = check_expr sequence env store in
          let element, store =
            demand_list sequence_type info
              "a comprehension walks a list, but this one" store
          in
          check_pattern pattern element env store
      | CompIf (info, condition, _) ->
          let condition_type, store = check_expr condition env store in
          (match condition_type with
          | TBool _ -> ()
          | _ ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "the condition of a comprehension must be Bool, not %s"
                       (printed condition_type) )));
          (env, store))
    (env, store) clauses

(** The environment a pattern binds and the store in which the value it
    matches has the shape it looks at. A pattern is a *demand*: what it
    takes apart, the subject has to be, which `unify` decides -- so a
    pattern is also how the type of something still open is settled.
    Raises Type_error for a pattern that could never match.
    pattern -> typ -> env -> store -> (env, store) *)
and check_pattern pattern type_ env store =
  match pattern with
  | PWildcard (_, sym) -> (env, record store sym type_)
  | PCapture (_, name, sym) -> (bind env name type_, record store sym type_)
  | PInt (info, _, sym) ->
      let store = pattern_shape (t_int info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PString (info, _, sym) ->
      let store = pattern_shape (t_string info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PBool (info, _, sym) ->
      let store = pattern_shape (t_bool info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PTuple (info, elements, sym) ->
      let parts, store = fresh_metas (List.length elements) info store in
      let store = pattern_shape (t_tuple info parts) type_ info store in
      let store = record store sym (zonk type_ store) in
      List.fold_left2
        (fun (env, store) element part -> check_pattern element part env store)
        (env, store) elements parts
  | PText (info, _, name, _, sym) ->
      (* A string split around a fixed beginning and end. The middle is a
         String like the whole, so there is one type here and nothing to
         take apart. *)
      let store = pattern_shape (t_string info) type_ info store in
      let store = record store sym (zonk type_ store) in
      let env =
        match name with None -> env | Some name -> bind env name (t_string info)
      in
      (env, store)
  | PConstructor (info, module_, name, fields, _, sym) ->
      let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
      let _, wanted, result, store = constructor_use info spelled name store in
      let store =
        match unify result type_ store with
        | Some answer -> answer
        | None ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "this pattern matches %s, but it is matched against %s"
                     (shown result store) (shown type_ store) ))
      in
      if List.length fields <> List.length wanted then
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' has %d field%s, and this pattern matches %d"
                 spelled (List.length wanted)
                 (if List.length wanted = 1 then "" else "s")
                 (List.length fields) ));
      let store = record store sym (zonk type_ store) in
      List.fold_left2
        (fun (env, store) one (_, field_type) ->
          check_pattern one (zonk field_type store) env store)
        (env, store) fields wanted
  | POr (info, alternatives, sym) -> (
      (* Every alternative matches the same value and binds the same
         names, at the same types: whichever of them matched, the arm
         after it sees one set of bindings. *)
      match alternatives with
      | [] -> unsupported info
      | first :: rest ->
          let first_env, store = check_pattern first type_ env store in
          let names = List.map fst (Analyses.pattern_bindings first) in
          let store =
            List.fold_left
              (fun store alternative ->
                let alternative_env, store =
                  check_pattern alternative type_ env store
                in
                List.fold_left
                  (fun store name ->
                    match (type_of first_env name, type_of alternative_env name) with
                    | Some mine, Some theirs -> (
                        match unify mine theirs store with
                        | Some store -> store
                        | None ->
                            raise
                              (Type_error
                                 ( pattern_info alternative,
                                   Printf.sprintf
                                     "'%s' is %s in one alternative of this \
                                      '|' and %s in another; every \
                                      alternative binds a name at one type"
                                     name (shown mine store) (shown theirs store)
                                 )))
                    | _ -> store)
                  store names)
              store rest
          in
          (first_env, record store sym (zonk type_ store)))
  | PAs (_, inner, name, sym) ->
      let env, store = check_pattern inner type_ env store in
      (bind env name type_, record store sym (zonk type_ store))
  | PList (info, prefix, rest, suffix, sym) ->
      let element, store = fresh_meta info store in
      let store = pattern_shape (t_list info element) type_ info store in
      let store = record store sym (zonk type_ store) in
      let env, store =
        List.fold_left
          (fun (env, store) one -> check_pattern one element env store)
          (env, store) (prefix @ suffix)
      in
      let env =
        match rest with
        (* The rest of a list is a list of the same elements. *)
        | Some (ListRest (_, Some name, _)) ->
            bind env name (zonk type_ store)
        | _ -> env
      in
      (env, store)

(* --- the program --- *)

(** Refuses a `match` in these statements that does not match every
    value, or that has a case no value can reach, in the words
    exhaustive.ml puts it. Run once the types are worked out, since what
    a pattern could match is a question about its type.
    [stmt] -> store -> () *)
let check_matches stmts store =
  let tmap = IntMap.map (fun type_ -> zonk type_ store) store.tmap in
  try
    Exhaustive.check
      (fun canonical -> SMap.find_opt canonical store.datatypes)
      tmap stmts
  with Exhaustive.Refused (info, message) -> raise (Type_error (info, message))

(** One resolution with every type in it read back through what has
    since been solved. resolution -> store -> resolution *)
let rec resolved_types answer store =
  match answer with
  | Call (target, supplied) ->
      Call
        ( (match target with
          | None -> None
          | Some (name, type_) -> Some (name, zonk type_ store)),
          List.map (fun one -> resolved_argument one store) supplied )
  | Adapted (type_, passed, supplied) ->
      Adapted
        ( zonk type_ store,
          passed,
          List.map (fun one -> resolved_argument one store) supplied )

(** One resolved argument, read back the same way.
    argument -> store -> argument *)
and resolved_argument one store =
  match one with
  | Direct (name, type_) -> Direct (name, zonk type_ store)
  | Wrapped (name, type_, passed, inner) ->
      Wrapped
        ( name,
          zonk type_ store,
          passed,
          List.map (fun one -> resolved_argument one store) inner )

(** Type-checks one module -- or a whole one-file program, which is the
    same thing. `sigmaps` pairs the name of every module this one imports
    with what that module exports and at what type, which is all of it
    this check can see (module.ml). Raises Type_error for the first thing
    that does not check out. Answers the types it worked out and, beside
    them, what every call it resolved denotes.
    [stmt] -> [(string, sigmap)] -> (typ IntMap.t, resolution IntMap.t) *)
let type_check ?(declared = []) stmts sigmaps =
  let store = declare_datatypes stmts (empty_store sigmaps) in
  (* A module's own declaration half is in scope here, unqualified and
     with no import: `foo.pyk` and `foo_external.pyk` are one module, so
     a name the target's source provides is a name of this module (see
     docs/modules.md, "A module in two halves"). It goes in before the
     imports, since it is the module's own. *)
  let start =
    List.fold_left (fun env (name, type_) -> bind env name type_)
      (builtin_env ()) declared
  in
  let _, store =
    check_stmts stmts (import_env stmts start store) No_function None store
  in
  check_exports stmts store;
  check_exported_datatypes stmts store;
  check_matches stmts store;
  (* Every type is read back once the whole module has been checked,
     because a metavariable open where it was recorded may have been
     solved by something written further down -- a definition worked out
     before the call that says what it holds, most often. What is still
     open then is open for good, and is shown as the variable it is. *)
  ( IntMap.map (fun type_ -> displayed (zonk type_ store) store) store.tmap,
    (* Every resolution is read back for the same reason: one recorded
       while a metavariable was open may have been decided by something
       written further down, and `elaborate.ml` fills `tmap` from these
       types rather than running the checker again (docs/implicits.md). *)
    IntMap.map (fun answer -> resolved_types answer store) store.qmap )
