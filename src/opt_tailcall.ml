(** Tail-call optimization: Pyking AST in, Pyking AST out. A function
    that calls itself in tail position becomes a `loop` carrying its own
    parameters, and a group of functions that tail-call each other
    becomes one worker carrying a state tag. Runs for every mode unless
    --no-tail-call-opt is given, so every backend and the interpreter
    get it at once. See docs/optimization.md.

    It runs *after* the type checker and only on a program the checker
    accepted, which is what makes the rewrite safe to leave unchecked:
    the types decide which groups can be merged, and give the value a
    padded slot is entered with. See docs/optimization.md for what
    counts as a tail call, what is deliberately left alone, and why one
    check is enough.

    Data structures:
      callee -- a call this loop stands for: its state tag and its arity.
      context -- what a rewrite needs: the calls it stands for, the slots
        the loop carries, and the names the program already uses.
      pass_state -- the two things filled in as the pass runs: the type
        table it extends, and the symbols it hands out.

    Functions:
      optimize stmts tmap -- the whole program, tail calls rewritten,
        with the type table extended for what was built.
      tail_calls func names -- the names func tail-calls. *)

open Syntax

(* The generated worker for a mutually recursive group, and the
   parameter that says which of its functions is running. Both are
   ordinary Pyking names -- they appear in `-t pyking` output and in
   every backend's source, so they are named to read as what they are
   rather than to hide. *)
let group_name = "tail_group"
let state_name = "state"

(** A call the loop being built stands for: the state a call to it
    becomes (absent when the loop carries no state), and how many
    arguments such a call gives -- which need not be how many the loop
    carries, since a group is as wide as its widest member. *)
type callee = { tag : int option; arity : int }

(** What rewriting one body needs: the calls this loop stands for; the
    values the loop carries, *not* counting the state tag, so a call
    that fills fewer of them can carry the rest forward; every name the
    program already uses; and whether a path that supplies no value can
    be reached at all (see `falls_through`). *)
type context = {
  names : (string * callee) list;
  slots : string list;
  reserved : StringSet.t;
  falls_through : bool;
}

(** The two things this pass fills in rather than rebuilds, for the same
    reason `Typesystem.record` fills in one table: they are its result,
    not its context. `types` is the checker's table, extended for the
    annotatable nodes the pass builds -- without it, a `-t pyking` run
    would print those with no type at all, the checker having never seen
    them. `next_symbol` hands out the identities those entries are keyed
    by, continuing past the highest the program already uses, which is
    exactly what `Analyses.symbolize` will do with the rest afterwards.
    `reserved` is ordinary context: every name the program writes. *)
type pass_state = {
  reserved : StringSet.t;
  types : typ IntMap.t;
  next_symbol : int;
}

(** A symbol nothing else has. pass_state -> (int, pass_state) *)
let symbol work = (work.next_symbol, { work with next_symbol = work.next_symbol + 1 })

(** pass_state remembering a type under a symbol, so that a printed AST
    shows what the pass built with the types it built them from.
    pass_state -> int -> typ -> pass_state *)
let remember work sym type_ = { work with types = IntMap.add sym type_ work.types }

(* --- building the nodes the pass writes ---
   The Python leaves the symbol to the dataclass default; the nodes that
   need one of their own ask `symbol` for it. *)

let e_int info n = EInt (info, n, 0)
let e_string info s = EString (info, s, 0)
let e_bool info b = EBool (info, b, 0)
let e_var info name = EVar (info, name, 0)
let e_eq info left right = EEq (info, left, right, 0)
let e_call info func args = ECall (info, func, plain_args args, 0)
let e_list info elements = EList (info, elements, 0)
let e_tuple info elements = ETuple (info, elements, 0)
let target_name info name = TargetName (info, name, 0)
let target_tuple info elements = TargetTuple (info, elements, 0)
let s_return info e = SReturn (info, e, 0)
let s_expr info e = SExprStmt (info, e, 0)
let s_continue info = SContinue (info, 0)
let s_if info cond then_body else_body = SIf (info, cond, then_body, else_body, 0)
let unit_value info = e_tuple info []
let t_int info = TInt (info, 0)

(** The body a definition was written with. stmt -> [stmt] *)
let def_body node =
  match node with SFunctionDef (_, _, _, body, _, _, _) -> body | _ -> []

(** The name a definition was written with. stmt -> string *)
let def_name node =
  match node with SFunctionDef (_, name, _, _, _, _, _) -> name | _ -> ""

(** The parameters a definition was written with. stmt -> [param] *)
let def_params node =
  match node with SFunctionDef (_, _, params, _, _, _, _) -> params | _ -> []

let param_name (Param (_, name, _, _, _)) = name
let param_info (Param (info, _, _, _, _)) = info

(** node with a different body. stmt -> [stmt] -> stmt *)
let with_body node body =
  match node with
  | SFunctionDef (info, name, params, _, return_type, sym, public) ->
      SFunctionDef (info, name, params, body, return_type, sym, public)
  | node -> node

(* --- finding tail calls ---

   Tail position is PYKING.md's own: a block's last statement,
   recursively through the branches of an `if` and the arms of a
   `match`, plus the operand of every `return`. The walk stops at a
   nested `def` -- a tail call written there belongs to *that* function
   -- and at a `for`, `while` or `loop`, since a `break` written inside
   one of those would belong to it rather than to the loop being
   built. *)

