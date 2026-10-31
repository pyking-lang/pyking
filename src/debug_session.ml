(** The debugger's core: a program run by the interpreter one step at a
    time, with breakpoints, stepping, the calls in progress and their
    variables, and expressions evaluated where the program stopped. It
    knows no protocol: `pyk dap` (dap.ml) and the playground's Debug tab
    are two transports over it, so stepping means the same thing in
    both. See docs/debugging.md.

    A session is a value. A transport hands it a command, lets it run a
    number of steps with `advance`, and reads what happened from the
    events that answers with; nothing here waits for anything, which is
    what lets a browser worker drive it in slices.

    Data structures:
      source -- one module as the checker saw it, with what its names
        mean.
      program -- every module of a program, checked and made ready.
      command -- what a reader asks the debugger to do.
      reason -- why the program stopped.
      event -- what running produced.
      breakpoint -- a line to stop at, as set and as verified.
      frame -- one call in progress, as shown.
      variable -- one name or part of a value, as shown.
      t -- a session.

    Functions:
      prepare release units -- a program loaded by Module.load, checked.
      warnings session -- the warnings its program's own modules have.
      create program host -- a session about to run a program.
      set_breakpoints t file specs -- the breakpoints of one file.
      resume t command -- the session told to go on, or to pause.
      advance t steps -- runs up to `steps` steps; answers the events.
      push_call t machine -- a callback to run, the host's or the page's.
      stopped t / idle t / ended t -- where the session is.
      frames t -- the calls in progress where it stopped.
      scopes t frame -- a frame's scopes, each a reference.
      variables t reference -- what a reference holds.
      evaluate t frame text -- an expression's value, in a frame.
      set_variable t reference name text -- a `var` given a new value.
      stop_on_errors t on -- whether a runtime error stops the program.
      terminate t -- the session ended where it stands. *)

open Syntax

module PosMap = Map.Make (struct
  type t = string * int

  let compare = compare
end)

(* --- a program made ready --- *)

(** One module as the checker saw it: the module as loaded, the types
    worked out for its statements, what the modules it imports export,
    what its names mean, and the symbols of the bindings written
    `implicit`. *)
type source = {
  unit : Module.t;
  tmap : typ IntMap.t;
  sigmaps : (string * Typesystem.sigmap) list;
  found : Scopes.found;
  implicits : IntSet.t;
}

(** A program ready to debug: every module with a Pyking half as the
    checker saw it, what the interpreter runs -- each module's name, its
    Pyking half and its declaration half, in dependency order -- and the
    highest symbol anywhere in it. *)
type program = {
  sources : source list;
  units : (string * stmt list * stmt list) list;
  highest : int;
  warned : Warnings.warning list;
}

(** The symbols of every binding in stmts written `implicit`.
    [stmt] -> IntSet.t *)
let implicit_symbols stmts =
  Walk.fold_stmts
    (fun found node ->
      match node with
      | Walk.NStmt (SFunctionDef (_, _, _, _, _, s, _, _, true)) -> IntSet.add s found
      | Walk.NStmt (SLet (_, target, _, _, _, _, true)) ->
          List.fold_left
            (fun found (_, _, s) -> IntSet.add s found)
            found (Scopes.target_bindings target)
      | _ -> found)
    IntSet.empty stmts

