(** A REPL session, without the terminal: what `pyk repl` (repl.ml) and
    the playground's REPL (src/web/pyking_web.ml) share. A session is a
    program written one entry at a time: each entry is checked against
    what the entries before it left behind, then run there. Everything
    it shows goes through its host, so it opens no file and reads no
    terminal. See docs/repl.md.

    Data structures:
      host -- where a session's lines go, how its machine prints, and
        how it reaches a module implemented in a target language.
      session -- a REPL session: statements seen, machine state, types,
        store, source text of each definition.
      binding -- one name the session has bound, as `:ls` shows it.
      outcome -- what a meta-command leaves behind.

    Functions:
      new_session host -- an empty session.
      complete / continuable / next_indent -- whether an entry is finished,
        and where its next line is indented.
      submit session stmts report source -- checks and runs one entry.
      accept session stmts report source -- submit, reporting a refusal.
      bindings session -- what the session has bound.
      run_meta session line report -- runs a meta-command.
      completions session line col -- what may be typed at col.
      undefined_name error -- the name an "unbound name" error is about. *)

open Lexer
open Syntax

(* One level of indentation, in the only width Pyking accepts (see
   PYKING.md, "Indentation-based blocks"). *)
let indent_width = "    "

(* What the parser says when it stopped because the input ran out rather
   than because it was wrong. A line that ends this way is not an error
   yet: it is an entry that is still being typed. The parser is the only
   thing that knows this, which is why the REPL asks it rather than
   looking for a trailing ':'. *)
let incomplete_reasons = [ "unexpected end of input"; "expected an indented block" ]

(** Whether text starts with prefix. string -> string -> bool *)
let starts_with prefix text =
  String.length text >= String.length prefix
  && String.sub text 0 (String.length prefix) = prefix