(** Records expr if it is a call to one of names, or if a branch of it
    is: `if c then a else f(x)` waits for nothing either, so its
    branches are tail positions as much as an `if` statement's are.
    expr -> StringSet.t -> StringSet.t -> StringSet.t *)
let rec record_call e names found =
  match e with
  | ECall (_, EVar (_, name, _), _, _) when StringSet.mem name names ->
      StringSet.add name found
  | EIf (_, _, then_expr, else_expr, _) ->
      record_call else_expr names (record_call then_expr names found)
  | _ -> found

(** Records the tail calls in one statement.
    stmt -> StringSet.t -> StringSet.t -> bool -> StringSet.t *)
let rec tail_calls_in_stmt statement names found tail =
  match statement with
  | SReturn (_, e, _) -> record_call e names found
  | SReturnStmt (_, inner, _) -> tail_calls_in_stmt inner names found true
  | SExprStmt (_, e, _) when tail -> record_call e names found
  | SIf (_, _, then_body, else_body, _) ->
      let found = tail_calls_in then_body names found tail in
      (match else_body with
      | None -> found
      | Some else_body -> tail_calls_in else_body names found tail)
  | SMatch (_, _, cases, _) ->
      List.fold_left
        (fun found (MatchCase (_, _, body, _)) ->
          tail_calls_in body names found tail)
        found cases
  (* A `break` written in one of these would belong to it, and a `def`'s
     tail is its own. *)
  | SLoop _ | SFunctionDef _ -> found
  | _ -> found

(** Records the tail calls in one block. The last statement is in tail
    position when tail; a `return` anywhere is.
    [stmt] -> StringSet.t -> StringSet.t -> bool -> StringSet.t *)
and tail_calls_in stmts names found tail =
  let count = List.length stmts in
  let found, _ =
    List.fold_left
      (fun (found, index) statement ->
        ( tail_calls_in_stmt statement names found (tail && index = count - 1),
          index + 1 ))
      (found, 0) stmts
  in
  found

(** The names in `names` that func calls in tail position.
    stmt -> StringSet.t -> StringSet.t *)
let tail_calls func names =
  tail_calls_in (def_body func) names StringSet.empty true

(* --- rewriting one body --- *)

(** Whether a body of this result type can reach a path that supplies no
    value, and so needs the `break ()` that stands for one.

    Only a function worth unit can: the checker asks every other body to
    return on every path or to end in a value of its type, so a
    fallthrough is already ruled out. Emitting `break ()` there anyway
    builds a loop whose `break`s disagree -- unreachable, so the program
    still runs, but no longer a program the checker accepts, which is
    what the `pyking` target's output would show. Unknown counts as
    "can", since dropping one that is needed leaves a loop nothing goes
    round with. typ option -> bool *)
let falls_through result =
  match result with
  | Some (TTuple (_, elements, _)) -> elements = []
  | None -> true
  | Some _ -> false

(** The same question asked of a function's whole type rather than of
    its result. An `all` around it says what its variables are and
    nothing about whether it falls through, so it is stepped past.
    typ option -> bool *)
let rec falls_through_signature signature =
  match signature with
  | Some (TForall (_, _, body, _)) -> falls_through_signature (Some body)
  | Some (TFunction (_, _, result, _, _, _)) -> falls_through (Some result)
  | _ -> true

(** Raised where a tail call cannot be turned into going round, so the
    function or group it is in is left as the recursion it was. *)
exception Decline

(** Whether every path through this block leaves the function. A
    `break`/`continue` cannot appear here -- one written inside a loop of
    the program's own is that loop's, and this walk does not enter one --
    so a `return` is the only way out. [stmt] -> bool *)
let rec always_returns stmts =
  match List.rev stmts with
  | [] -> false
  | last :: _ -> (
      match last with
      | SReturn _ | SReturnStmt _ -> true
      | SIf (_, _, then_body, else_body, _) -> (
          match else_body with
          | None -> false
          | Some else_body ->
              always_returns then_body && always_returns else_body)
      | _ -> false)

(** The block `head :: rest` written so that head's own tails are the
    block's: a statement that always leaves the block takes what follows
    it into the branch that does not. Declines where it cannot, rather
    than moving statements into a block that binds names of its own --
    what `rest` reads would change meaning. stmt -> [stmt] -> [stmt] *)
let hoist head rest =
  match head with
  (* Nothing written after a `return` runs. *)
  | SReturn _ | SReturnStmt _ -> [ head ]
  | SIf (info, cond, then_body, else_body, sym) -> (
      match else_body with
      | None when always_returns then_body ->
          [ SIf (info, cond, then_body, Some rest, sym) ]
      | Some else_body
        when always_returns then_body && always_returns else_body ->
          [ head ]
      | _ -> raise Decline)
  | _ -> raise Decline

(** Whether this value is another turn rather than an answer: a call the
    loop stands for, or an `if` expression choosing one.
    expr -> context -> bool *)
let is_going_round e context =
  match e with
  | ECall (_, EVar (_, name, _), args, _) -> (
      match List.assoc_opt name context.names with
      | Some callee -> List.length args = callee.arity
      | None -> false)
  | EIf _ ->
      not
        (StringSet.is_empty
           (record_call e
              (List.fold_left
                 (fun s (name, _) -> StringSet.add name s)
                 StringSet.empty context.names)
              StringSet.empty))
  | _ -> false

