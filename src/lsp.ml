(** The Pyking language server: a state and one function from a message an
    editor sent to the messages to send back. It checks a document with
    the compiler's own front end -- Module.load, Typesystem.type_check,
    Analyses.analyze_mutability -- and reads hover, definition, outline
    and completion out of what that produced. No file is opened here:
    the caller hands in where files come from, so the same server runs
    in `pyk lsp` and in the browser. See design/lsp.md.

    Data structures:
      settings -- what the editor configured.
      document -- one open file.
      analysis -- what checking one document as a program found.
      meaning -- what a name refers to.
      phase -- where the protocol is.
      state -- everything the server knows.

    Functions:
      create sources libs version -- a server that has seen nothing.
      handle state text -- one message received, and what to send back.
      idle state -- the diagnostics of every document due to be checked.
      exit_code state -- the status to exit with, once `exit` arrived. *)

open Syntax

module SMap = Map.Make (String)

(* What the editor configured: more library directories, and whether to
   check only on save. *)
type settings = { lib_path : string list; on_save : bool }

(* One open file: its URI and path, its text and version as the editor
   last sent them, and whether it is due to be checked. *)
type document = { uri : string; path : string; text : string; version : int; due : bool }

(* The first error a check found: where, pyk's label for its stage, and
   what it says. *)
type problem = { at : Lexer.info; kind : string; message : string }

(* What checking a document as a program found: the version checked,
   the modules loaded, each checked module's types and exports, the last
   check that reached the document's own module, and the error or the
   internal failure that stopped it. *)
type analysis = {
  checked_version : int;
  units : Module.t list;
  tmaps : (string * typ IntMap.t) list;
  sigmaps : (string * Typesystem.sigmap) list;
  typed : (Module.t list * (string * typ IntMap.t) list) option;
  problem : problem option;
  internal : string option;
}

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

(* Where the protocol is: before initialize, running, after shutdown, and
   after exit with the status to end with. *)
type phase = Fresh | Running | Shut_down | Exited of int

(* Everything the server knows: where files come from, the library path,
   its version, the settings, the open documents, each one's analysis,
   what was last published for each, and the phase. *)
type state = {
  base : Module.sources;
  libs : Module.lib_entry list;
  server_version : string;
  settings : settings;
  documents : document list;
  analyses : (string * analysis) list;
  published : (string * string) list;
  phase : phase;
}

let create base libs server_version =
  {
    base;
    libs;
    server_version;
    settings = { lib_path = []; on_save = false };
    documents = [];
    analyses = [];
    published = [];
    phase = Fresh;
  }

let exit_code state = match state.phase with Exited code -> Some code | _ -> None

(* --- paths and URIs --- *)

(** A URI's path with its %XX escapes decoded: file:///a/b%20c.pyk is
    /a/b c.pyk, and file:///C:/x.pyk is C:/x.pyk. string -> string *)
let path_of_uri uri =
  let rest =
    if String.length uri >= 7 && String.sub uri 0 7 = "file://" then
      String.sub uri 7 (String.length uri - 7)
    else uri
  in
  let rest =
    if String.length rest >= 9 && String.sub rest 0 9 = "localhost" then
      String.sub rest 9 (String.length rest - 9)
    else rest
  in
  let decoded = Buffer.create (String.length rest) in
  let n = String.length rest in
  let rec go i =
    if i < n then
      if rest.[i] = '%' && i + 2 < n then (
        match int_of_string_opt ("0x" ^ String.sub rest (i + 1) 2) with
        | Some c ->
            Buffer.add_char decoded (Char.chr c);
            go (i + 3)
        | None ->
            Buffer.add_char decoded '%';
            go (i + 1))
      else (
        Buffer.add_char decoded rest.[i];
        go (i + 1))
  in
  go 0;
  let path = Buffer.contents decoded in
  (* A Windows drive: /C:/x is C:/x. *)
  if String.length path >= 3 && path.[0] = '/' && path.[2] = ':' then
    String.sub path 1 (String.length path - 1)
  else path

(** The file URI of a path. string -> string *)
let uri_of_path path =
  let buffer = Buffer.create (String.length path + 8) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' | ':' ->
          Buffer.add_char buffer c
      | '\\' -> Buffer.add_char buffer '/'
      | c -> Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code c)))
    path;
  let encoded = Buffer.contents buffer in
  if String.length encoded > 0 && encoded.[0] = '/' then "file://" ^ encoded
  else "file:///" ^ encoded

(* --- positions --- *)

(** The lines of a text, without their line ends. string -> [string] *)
let lines_of text =
  List.map
    (fun line ->
      let n = String.length line in
      if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line)
    (String.split_on_char '\n' text)

(** Line `row` (counted from 1) of a text, or "" past its end.
    string -> int -> string *)