(** Where a session's lines go and how it reaches what it imports.
    write -- one line the session shows: a value, a meta-command's answer.
    machine -- the interpreter's host, given how to reach the modules
      imported so far that are implemented in a target language.
    connect -- how to reach those modules: the ones just imported, then
      all of them.
    warn -- one warning an entry has, as the CLI prints it.
    from -- where an imported module's files are read, if not from disk. *)
type host = {
  write : string -> unit;
  machine : Interpreter.externals option -> Interpreter.host;
  connect : Module.t list -> Module.t list -> Interpreter.externals;
  warn : string -> unit;
  from : Module.sources option;
}

(** A REPL session. An entry is checked the way it is run: each is its
    own group, checked and run against what earlier entries left behind
    (see docs/repl.md).
    seen -- every statement given so far, for `symbolize`.
    state -- the machine's names -> values.
    types -- the checker's names -> types.
    store -- what the checker has worked out.
    kinds -- the mutability analysis's names -> kinds.
    sources -- each name's own source text, for `:edit`.
    arguments -- what Desugar_args knows about the defs written so far,
      so a later entry may call an earlier one with its defaults.
    libs -- where an imported module is looked for after the current
      directory.
    modules -- every module an entry has imported, as the module system
      prepared it.
    sigmaps -- what each of them exports, for the checker.
    exports -- the value of each name each of them exports, for the
      machine.
    hosted -- the ones implemented in a target language, which the
      machine reaches through the host's `connect`.
    features -- what the entries' `use` lines have turned on, for every
      entry after them (design/steps.md, step 1).
    host -- where the session's lines go. *)
type session = {
  seen : stmt list;
  written : stmt list;
  high : int;
  state : Interpreter.state;
  types : Typesystem.env;
  store : Typesystem.store;
  kinds : Analyses.env;
  sources : (string * string) list;
  arguments : Desugar_args.signatures;
  libs : Module.lib_entry list;
  modules : (string * Module.t) list;
  sigmaps : (string * Typesystem.sigmap) list;
  exports : (string * (string * Interpreter.value) list) list;
  hosted : Module.t list;
  features : string list;
  warnings : Warnings.config;
  host : host;
}

(** The mutability analysis's starting environment: the builtins, and
    nothing a `:=` may name. () -> Analyses.env *)
let builtin_kinds () =
  List.fold_left
    (fun env name ->
      Analyses.SMap.add name Analyses.{ kind = Builtin; info = None } env)
    Analyses.SMap.empty Builtin.names

(** An empty session: builtins in scope, nothing seen, and modules
    looked for in `libs` after the current directory.
    [Module.lib_entry]? -> host -> session *)
let new_session ?(libs = []) host =
  {
    seen = [];
    written = [];
    high = 0;
    state = Interpreter.initial_state [] (host.machine None);
    types = Typesystem.builtin_env ();
    store = Typesystem.empty_store [];
    kinds = builtin_kinds ();
    sources = [];
    arguments = Desugar_args.no_signatures;
    libs;
    modules = [];
    sigmaps = [];
    exports = [];
    hosted = [];
    features = [];
    warnings = Warnings.default;
    host;
  }

(* --- reading --- *)

(* A session is one module, written an entry at a time. *)
let repl_module = "<repl>"

(** source as a list of statements, with `features` already on.
    Raises Lex_error/Parse_error. string? -> [string]? -> string -> [stmt] *)
let parse_source ?(name = "<repl>") ?(features = []) source =
  snd
    (Parser.parse_with features
       (Lexer.lexing name (Lexer.chars_of_string (source ^ "\n"))))

(** session with these features on, as a `use` line would turn them
    on. session -> [string] -> session *)
let with_features session features =
  { session with
    features = session.features @ List.filter (fun f -> not (List.mem f session.features)) features }

(** session with warnings reported as `config` says, as -W flags
    would. session -> Warnings.config -> session *)
let with_warnings session config = { session with warnings = config }

(** One entry's statements, parsed with what the session's earlier
    `use` lines turned on, and the session with what this entry's own
    turn on added: a `use` typed at the prompt holds for the rest of the
    session. Raises Lex_error/Parse_error.
    string? -> session -> string -> (session, [stmt]) *)
let parse_entry ?(name = "<repl>") session source =
  let own, stmts =
    Parser.parse_with session.features
      (Lexer.lexing name (Lexer.chars_of_string (source ^ "\n")))
  in
  let added = List.filter (fun f -> not (List.mem f session.features)) own in
  ({ session with features = session.features @ added }, stmts)

(** Whether source is a whole entry, per the parser (anything wrong for
    another reason counts as complete). string -> bool *)
let complete source =
  match parse_source source with
  | _ -> true
  | exception Lexer.Lex_error (_, message)
  | exception Parser.Parse_error (_, message) ->
      not (List.exists (fun reason -> starts_with reason message) incomplete_reasons)

(** Whether one statement could take another line. stmt -> bool *)
let rec open_block stmt =
  match stmt with
  | SIf (_, _, _, None, _) -> true
  | SIf (_, _, _, Some else_body, _) -> (
      (* An `else if` rung: the chain ends in the innermost `if`, so that
         is the one an `else` would still attach to. *)
      match List.rev else_body with [] -> false | last :: _ -> open_block last)
  | _ -> false

(** Whether a line the parser accepts could still be continued by the
    line below it: an `if` with no `else` yet. Its block may sit on the
    header's own line, so it parses whole on one line while still being
    open, and the `else` that would follow has to start a line of its own
    (see PYKING.md, "A block on its header's own line"). The question is
    the parser's, like `complete`: it is asked of the tree, not of a
    trailing ':'. string -> bool *)
let continuable source =
  match parse_source source with
  | stmts -> ( match List.rev stmts with [] -> false | last :: _ -> open_block last)
  | exception Lexer.Lex_error _ -> false
  | exception Parser.Parse_error _ -> false

(** The indentation the line after source belongs at: one level in if the
    last line opened a block (ends in ':'), level with it otherwise.
    string -> string *)
let next_indent source =
  let lines = List.filter (fun line -> not (Lexer.blank line)) (String.split_on_char '\n' source) in
  match List.rev lines with
  | [] -> ""
  | last :: _ ->
      (* Ordinary spaces, however many non-breaking ones a pasted line
         was indented with. *)
      let indent = String.make (Lexer.indent_width last) ' ' in
      let stripped = String.trim last in
      if
        String.length stripped > 0
        && stripped.[String.length stripped - 1] = ':'
      then indent ^ indent_width
      else indent

(* --- accepting an entry --- *)

(** The names a top-level statement binds. stmt -> [string] *)
let defined_names stmt =
  match stmt with
  | SFunctionDef (_, name, _, _, _, _, _, _, _) -> [ name ]
  | stmt -> List.map fst (Analyses.bound_names stmt)

(** The whole lines of source a statement covers. string -> stmt
    -> string *)
let statement_source source stmt =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let info = stmt_info stmt in
  let first = max 0 (info.row1 - 1) in
  let last = min (Array.length lines) info.row2 in
  if first >= last then ""
  else String.concat "\n" (Array.to_list (Array.sub lines first (last - first)))

(** What stmt defined, as name -> the source text that defined it (sliced
    from source by whole lines, or printed back where there is no
    source). stmt -> string -> [(string, string)] *)
let defined_sources stmt source =
  match defined_names stmt with
  | [] -> []
  | names ->
      let text =
        if source <> "" then statement_source source stmt
        else pprint_program [ stmt ] false None
      in
      List.map (fun name -> (name, text)) names

(** An association list with `name` set to `text`: the existing entry
    replaced where there is one, and a new entry appended where there is
    not, so the order names were bound in survives.
    string -> string -> [(string, string)] -> [(string, string)] *)
let rec set_source name text = function
  | [] -> [ (name, text) ]
  | (held, _) :: rest when held = name -> (name, text) :: rest
  | pair :: rest -> pair :: set_source name text rest

(** Checks entry as one group (its datatypes declared, defs declared
    together via `declare_functions`, then `check_stmt` per statement,
    and every `match` held to matching every value), keeping each
    statement's environment and store rather than only the last. The
    table it filled comes back too: the tail-call pass reads it.
    [stmt] -> Typesystem.env -> Typesystem.store
    -> ([(stmt, typ option, Typesystem.env, Typesystem.store)], typ IntMap.t) *)
let check_entry entry types store =
  let store = Typesystem.declare_datatypes entry store in
  let types = Typesystem.import_env entry types store in
  let types, store = Typesystem.declare_functions entry types store in
  let store =
    { store with Typesystem.tmap = IntMap.empty; Typesystem.qmap = IntMap.empty }
  in
  let checked, _, store =
    List.fold_left
      (fun (checked, types, store) stmt ->
        let supplied, types, store =
          Typesystem.check_stmt stmt types Typesystem.No_function None store
        in
        (checked @ [ (stmt, supplied, types, store) ], types, store))
      ([], types, store) entry
  in
  Typesystem.check_matches entry store;
  (checked, store.Typesystem.tmap, store.Typesystem.qmap)

(** A value as the prompt shows it: `display_value`, except a function
    shows as <function>. Interpreter.value -> string *)
let value_text value =
  match value with
  | Interpreter.VClosure _ | Interpreter.VBuiltin _ -> "<function>"
  | value -> Interpreter.display_value value

(** ` : Type`, or "" if there is no type. A type the checker has not
    settled prints with `?` where it is still open -- an unannotated
    `def` has none until something calls it (see
    docs/type_inference.md), and `?` is what `displayed` renders that
    as. The prompt is the one place it is shown rather than suppressed:
    a session is a conversation about what is known so far, so "not
    known yet" is worth seeing. typ option -> string *)
let type_suffix type_ =
  match type_ with
  | None -> ""
  | Some type_ -> " : " ^ pprint_type default_config type_

(** Shows value as `value : Type`, or nothing for unit.
    host -> Interpreter.value option -> typ option -> () *)
let show host value type_ =
  match value with
  | None | Some Interpreter.VUnit -> ()
  | Some value -> host.write (value_text value ^ type_suffix type_)

(** One module an entry imported, made ready to run the way pyk.ml makes a
    program's: checked against what the modules it imports export, the
    mutability rule applied, overloading and implicits removed and its
    tail calls made loops. Answers what it exports, the statements to
    run, and the highest symbol handed out. Raises the stages' own
    errors. [(string, sigmap)] -> int -> Module.t -> (sigmap, [stmt], int) *)
let check_import sigmaps high (unit : Module.t) =
  if unit.is_external then (Module.external_sigmap unit.declarations, [], high)
  else
    let declared = Module.external_signatures unit.declarations in
    let tmap, qmap =
      Typesystem.type_check ~declared unit.stmts (Module.sigmaps_for unit sigmaps)
    in
    Analyses.analyze_mutability unit.stmts;
    let sigmap = Module.module_sigmap unit.name unit.stmts unit.declarations tmap in
    let elaborated, tmap = Elaborate.program qmap tmap unit.stmts in
    let elaborated = Analyses.symbolize ~start:high elaborated in
    let high = max high (Analyses.highest_sym elaborated) in
    let optimized, _ = Opt_tailcall.optimize elaborated tmap in
    let optimized = Analyses.symbolize ~start:high optimized in
    (sigmap, Analyses.apply_signatures optimized, max high (Analyses.highest_sym optimized))

(** The modules the imports in stmts newly reach, as the module system
    prepares them, with stmts' imports resolved against them; nothing is
    checked or run. Raises Module_error.
    session -> [stmt] -> ([Module.t], [stmt], Desugar_args.signatures, int) *)
let reached session stmts =
  Module.load_imports ?from:session.host.from ~libs:session.libs
    ~loaded:session.modules ~start:session.high ~signatures:session.arguments ""
    stmts

(** The session with every module an entry's imports newly reach loaded,
    checked and run, and the entry with its imports resolved against
    them. A module implemented in a target language is reached through
    the host's `connect`. An entry with no import comes back as it was.
    Raises the stages' own errors, and the one a module's top level
    failed with. session -> [stmt] -> (session, [stmt]) *)
let import_modules session stmts =
  if not (List.exists (function SImport _ -> true | _ -> false) stmts) then
    (session, stmts)
  else
    let modules, stmts, arguments, high = reached session stmts in
    let sigmaps, units, high =
      List.fold_left
        (fun (sigmaps, units, high) (unit : Module.t) ->
          let sigmap, running, high = check_import sigmaps high unit in
          ( sigmaps @ [ (unit.name, sigmap) ],
            units @ [ (unit.name, running, unit.declarations) ],
            high ))
        (session.sigmaps, [], high) modules
    in
    let added =
      List.filter (fun (unit : Module.t) -> unit.declarations <> []) modules
    in
    let hosted = session.hosted @ added in
    let state =
      if added = [] then session.state
      else
        Interpreter.with_host session.state
          (session.host.machine (Some (session.host.connect added hosted)))
    in
    let state, exports = Interpreter.load_modules state units session.exports in
    (match Interpreter.failure state with Some error -> raise error | None -> ());
    ( {
        session with
        high;
        arguments;
        state;
        store = { session.store with Typesystem.modules = sigmaps };
        modules =
          session.modules
          @ List.map (fun (unit : Module.t) -> (unit.name, unit)) modules;
        sigmaps;
        exports;
        hosted;
      },
      stmts )

(** `import_modules`, with every dotted name the entry defines or reaches
    given the plain name it compiles to first: the modules its imports
    name are loaded, the entry is rewritten against them and against
    what earlier entries wrote, and its imports are then resolved.
    Raises Module_error and the stages' own errors.
    session -> [stmt] -> string -> (session, [stmt]) *)
let import_modules_ session stmts source =
  let roots =
    List.sort_uniq compare
      (List.filter_map
         (function SImport (_, name, _, _, _, _) -> Some (Submodules.root name) | _ -> None)
         stmts)
  in
  let loading =
    List.filter_map
      (fun name ->
        match List.find_opt (function SImport (_, n, _, _, _, _) -> Submodules.root n = name | _ -> false) stmts with
        | Some (SImport (info, _, _, _, _, sym)) -> Some (SImport (info, name, name, false, [], sym))
        | _ -> None)
      roots
  in
  let session, _ = import_modules session loading in
  let imported =
    List.map
      (fun (name, (unit : Module.t)) -> (name, (unit.dotted, List.map fst unit.publics)))
      session.modules
  in
  let tokens =
    try Lexer.lexing repl_module (Lexer.chars_of_string (source ^ "\n")) with _ -> []
  in
  let stmts, _, _ =
    try Submodules.module_ ~context:session.written tokens stmts [] imported
    with Submodules.Error (info, message) -> raise (Module.Module_error (info, message))
  in
  import_modules session stmts

(** The modules the imports in stmts would newly load: what a host has to
    make ready before the entry is submitted. Nothing is loaded into the
    session. Raises Module_error. session -> [stmt] -> [Module.t] *)
let imported_modules session stmts =
  if not (List.exists (function SImport _ -> true | _ -> false) stmts) then []
  else
    let modules, _, _, _ = reached session stmts in
    modules

(** Shows the warnings an entry has, through the host, unless a -Werror
    made one of them an error: then the entry is refused, and the
    exception answered carries those. Its top-level names are never
    reported, since a later entry may use them.
    session -> string -> resolution IntMap.t -> [stmt] -> exn? *)
let entry_warnings session source qmap entry =
  let file = match entry with s :: _ -> (stmt_info s).file | [] -> "<repl>" in
  let tokens = try Lexer.lexing file (Lexer.chars_of_string (source ^ "\n")) with _ -> [] in
  let outer =
    Analyses.SMap.fold
      (fun name (b : Analyses.binding) out ->
        match b.info with Some info -> (name, info) :: out | None -> out)
      session.kinds []
  in
  let found = Warnings.check ~qmap ~toplevel_used:true ~outer session.warnings tokens entry in
  let errors, others = List.partition (fun (w : Warnings.warning) -> w.error) found in
  List.iter (fun w -> session.host.warn (Warnings.format w)) others;
  if errors = [] then None else Some (Warnings.Refused errors)

(** Checks stmts as one entry (all of it, before any of it runs), then
    runs whichever of them the checker accepted, reporting any runtime
    error via report. `source` is kept per-name for `:edit`. Answers the
    session and the check-time error, if any, left for the caller to
    handle rather than reported here.
    session -> [stmt] -> (exn -> ()) -> string -> (session, exn option) *)
let submit session stmts report source =
  let written = stmts in
  (* What the entry imports comes first: the sugar has to know what an
     imported definition's defaults are, and the checker what it
     exports. A submodule an entry names is settled before that, once
     the modules holding it are loaded (submodules.ml). *)
  match
    try Ok (import_modules_ session stmts source) with
    | Module.Module_error _ as e -> Error e
    | Lexer.Lex_error _ as e -> Error e
    | Parser.Parse_error _ as e -> Error e
    | Analyses.Analysis_error _ as e -> Error e
    | Typesystem.Type_error _ as e -> Error e
    | Interpreter.Runtime_error _ as e -> Error e
  with
  | Error e -> (session, Some e)
  | Ok (session, stmts) ->
  (* The sugar goes first, as it does in a file. The pass is over the
     entry alone and answers a possibly longer list, so `seen` is built
     from that rather than from what was typed. *)
  match
    try
      Ok (Desugar_args.desugar session.arguments repl_module stmts)
    with Analyses.Analysis_error _ as e -> Error e
  with
  | Error e -> (session, Some e)
  | Ok (stmts, arguments) ->
  let session = { session with arguments } in
  let seen = Analyses.symbolize ~start:session.high (session.seen @ stmts) in
  let entry = List.filteri (fun i _ -> i >= List.length session.seen) seen in
  match
    try
      let checked, tmap, qmap = check_entry entry session.types session.store in
      (* The one rule types do not state, asked of the entry as a block,
         exactly as `pyk` asks it of a file. *)
      let kinds = Analyses.analyze_stmts entry session.kinds in
      Ok (checked, tmap, qmap, kinds, seen, entry)
    with
    | Analyses.Analysis_error _ as e -> Error e
    | Typesystem.Type_error _ as e -> Error e
  with
  | Error e -> (session, Some e)
  | Ok (checked, tmap, qmap, kinds, seen, entry) -> (
      match entry_warnings session source qmap entry with
      | Some refused -> (session, Some refused)
      | None ->
      (* An entry's tail calls become loops here as they would in a file,
         so a function written at the prompt runs the way `pyk <file>`
         runs it (see docs/optimization.md). The pass needs the types, so
         it goes after the check; the entry is then checked again, not to
         verify it -- the rewrite preserves typing -- but because a
         merged group is a different number of statements, and the prompt
         shows a type per statement it runs. The pass is over the entry
         alone, which is exactly right: an entry is its own group of
         `def`s. *)
      let optimized, _ = Opt_tailcall.optimize entry tmap in
      let checked, qmap, seen, entry =
        if optimized = entry then (checked, qmap, seen, entry)
        else
          let seen =
            Analyses.symbolize ~start:session.high (session.seen @ optimized)
          in
          let entry =
            List.filteri (fun i _ -> i >= List.length session.seen) seen
          in
          let checked, _, qmap =
            check_entry entry session.types session.store
          in
          (checked, qmap, seen, entry)
      in
      (* The entry is *checked* under the names the prompt was typed
         with and *run* with overloading and implicits removed, exactly
         as a file is: the checker's environment keeps `int::leq`, so a
         later entry may name it, while the machine's holds the plain
         name the rewrite gave it (docs/implicits.md). *)
      let running, _ = Elaborate.program qmap tmap entry in
      let high = max session.high (Analyses.highest_sym seen) in
      let running = Analyses.symbolize ~start:high running in
      let high = max high (Analyses.highest_sym running) in
      let checked =
        List.map2
          (fun (_, supplied, types, store) stmt ->
            (stmt, supplied, types, store))
          checked running
      in
      (* `seen` grows whether or not every statement runs: a symbol
         handed out once must not be handed out again. *)
      let session = { session with seen; high; kinds; written = session.written @ written } in
      let state = Interpreter.declare_entry session.state running in
      let state = Interpreter.bind_imports state running session.exports in
      let rec run session state checked =
        match checked with
        | [] -> (session, None)
        | (stmt, supplied, types, store) :: rest -> (
            let after = Interpreter.eval_in state stmt in
            match Interpreter.failure after with
            | Some error ->
                (* An error in a library's own code is reported where the
                   entry called into the library. *)
                report (fst (Interpreter.outside_libraries (Module.in_library session.libs) after error));
                ({ session with state }, None)
            | None ->
                let session =
                  {
                    session with
                    state = after;
                    types;
                    store;
                    sources =
                      List.fold_left
                        (fun sources (name, text) -> set_source name text sources)
                        session.sources
                        (defined_sources stmt source);
                  }
                in
                show session.host (Interpreter.result after)
                  (Option.map
                     (fun s ->
                       Typesystem.displayed (Typesystem.zonk s store) store)
                     supplied);
                run session after rest)
      in
      run { session with state } state checked)

(** `submit`, with a refusal simply reported -- for callers with nothing
    better to do with one than say so.
    session -> [stmt] -> (exn -> ()) -> string -> session *)
let accept session stmts report source =
  let session, refused = submit session stmts report source in
  (match refused with Some error -> report error | None -> ());
  session

(** name -> Type for what the session has bound, read back against its
    store (so a deferred function shows what it turned out to be, and a
    type still being worked out shows what has been settled), in the
    order the session bound them -- which is the order `sources` records,
    since a name reaches both at the same statement.
    session -> [(string, typ)] *)
let binding_types session =
  let settled type_ =
    Typesystem.displayed
      (Typesystem.zonk (Typesystem.settled_type type_ session.store) session.store)
      session.store
  in
  let named name =
    match Typesystem.SMap.find_opt name session.types with
    | Some { Typesystem.btype = TBuiltin _; _ } | None -> None
    | Some binding -> Some (name, settled binding.Typesystem.btype)
  in
  let ordered = List.filter_map (fun (name, _) -> named name) session.sources in
  ordered
  @ Typesystem.SMap.fold
      (fun name binding found ->
        if List.mem_assoc name ordered then found
        else
          match binding.Typesystem.btype with
          | TBuiltin _ -> found
          | type_ -> found @ [ (name, settled type_) ])
      session.types []

(** One name the session has bound, as `:ls` shows it.
    implicit -- whether it was bound as an implicit.
    name -- the name, as the prompt wrote it.
    value -- the value, as the prompt shows one.
    type_ -- its type, where the checker has one. *)
type binding = { implicit : bool; name : string; value : string; type_ : string option }

(** What the session has bound (builtins excluded), in binding order.
    session -> [binding] *)
let bindings session =
  let values = Interpreter.bindings_in_scope session.state.Interpreter.env in
  let types = binding_types session in
  (* A qualified name runs under the plain one the rewrite gave it
     (docs/overloading.md), so the machine is asked for that while the
     prompt shows what was typed. *)
  let held name = List.mem_assoc (Names.renamed name) values in
  let names = List.filter (fun (name, _) -> held name) types |> List.map fst in
  let shown = List.map Names.renamed names in
  let names =
    names
    @ List.filter_map
        (fun (name, _) ->
          if List.mem name shown || List.mem name Builtin.names then None
          else Some name)
        values
  in
  (* A def holding a parameter's default is the pass's, not the
     session's: nobody typed it, so nobody is shown it. *)
  let names =
    List.filter
      (fun name ->
        (not (Desugar_args.generated_name name))
        && not (Elaborate.generated_name name))
      names
  in
  List.map
    (fun name ->
      {
        implicit =
          (match Typesystem.SMap.find_opt name session.types with
          | Some { Typesystem.bimplicit = true; _ } -> true
          | _ -> false);
        name;
        value = value_text (List.assoc (Names.renamed name) values);
        type_ =
          Option.map
            (pprint_type default_config)
            (List.assoc_opt name types);
      })
    names

(* --- meta-commands ---

   Each takes the session and the argument text, and answers the session
   to carry on with -- so a command that changes the session (`:load`,
   `:reset`) and one that only reports (`:type`, `:ls`) have the same
   shape, and the loop needs to know nothing about which is which. *)

(** What a meta-command leaves behind: the session, and text to put back
    in front of the user (only `:edit` sets that). *)
type outcome = { out_session : session; pending : string }

let plain session = { out_session = session; pending = "" }

(* Every command, its usage and what it does, and whether only a
   terminal has it. *)
let command_help =
  [
    (":help", "this help list", false);
    (":quit, :q", "leave (or type Ctrl-D)", true);
    (":ls", "list all bound values and variables", false);
    (":type <expr>", "the type of expression <expr>", false);
    (":edit <name>", "edit defined <name> again", false);
    (":ast <stmt>", "the parsed form of <stmt>", false);
    (":tokens <line>", "the token stream for <line>", false);
    (":load <file>", "read a file into the session", true);
    (":reset", "forget everything and start again", false);
  ]

(** The help list: every command, or only those a page has.
    bool -> string *)
let help_text terminal =
  "\nCommands:\n"
  ^ String.concat ""
      (List.filter_map
         (fun (usage, what, terminal_only) ->
           if terminal_only && not terminal then None
           else Some (Printf.sprintf "  %-17s%s\n" usage what))
         command_help)

(** Shows the help list. *)
let meta_help terminal session _argument _report =
  session.host.write (help_text terminal);
  plain session

(** Shows what the session has bound, as `name = value : Type`
    (builtins excluded), in binding order. *)
let meta_ls session _argument _report =
  (match bindings session with
  | [] -> session.host.write "no bindings yet"
  | shown ->
      let width =
        List.fold_left
          (fun width binding -> max width (String.length binding.name))
          0 shown
      in
      List.iter
        (fun binding ->
          session.host.write
            (Printf.sprintf "%s%s%s = %s%s"
               (if binding.implicit then "implicit " else "")
               binding.name
               (String.make (width - String.length binding.name) ' ')
               binding.value
               (match binding.type_ with None -> "" | Some t -> " : " ^ t)))
        shown);
  plain session

(** Shows the type of the expression argument, checked in the session's
    own type environment. *)
let meta_type session argument report =
  if argument = "" then (
    session.host.write "usage: :type <expression>";
    plain session)
  else
    match parse_source ~features:session.features argument with
    | exception (Lexer.Lex_error _ as e) ->
        report e;
        plain session
    | exception (Parser.Parse_error _ as e) ->
        report e;
        plain session
    | [ SExprStmt (_, e, _) ] -> (
        match Typesystem.check_expr e session.types session.store with
        | checked, store ->
            session.host.write
              (pprint_type default_config
                 (Typesystem.displayed
                    (Typesystem.zonk (Typesystem.settled_type checked store) store)
                    store));
            plain session
        | exception (Analyses.Analysis_error _ as e) ->
            report e;
            plain session
        | exception (Typesystem.Type_error _ as e) ->
            report e;
            plain session)
    | _ ->
        session.host.write ":type takes one expression";
        plain session

(** Shows the parsed form of the statement argument. *)
let meta_ast session argument report =
  if argument = "" then (
    session.host.write "usage: :ast <statement>";
    plain session)
  else
    match parse_source ~features:session.features argument with
    | stmts ->
        session.host.write (pprint_program stmts false None);
        plain session
    | exception (Lexer.Lex_error _ as e) ->
        report e;
        plain session
    | exception (Parser.Parse_error _ as e) ->
        report e;
        plain session

(** Shows the token stream for the line argument. *)
let meta_tokens session argument report =
  (match Lexer.lexing "<repl>" (Lexer.chars_of_string (argument ^ "\n")) with
  | tokens ->
      List.iter
        (fun token ->
          session.host.write
            (Printf.sprintf "%s %s"
               (Lexer.pprint_info (Lexer.token_info token))
               (Lexer.pprint_token token)))
        tokens
  | exception (Lexer.Lex_error _ as e) -> report e);
  plain session

(** Puts the source text that defined argument back into the prompt to
    edit and re-enter. *)
let meta_edit session argument _report =
  if argument = "" then (
    session.host.write "usage: :edit <name>";
    plain session)
  else
    match List.assoc_opt argument session.sources with
    | None ->
        session.host.write
          (Printf.sprintf "nothing named '%s' was defined in this session" argument);
        plain session
    | Some text -> { out_session = session; pending = text }

(** Starts a new, empty session, looking for modules where this one did. *)
let meta_reset session _argument _report =
  session.host.write "session reset";
  plain (new_session ~libs:session.libs session.host)

(** Runs the meta-command in line, or reports "unknown command". `extra`
    is the commands only a terminal has, and its presence is what says
    the help list names them.
    [(string, session -> string -> (exn -> ()) -> outcome)]? -> session
    -> string -> (exn -> ()) -> outcome *)
let run_meta ?(extra = []) session line report =
  let word, argument =
    match String.index_opt line ' ' with
    | None -> (line, "")
    | Some i ->
        (String.sub line 0 i, String.trim (String.sub line (i + 1) (String.length line - i - 1)))
  in
  let commands =
    [
      (":help", meta_help (extra <> []));
      (":ls", meta_ls);
      (":type", meta_type);
      (":edit", meta_edit);
      (":ast", meta_ast);
      (":tokens", meta_tokens);
      (":reset", meta_reset);
    ]
    @ extra
  in
  match List.assoc_opt word commands with
  | None ->
      session.host.write (Printf.sprintf "unknown command '%s'; :help lists them" word);
      plain session
  | Some command -> command session argument report

(** What may be typed where the cursor is: where the word being typed
    starts, and every name that fits it with its type -- after `m.`, what
    the module the session imported as `m` exports; at the start of a
    line beginning `:`, the meta-commands; elsewhere what the session has
    bound, the modules it imported, the builtins and the keywords. Every
    command a terminal has is offered when `terminal` says so.
    bool? -> session -> string -> int -> (int, [(string, string?)]) *)
let completions ?(terminal = false) session line col =
  let start, prefix, module_ = Completion.word_before line col in
  let shown t = Syntax.pprint_type Syntax.default_config t in
  let imported =
    List.filter_map
      (fun s -> match s with SImport (_, real, alias, false, _, _) -> Some (alias, real) | _ -> None)
      session.written
  in
  let candidates =
    match module_ with
    | Some m -> (
        match List.assoc_opt m imported with
        | None -> []
        | Some real -> (
            match List.assoc_opt real session.sigmaps with
            | None -> []
            | Some sigmap -> List.map (fun (name, t, _) -> (name, Some (shown t))) sigmap))
    | None when String.length prefix > 0 && prefix.[0] = ':' && String.trim (String.sub line 0 start) = "" ->
        List.filter_map
          (fun (usage, what, terminal_only) ->
            if terminal_only && not terminal then None
            else
              let word = match String.index_opt usage ' ' with Some i -> String.sub usage 0 i | None -> usage in
              let word = match String.index_opt word ',' with Some i -> String.sub word 0 i | None -> word in
              Some (word, Some what))
          command_help
    | None ->
        List.map (fun (name, t) -> (name, Some (shown t))) (binding_types session)
        @ List.map (fun (alias, real) -> (alias, Some ("module " ^ real))) imported
        @ List.map (fun name -> (name, Some "builtin")) Builtin.names
        @ List.map (fun k -> (k, None)) Lexer.keywords
  in
  (start, Completion.matching prefix candidates)

(* What the front end says when a name resolves to nothing. Read here
   rather than re-derived: the wording is analyses.ml's, in one place,
   and this is the one caller that wants the *name* out of it rather
   than the sentence. *)
let unbound_prefix = "unbound name '"

(** The name an "unbound name" error is about, or None.
    exn -> string option *)
let undefined_name error =
  match error with
  | Analyses.Analysis_error (_, message) when starts_with unbound_prefix message ->
      let rest =
        String.sub message (String.length unbound_prefix)
          (String.length message - String.length unbound_prefix)
      in
      (* The name ends at its closing quote; a "did you mean" may follow. *)
      Some
        (match String.index_opt rest '\'' with
        | Some close -> String.sub rest 0 close
        | None -> rest)
  | _ -> None

(** Whether stmts include a def. [stmt] -> bool *)
let defines_function stmts =
  List.exists (fun s -> match s with SFunctionDef _ -> true | _ -> false) stmts