(** Whether a branch of this `if` expression, however deeply chained, is
    a call the loop stands for. expr -> context -> bool *)
let chooses_call e context =
  not
    (StringSet.is_empty
       (record_call e
          (List.fold_left
             (fun s (name, _) -> StringSet.add name s)
             StringSet.empty context.names)
          StringSet.empty))

(** Whether a call the loop stands for is written in a tail position of
    this statement -- the calls `going_on` would turn into another turn.
    `tail` says the statement's own value is the body's.
    stmt -> context -> bool -> bool *)
let rec goes_round statement context tail =
  match statement with
  | SReturn (_, e, _) -> is_going_round e context
  | SExprStmt (_, e, _) -> tail && is_going_round e context
  | SReturnStmt (_, inner, _) -> goes_round inner context true
  | SIf (_, _, then_body, else_body, _) ->
      goes_round_in then_body context tail
      || (match else_body with
         | None -> false
         | Some else_body -> goes_round_in else_body context tail)
  | SMatch (_, _, cases, _) ->
      List.exists
        (fun (MatchCase (_, _, body, _)) -> goes_round_in body context tail)
        cases
  | _ -> false

(** The same question asked of a block: only its last statement is in
    tail position. [stmt] -> context -> bool -> bool *)
and goes_round_in stmts context tail =
  let count = List.length stmts in
  List.exists
    (fun (index, statement) ->
      goes_round statement context (tail && index = count - 1))
    (List.mapi (fun index statement -> (index, statement)) stmts)

(** The accumulator a call to a rewritten function becomes: its
    arguments, the state tag in front where there is a group, and the
    slots it does not fill carried forward from the turn it is on --
    which is what lets one loop serve functions of different widths.
    None where the loop carries nothing at all.
    info -> callee -> [expr] -> context -> expr option *)
let state_of info callee args context =
  let rec drop n = function
    | list when n <= 0 -> list
    | [] -> []
    | _ :: rest -> drop (n - 1) rest
  in
  let values =
    args
    @ List.map (fun slot -> e_var info slot) (drop (List.length args) context.slots)
  in
  let values =
    match callee.tag with
    | Some tag -> e_int info tag :: values
    | None -> values
  in
  match values with
  | [] -> None
  | [ one ] -> Some one
  | values -> Some (e_tuple info values)

(** What the loop does with this value: go round again when it is a call
    the loop stands for, and stop with it otherwise.
    info -> expr -> context -> [stmt] *)
let rec going_on info e context =
  match e with
  | EIf (if_info, cond, then_expr, else_expr, _) when chooses_call e context ->
      (* An `if` expression one of whose branches goes round again: as an
         expression there is nowhere to say that, so it becomes the
         statement it already means. *)
      [
        s_if if_info cond
          (going_on if_info then_expr context)
          (Some (going_on if_info else_expr context));
      ]
  | ECall (call_info, EVar (_, name, _), args, _)
    when (match List.assoc_opt name context.names with
         | Some callee -> List.length args = callee.arity
         | None -> false) -> (
      let callee = List.assoc name context.names in
      match state_of call_info callee (arg_exprs args) context with
      (* A loop carrying nothing: there is no next value to give it, only
         another turn. *)
      | None -> [ s_continue info ]
      (* The next turn carries what the body ends in, so saying it is
         leaving it there (PYKING.md, "`loop` loops"). *)
      | Some state -> [ s_expr info state ])
  | _ -> [ s_return info e ]

(** preferred, or preferred2, preferred3, ... -- the first name the
    program does not already use. StringSet.t -> string -> string *)
let fresh reserved preferred =
  if not (StringSet.mem preferred reserved) then preferred
  else
    let rec go n =
      let candidate = Printf.sprintf "%s%d" preferred n in
      if StringSet.mem candidate reserved then go (n + 1) else candidate
    in
    go 2

(** A block whose last statement is what the loop does next, and whose
    `return`s are likewise wherever they are. A statement before the last
    with a call the loop stands for inside it is restructured first
    (`hoist`), since going round is said by ending in the next
    accumulator and only the block's last statement can do that.
    [stmt] -> context -> [stmt] *)
let rec rewrite_block stmts context =
  match stmts with
  | [] -> stmts
  | [ head ] -> rewrite_tail head context
  | head :: rest ->
      if goes_round head context false then
        rewrite_block (hoist head rest) context
      else rewrite_inner head context @ rewrite_block rest context

(** The last statement of a block, as the statements saying what the loop
    does next. stmt -> context -> [stmt] *)