(** A program Module.load read, checked and made ready to run exactly as
    `pyk <file>` runs it, keeping beside what runs what the checker saw.
    `release` removes every call to `debug` first. Raises the front
    end's own errors. bool? -> [Module.t] -> program *)
let prepare ?(release = false) ?(warnings = Warnings.default) ?(own = fun (_ : Module.t) -> false)
    (loaded : Module.t list) =
  let highest =
    List.fold_left
      (fun highest (unit : Module.t) -> max highest (Analyses.highest_sym unit.stmts))
      0 loaded
  in
  let warned = ref [] in
  let _, highest, sources, units =
    List.fold_left
      (fun (sigmaps, highest, sources, units) (unit : Module.t) ->
        if unit.is_external then
          ( sigmaps @ [ (unit.name, Module.external_sigmap unit.declarations) ],
            highest,
            sources,
            units @ [ (unit.name, [], unit.declarations) ] )
        else
          let declared = Module.external_signatures unit.declarations in
          let imported = Module.sigmaps_for unit sigmaps in
          let tmap, qmap = Typesystem.type_check ~declared unit.stmts imported in
          Analyses.analyze_mutability unit.stmts;
          if own unit then
            warned :=
              !warned
              @ Warnings.check ~qmap ~public:(List.map fst unit.publics)
                  ~display:(fun name ->
                    match List.find_opt (fun (_, plain) -> plain = name) unit.dotted with
                    | Some (written, _) -> written
                    | None -> name)
                  warnings unit.tokens unit.stmts;
          let sigmap = Module.module_sigmap unit.name unit.stmts unit.declarations tmap in
          let elaborated, running_types = Elaborate.program qmap tmap unit.stmts in
          let elaborated =
            if release then Release.program running_types elaborated else elaborated
          in
          let elaborated = Analyses.symbolize ~start:highest elaborated in
          let highest = max highest (Analyses.highest_sym elaborated) in
          let optimized, _ = Opt_tailcall.optimize elaborated running_types in
          let optimized = Analyses.symbolize ~start:highest optimized in
          let highest = max highest (Analyses.highest_sym optimized) in
          let source =
            {
              unit;
              tmap;
              sigmaps = imported;
              found = Scopes.resolve loaded unit;
              implicits = implicit_symbols unit.stmts;
            }
          in
          ( sigmaps @ [ (unit.name, sigmap) ],
            highest,
            sources @ [ source ],
            units
            @ [ (unit.name, Analyses.apply_signatures optimized, unit.declarations) ] ))
      ([], highest, [], []) loaded
  in
  (* A program a -Werror made a warning an error in is not run, and so
     not debugged either. *)
  if Warnings.has_error !warned then
    raise (Warnings.Refused (List.filter (fun (w : Warnings.warning) -> w.error) !warned));
  { sources; units; highest; warned = !warned }

(* --- the session --- *)

(** What a reader asks the debugger to do. *)
type command = Continue | Next | Step_in | Step_out | Pause

(** Why the program stopped: on entry, a step finished, breakpoints
    (their ids), a pause, or a runtime error (its message). *)
type reason = Entry | Step | Breakpoint of int list | Paused | Exception of string

(** What running produced: the program stopped; a logpoint's line, or a
    condition that could not be evaluated; the top level ended, in the
    machine it ended in; a callback ended, likewise. *)
type event =
  | Stopped of reason
  | Output of string
  | Program_done of Interpreter.state
  | Callback_done of Interpreter.state

(** Where a stop is looked for: nowhere but breakpoints, at the next
    statement (the first one of all, for `Entry`), at the next one no
    deeper than a call depth, or at the next one shallower than it. *)
type goal = Free | Entry_goal | Into | Over of int | Out of int

(** Where the session is: running towards a goal, stopped, waiting for a
    callback once the top level has ended, or over. *)
type mode = Running of goal | Stopped_at of reason | Waiting | Over_

(** A program in progress: the top level, or a callback. *)
type run = Top of Interpreter.runner | Call of Interpreter.state

(** A line to stop at: its id, the file and the line asked for, the line
    of the statement it stops at (None where there is none), a condition
    and a hit condition, a logpoint's message, and how often it was
    reached. *)
type breakpoint = {
  id : int;
  file : string;
  line : int;
  at : int option;
  condition : string option;
  hit : string option;
  log : string option;
  count : int;
}

(** One call in progress, as shown: an id, the function's name, where it
    is (file and span), the environment there, where its own names stop,
    the module it is in, and whether that module is a library's. *)
type frame = {
  fid : int;
  name : string;
  file : string;
  span : Lexer.info;
  env : Interpreter.env;
  upto : Interpreter.env option;
  machine : Interpreter.state;
  library : bool;
}

(** What a reference stands for: the names a frame sees, or a value's
    parts. *)
type handle = Env of int | Parts of Interpreter.value

(** One name, or one part of a value, as shown: its name, the value as
    a prompt shows it, its type, the reference its parts are under (0
    for none), and whether it may be given a new value. *)
type variable = {
  vname : string;
  value : string;
  vtype : string;
  reference : int;
  settable : bool;
}

(** A session: the program, the runs in progress (innermost first, each
    with the statement it last started), where it is, the breakpoints
    and the next id to give one, whether library code is stepped over
    and how to tell it, the statement started last and its depth, a
    pause asked for, whether the next step is taken unchecked, the error
    already stopped at, the frames and references of the current stop,
    and the next reference to give out. While stepping over or out of a
    call, where the call being stepped out of was made; once stopped
    there, where the program stopped. *)
type t = {
  program : program;
  runs : (run * stmt option) list;
  mode : mode;
  breakpoints : breakpoint list;
  lines : breakpoint list PosMap.t;
  next_id : int;
  just_my_code : bool;
  is_library : string -> bool;
  previous : (stmt * int) option;
  pause : bool;
  resumed : bool;
  failed_seen : bool;
  stop_on_error : bool;
  return_site : Lexer.info option;
  here : Lexer.info option;
  shown : frame list;
  handles : (int * handle) list;
  next_handle : int;
}

(** The machine a run is running. run -> Interpreter.state *)
let machine_of run =
  match run with Top r -> Interpreter.runner_machine r | Call m -> m

(** Whether a run has nothing left to do. run -> bool *)
let run_done run =
  match run with Top r -> Interpreter.runner_done r | Call m -> Interpreter.finished m

(** One step of a run. run -> run *)
let step_run run =
  match run with
  | Top r -> Top (Interpreter.runner_step r)
  | Call m -> Call (Interpreter.step m)

(** Whether two paths name one file. string -> string -> bool *)
let same_file a b = a = b || Module.absolute a = Module.absolute b

(** The module a file holds, where the program has it.
    t -> string -> source option *)
let source_of t file =
  List.find_opt
    (fun s ->
      same_file s.unit.path file
      || match s.unit.declaration_path with Some d -> same_file d file | None -> false)
    t.program.sources

(** A session about to run a program from its first statement, writing
    through host. `drive` is how a callback the host makes is run; by
    default it is stepped to its end. The session stops at the first
    statement where `stop_on_entry`, and library code -- a file
    `is_library` names -- is stepped over where `just_my_code`.
    bool? -> bool? -> (string -> bool)? -> (state -> state)? -> program
    -> Interpreter.host -> t *)
let create ?(stop_on_entry = false) ?(just_my_code = true) ?(is_library = fun _ -> false)
    ?drive program host =
  {
    program;
    runs = [ (Top (Interpreter.start_modules ?drive program.units host), None) ];
    mode = Running (if stop_on_entry then Entry_goal else Free);
    breakpoints = [];
    lines = PosMap.empty;
    next_id = 1;
    just_my_code;
    is_library;
    previous = None;
    pause = false;
    resumed = false;
    failed_seen = false;
    stop_on_error = true;
    return_site = None;
    here = None;
    shown = [];
    handles = [];
    next_handle = 1;
  }

(* --- breakpoints --- *)

(** The rows statements start on in a file, in what the interpreter
    runs, in order and each once. t -> string -> [int] *)
let statement_rows t file =
  List.concat_map
    (fun (_, stmts, _) ->
      Walk.fold_stmts
        (fun rows node ->
          match node with
          | Walk.NStmt s ->
              let i = stmt_info s in
              if same_file i.file file && not (List.mem i.row1 rows) then i.row1 :: rows
              else rows
          | _ -> rows)
        [] stmts)
    t.program.units
  |> List.sort_uniq compare

(** The breakpoints by the file and row they stop at.
    [breakpoint] -> breakpoint list PosMap.t *)
let index_breakpoints breakpoints =
  List.fold_left
    (fun map (b : breakpoint) ->
      match b.at with
      | None -> map
      | Some row ->
          let key = (Module.absolute b.file, row) in
          let held = Option.value ~default:[] (PosMap.find_opt key map) in
          PosMap.add key (held @ [ b ]) map)
    PosMap.empty breakpoints

(** The breakpoints of one file, replacing the ones it had: each a line,
    a condition, a hit condition and a logpoint message. A breakpoint
    stops at the first statement starting on its line or after it.
    Answers the session and the breakpoints as verified.
    t -> string -> [(int, string?, string?, string?)] -> (t, [breakpoint]) *)
let set_breakpoints t file specs =
  let rows = statement_rows t file in
  let keep = List.filter (fun (b : breakpoint) -> not (same_file b.file file)) t.breakpoints in
  let made, next_id =
    List.fold_left
      (fun (made, id) (line, condition, hit, log) ->
        let at = List.find_opt (fun r -> r >= line) rows in
        let blank s = match s with Some "" -> None | s -> s in
        ( made
          @ [ { id; file; line; at; condition = blank condition; hit = blank hit; log = blank log; count = 0 } ],
          id + 1 ))
      ([], t.next_id) specs
  in
  let breakpoints = keep @ made in
  ({ t with breakpoints; lines = index_breakpoints breakpoints; next_id }, made)

(* --- names and types where the program stopped --- *)

(** A type with nothing the checker was working on left in it: a
    function type forgets the definition behind it.
    typ -> typ *)
let rec settled t =
  match t with
  | TList (i, e, s) -> TList (i, settled e, s)
  | TTuple (i, es, s) -> TTuple (i, List.map settled es, s)
  | TFunction (i, ps, r, _, _, _, implicits) ->
      TFunction
        ( i,
          List.map settled ps,
          settled r,
          0,
          0,
          None,
          List.map (fun (IParam (n, t)) -> IParam (n, settled t)) implicits )
  | TForall (i, vs, b, s) -> TForall (i, vs, settled b, s)
  | TCon (i, n, args, s) -> TCon (i, n, List.map settled args, s)
  | t -> t

(** The type variables a type names, each once. typ -> [string] *)
let rec type_variables t =
  let all ts = List.sort_uniq compare (List.concat_map type_variables ts) in
  match t with
  | TVar (_, n, _, _) -> [ n ]
  | TList (_, e, _) -> type_variables e
  | TTuple (_, es, _) -> all es
  | TFunction (_, ps, r, _, _, _, implicits) ->
      all (r :: ps @ List.map (fun (IParam (_, t)) -> t) implicits)
  | TForall (_, vs, b, _) -> List.filter (fun v -> not (List.mem v vs)) (type_variables b)
  | TCon (_, _, args, _) -> all args
  | _ -> []

(** The type a value has, where the value alone says.
    Interpreter.value -> typ option *)
let rec value_type v =
  let none = { Lexer.file = ""; row1 = 0; col1 = 0; row2 = 0; col2 = 0 } in
  let all vs =
    List.fold_right
      (fun v acc ->
        match (value_type v, acc) with Some t, Some ts -> Some (t :: ts) | _ -> None)
      vs (Some [])
  in
  match v with
  | Interpreter.VInt _ -> Some (TInt (none, 0))
  | Interpreter.VFloat _ -> Some (TFloat (none, 0))
  | Interpreter.VString _ -> Some (TString (none, 0))
  | Interpreter.VChar _ -> Some (TChar (none, 0))
  | Interpreter.VBool _ -> Some (TBool (none, 0))
  | Interpreter.VUnit -> Some (TTuple (none, [], 0))
  | Interpreter.VList (first :: _) -> Option.map (fun e -> TList (none, e, 0)) (value_type first)
  | Interpreter.VTuple parts -> Option.map (fun ts -> TTuple (none, ts, 0)) (all parts)
  | _ -> None

(** The type the checker worked out for a binding, from the table of the
    module it is in. t -> Scopes.place -> int -> typ option *)
let binding_type t (place : Scopes.place) sym =
  Option.bind (source_of t place.file) (fun s -> IntMap.find_opt sym s.tmap)
  |> Option.map settled

(** A type as Pyking writes it. typ -> string *)
let show_type ty = pprint_type default_config ty

(** The source and the row and column a frame is at.
    t -> frame -> (source, int, int) option *)
let frame_place t frame =
  Option.map (fun s -> (s, frame.span.row1, frame.span.col1)) (source_of t frame.file)

(** What the names in scope at a frame's position mean.
    t -> frame -> Scopes.meaning Scopes.SMap.t *)
let static_names t frame =
  match frame_place t frame with
  | Some (s, row, col) -> Scopes.names_at s.found row col
  | None -> Scopes.SMap.empty

(** The name a runtime binding is shown by: an overloaded definition's
    as written, every other name as it is. Answers None for a name the
    compiler made up or one no reader wrote by itself.
    Scopes.meaning Scopes.SMap.t -> string -> string option *)
let shown_name names n =
  let generated =
    Desugar_args.generated_name n || Elaborate.generated_name n
    || (String.length n >= 10 && String.sub n 0 10 = "tail_group")
  in
  if generated || String.contains n '.' then None
  else
    match
      Scopes.SMap.fold
        (fun written _ found ->
          match found with
          | Some _ -> found
          | None -> if Names.is_qualified written && Names.renamed written = n then Some written else None)
        names None
    with
    | Some written -> Some written
    | None -> Some n

(* --- frames --- *)

(** The name a function was written with: an overloaded definition runs
    under the plain name it compiles to, `int__abs`, and is shown as
    `int::abs`. t -> string -> string *)
let written_name t name =
  let found =
    List.find_map
      (fun s ->
        Walk.fold_stmts
          (fun found node ->
            match (found, node) with
            | None, Walk.NStmt (SFunctionDef (_, n, _, _, _, _, _, _, _))
              when Names.is_qualified n && Names.renamed n = name ->
                Some n
            | _ -> found)
          None s.unit.stmts)
      t.program.sources
  in
  Option.value ~default:name found

(** The frames of one run, innermost first, numbered from `first`.
    t -> run -> stmt option -> int -> [frame] *)
let run_frames t run last first =
  let m = machine_of run in
  let views = Interpreter.calls m in
  let failed =
    match Interpreter.failure m with
    | Some (Interpreter.Runtime_error (i, _)) -> Some i
    | _ -> None
  in
  let innermost = match t.runs with (r, _) :: _ -> r == run | [] -> false in
  let here =
    match (failed, Interpreter.statement_at m, t.here, last) with
    | Some i, _, _, _ -> i
    | None, Some s, _, _ -> stmt_info s
    | None, None, Some i, _ when innermost -> i
    | None, None, _, Some s -> stmt_info s
    | None, None, _, None -> { Lexer.file = ""; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }
  in
  let top_name (span : Lexer.info) =
    match run with
    | Top _ -> (
        match source_of t span.file with
        | Some s -> "<module " ^ s.unit.name ^ ">"
        | None -> "<module>")
    | Call _ -> "<callback>"
  in
  let count = List.length views + match run with Top _ -> 1 | Call _ -> 0 in
  List.init count (fun k ->
      let span, env =
        if k = 0 then (here, m.Interpreter.env)
        else
          let below = List.nth views (k - 1) in
          (below.Interpreter.call_site, below.Interpreter.caller_env)
      in
      let name =
        if k < List.length views then written_name t (List.nth views k).Interpreter.call_name
        else top_name span
      in
      let upto =
        if k < List.length views then Some (List.nth views k).Interpreter.written_in else None
      in
      {
        fid = first + k;
        name;
        file = span.Lexer.file;
        span;
        env;
        upto;
        machine = m;
        library = t.is_library span.Lexer.file;
      })

(** Every frame where the session stopped: the run in progress, then
    the runs it is inside, innermost first. Library frames are left out
    where library code is stepped over, except the innermost.
    t -> [frame] *)
let all_frames t =
  let _, frames =
    List.fold_left
      (fun (first, out) (run, last) ->
        let fs = run_frames t run last first in
        (first + List.length fs, out @ fs))
      (1, []) t.runs
  in
  match frames with
  | [] -> []
  | top :: rest ->
      top :: (if t.just_my_code then List.filter (fun f -> not f.library) rest else rest)

(** The session stopped, for a reason: its frames worked out afresh and
    every reference given out before forgotten. t -> reason -> t *)
let stop t reason =
  let t = { t with mode = Stopped_at reason; pause = false; handles = []; next_handle = 1 } in
  { t with shown = all_frames t }

(* --- evaluating where the program stopped --- *)

(** The checker's environment and store for the names in scope at a
    frame: the builtins, what the module imports, and every binding in
    scope at the type it was worked out to be -- a definition's
    generalised, a value's taken from the value itself where its own type
    still names a variable. t -> frame -> (Typesystem.env,
    Typesystem.store) *)
let checker_scope t frame =
  let none = { Lexer.file = ""; row1 = 0; col1 = 0; row2 = 0; col2 = 0 } in
  match frame_place t frame with
  | None -> (Typesystem.builtin_env (), Typesystem.empty_store [])
  | Some (s, row, col) ->
      let store = Typesystem.declare_datatypes s.unit.stmts (Typesystem.empty_store s.sigmaps) in
      let env = Typesystem.import_env s.unit.stmts (Typesystem.builtin_env ()) store in
      let declared = Module.external_signatures s.unit.declarations in
      let env =
        List.fold_left
          (fun env (n, ty) ->
            Typesystem.SMap.add n { Typesystem.btype = settled ty; bimplicit = false } env)
          env declared
      in
      let values = Interpreter.bindings_in_scope frame.env in
      let env =
        Scopes.SMap.fold
          (fun n meaning env ->
            match meaning with
            | Scopes.Bound (place, sym, kind) -> (
                let own = same_file place.file s.unit.path in
                if (not own) && Typesystem.SMap.mem n env then env
                else
                  let recorded = binding_type t place sym in
                  let runtime = Option.bind (List.assoc_opt (Names.renamed n) values) value_type in
                  let ty =
                    match (kind, recorded, runtime) with
                    | Scopes.KFunction, Some ty, _ -> (
                        match (ty, type_variables ty) with
                        | TForall _, _ | _, [] -> Some ty
                        | _, vars -> Some (TForall (none, vars, ty, 0)))
                    | _, Some ty, Some value_ty when type_variables ty <> [] -> Some value_ty
                    | _, Some ty, _ -> Some ty
                    | _, None, runtime -> runtime
                  in
                  match ty with
                  | None -> env
                  | Some ty ->
                      let source = source_of t place.file in
                      let implicit =
                        match source with Some src -> IntSet.mem sym src.implicits | None -> false
                      in
                      Typesystem.SMap.add n { Typesystem.btype = ty; bimplicit = implicit } env)
            | _ -> env)
          (Scopes.names_at s.found row col)
          env
      in
      (env, store)

(** Checks one statement written where a frame stopped and runs it in
    that frame's environment: a Watch expression, a line typed at the
    Console, a breakpoint's condition, a value given to a `var`. Answers
    the value and its type, or why there is none.
    t -> frame -> string -> (Interpreter.value, string) result *)
let run_text t frame text =
  let parsed =
    (* What is typed here acts on a program that is running, from outside
       its source, so every feature is on: a `var` given a new value is
       a `:=` whatever the program's own `use` lines say. *)
    try
      Ok
        (snd
           (Parser.parse_with Parser.features
              (Lexer.lexing "<debugger>" (Lexer.chars_of_string (text ^ "\n")))))
    with
    | Lexer.Lex_error (_, message) | Parser.Parse_error (_, message) -> Error message
  in
  match parsed with
  | Error message -> Error message
  | Ok [ (SExprStmt _ as stmt) ] | Ok [ (SMutate _ as stmt) ] -> (
      let stmt = List.hd (Analyses.symbolize ~start:t.program.highest [ stmt ]) in
      let env, store = checker_scope t frame in
      match
        try
          let supplied, _, store = Typesystem.check_stmt stmt env Typesystem.No_function None store in
          let running, _ = Elaborate.program store.qmap store.tmap [ stmt ] in
          let running =
            Analyses.symbolize ~start:(Analyses.highest_sym [ stmt ] + 1) running
          in
          let shown =
            match supplied with
            | Some ty -> show_type (Typesystem.displayed (Typesystem.zonk ty store) store)
            | None -> "()"
          in
          Ok (running, shown)
        with
        | Typesystem.Type_error (_, message) | Analyses.Analysis_error (_, message) -> Error message
      with
      | Error message -> Error message
      | Ok (running, shown) -> (
          let m = Interpreter.with_env frame.machine frame.env in
          let after =
            List.fold_left
              (fun m stmt ->
                if Interpreter.failure m <> None then m else Interpreter.eval_in ~steps:1_000_000 m stmt)
              m running
          in
          match (Interpreter.failure after, Interpreter.result after) with
          | Some (Interpreter.Runtime_error (_, message)), _ -> Error message
          | Some _, _ -> Error "runtime error"
          | None, Some value -> Ok (value, shown)
          | None, None -> Error "this did not finish within a million steps"))
  | Ok [ _ ] -> Error "only an expression can be evaluated here"
  | Ok _ -> Error "only one expression can be evaluated here"

(* --- running --- *)

(** Whether a statement is the rest of the line the statement before it
    started: written inside it, on its row, one call level down from
    nowhere -- the value of `x = if ...`, or a block on its header's own
    line. Such a statement is not a new line to stop at.
    t -> stmt -> int -> bool *)
let continues t s depth =
  match t.previous with
  | Some (p, d) when p != s && d = depth ->
      let a = stmt_info p and b = stmt_info s in
      a.row1 = b.row1 && same_file a.file b.file
      && compare (a.row1, a.col1) (b.row1, b.col1) <= 0
      && compare (b.row2, b.col2) (a.row2, a.col2) <= 0
  | _ -> false

(** Whether a hit condition holds for the nth time a breakpoint is
    reached: `N` (the Nth time only), `>= N`, `> N`, `== N`, `< N`,
    `<= N` or `% N`.
    string -> int -> bool *)
let hit_holds condition n =
  let text = String.trim condition in
  let number s = int_of_string_opt (String.trim s) in
  let after k = String.sub text k (String.length text - k) in
  let starts p = String.length text >= String.length p && String.sub text 0 (String.length p) = p in
  let test op k =
    match number (after k) with Some m -> op n m | None -> true
  in
  if starts ">=" then test ( >= ) 2
  else if starts "<=" then test ( <= ) 2
  else if starts "==" then test ( = ) 2
  else if starts ">" then test ( > ) 1
  else if starts "<" then test ( < ) 1
  else if starts "%" then test (fun n m -> m <> 0 && n mod m = 0) 1
  else test ( = ) 0

(** A logpoint's message with each `{expression}` replaced by its value,
    as print writes it. t -> frame -> string -> string *)
let interpolate t frame message =
  let out = Buffer.create (String.length message) in
  let rec go i =
    if i >= String.length message then ()
    else if message.[i] = '{' then
      match String.index_from_opt message i '}' with
      | None ->
          Buffer.add_string out (String.sub message i (String.length message - i))
      | Some j ->
          let text = String.sub message (i + 1) (j - i - 1) in
          (match run_text t frame text with
          | Ok (value, _) -> Buffer.add_string out (Interpreter.format_value value)
          | Error message -> Buffer.add_string out ("<" ^ message ^ ">"));
          go (j + 1)
    else (
      Buffer.add_char out message.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents out

(** The breakpoints a statement reaches that stop the program, with the
    session (each one's count moved on) and what logpoints wrote.
    t -> run -> stmt -> (t, [int], [event]) *)
let reached t run s =
  let i = stmt_info s in
  match PosMap.find_opt (Module.absolute i.file, i.row1) t.lines with
  | None -> (t, [], [])
  | Some here ->
      let frame () = List.hd (run_frames t run (Some s) 1) in
      let t, stops, events =
        List.fold_left
          (fun (t, stops, events) b ->
            let condition_holds, events =
              match b.condition with
              | None -> (true, events)
              | Some text -> (
                  match run_text t (frame ()) text with
                  | Ok (Interpreter.VBool held, _) -> (held, events)
                  | Ok _ -> (true, events @ [ Output (Printf.sprintf "breakpoint condition '%s' is not a Bool\n" text) ])
                  | Error message ->
                      (true, events @ [ Output (Printf.sprintf "breakpoint condition '%s': %s\n" text message) ]))
            in
            if not condition_holds then (t, stops, events)
            else
              let b = { b with count = b.count + 1 } in
              let t =
                {
                  t with
                  breakpoints = List.map (fun o -> if o.id = b.id then b else o) t.breakpoints;
                }
              in
              let hits = match b.hit with None -> true | Some h -> hit_holds h b.count in
              if not hits then (t, stops, events)
              else
                match b.log with
                | Some message -> (t, stops, events @ [ Output (interpolate t (frame ()) message ^ "\n") ])
                | None -> (t, stops @ [ b.id ], events))
          (t, [], []) here
      in
      ({ t with lines = index_breakpoints t.breakpoints }, stops, events)

(** Whether a statement in a run is where the goal stops.
    t -> goal -> stmt -> int -> bool -> bool *)
let goal_stops t goal s depth continuing =
  let library = t.just_my_code && t.is_library (stmt_info s).file in
  if library || continuing then false
  else
    match goal with
    | Free -> false
    | Entry_goal | Into -> true
    | Over d -> depth <= d
    | Out d -> depth < d

(** The goal that goes on in the run outside one that ended: stepping
    out of a callback stops at what follows it. goal -> goal *)
let after_run goal = match goal with Free -> Free | _ -> Into

(** Runs up to `steps` steps, or until the program stops or a run ends.
    Answers the session and what happened. t -> int -> (t, [event]) *)
let advance t steps =
  let rec go t n events =
    match (t.mode, t.runs) with
    | (Stopped_at _ | Waiting | Over_), _ -> (t, events)
    | Running _, [] -> ({ t with mode = Waiting }, events)
    | Running goal, (run, last) :: outer -> (
        if n <= 0 then (t, events)
        else
          let m = machine_of run in
          (* A run waiting for the page goes no further until `answer`
             hands it what it waits for. *)
          if Interpreter.waiting m <> None then (t, events)
          else if run_done run then
            match Interpreter.failure m with
            | Some (Interpreter.Runtime_error (_, message))
              when t.stop_on_error && not t.failed_seen ->
                (stop { t with failed_seen = true } (Exception message), events @ [ Stopped (Exception message) ])
            | _ ->
                let ended = match run with Top _ -> Program_done m | Call _ -> Callback_done m in
                let mode =
                  if outer = [] then (match run with Top _ -> Waiting | Call _ -> Waiting)
                  else Running (after_run goal)
                in
                ({ t with runs = outer; mode; failed_seen = false; previous = None }, events @ [ ended ])
          else if t.resumed then
            go { t with runs = (step_run run, last) :: outer; resumed = false } (n - 1) events
          else
            match Interpreter.statement_at m with
            | None -> (
                (* Stepping over or out of a call: once it has returned,
                   the program stops in the caller, at the call. *)
                match goal with
                | Over d | Out d ->
                    let depth = Interpreter.call_depth m in
                    if depth = d then
                      go
                        {
                          t with
                          runs = (step_run run, last) :: outer;
                          return_site = Interpreter.innermost_call_site m;
                        }
                        (n - 1) events
                    else if depth < d && t.return_site <> None
                            && not (t.just_my_code && t.is_library (Option.get t.return_site).file)
                    then
                      let t = { t with here = t.return_site; return_site = None } in
                      (stop t Step, events @ [ Stopped Step ])
                    else go { t with runs = (step_run run, last) :: outer } (n - 1) events
                | _ -> go { t with runs = (step_run run, last) :: outer } (n - 1) events)
            | Some s ->
                let depth = Interpreter.call_depth m in
                let continuing = continues t s depth in
                let t = { t with runs = (run, Some s) :: outer } in
                let t, stops, logged =
                  if continuing then (t, [], []) else reached t run s
                in
                let events = events @ logged in
                let t = { t with previous = Some (s, depth) } in
                let library = t.just_my_code && t.is_library (stmt_info s).file in
                let halt reason = (stop t reason, events @ [ Stopped reason ]) in
                if stops <> [] then halt (Breakpoint stops)
                else if t.pause && not library then halt Paused
                else if goal_stops t goal s depth continuing then
                  halt (if goal = Entry_goal then Entry else Step)
                else go { t with runs = (step_run run, Some s) :: outer } (n - 1) events)
  in
  go t steps []

(** The session told to go on, or to pause where it is running. A step
    is measured from the frame the program stopped in.
    t -> command -> t *)
let resume t command =
  match (command, t.mode, t.runs) with
  | Pause, Running _, _ -> { t with pause = true }
  | Pause, _, _ -> t
  | _, Stopped_at _, (run, _) :: _ ->
      let depth = Interpreter.call_depth (machine_of run) in
      let goal =
        match command with
        | Continue | Pause -> Free
        | Next -> Over depth
        | Step_in -> Into
        | Step_out -> Out depth
      in
      { t with mode = Running goal; resumed = true; shown = []; handles = []; here = None; return_site = None }
  | _ -> t

(** A callback to run: a machine about to call it, from the host or the
    page. It runs inside whatever is running, or starts the session
    going again once the top level has ended. t -> Interpreter.state -> t *)
let push_call t machine =
  let mode = match t.mode with Running goal -> Running goal | _ -> Running Free in
  { t with runs = (Call machine, None) :: t.runs; mode; resumed = false; previous = None }

(** The session told whether to stop where a runtime error ends the
    program, before it ends. t -> bool -> t *)
let stop_on_errors t on = { t with stop_on_error = on }

(** The number the running run waits on, where it waits for the page
    (Interpreter.Wait). t -> int option *)
let waiting_on t =
  match (t.mode, t.runs) with
  | Running _, (run, _) :: _ -> Interpreter.waiting (machine_of run)
  | _ -> None

(** The session with the run that waits on id handed value, going on
    from there once it runs again. t -> int -> Interpreter.value -> t *)
let answer t id value =
  let answered run =
    let m = machine_of run in
    if Interpreter.waiting m <> Some id then run
    else
      match run with
      | Top r -> Top (Interpreter.with_machine r (Interpreter.resume m value))
      | Call m -> Call (Interpreter.resume m value)
  in
  { t with runs = List.map (fun (run, last) -> (answered run, last)) t.runs }

(** The session ended where it stands. t -> t *)
let terminate t = { t with mode = Over_; runs = [] }

(** The reason the session stopped, where it has. t -> reason option *)
let stopped t = match t.mode with Stopped_at r -> Some r | _ -> None

(** Whether the session waits for a callback: the top level has ended,
    and nothing runs. t -> bool *)
let idle t = t.mode = Waiting

(** Whether the session is over. t -> bool *)
let ended t = t.mode = Over_

(** The calls in progress where the session stopped, innermost first.
    t -> [frame] *)
let frames t = t.shown

(** The frame with an id, where the session stopped. t -> int -> frame? *)
let frame_by_id t id = List.find_opt (fun f -> f.fid = id) t.shown

(** A reference to what a handle stands for, valid until the session
    goes on. t -> handle -> (t, int) *)
let reference t handle =
  let n = t.next_handle in
  ({ t with handles = (n, handle) :: t.handles; next_handle = n + 1 }, n)

(** A frame's one scope, its environment: every name it sees, with its
    reference. t -> int -> (t, [(string, int)]) *)
let scopes t fid =
  match frame_by_id t fid with
  | None -> (t, [])
  | Some _ ->
      let t, env = reference t (Env fid) in
      (t, [ ("Environment", env) ])

(** Whether a value has parts to show. Interpreter.value -> bool *)
let has_parts v =
  match v with
  | Interpreter.VList (_ :: _) | Interpreter.VTuple (_ :: _) | Interpreter.VData (_, _ :: _) -> true
  | _ -> false

(** How many parts of a value are shown before the rest are left out. *)
let parts_shown = 1000

(** One variable for a value, with a reference to its parts where it has
    any. t -> string -> Interpreter.value -> string -> bool -> (t, variable) *)
let variable_of t name value vtype settable =
  let t, reference = if has_parts value then reference t (Parts value) else (t, 0) in
  (t, { vname = name; value = Interpreter.display_value value; vtype; reference; settable })

(** What a reference holds: a frame's names, or a value's parts.
    t -> int -> (t, [variable]) *)
let variables t reference =
  let named t frame bindings own =
    let names = static_names t frame in
    let shown =
      List.filter_map
        (fun (n, value) ->
          match value with
          | Interpreter.VBuiltin b when b = n -> None
          | Interpreter.VUndefined _ -> None
          | _ -> Option.map (fun shown -> (shown, value)) (shown_name names n))
        bindings
    in
    (* The call's own names first, then the rest; each in the order they
       are written, anything the program did not write after, as found. *)
    let place n =
      let outer = if List.mem_assoc n own then 0 else 1 in
      match Scopes.SMap.find_opt n names with
      | Some (Scopes.Bound (p, _, _)) -> (outer, 0, p.Scopes.span.Lexer.row1, p.Scopes.span.Lexer.col1)
      | _ -> (outer, 1, 0, 0)
    in
    let shown = List.stable_sort (fun (a, _) (b, _) -> compare (place a) (place b)) (List.rev shown) in
    List.fold_left
      (fun (t, out) (n, value) ->
        let meaning = Scopes.SMap.find_opt n names in
        let vtype, settable =
          match meaning with
          | Some (Scopes.Bound (place, sym, kind)) ->
              let ty =
                match binding_type t place sym with
                | Some ty when type_variables ty = [] -> Some ty
                | recorded -> (
                    match value_type value with Some v -> Some v | None -> recorded)
              in
              ( (match ty with Some ty -> show_type ty | None -> Interpreter.describe value),
                kind = Scopes.KVariable )
          | _ ->
              ( (match value_type value with
                | Some ty -> show_type ty
                | None -> Interpreter.describe value),
                false )
        in
        let t, v = variable_of t n value vtype settable in
        (t, out @ [ v ]))
      (t, []) shown
  in
  match List.assoc_opt reference t.handles with
  | None -> (t, [])
  | Some (Env fid) -> (
      match frame_by_id t fid with
      | None -> (t, [])
      | Some frame ->
          let own =
            match frame.upto with
            | Some _ -> Interpreter.own_bindings frame.env frame.upto
            | None -> []
          in
          named t frame (Interpreter.own_bindings frame.env None) own)
  | Some (Parts value) ->
      let parts =
        match value with
        | Interpreter.VList items -> List.mapi (fun i v -> (Printf.sprintf "[%d]" i, v)) items
        | Interpreter.VTuple items -> List.mapi (fun i v -> (string_of_int i, v)) items
        | Interpreter.VData (_, fields) ->
            List.mapi
              (fun i (label, v) -> ((match label with Some l -> l | None -> string_of_int i), v))
              fields
        | _ -> []
      in
      let total = List.length parts in
      let t, out =
        List.fold_left
          (fun (t, out) (n, v) ->
            let vtype =
              match value_type v with Some ty -> show_type ty | None -> Interpreter.describe v
            in
            let t, var = variable_of t n v vtype false in
            (t, out @ [ var ]))
          (t, [])
          (List.filteri (fun i _ -> i < parts_shown) parts)
      in
      if total > parts_shown then
        ( t,
          out
          @ [
              {
                vname = "...";
                value = Printf.sprintf "%d more" (total - parts_shown);
                vtype = "";
                reference = 0;
                settable = false;
              };
            ] )
      else (t, out)

(** An expression's value where the program stopped, in a frame (the
    innermost where none is named), as a variable with no name.
    t -> int option -> string -> (t, (variable, string) result) *)
let evaluate t fid text =
  let frame =
    match fid with
    | Some id -> frame_by_id t id
    | None -> ( match t.shown with f :: _ -> Some f | [] -> None)
  in
  match frame with
  | None -> (t, Error "the program is not stopped")
  | Some frame -> (
      match run_text t frame text with
      | Error message -> (t, Error message)
      | Ok (value, shown) ->
          let t, v = variable_of t "" value shown false in
          (t, Ok v))

(** A `var` in a frame's scope given the value of an expression, written
    into its cell. Answers the variable as it now is.
    t -> int -> string -> string -> (t, (variable, string) result) *)
let set_variable t reference name text =
  let frame =
    match List.assoc_opt reference t.handles with
    | Some (Env fid) -> frame_by_id t fid
    | _ -> None
  in
  match frame with
  | None -> (t, Error "only a variable a frame names can be set")
  | Some frame -> (
      match Scopes.SMap.find_opt name (static_names t frame) with
      | Some (Scopes.Bound (_, _, Scopes.KVariable)) -> (
          match run_text t frame (Printf.sprintf "%s := %s" name text) with
          | Error message -> (t, Error message)
          | Ok _ -> (
              let runtime = Names.renamed name in
              match List.assoc_opt runtime (Interpreter.bindings_in_scope frame.env) with
              | None -> (t, Error ("'" ^ name ^ "' is not in scope here"))
              | Some value ->
                  let vtype =
                    match value_type value with Some ty -> show_type ty | None -> Interpreter.describe value
                  in
                  let t, v = variable_of t name value vtype true in
                  (t, Ok v)))
      | _ -> (t, Error ("'" ^ name ^ "' is not a var, so it cannot be given a new value")))

let warnings session = session.program.warned