let line_at text row =
  match List.nth_opt (lines_of text) (row - 1) with Some line -> line | None -> ""

(** The length in bytes of the UTF-8 sequence a byte starts. char -> int *)
let utf8_length c =
  let b = Char.code c in
  if b < 0x80 then 1 else if b < 0xC0 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4

(** How many UTF-16 code units the first `bytes` bytes of a line are.
    string -> int -> int *)
let utf16_of_bytes line bytes =
  let stop = min bytes (String.length line) in
  let rec go i units =
    if i >= stop then units + max 0 (bytes - String.length line)
    else
      let k = utf8_length line.[i] in
      go (i + k) (units + if k = 4 then 2 else 1)
  in
  go 0 0

(** How many bytes the first `units` UTF-16 code units of a line are.
    string -> int -> int *)
let bytes_of_utf16 line units =
  let n = String.length line in
  let rec go i u =
    if u >= units || i >= n then i
    else
      let k = utf8_length line.[i] in
      go (i + k) (u + if k = 4 then 2 else 1)
  in
  go 0 0

(** An LSP position for a row (from 1) and byte column of a text.
    string -> int -> int -> Json.t *)
let position text row col =
  Json.Object
    [
      ("line", Json.Number (float_of_int (max 0 (row - 1))));
      ("character", Json.Number (float_of_int (utf16_of_bytes (line_at text row) col)));
    ]

(** An LSP range for a span of a text. string -> Lexer.info -> Json.t *)
let range text (i : Lexer.info) =
  let row2, col2 = if (i.row2, i.col2) < (i.row1, i.col1) then (i.row1, i.col1) else (i.row2, i.col2) in
  Json.Object [ ("start", position text i.row1 i.col1); ("end", position text row2 col2) ]

(** The row (from 1) and byte column an LSP position names in a text.
    string -> Json.t -> (int, int) *)
let row_col text pos =
  let line = Option.value ~default:0 (Json.to_int_option (Json.member "line" pos)) in
  let character = Option.value ~default:0 (Json.to_int_option (Json.member "character" pos)) in
  (line + 1, bytes_of_utf16 (line_at text (line + 1)) character)

(** The byte offset of a row and column in a text. string -> int -> int -> int *)
let offset_of text row col =
  let lines = String.split_on_char '\n' text in
  let rec go lines r offset =
    match lines with
    | [] -> String.length text
    | line :: rest ->
        if r = row then min (offset + col) (offset + String.length line)
        else go rest (r + 1) (offset + String.length line + 1)
  in
  min (String.length text) (go lines 1 0)

(** Whether a span holds a row and byte column. Lexer.info -> int -> int -> bool *)
let contains (i : Lexer.info) row col =
  compare (i.row1, i.col1) (row, col) <= 0 && compare (row, col) (i.row2, i.col2) <= 0

(** How big a span is, for picking the smallest. Lexer.info -> (int, int) *)
let size (i : Lexer.info) = (i.row2 - i.row1, if i.row1 = i.row2 then i.col2 - i.col1 else i.col2)

(* --- files --- *)