and rewrite_tail statement context =
  match statement with
  | SExprStmt (info, e, _) | SReturn (info, e, _) -> going_on info e context
  | SReturnStmt (_, inner, _) ->
      (* `return if c: ...` -- the branches are the tails, and the
         `return` itself has nothing left to say. *)
      rewrite_tail inner context
  | SIf (info, cond, then_body, else_body, _) ->
      (* A path that runs no branch supplies unit, and that is what the
         function would have returned -- where such a path exists at all
         (`falls_through`). *)
      let then_rewritten = rewrite_block then_body context in
      let otherwise =
        match else_body with
        | Some else_body -> Some (rewrite_block else_body context)
        | None ->
            if context.falls_through then
              Some [ s_return info (unit_value info) ]
              (* No such path, so the `if` keeps the one branch it was
                 written with rather than growing an empty `else`. *)
            else if always_returns then_rewritten then None
            else raise Decline
      in
      [ s_if info cond then_rewritten otherwise ]
  | SMatch (info, subject, cases, _) ->
      (* A subject matching no arm falls out of the function as unit,
         which the `return` after the match is. A match that covers every
         value cannot do that, and needs none. *)
      let rewritten_cases =
        List.map (fun c -> rewrite_case c context) cases
      in
      let rewritten = SMatch (info, subject, rewritten_cases, 0) in
      if
        (not context.falls_through)
        || Typesystem.covers
             (List.map (fun (MatchCase (_, p, _, _)) -> p) cases)
      then [ rewritten ]
      else if
        (* An arm that went round would reach that `return` instead of
           taking another turn, so a match that needs one is declined. *)
        not
          (List.for_all
             (fun (MatchCase (_, _, body, _)) -> always_returns body)
             rewritten_cases)
      then raise Decline
      else [ rewritten; s_return info (unit_value info) ]
  | SLoop (info, _, _, _, _, _, _) ->
      (* A loop of the program's own in tail position is what the
         function is worth, so it is bound and then returned. *)
      let name = fresh context.reserved "answer" in
      [
        SLetStmt (info, target_name info name, statement, None, 0, false);
        s_return info (e_var info name);
      ]
  | statement ->
      (* Anything else supplies unit (PYKING.md, "Tail position"). *)
      let info = stmt_info statement in
      [ statement; s_return info (unit_value info) ]

(** One arm of a `match` in tail position: its block, rewritten like any
    other. match_case -> context -> match_case *)
and rewrite_case (MatchCase (info, pattern, body, sym)) context =
  MatchCase (info, pattern, rewrite_block body context, sym)

(** A statement that is not the block's last: only the `return`s inside
    it change, since each one leaves the function and so is a tail
    position of its own. None of them goes round -- a block whose head
    does has been restructured already (`hoist`).
    stmt -> context -> [stmt] *)
and rewrite_inner statement context =
  match statement with
  | SReturn (info, e, _) -> going_on info e context
  | SReturnStmt (_, inner, _) -> rewrite_tail inner context
  | SIf (info, cond, then_body, else_body, sym) ->
      [
        SIf
          ( info,
            cond,
            rewrite_inners then_body context,
            Option.map (fun body -> rewrite_inners body context) else_body,
            sym );
      ]
  | SMatch (info, subject, cases, sym) ->
      [
        SMatch
          ( info,
            subject,
            List.map
              (fun (MatchCase (case_info, pattern, body, case_sym)) ->
                MatchCase
                  (case_info, pattern, rewrite_inners body context, case_sym))
              cases,
            sym );
      ]
  (* A `for`, `while` or `loop` of the program's own: a `break` written
     inside it would belong to it, so the `return`s in there stay
     `return`s. A nested `def` is its own business. *)
  | statement -> [ statement ]

(** Every statement of a block, none of them its last.
    [stmt] -> context -> [stmt] *)
and rewrite_inners stmts context =
  List.concat_map (fun s -> rewrite_inner s context) stmts

(* --- one function that calls itself --- *)

(** The loop a rewritten body runs in: it carries the names it was given,
    starting from what they already hold. `carried` is what the checker
    says each of them is, so that the loop node carries its own type into
    the table.
    info -> [string] -> [stmt] -> [typ option] -> pass_state
    -> (stmt, pass_state) *)
let loop_over info names body carried work =
  match names with
  | [] -> (SLoop (info, None, None, None, None, body, 0), work)
  | first :: _ ->
      let target =
        match names with
        | [ one ] -> target_name info one
        | names ->
            target_tuple info (List.map (fun name -> target_name info name) names)
      in
      let init =
        match names with
        | [ one ] -> e_var info one
        | names -> e_tuple info (List.map (fun name -> e_var info name) names)
      in
      ignore first;
      if List.exists (fun type_ -> type_ = None) carried then
        (SLoop (info, Some target, Some init, None, None, body, 0), work)
      else
        let accumulator =
          match carried with
          | [ one ] -> Option.get one
          | carried -> TTuple (info, List.map Option.get carried, 0)
        in
        let sym, work = symbol work in
        ( SLoop (info, Some target, Some init, None, None, body, sym),
          remember work sym accumulator )

(** func with its own tail calls turned into a loop carrying its
    parameters. stmt -> pass_state -> (stmt, pass_state) *)
let rewrite_self func work =
  let slots = List.map param_name (def_params func) in
  let context =
    {
      names = [ (def_name func, { tag = None; arity = List.length slots }) ];
      slots;
      reserved = work.reserved;
      falls_through =
        falls_through_signature (IntMap.find_opt (stmt_sym func) work.types);
    }
  in
  let carried =
    List.map
      (fun (Param (_, _, _, _, sym)) -> IntMap.find_opt sym work.types)
      (def_params func)
  in
  let loop, work =
    loop_over (stmt_info func) slots
      (rewrite_block (def_body func) context)
      carried work
  in
  (with_body func [ loop ], work)

(* --- a group that calls each other --- *)

(** Whether the checker left this type open, so that nothing can be
    written down for it. typ -> bool *)
let undecided type_ =
  match type_ with
  | TUnknown _ -> true
  | TVar (_, _, _, rigid) -> not rigid
  | _ -> false

(** A value of this type to enter a slot with, or None for a type that
    has no obvious one. Never read -- see `merge` -- so the only thing
    asked of it is that it type-checks. typ -> info -> expr option *)
let rec zero type_ info =
  match type_ with
  | TInt _ -> Some (e_int info 0)
  | TString _ -> Some (e_string info "")
  | TBool _ -> Some (e_bool info false)
  | TList _ -> Some (e_list info [])
  | TTuple (_, elements, _) ->
      let insides = List.map (fun element -> zero element info) elements in
      if List.exists (fun inside -> inside = None) insides then None
      else Some (e_tuple info (List.map Option.get insides))
  (* A function has no zero, and neither has a type variable: the caller
     picks what it is, so nothing here can name a value of it. *)
  | _ -> None

(** The parameter and result types the checker worked out for func, or
    None where it did not work out exactly one -- a function nothing
    called, or one checked at several shapes, has no single answer to
    give a shared loop.
    stmt -> typ IntMap.t -> ([typ], typ) option *)
let signature func types =
  match IntMap.find_opt (stmt_sym func) types with
  | Some (TFunction (_, params, result, _, _, _))
    when List.length params = List.length (def_params func) ->
      if List.exists undecided (params @ [ result ]) then None
      else Some (params, result)
  | _ -> None

(** What the group's functions agree on, as (slot types, result type), or
    None if the checker's types say they do not agree enough to share one
    loop. Four things are asked, and each of them is a thing only the
    checker knows (docs/optimization.md, "The gate").
    [stmt] -> typ IntMap.t -> ([typ], typ) option *)
let shared group types =
  let signatures = List.map (fun func -> signature func types) group in
  if List.exists (fun s -> s = None) signatures then None
    (* 4. one definite type each *)
  else
    let signatures = List.map Option.get signatures in
    let width =
      List.fold_left
        (fun width (params, _) -> max width (List.length params))
        0 signatures
    in
    let info = stmt_info (List.hd group) in
    let rec slots position =
      if position >= width then Some []
      else
        let here =
          List.filter_map
            (fun (params, _) ->
              if position < List.length params then
                Some (List.nth params position)
              else None)
            signatures
        in
        let first = List.hd here in
        if not (List.for_all (fun type_ -> Typesystem.same_type type_ first) here) then
          None (* 1. the members agree per position *)
        else if
          List.length here <> List.length signatures && zero first info = None
        then None (* 2. a padded slot needs a zero *)
        else
          match slots (position + 1) with
          | None -> None
          | Some rest -> Some (first :: rest)
    in
    match slots 0 with
    | None -> None
    | Some slot_types ->
        let results = List.map snd signatures in
        let first = List.hd results in
        if not (List.for_all (fun result -> Typesystem.same_type result first) results) then
          None (* 3. and on what they answer with *)
        else Some (slot_types, first)

(** Whether name appears anywhere in node, as a use or a binding. A
    deliberately blunt test: it decides only whether a generated name may
    reuse a written one, where being over-careful costs a longer name and
    being wrong costs a captured variable. [stmt] -> string -> bool *)
let mentions stmts name =
  Walk.exists_stmts (fun node -> Walk.name_field node = Some name) stmts

(** Whether giving a slot this name would change what it means inside
    func: it does unless func's own parameter there is already called
    that, or func never mentions the name at all.
    stmt -> int -> string -> bool *)
let would_capture func position name =
  let params = def_params func in
  if position < List.length params && param_name (List.nth params position) = name
  then false
  else mentions (def_body func) name

(** One name per slot -- as many as the widest function takes. Each is
    the name of the first function that *has* that position, unless some
    function's body would have it mean something else, in which case a
    fresh one. A function narrower than the group is asked too: it does
    not use the slot, but a name that captured something it reads would
    change it all the same. [stmt] -> int -> StringSet.t -> [string] *)
let slot_names group width reserved =
  let rec go position slots =
    if position >= width then List.rev slots
    else
      let owner =
        List.nth
          (def_params
             (List.find
                (fun func -> position < List.length (def_params func))
                group))
          position
      in
      let name = param_name owner in
      let name =
        if List.exists (fun func -> would_capture func position name) group then
          fresh
            (List.fold_left (fun s n -> StringSet.add n s) reserved slots)
            (param_name owner ^ "_slot")
        else name
      in
      go (position + 1) (name :: slots)
  in
  go 0 []

(** One function's body inside the worker: its parameters read off the
    slots they were passed in, and its tail calls rewritten. A function
    narrower than the group reads only the slots it has.
    stmt -> [string] -> [typ] -> context -> pass_state
    -> ([stmt], pass_state) *)
let branch func slots slot_types context work =
  let rec rebind params slots types out work =
    match (params, slots, types) with
    | param :: params, slot :: slots, type_ :: types ->
        if param_name param = slot then
          rebind params slots types out work
        else
          let sym, work = symbol work in
          let node =
            SLet
              ( param_info param,
                target_name (param_info param) (param_name param),
                e_var (param_info param) slot,
                None,
                sym,
                false )
          in
          rebind params slots types (out @ [ node ]) (remember work sym type_)
    | _ -> (out, work)
  in
  let rebindings, work = rebind (def_params func) slots slot_types [] work in
  (rebindings @ rewrite_block (def_body func) context, work)