(** Where a server's files come from: the open documents, then the
    caller's. state -> Module.sources *)
let sources state : Module.sources =
  let open_at path = List.find_opt (fun d -> d.path = path) state.documents in
  {
    exists = (fun path -> open_at path <> None || state.base.exists path);
    contents =
      (fun path ->
        match open_at path with Some d -> d.text | None -> state.base.contents path);
  }

(** A file's text, or "" where it cannot be read. state -> string -> string *)
let text_of state path =
  let s = sources state in
  try if s.exists path then s.contents path else "" with _ -> ""

(* --- checking a document --- *)

(** The label pyk gives an error of each stage, and its span and message.
    exn -> (Lexer.info, string, string)? *)
let describe error =
  match error with
  | Lexer.Lex_error (at, message) -> Some (at, "Lexing error", message)
  | Parser.Parse_error (at, message) -> Some (at, "Parsing error", message)
  | Module.Module_error (at, message) -> Some (at, "Module error", message)
  | Analyses.Analysis_error (at, message) -> Some (at, "Name error", message)
  | Typesystem.Type_error (at, message) -> Some (at, "Type error", message)
  | _ -> None

(** Checks one document as a program, as pyk does: every module it
    reaches, each against what the ones it imports export. Keeps the
    previous analysis's modules where this one could not load any.
    state -> document -> analysis? -> analysis *)
let analyse state document previous =
  let libs =
    state.libs
    @ List.map
        (fun directory -> Module.{ lib_directory = directory; lib_origin = "editor setting" })
        state.settings.lib_path
  in
  let kept =
    match previous with
    | Some a -> a
    | None -> { checked_version = -1; units = []; tmaps = []; sigmaps = []; typed = None; problem = None; internal = None }
  in
  (* Where this check did not reach the document's own module, its types
     come from the last check that did: stale, but each node there still
     has its own type. *)
  let typed units tmaps =
    if List.mem_assoc document.path tmaps then Some (units, tmaps)
    else match kept.typed with Some t -> Some t | None -> Some (units, tmaps)
  in
  let failed error units tmaps sigmaps =
    let base = { checked_version = document.version; units; tmaps; sigmaps; typed = typed units tmaps; problem = None; internal = None } in
    match describe error with
    | Some (at, kind, message) -> { base with problem = Some { at; kind; message } }
    | None -> { base with internal = Some (Printexc.to_string error) }
  in
  match Module.load ~from:(sources state) ~libs ~splash:false document.path with
  | exception error -> failed error kept.units kept.tmaps kept.sigmaps
  | units ->
      let rec check units_left tmaps sigmaps =
        match units_left with
        | [] ->
            { checked_version = document.version; units; tmaps; sigmaps; typed = Some (units, tmaps);
              problem = None; internal = None }
        | (unit : Module.t) :: rest ->
            if unit.is_external then
              check rest tmaps (sigmaps @ [ (unit.name, Module.external_sigmap unit.declarations) ])
            else (
              match
                let declared = Module.external_signatures unit.declarations in
                let tmap, _ =
                  Typesystem.type_check ~declared unit.stmts (Module.sigmaps_for unit sigmaps)
                in
                Analyses.analyze_mutability unit.stmts;
                (tmap, Module.module_sigmap unit.name unit.stmts unit.declarations tmap)
              with
              | exception error -> failed error units tmaps sigmaps
              | tmap, sigmap ->
                  check rest (tmaps @ [ (unit.path, tmap) ]) (sigmaps @ [ (unit.name, sigmap) ]))
      in
      check units [] []

(** The analysis of a document as it is now, checking it if it changed.
    state -> document -> (state, analysis) *)
let analysis_of state document =
  let previous = List.assoc_opt document.uri state.analyses in
  match previous with
  | Some a when a.checked_version = document.version -> (state, a)
  | _ ->
      let a = analyse state document previous in
      ({ state with analyses = (document.uri, a) :: List.remove_assoc document.uri state.analyses }, a)

(* --- what names mean --- *)

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
  | PInt _ | PString _ | PBool _ | PWildcard _ | PText _ -> []

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
  | EInt _ | EFloat _ | EString _ | EBool _ -> found
  | EVar (i, n, _) -> { found with uses = { use_at = i; use_name = n; use_meaning = lookup env n } :: found.uses }
  | EAdd (_, a, b, _) | ESub (_, a, b, _) | EMul (_, a, b, _) | EDiv (_, a, b, _)
  | EConcat (_, a, b, _) | ELessThan (_, a, b, _) | ELessThanEq (_, a, b, _)
  | EGreatThan (_, a, b, _) | EGreatThanEq (_, a, b, _) | EEq (_, a, b, _) ->
      go b (go a found)
  | ENeg (_, a, _) -> go a found
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

(* --- answers --- *)

(** A doc comment's lines with each section line outside a code block --
    `# Parameters`, `# Returns`, `# Examples` -- made a bold label, which
    an editor's hover shows at the size of the text around it.
    [string] -> [string] *)
let section_labels lines =
  let _, out =
    List.fold_left
      (fun (fenced, out) line ->
        let fence = String.length line >= 3 && String.sub line 0 3 = "```" in
        let heading =
          (not fenced) && String.length line > 2 && String.sub line 0 2 = "# "
        in
        let shown =
          if heading then "**" ^ String.sub line 2 (String.length line - 2) ^ "**"
          else line
        in
        ((if fence then not fenced else fenced), shown :: out))
      (false, []) lines
  in
  List.rev out

(** The `##` comment written directly above a row of a file, without its
    markers. state -> string -> int -> string? *)
let doc_comment state file row =
  let lines = Array.of_list (lines_of (text_of state file)) in
  let rec go r acc =
    if r < 1 || r > Array.length lines then acc
    else
      let line = String.trim lines.(r - 1) in
      if String.length line >= 2 && String.sub line 0 2 = "##" then
        let body = String.sub line 2 (String.length line - 2) in
        let body = if String.length body > 0 && body.[0] = ' ' then String.sub body 1 (String.length body - 1) else body in
        go (r - 1) (body :: acc)
      else acc
  in
  match go (row - 1) [] with
  | [] -> None
  | lines -> Some (String.concat "\n" (section_labels lines))

(** The unit an analysis holds for a document, and its types.
    analysis -> document -> (Module.t, typ IntMap.t)? *)
let own_unit analysis document =
  List.find_opt (fun (u : Module.t) -> u.path = document.path) analysis.units
  |> Option.map (fun (u : Module.t) ->
         (u, Option.value ~default:IntMap.empty (List.assoc_opt u.path analysis.tmaps)))

(** A type as Pyking writes it. typ -> string *)
let show_type t = pprint_type default_config t

(** The type the checker recorded for a binding, or, for a name another
    module exports, the type it exports it at. analysis -> meaning ->
    string? *)
let meaning_type analysis meaning =
  match meaning with
  | Bound (place, s, _) -> (
      let recorded =
        if s = 0 then None
        else
          List.find_map
            (fun (_, tmap) -> IntMap.find_opt s tmap)
            (List.filter (fun (p, _) -> p = place.file) analysis.tmaps)
      in
      match recorded with
      | Some t -> Some (show_type t)
      | None ->
          let owner =
            List.find_opt
              (fun (u : Module.t) -> u.path = place.file || u.declaration_path = Some place.file)
              analysis.units
          in
          Option.bind owner (fun (u : Module.t) ->
              Option.bind (List.assoc_opt u.name analysis.sigmaps) (fun sigmap ->
                  List.find_map
                    (fun (n, t, _) ->
                      match export_place u n with
                      | Some (p, _, _) when p.span = place.span -> Some (show_type t)
                      | _ -> None)
                    sigmap)))
  | _ -> None

(** The smallest node in a module holding a position whose type the
    checker recorded: an expression, a binding's target, a parameter, or
    a definition's first line -- with the name it binds, where it binds
    one. [stmt] -> typ IntMap.t -> int -> int -> (Lexer.info, typ,
    string?)? *)
let typed_node stmts tmap row col =
  let candidate node =
    match node with
    | Walk.NExpr e -> Some (expr_info e, expr_sym e, None)
    | Walk.NTarget (TargetName (i, n, s)) -> Some (i, s, Some n)
    | Walk.NTarget t -> Some (target_info t, target_sym t, None)
    | Walk.NParam (Param (i, n, _, _, s)) -> Some (i, s, Some n)
    | Walk.NStmt (SFunctionDef (i, n, _, _, _, s, _, _, _)) when i.row1 = row ->
        Some ({ i with row2 = i.row1; col2 = max_int }, s, Some ("def " ^ n))
    | Walk.NStmt (SVar (i, n, _, s)) when i.row1 = row ->
        Some ({ i with row2 = i.row1; col2 = i.col1 + String.length "var " + String.length n }, s, Some ("var " ^ n))
    | _ -> None
  in
  Walk.fold_stmts
    (fun best node ->
      match candidate node with
      | Some (i, s, name) when contains i row col -> (
          match IntMap.find_opt s tmap with
          | Some t -> (
              match best with
              | Some (b, _, _) when compare (size b) (size i) <= 0 -> best
              | _ -> Some (i, t, name))
          | None -> best)
      | _ -> best)
    None stmts

(** The use of a name at a position, the smallest holding it.
    found -> int -> int -> use? *)
let use_at found row col =
  List.fold_left
    (fun best u ->
      if contains u.use_at row col then
        match best with
        | Some b when compare (size b.use_at) (size u.use_at) <= 0 -> best
        | _ -> Some u
      else best)
    None found.uses

(** A Markdown hover holding Pyking. string -> string? -> Json.t *)
let hover_contents code doc =
  Json.Object
    [
      ("kind", Json.String "markdown");
      ( "value",
        Json.String
          ("```pyking\n" ^ code ^ "\n```" ^ match doc with Some d -> "\n\n" ^ d | None -> "") );
    ]

(** The hover at a position of a document. state -> document -> Json.t ->
    (state, Json.t) *)
let hover state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  let typed_analysis =
    match analysis.typed with Some (units, tmaps) -> { analysis with units; tmaps } | None -> analysis
  in
  match own_unit typed_analysis document with
  | None -> (state, Json.Null)
  | Some (unit, tmap) -> (
      let analysis = typed_analysis in
      let found = resolve analysis.units unit in
      let use = use_at found row col in
      let doc =
        match use with
        | Some { use_meaning = Bound (place, _, _); _ } -> doc_comment state place.file place.span.row1
        | _ -> None
      in
      match use with
      | Some { use_name; use_meaning = Builtin; use_at } ->
          (state, Json.Object [ ("contents", hover_contents (use_name ^ " -- builtin") None); ("range", range document.text use_at) ])
      | Some { use_name; use_meaning = Module_of real; use_at } ->
          (state, Json.Object [ ("contents", hover_contents ("import " ^ real ^ (if real = use_name then "" else " as " ^ use_name)) None); ("range", range document.text use_at) ])
      | _ -> (
          match typed_node unit.stmts tmap row col with
          | Some (i, t, name) ->
              let label =
                match (use, name) with
                | Some u, _ when compare (size u.use_at) (size i) <= 0 -> u.use_name ^ ": "
                | _, Some n -> n ^ ": "
                | _ -> ""
              in
              let shown = { i with col2 = (if i.col2 = max_int then String.length (line_at document.text i.row1) else i.col2) } in
              (state, Json.Object [ ("contents", hover_contents (label ^ show_type t) doc); ("range", range document.text shown) ])
          | None -> (
              match use with
              | Some u -> (
                  match meaning_type analysis u.use_meaning with
                  | Some t -> (state, Json.Object [ ("contents", hover_contents (u.use_name ^ ": " ^ t) doc) ])
                  | None -> (state, Json.Null))
              | None -> (state, Json.Null))))

(** An LSP location for a place. state -> place -> Json.t *)
let location state place =
  Json.Object [ ("uri", Json.String (uri_of_path place.file)); ("range", range (text_of state place.file) place.span) ]

(** Where the name at a position of a document is bound.
    state -> document -> Json.t -> (state, Json.t) *)
let definition state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  match own_unit analysis document with
  | None -> (state, Json.Null)
  | Some (unit, _) -> (
      let found = resolve analysis.units unit in
      match use_at found row col with
      | Some { use_meaning = Bound (place, _, _); _ } -> (state, location state place)
      | Some { use_meaning = Module_of real; _ } -> (
          match List.find_opt (fun (u : Module.t) -> u.name = real) analysis.units with
          | Some u ->
              let file = if u.is_external then Option.value ~default:u.path u.declaration_path else u.path in
              (state, location state { file; span = { file; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } })
          | None -> (state, Json.Null))
      | _ -> (state, Json.Null))

(** One DocumentSymbol. string -> int -> string -> Lexer.info ->
    Lexer.info -> string? -> [Json.t] -> Json.t *)
let symbol text kind name (whole : Lexer.info) (selection : Lexer.info) detail children =
  Json.Object
    ([ ("name", Json.String name); ("kind", Json.Number (float_of_int kind));
       ("range", range text whole); ("selectionRange", range text selection) ]
    @ (match detail with Some d -> [ ("detail", Json.String d) ] | None -> [])
    @ if children = [] then [] else [ ("children", Json.List children) ])

(** The outline of a document: its definitions, nested ones inside, its
    top-level bindings and its imports. state -> document -> (state, Json.t) *)
let document_symbols state document =
  let state, analysis = analysis_of state document in
  match own_unit analysis document with
  | None -> (state, Json.List [])
  | Some (unit, tmap) ->
      let text = document.text in
      let typed s = Option.map show_type (IntMap.find_opt s tmap) in
      let rec of_stmts top stmts =
        List.concat_map
          (fun stmt ->
            match stmt with
            | SFunctionDef (i, n, _, body, _, s, _, _, _) ->
                [ symbol text 12 n i (name_span unit.tokens n i) (typed s) (of_stmts false body) ]
            | SLet (i, target, _, _, _, _, _) when top ->
                List.map (fun (n, span, s) -> symbol text 14 n i span (typed s) []) (target_bindings target)
            | SLetStmt (i, target, _, _, _, _) when top ->
                List.map (fun (n, span, s) -> symbol text 14 n i span (typed s) []) (target_bindings target)
            | SVar (i, n, _, _) when top -> [ symbol text 13 n i (name_span unit.tokens n i) None [] ]
            | SImport (i, module_, name, selected, fields, _) ->
                if selected then
                  List.map (fun (_, local) -> symbol text 2 local i (name_span unit.tokens local i) (Some ("from " ^ module_)) []) fields
                else [ symbol text 2 name i (name_span unit.tokens name i) (Some ("import " ^ module_)) [] ]
            | _ -> [])
          stmts
      in
      (state, Json.List (of_stmts true unit.stmts))

(** A completion item. string -> int -> string? -> Json.t *)
let item label kind detail =
  Json.Object
    ([ ("label", Json.String label); ("kind", Json.Number (float_of_int kind)) ]
    @ match detail with Some d -> [ ("detail", Json.String d) ] | None -> [])

(** Whether a name was made up by a pass rather than written: a default
    argument's helper, an elaborated overload. string -> bool *)
let hidden name = Desugar_args.generated_name name || Elaborate.generated_name name

(** The qualifier written before the cursor, as in `m.` or `m.pa`, if
    there is one. string -> int -> string? *)
let qualifier line col =
  let rec back i = if i > 0 && (match line.[i - 1] with 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) then back (i - 1) else i in
  let start = back (min col (String.length line)) in
  if start > 0 && line.[start - 1] = '.' then
    let stop = start - 1 in
    let first = back stop in
    if first < stop then Some (String.sub line first (stop - first)) else None
  else None

(** What may be written at a position of a document: after `m.`, what
    module m exports; elsewhere the names in scope there, the keywords
    and the builtins. state -> document -> Json.t -> (state, Json.t) *)
let completion state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  let found = Option.map (fun (u, _) -> resolve analysis.units u) (own_unit analysis document) in
  let scope_names =
    match found with
    | None -> SMap.empty
    | Some found ->
        List.fold_left
          (fun best s ->
            match best with
            | Some b when compare b.scope_from s.scope_from >= 0 -> best
            | _ ->
                if compare s.scope_from (row, col) <= 0 && compare (row, col) s.scope_to <= 0 then Some s else best)
          None found.scopes
        |> Option.map (fun s -> s.names)
        |> Option.value ~default:SMap.empty
  in
  let module_names =
    List.fold_left (fun env (u : Module.t) -> SMap.add u.name (Module_of u.name) env) SMap.empty analysis.units
  in
  match qualifier (line_at document.text row) col with
  | Some m ->
      let real =
        match SMap.find_opt m scope_names with
        | Some (Module_of real) -> Some real
        | _ -> (match SMap.find_opt m module_names with Some (Module_of r) -> Some r | _ -> None)
      in
      let items =
        match Option.bind real (fun r -> List.assoc_opt r analysis.sigmaps) with
        | Some sigmap ->
            List.filter_map
              (fun (n, t, _) ->
                if hidden n then None
                else Some (item n (match t with TFunction _ -> 3 | _ -> 6) (Some (show_type t))))
              sigmap
        | None -> []
      in
      (state, Json.Object [ ("isIncomplete", Json.Bool false); ("items", Json.List items) ])
  | None ->
      let names =
        SMap.fold
          (fun n meaning acc ->
            if String.contains n '.' || hidden n then acc
            else
              let kind, detail =
                match meaning with
                | Builtin -> (3, Some "builtin")
                | Module_of real -> (9, Some ("module " ^ real))
                | Bound (_, _, KFunction) -> (3, meaning_type analysis meaning)
                | Bound (_, _, KVariable) -> (6, Option.map (fun t -> "var " ^ t) (meaning_type analysis meaning))
                | Bound _ -> (6, meaning_type analysis meaning)
                | Unknown -> (6, None)
              in
              item n kind detail :: acc)
          scope_names []
      in
      let names = if names = [] then List.map (fun n -> item n 3 (Some "builtin")) Builtin.names else names in
      let keywords = List.map (fun k -> item k 14 None) Lexer.keywords in
      (state, Json.Object [ ("isIncomplete", Json.Bool false); ("items", Json.List (List.rev names @ keywords)) ])

(* --- diagnostics --- *)

(** The import in a module that reaches the module a file belongs to,
    directly or through others. [Module.t] -> Module.t -> string ->
    stmt? *)
let import_reaching units (unit : Module.t) file =
  let owner =
    List.find_opt (fun (u : Module.t) -> u.path = file || u.declaration_path = Some file) units
  in
  let rec reaches seen name =
    match owner with
    | Some o when o.name = name -> true
    | _ -> (
        if List.mem name seen then false
        else
          match List.find_opt (fun (u : Module.t) -> u.name = name) units with
          | Some u -> List.exists (reaches (name :: seen)) u.imports
          | None -> false)
  in
  let stem = Filename.remove_extension (Filename.basename file) in
  List.find_opt
    (fun stmt ->
      match stmt with
      | SImport (_, module_, _, _, _, _) ->
          (owner <> None && reaches [] module_) || module_ = stem
          || module_ ^ "_external" = stem
      | _ -> false)
    unit.stmts

(** The diagnostics of a document: the first error the front end raised,
    placed in the document, or at the import that reaches the module it
    is in. state -> document -> analysis -> [Json.t] *)
let diagnostics state document analysis =
  let diagnostic range_ severity code message =
    Json.Object
      [ ("range", range_); ("severity", Json.Number (float_of_int severity)); ("source", Json.String "pyking");
        ("code", Json.String code); ("message", Json.String message) ]
  in
  let start = { Lexer.file = document.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } in
  match (analysis.problem, analysis.internal) with
  | Some p, _ when p.at.file = document.path || p.at.file = "" ->
      [ diagnostic (range document.text p.at) 1 p.kind p.message ]
  | Some p, _ ->
      let own =
        match List.find_opt (fun (u : Module.t) -> u.path = document.path) analysis.units with
        | Some u -> Some u
        | None -> ( try Some (Module.read_file ~from:(sources state) document.path None) with _ -> None)
      in
      let at =
        match Option.bind own (fun u -> import_reaching analysis.units u p.at.file) with
        | Some stmt -> stmt_info stmt
        | None -> start
      in
      let where = Printf.sprintf "'%s' %d:%d" p.at.file p.at.row1 p.at.col1 in
      [ diagnostic (range document.text at) 1 p.kind (Printf.sprintf "%s: %s" where p.message) ]
  | None, Some internal ->
      [ diagnostic (range document.text start) 2 "internal" ("pyk lsp could not check this file: " ^ internal) ]
  | None, None -> []

(** A publishDiagnostics notification for a document. string -> int ->
    [Json.t] -> Json.t *)
let publish uri version items =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("method", Json.String "textDocument/publishDiagnostics");
      ( "params",
        Json.Object
          [ ("uri", Json.String uri); ("version", Json.Number (float_of_int version)); ("diagnostics", Json.List items) ] ) ]

let idle state =
  let due = List.filter (fun d -> d.due) state.documents in
  let state, messages =
    List.fold_left
      (fun (state, messages) document ->
        let state, analysis = analysis_of state document in
        let found = Json.to_string (Json.List (diagnostics state document analysis)) in
        (* Sent again only where it changed: every open document is
           checked when any changes, and most are as they were. *)
        if List.assoc_opt document.uri state.published = Some found then (state, messages)
        else
          ( { state with published = (document.uri, found) :: List.remove_assoc document.uri state.published },
            messages @ [ Json.to_string (publish document.uri document.version (diagnostics state document analysis)) ] ))
      (state, []) due
  in
  ({ state with documents = List.map (fun d -> { d with due = false }) state.documents }, messages)

(* --- the protocol --- *)

(** A response to a request. Json.t -> Json.t -> Json.t *)
let response id result = Json.Object [ ("jsonrpc", Json.String "2.0"); ("id", id); ("result", result) ]

(** An error response to a request. Json.t -> int -> string -> Json.t *)
let error_response id code message =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("id", id);
      ("error", Json.Object [ ("code", Json.Number (float_of_int code)); ("message", Json.String message) ]) ]

(** A message for the editor's log. string -> Json.t *)
let log_message message =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("method", Json.String "window/logMessage");
      ("params", Json.Object [ ("type", Json.Number 1.); ("message", Json.String message) ]) ]

(** Settings with what an editor sent applied: `libPath` and
    `diagnostics`, at the top or under `pyking`. settings -> Json.t ->
    settings *)
let configure settings value =
  let value = match Json.member "pyking" value with Json.Null -> value | inner -> inner in
  let lib_path =
    match Json.member "libPath" value with
    | Json.List items -> List.filter_map Json.to_string_option items
    | Json.String s -> [ s ]
    | _ -> settings.lib_path
  in
  let on_save =
    match Json.member "diagnostics" value with
    | Json.String "save" -> true
    | Json.String "change" -> false
    | _ -> settings.on_save
  in
  { lib_path; on_save }

(** What the server can do, for `initialize`. state -> Json.t *)
let capabilities state =
  Json.Object
    [
      ( "capabilities",
        Json.Object
          [
            ("positionEncoding", Json.String "utf-16");
            ( "textDocumentSync",
              Json.Object
                [ ("openClose", Json.Bool true); ("change", Json.Number 1.);
                  ("save", Json.Object [ ("includeText", Json.Bool false) ]) ] );
            ("hoverProvider", Json.Bool true);
            ("definitionProvider", Json.Bool true);
            ("documentSymbolProvider", Json.Bool true);
            ("completionProvider", Json.Object [ ("triggerCharacters", Json.List [ Json.String "." ]) ]);
          ] );
      ("serverInfo", Json.Object [ ("name", Json.String "pyk lsp"); ("version", Json.String state.server_version) ]);
    ]

(** Every open document marked due to be checked again, as a change to
    one can change what another that imports it finds. state -> state *)
let all_due state = { state with documents = List.map (fun d -> { d with due = true }) state.documents }

(** A document's text with one change applied: the whole text, or a
    range replaced. string -> Json.t -> string *)
let apply_change text change =
  match Json.member "range" change with
  | Json.Null -> Option.value ~default:text (Json.to_string_option (Json.member "text" change))
  | r ->
      let replacement = Option.value ~default:"" (Json.to_string_option (Json.member "text" change)) in
      let r1, c1 = row_col text (Json.member "start" r) in
      let r2, c2 = row_col text (Json.member "end" r) in
      let a = offset_of text r1 c1 and b = offset_of text r2 c2 in
      String.sub text 0 a ^ replacement ^ String.sub text b (String.length text - b)

(** A notification: what it changes. state -> string -> Json.t -> state *)
let notify state method_ params =
  let uri = Option.value ~default:"" (Json.to_string_option (Json.member "uri" (Json.member "textDocument" params))) in
  let version = Option.value ~default:0 (Json.to_int_option (Json.member "version" (Json.member "textDocument" params))) in
  match method_ with
  | "initialized" | "$/cancelRequest" | "$/setTrace" -> state
  | "workspace/didChangeConfiguration" ->
      all_due { state with settings = configure state.settings (Json.member "settings" params) }
  | "textDocument/didOpen" ->
      let text = Option.value ~default:"" (Json.to_string_option (Json.member "text" (Json.member "textDocument" params))) in
      let document = { uri; path = path_of_uri uri; text; version; due = true } in
      let others = List.filter (fun d -> d.uri <> uri) state.documents in
      let state = { state with documents = others @ [ document ]; analyses = List.remove_assoc uri state.analyses } in
      if state.settings.on_save then state else all_due state
  | "textDocument/didChange" -> (
      match List.find_opt (fun d -> d.uri = uri) state.documents with
      | None -> state
      | Some d ->
          let text = List.fold_left apply_change d.text (Json.to_list (Json.member "contentChanges" params)) in
          let changed = { d with text; version = (if version = 0 then d.version + 1 else version) } in
          let state = { state with documents = List.map (fun x -> if x.uri = uri then changed else x) state.documents } in
          (* Every analysis may read this text, through an import. *)
          let state = { state with analyses = List.map (fun (u, a) -> (u, { a with checked_version = -1 })) state.analyses } in
          if state.settings.on_save then state else all_due state)
  | "textDocument/didSave" ->
      let state = { state with analyses = List.map (fun (u, a) -> (u, { a with checked_version = -1 })) state.analyses } in
      all_due state
  | "textDocument/didClose" ->
      {
        state with
        documents = List.filter (fun d -> d.uri <> uri) state.documents;
        published = List.remove_assoc uri state.published;
        analyses =
          List.map (fun (u, a) -> (u, { a with checked_version = -1 })) (List.remove_assoc uri state.analyses);
      }
  | _ -> state

(** A request: the state after it and its result, or an error code and
    message. state -> string -> Json.t -> (state, (Json.t, (int, string))
    result) *)
let request state method_ params =
  let document () =
    let uri = Option.value ~default:"" (Json.to_string_option (Json.member "uri" (Json.member "textDocument" params))) in
    List.find_opt (fun d -> d.uri = uri) state.documents
  in
  let on_document answer =
    match document () with
    | Some d ->
        let state, result = answer state d in
        (state, Ok result)
    | None -> (state, Ok Json.Null)
  in
  match method_ with
  | "shutdown" -> ({ state with phase = Shut_down }, Ok Json.Null)
  | "textDocument/hover" -> on_document (fun s d -> hover s d (Json.member "position" params))
  | "textDocument/definition" -> on_document (fun s d -> definition s d (Json.member "position" params))
  | "textDocument/documentSymbol" -> on_document document_symbols
  | "textDocument/completion" -> on_document (fun s d -> completion s d (Json.member "position" params))
  | _ -> (state, Error (-32601, "method not found: " ^ method_))

let handle state text =
  match Json.parse text with
  | exception Json.Parse_error message ->
      (state, [ Json.to_string (error_response Json.Null (-32700) ("parse error: " ^ message)) ])
  | message -> (
      let id = Json.member "id" message in
      let method_ = Option.value ~default:"" (Json.to_string_option (Json.member "method" message)) in
      let params = Json.member "params" message in
      let is_request = id <> Json.Null && method_ <> "" in
      let reply json = Json.to_string json in
      match state.phase with
      | Exited _ -> (state, [])
      | _ when method_ = "exit" -> ({ state with phase = Exited (if state.phase = Shut_down then 0 else 1) }, [])
      | _ when method_ = "" -> (state, [])
      | Fresh ->
          if method_ = "initialize" then
            let settings = configure state.settings (Json.member "initializationOptions" params) in
            ({ state with phase = Running; settings }, [ reply (response id (capabilities state)) ])
          else if is_request then (state, [ reply (error_response id (-32002) "the server is not initialized") ])
          else (state, [])
      | Shut_down ->
          if is_request then (state, [ reply (error_response id (-32600) "the server has been shut down") ])
          else (state, [])
      | Running ->
          if method_ = "initialize" then
            (state, [ reply (error_response id (-32600) "initialize was sent twice") ])
          else if is_request then
            match request state method_ params with
            | state, Ok result -> (state, [ reply (response id result) ])
            | state, Error (code, why) -> (state, [ reply (error_response id code why) ])
            | exception error ->
                let why = Printexc.to_string error in
                (state, [ reply (error_response id (-32603) ("internal error: " ^ why)); reply (log_message ("pyk lsp: " ^ method_ ^ ": " ^ why)) ])
          else
            match notify state method_ params with
            | state -> (state, [])
            | exception error ->
                (state, [ reply (log_message ("pyk lsp: " ^ method_ ^ ": " ^ Printexc.to_string error)) ]))