(** The `if state == 0: ... else: ...` chain choosing whose body runs.
    The last function needs no test: the state is one of them.
    info -> string -> [(string, int)] -> [stmt] -> [[stmt]] -> stmt *)
let dispatch info state tags group branches =
  let pairs = List.combine group branches in
  let last = List.nth branches (List.length branches - 1) in
  let earlier = List.filteri (fun i _ -> i < List.length pairs - 1) pairs in
  let chain =
    List.fold_left
      (fun chain (func, branch) ->
        [
          s_if info
            (e_eq info (e_var info state)
               (e_int info (List.assoc (def_name func) tags)))
            branch (Some chain);
        ])
      last (List.rev earlier)
  in
  List.hd chain

(** The one-line function left where a merged one was: it hands the
    worker its state, its arguments, and a value of the right type for
    each slot it does not have.
    stmt -> string -> int -> [expr] -> stmt *)
let wrapper func worker tag zeros =
  let info = stmt_info func in
  let rec drop n = function
    | list when n <= 0 -> list
    | [] -> []
    | _ :: rest -> drop (n - 1) rest
  in
  let call =
    e_call info (e_var info worker)
      ((e_int info tag
       :: List.map (fun p -> e_var (param_info p) (param_name p)) (def_params func))
      @ drop (List.length (def_params func)) zeros)
  in
  (* A body of one expression: what the block supplies is that call's
     value, which is what this function now returns (PYKING.md, "Tail
     position"). *)
  with_body func [ s_expr info call ]

(** The worker and wrappers a mutually recursive group becomes, or None
    if the checker's types say it is one this cannot make (see `shared`).
    [stmt] -> pass_state -> int -> ([stmt] option, pass_state) *)
let merge group work index =
  match shared group work.types with
  | None -> (None, work)
  | Some (slot_types, result) ->
      let width = List.length slot_types in
      let worker = fresh work.reserved (Printf.sprintf "%s%d" group_name index) in
      let state =
        fresh (StringSet.add worker work.reserved) state_name
      in
      let slots =
        slot_names group width
          (StringSet.add state (StringSet.add worker work.reserved))
      in
      let tags = List.mapi (fun tag func -> (def_name func, tag)) group in
      let context =
        {
          names =
            List.map
              (fun func ->
                ( def_name func,
                  {
                    tag = Some (List.assoc (def_name func) tags);
                    arity = List.length (def_params func);
                  } ))
              group;
          slots;
          reserved =
            List.fold_left
              (fun s n -> StringSet.add n s)
              (StringSet.add state (StringSet.add worker work.reserved))
              slots;
          falls_through = falls_through (Some result);
        }
      in
      let info = stmt_info (List.hd group) in
      let branches, work =
        List.fold_left
          (fun (branches, work) func ->
            let one, work = branch func slots slot_types context work in
            (branches @ [ one ], work))
          ([], work) group
      in
      let chosen = dispatch info state tags group branches in
      let carried = List.map (fun t -> Some t) (t_int info :: slot_types) in
      let loop, work =
        loop_over info (state :: slots) [ chosen ] carried work
      in
      let body = [ loop ] in
      let state_sym, work = symbol work in
      let work = remember work state_sym (t_int info) in
      let params, work =
        List.fold_left2
          (fun (params, work) slot type_ ->
            let sym, work = symbol work in
            ( params @ [ Param (info, slot, Some type_, None, sym) ],
              remember work sym type_ ))
          ([ Param (info, state, Some (t_int info), None, state_sym) ], work)
          slots slot_types
      in
      let definition_sym, work = symbol work in
      let definition =
        SFunctionDef
          (info, worker, params, body, Some result, definition_sym, false)
      in
      let work =
        remember work definition_sym
          (TFunction (info, t_int info :: slot_types, result, 0, 0, None))
      in
      (* Every slot has a type, so every wrapper has something to enter
         the ones it does not fill with. The value is never read -- the
         state it belongs to has no such parameter -- so being of the
         right type is the whole of what is asked of it. *)
      let zeros = List.map (fun type_ -> Option.get (zero type_ info)) slot_types in
      ( Some
          (definition
          :: List.map
               (fun func ->
                 wrapper func worker (List.assoc (def_name func) tags) zeros)
               group),
        work )

(* --- walking the program --- *)

(** Every name an assignment target binds. assign_target -> [string] *)
let rec target_names target =
  match target with
  | TargetName (_, name, _) -> [ name ]
  | TargetTuple (_, elements, _) -> List.concat_map target_names elements

(** Whether stmts bind any of names anywhere inside them -- which would
    make a call written there mean something other than the function.
    [stmt] -> StringSet.t -> bool *)
let binds stmts names =
  let touches list = List.exists (fun name -> StringSet.mem name names) list in
  Walk.exists_stmts
    (fun node ->
      match node with
      | Walk.NStmt (SLet (_, target, _, _, _, _))
      | Walk.NStmt (SLetStmt (_, target, _, _, _, _)) ->
          touches (target_names target)
      | Walk.NStmt (SVar (_, name, _, _)) -> StringSet.mem name names
      | Walk.NStmt (SLoop (_, target, _, _, iterate, _, _)) ->
          (match target with
          | Some target -> touches (target_names target)
          | None -> false)
          (* A `for` binds its element name each turn, so it is a
             rebinding like any other. *)
          || (match iterate with
             | Some (ForIn (_, name, _, _)) -> StringSet.mem name names
             | _ -> false)
      | Walk.NStmt (SFunctionDef (_, name, params, _, _, _, _)) ->
          StringSet.mem name names || touches (List.map param_name params)
      | _ -> false)
    stmts

(** Whether func may be rewritten at all: its parameters have to be
    distinct names it does not bind again, since the loop carries them.
    stmt -> bool *)
let rewritable func =
  let names = List.map param_name (def_params func) in
  let distinct =
    StringSet.cardinal
      (List.fold_left (fun s n -> StringSet.add n s) StringSet.empty names)
    = List.length names
  in
  distinct
  && not (binds (def_body func) (StringSet.singleton (def_name func)))

(** The defs of one block, in source order, dropping any name defined
    twice (a program the name analysis will refuse anyway).
    [stmt] -> [(string, stmt)] *)
let functions_of stmts =
  let defs =
    List.filter_map
      (fun statement ->
        match statement with
        | SFunctionDef (_, name, _, _, _, _, _) -> Some (name, statement)
        | _ -> None)
      stmts
  in
  List.filter
    (fun (name, _) ->
      List.length (List.filter (fun (other, _) -> other = name) defs) = 1)
    defs

(** Every function reachable from name by tail calls.
    string -> [(string, StringSet.t)] -> StringSet.t *)
let reachable name calls =
  let rec go seen todo =
    match todo with
    | [] -> seen
    | current :: rest ->
        if StringSet.mem current seen then go seen rest
        else
          let next =
            match List.assoc_opt current calls with
            | Some names -> StringSet.elements names
            | None -> []
          in
          go (StringSet.add current seen) (next @ rest)
  in
  go StringSet.empty
    (match List.assoc_opt name calls with
    | Some names -> StringSet.elements names
    | None -> [])

(** The block's functions in tail-call groups: each is a list that
    tail-calls its way round to itself, in the order the functions were
    written. [(string, stmt)] -> [[string]] *)
let groups_of functions =
  let names =
    List.fold_left
      (fun s (name, _) -> StringSet.add name s)
      StringSet.empty functions
  in
  let calls =
    List.map (fun (name, func) -> (name, tail_calls func names)) functions
  in
  let order = List.map fst functions in
  let reaches = List.map (fun name -> (name, reachable name calls)) order in
  let groups, _ =
    List.fold_left
      (fun (groups, grouped) name ->
        if StringSet.mem name grouped then (groups, grouped)
        else
          let mine = List.assoc name reaches in
          let group =
            List.filter
              (fun other ->
                other = name
                || (StringSet.mem other mine
                   && StringSet.mem name (List.assoc other reaches)))
              order
          in
          ( groups @ [ group ],
            List.fold_left (fun s n -> StringSet.add n s) grouped group ))
      ([], StringSet.empty) order
  in
  groups

(** Every name one statement binds in its own block. stmt -> StringSet.t *)
let bound_names statement =
  let of_list names =
    List.fold_left (fun s n -> StringSet.add n s) StringSet.empty names
  in
  match statement with
  | SLet (_, target, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
      of_list (target_names target)
  | SVar (_, name, _, _) -> StringSet.singleton name
  | SFunctionDef (_, name, _, _, _, _, _) -> StringSet.singleton name
  | _ -> StringSet.empty

(** Whether a group may be merged where its first member stands: no
    member may read a name the block binds between them, since the merged
    worker takes the first member's place and everything after it is
    bound later than that.

    Blunt on purpose, like `mentions`: it asks whether the name appears
    at all, and being over-careful costs a merge that was safe rather
    than a program that captures the wrong thing.
    [stmt] -> [string] -> bool *)
let same_scope stmts group =
  let positions =
    List.rev
      (snd
         (List.fold_left
            (fun (index, found) statement ->
              match statement with
              | SFunctionDef (_, name, _, _, _, _, _)
                when List.mem name group && not (List.mem_assoc name found) ->
                  (index + 1, (name, index) :: found)
              | _ -> (index + 1, found))
            (0, []) stmts))
  in
  if List.length positions < 2 then true
  else
    let indices = List.map snd positions in
    let first = List.fold_left min (List.hd indices) indices in
    let last = List.fold_left max (List.hd indices) indices in
    let between =
      List.fold_left
        (fun between (index, statement) ->
          if index <= first || index >= last then between
          else
            match statement with
            | SFunctionDef (_, name, _, _, _, _, _) when List.mem name group ->
                between
            | statement -> StringSet.union between (bound_names statement))
        StringSet.empty
        (List.mapi (fun index statement -> (index, statement)) stmts)
    in
    if StringSet.is_empty between then true
    else
      not
        (List.exists
           (fun (_, index) ->
             StringSet.exists
               (fun bound -> mentions (def_body (List.nth stmts index)) bound)
               between)
           positions)

(** One block with its own functions rewritten and every nested block
    walked. [stmt] -> pass_state -> ([stmt], pass_state) *)
let rec block stmts work =
  let stmts, work =
    List.fold_left
      (fun (out, work) statement ->
        let statement, work = walk statement work in
        (out @ [ statement ], work))
      ([], work) stmts
  in
  let functions = functions_of stmts in
  if functions = [] then (stmts, work)
  else
    let groups = groups_of functions in
    let rewritten, replacements, work =
      List.fold_left
        (fun (rewritten, replacements, work) (index, group) ->
          match group with
          | [ only ] ->
              let func = List.assoc only functions in
              if
                StringSet.mem only (tail_calls func (StringSet.singleton only))
                && rewritable func
              then rewrite_one func work rewritten replacements
              else (rewritten, replacements, work)
          | group ->
              let members = List.map (fun name -> List.assoc name functions) group in
              if not (List.for_all rewritable members) then
                (rewritten, replacements, work)
              else if not (same_scope stmts group) then
                (* One of them reads a name bound between the group's
                   members. The merged worker stands where the *first*
                   member did, so that name would not be bound yet -- see
                   tests/lexical_capture_group.pyk, whose `odd` reads a
                   `step` written between it and `even`. *)
                rewrite_selves members work rewritten replacements
              else
                let merged, work =
                  try merge members work index with Decline -> (None, work)
                in
                (match merged with
                | None ->
                    (* A group the checker's types say cannot share one
                       loop, or one holding a tail call that cannot be
                       said as another turn, may still have self-calls
                       worth rewriting. *)
                    rewrite_selves members work rewritten replacements
                | Some merged ->
                    let replacements =
                      (List.hd group, merged)
                      :: List.map
                           (fun name -> (name, []))
                           (List.tl group)
                      @ replacements
                    in
                    (rewritten, replacements, work)))
        ([], [], work)
        (List.mapi (fun index group -> (index + 1, group)) groups)
    in
    if rewritten = [] && replacements = [] then (stmts, work)
    else
      ( List.concat_map
          (fun statement ->
            match statement with
            | SFunctionDef (_, name, _, _, _, _, _)
              when List.mem_assoc name replacements ->
                List.assoc name replacements
            | SFunctionDef (_, name, _, _, _, _, _)
              when List.mem_assoc name rewritten ->
                [ List.assoc name rewritten ]
            | statement -> [ statement ])
          stmts,
        work )

(** Records func's rewritten form, or leaves it alone where the rewrite
    declined.
    stmt -> pass_state -> [(string, stmt)] -> [(string, [stmt])]
    -> ([(string, stmt)], [(string, [stmt])], pass_state) *)
and rewrite_one func work rewritten replacements =
  match rewrite_self func work with
  | rewrote, work -> ((def_name func, rewrote) :: rewritten, replacements, work)
  | exception Decline -> (rewritten, replacements, work)

(** The members of a group that could not be merged, each rewritten on
    its own where it calls itself.
    [stmt] -> pass_state -> [(string, stmt)] -> [(string, [stmt])]
    -> ([(string, stmt)], [(string, [stmt])], pass_state) *)
and rewrite_selves members work rewritten replacements =
  List.fold_left
    (fun (rewritten, replacements, work) func ->
      if
        StringSet.mem (def_name func)
          (tail_calls func (StringSet.singleton (def_name func)))
      then rewrite_one func work rewritten replacements
      else (rewritten, replacements, work))
    (rewritten, replacements, work) members

(** statement with every block inside it optimized.
    stmt -> pass_state -> (stmt, pass_state) *)
and walk statement work =
  match statement with
  | SFunctionDef (info, name, params, body, return_type, sym, public) ->
      let body, work = block body work in
      (SFunctionDef (info, name, params, body, return_type, sym, public), work)
  | SLoop (info, target, init, annotation, iterate, body, sym) ->
      let body, work = block body work in
      (SLoop (info, target, init, annotation, iterate, body, sym), work)
  | SIf (info, cond, then_body, else_body, sym) ->
      let then_body, work = block then_body work in
      let else_body, work =
        match else_body with
        | None -> (None, work)
        | Some else_body ->
            let else_body, work = block else_body work in
            (Some else_body, work)
      in
      (SIf (info, cond, then_body, else_body, sym), work)
  | SMatch (info, subject, cases, sym) ->
      let cases, work =
        List.fold_left
          (fun (out, work) (MatchCase (case_info, pattern, body, case_sym)) ->
            let body, work = block body work in
            (out @ [ MatchCase (case_info, pattern, body, case_sym) ], work))
          ([], work) cases
      in
      (SMatch (info, subject, cases, sym), work)
  | SLetStmt (info, target, inner, annotation, sym, public) ->
      let inner, work = walk inner work in
      (SLetStmt (info, target, inner, annotation, sym, public), work)
  | SReturnStmt (info, inner, sym) ->
      let inner, work = walk inner work in
      (SReturnStmt (info, inner, sym), work)
  | statement -> (statement, work)

(** Every identifier written anywhere in the program, so a generated name
    can avoid all of them. [stmt] -> StringSet.t *)
let identifiers stmts =
  Walk.fold_stmts
    (fun found node ->
      match Walk.name_field node with
      | Some name -> StringSet.add name found
      | None -> found)
    StringSet.empty stmts

(** A whole program with its tail calls rewritten, and the checker's
    table extended for the nodes that rewriting built. Never rejects: a
    program it cannot improve comes back as it was.
    [stmt] -> typ IntMap.t -> ([stmt], typ IntMap.t) *)
let optimize stmts tmap =
  let work =
    {
      reserved = identifiers stmts;
      types = tmap;
      next_symbol = Analyses.highest_sym stmts + 1;
    }
  in
  let stmts, work = block stmts work in
  (stmts, work.types)
