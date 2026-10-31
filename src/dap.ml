(** The Pyking debug adapter: a state and one function from a message an
    editor sent to the messages to send back, over the Debug Adapter
    Protocol. What it debugs is a debug_session.ml session; this module
    only translates. It opens no file and starts nothing: the caller
    hands in how a launch starts a session and how a failed run is
    reported, and runs the program in slices with `advance`, so the
    same module could serve any transport. See docs/debugging.md.

    Data structures:
      hooks -- what the transport does that this module cannot.
      phase -- where the protocol is.
      state -- everything the adapter knows.

    Functions:
      create hooks -- an adapter that has seen nothing.
      handle state text output -- one message received, and what to send.
      running state -- whether the program should be given steps.
      advance state steps output -- the program run for a slice.
      push_call state machine -- a callback the host makes, to debug.
      take_call state -- the machine a callback ended in, once it has.
      top_level_ended state -- whether the top level ended without error.
      finish state code output -- the program over: exited, terminated.
      exit_code state -- the status to exit with, once disconnected. *)

(** What the transport does that this module cannot: start a session
    from a launch request's arguments (or say why not), and word the
    error a failed run ended in, as `pyk <file>` would print it. *)
type hooks = {
  start : Json.t -> (Debug_session.t, string) result;
  report : Interpreter.state -> string;
}

(** Where the protocol is: before a launch, launched but not configured,
    running, and disconnected with the status to end with. *)
type phase = Fresh | Launched | Configured | Disconnected of int

(** Everything the adapter knows: the hooks, the next sequence number,
    the session once launched, where the protocol is, the breakpoints
    asked for before the launch, whether a runtime error stops the
    program, the machine a callback ended in, and whether the top level
    ended without error and the transport has not finished it yet. *)
type state = {
  hooks : hooks;
  seq : int;
  session : Debug_session.t option;
  phase : phase;
  early : (string * Json.t) list;
  on_error : bool;
  call_ended : Interpreter.state option;
  top_ended : bool;
}

(** An adapter that has seen nothing. hooks -> state *)
let create hooks =
  {
    hooks;
    seq = 1;
    session = None;
    phase = Fresh;
    early = [];
    on_error = true;
    call_ended = None;
    top_ended = false;
  }

(** The status to exit with, once the editor disconnected.
    state -> int option *)
let exit_code state = match state.phase with Disconnected code -> Some code | _ -> None

(** A number as JSON. int -> Json.t *)
let int n = Json.Number (float_of_int n)

(** A message with the next sequence number, as text.
    state -> [(string, Json.t)] -> (state, string) *)
let message state fields =
  ({ state with seq = state.seq + 1 }, Json.to_string (Json.Object (("seq", int state.seq) :: fields)))

(** The response to a request. state -> Json.t -> string -> bool ->
    string? -> Json.t -> (state, string) *)
let response state request command success error body =
  message state
    ([
       ("type", Json.String "response");
       ("request_seq", Json.member "seq" request);
       ("success", Json.Bool success);
       ("command", Json.String command);
     ]
    @ (match error with Some m -> [ ("message", Json.String m) ] | None -> [])
    @ [ ("body", body) ])

(** An event. state -> string -> Json.t -> (state, string) *)
let event state name body =
  message state [ ("type", Json.String "event"); ("event", Json.String name); ("body", body) ]

(** Output events for what the program wrote, each a category and text.
    state -> [(string, string)] -> (state, [string]) *)
let outputs state written =
  List.fold_left
    (fun (state, out) (category, text) ->
      let state, m =
        event state "output"
          (Json.Object [ ("category", Json.String category); ("output", Json.String text) ])
      in
      (state, out @ [ m ]))
    (state, []) written

(** What DAP calls a stop's reason. Debug_session.reason -> string *)
let reason_name reason =
  match reason with
  | Debug_session.Entry -> "entry"
  | Debug_session.Step -> "step"
  | Debug_session.Breakpoint _ -> "breakpoint"
  | Debug_session.Paused -> "pause"
  | Debug_session.Exception _ -> "exception"

(** The `stopped` event for a reason. state -> Debug_session.reason ->
    (state, string) *)
let stopped_event state reason =
  let extra =
    match reason with
    | Debug_session.Breakpoint ids -> [ ("hitBreakpointIds", Json.List (List.map int ids)) ]
    | Debug_session.Exception message ->
        [ ("description", Json.String "Runtime error"); ("text", Json.String message) ]
    | _ -> []
  in
  event state "stopped"
    (Json.Object
       ([
          ("reason", Json.String (reason_name reason));
          ("threadId", int 1);
          ("allThreadsStopped", Json.Bool true);
        ]
       @ extra))

(** The program over: its status, then the end of the session. Answers
    the state and the messages. state -> int -> (state, [string]) *)
let ended state code =
  let state, exited = event state "exited" (Json.Object [ ("exitCode", int code) ]) in
  let state, terminated = event state "terminated" (Json.Object []) in
  ( { state with session = Option.map Debug_session.terminate state.session; top_ended = false },
    [ exited; terminated ] )

(** What a slice of running produced, as messages, with the state the
    events leave. state -> Debug_session.event list -> (state, [string]) *)
let translate state events =
  List.fold_left
    (fun (state, out) e ->
      match e with
      | Debug_session.Stopped reason ->
          let state, m = stopped_event state reason in
          (state, out @ [ m ])
      | Debug_session.Output text ->
          let state, ms = outputs state [ ("console", text) ] in
          (state, out @ ms)
      | Debug_session.Callback_done machine -> ({ state with call_ended = Some machine }, out)
      | Debug_session.Program_done machine -> (
          match Interpreter.failure machine with
          | None -> ({ state with top_ended = true }, out)
          | Some _ ->
              let state, ms = outputs state [ ("stderr", state.hooks.report machine ^ "\n") ] in
              let state, fin = ended state 1 in
              (state, out @ ms @ fin)))
    (state, []) events

(** Whether the program should be given steps: launched, configured and
    running. state -> bool *)
let running state =
  match (state.phase, state.session) with
  | Configured, Some s ->
      Debug_session.stopped s = None && (not (Debug_session.idle s)) && not (Debug_session.ended s)
  | _ -> false

(** The program run for up to `steps` steps. `output` hands over what the
    program wrote meanwhile, which goes out before the events.
    state -> int -> (() -> [(string, string)]) -> (state, [string]) *)
let advance state steps output =
  match state.session with
  | None -> (state, [])
  | Some s ->
      let s, events = Debug_session.advance s steps in
      let state = { state with session = Some s } in
      let state, written = outputs state (output ()) in
      let state, out = translate state events in
      (state, written @ out)

(** A callback the host makes, debugged in the session.
    state -> Interpreter.state -> state *)
let push_call state machine =
  {
    state with
    session = Option.map (fun s -> Debug_session.push_call s machine) state.session;
    call_ended = None;
  }

(** The machine a callback ended in, once it has, and the state without
    it. state -> (state, Interpreter.state?) *)
let take_call state = ({ state with call_ended = None }, state.call_ended)

(** Whether the top level ended without error and nothing has finished
    the program since. state -> bool *)
let top_level_ended state = state.top_ended

(** The program over with a status: exited, then terminated.
    state -> int -> (() -> [(string, string)]) -> (state, [string]) *)
let finish state code output =
  let state, written = outputs state (output ()) in
  let state, fin = ended state code in
  (state, written @ fin)

(** What the adapter can do. Json.t *)
let capabilities =
  Json.Object
    [
      ("supportsConfigurationDoneRequest", Json.Bool true);
      ("supportsConditionalBreakpoints", Json.Bool true);
      ("supportsHitConditionalBreakpoints", Json.Bool true);
      ("supportsLogPoints", Json.Bool true);
      ("supportsEvaluateForHovers", Json.Bool true);
      ("supportsSetVariable", Json.Bool true);
      ("supportsTerminateRequest", Json.Bool true);
      ( "exceptionBreakpointFilters",
        Json.List
          [
            Json.Object
              [
                ("filter", Json.String "uncaught");
                ("label", Json.String "Runtime errors");
                ("default", Json.Bool true);
              ];
          ] );
    ]

(** One variable as DAP shows it. Debug_session.variable -> Json.t *)
let variable_json (v : Debug_session.variable) =
  Json.Object
    [
      ("name", Json.String v.vname);
      ("value", Json.String v.value);
      ("type", Json.String v.vtype);
      ("variablesReference", int v.reference);
    ]

(** A breakpoint as DAP shows it. Debug_session.breakpoint -> Json.t *)
let breakpoint_json (b : Debug_session.breakpoint) =
  Json.Object
    ([ ("id", int b.id); ("verified", Json.Bool (b.at <> None)) ]
    @
    match b.at with
    | Some row -> [ ("line", int row) ]
    | None ->
        [ ("line", int b.line); ("message", Json.String "no statement starts on or after this line") ])

(** One frame as DAP shows it. Debug_session.frame -> Json.t *)
let frame_json (f : Debug_session.frame) =
  let i = f.span in
  (* Where a statement ends is said only of one on a single line: a
     block's end is not where the program stopped. *)
  let ending =
    if i.row2 = i.row1 then [ ("endLine", int i.row1); ("endColumn", int (i.col2 + 1)) ] else []
  in
  Json.Object
    ([
       ("id", int f.fid);
       ("name", Json.String f.name);
       ( "source",
         Json.Object
           [ ("name", Json.String (Filename.basename f.file)); ("path", Json.String (Module.absolute f.file)) ] );
       ("line", int i.row1);
       ("column", int (i.col1 + 1));
     ]
    @ ending
    @ if f.library then [ ("presentationHint", Json.String "subtle") ] else [])

(** A setBreakpoints request's breakpoints, as the session takes them.
    Json.t -> [(int, string?, string?, string?)] *)
let breakpoint_specs arguments =
  List.filter_map
    (fun b ->
      Option.map
        (fun line ->
          ( line,
            Json.to_string_option (Json.member "condition" b),
            Json.to_string_option (Json.member "hitCondition" b),
            Json.to_string_option (Json.member "logMessage" b) ))
        (Json.to_int_option (Json.member "line" b)))
    (Json.to_list (Json.member "breakpoints" arguments))

(** The path a setBreakpoints request names. Json.t -> string *)
let breakpoint_path arguments =
  Option.value ~default:"" (Json.to_string_option (Json.member "path" (Json.member "source" arguments)))

(** One request answered, with what it sets off.
    state -> Json.t -> string -> Json.t -> (state, [string]) *)
let request state request command arguments =
  let ok state body =
    let state, m = response state request command true None body in
    (state, [ m ])
  in
  let refuse state text =
    let state, m = response state request command false (Some text) (Json.Object []) in
    (state, [ m ])
  in
  let with_session f =
    match state.session with None -> refuse state "nothing is being debugged" | Some s -> f s
  in
  let go state command_ =
    with_session (fun s -> ok { state with session = Some (Debug_session.resume s command_) } (Json.Object []))
  in
  match command with
  | "initialize" -> ok state capabilities
  | "launch" -> (
      match state.hooks.start arguments with
      | Error text -> refuse state text
      | Ok s ->
          let s = Debug_session.stop_on_errors s state.on_error in
          let s =
            List.fold_left
              (fun s (path, args) -> fst (Debug_session.set_breakpoints s path (breakpoint_specs args)))
              s state.early
          in
          let state = { state with session = Some s; phase = Launched; early = [] } in
          let state, answer = ok state (Json.Object []) in
          (* The program's warnings, on the debug console before it runs,
             where `pyk <file>` would print them. *)
          let state, warned =
            outputs state
              (List.map (fun w -> ("stderr", Warnings.format w ^ "\n")) (Debug_session.warnings s))
          in
          let state, initialized = event state "initialized" (Json.Object []) in
          (state, answer @ warned @ [ initialized ]))
  | "attach" -> refuse state "pyk dap launches a program; it cannot attach to one"
  | "setBreakpoints" -> (
      let path = breakpoint_path arguments in
      match state.session with
      | None ->
          let early = List.remove_assoc path state.early @ [ (path, arguments) ] in
          let made =
            List.mapi
              (fun k (line, _, _, _) ->
                Json.Object [ ("id", int (k + 1)); ("verified", Json.Bool false); ("line", int line) ])
              (breakpoint_specs arguments)
          in
          ok { state with early } (Json.Object [ ("breakpoints", Json.List made) ])
      | Some s ->
          let s, made = Debug_session.set_breakpoints s path (breakpoint_specs arguments) in
          ok { state with session = Some s }
            (Json.Object [ ("breakpoints", Json.List (List.map breakpoint_json made)) ]))
  | "setExceptionBreakpoints" ->
      let on =
        List.exists
          (fun f -> Json.to_string_option f = Some "uncaught")
          (Json.to_list (Json.member "filters" arguments))
      in
      let state =
        { state with on_error = on; session = Option.map (fun s -> Debug_session.stop_on_errors s on) state.session }
      in
      ok state (Json.Object [])
  | "configurationDone" -> ok { state with phase = Configured } (Json.Object [])
  | "threads" ->
      ok state
        (Json.Object
           [ ("threads", Json.List [ Json.Object [ ("id", int 1); ("name", Json.String "main") ] ]) ])
  | "stackTrace" ->
      with_session (fun s ->
          let frames = Debug_session.frames s in
          let start = Option.value ~default:0 (Json.to_int_option (Json.member "startFrame" arguments)) in
          let levels = Option.value ~default:0 (Json.to_int_option (Json.member "levels" arguments)) in
          let shown =
            List.filteri (fun k _ -> k >= start && (levels <= 0 || k < start + levels)) frames
          in
          ok state
            (Json.Object
               [
                 ("stackFrames", Json.List (List.map frame_json shown));
                 ("totalFrames", int (List.length frames));
               ]))
  | "scopes" ->
      with_session (fun s ->
          let fid = Option.value ~default:0 (Json.to_int_option (Json.member "frameId" arguments)) in
          let s, scopes = Debug_session.scopes s fid in
          ok { state with session = Some s }
            (Json.Object
               [
                 ( "scopes",
                   Json.List
                     (List.map
                        (fun (name, reference) ->
                          Json.Object
                            ([
                               ("name", Json.String name);
                               ("variablesReference", int reference);
                               ("expensive", Json.Bool false);
                             ]
                            @ if name = "Environment" then [ ("presentationHint", Json.String "locals") ] else []))
                        scopes) );
               ]))
  | "variables" ->
      with_session (fun s ->
          let reference =
            Option.value ~default:0 (Json.to_int_option (Json.member "variablesReference" arguments))
          in
          let s, vars = Debug_session.variables s reference in
          ok { state with session = Some s }
            (Json.Object [ ("variables", Json.List (List.map variable_json vars)) ]))
  | "setVariable" ->
      with_session (fun s ->
          let reference =
            Option.value ~default:0 (Json.to_int_option (Json.member "variablesReference" arguments))
          in
          let name = Option.value ~default:"" (Json.to_string_option (Json.member "name" arguments)) in
          let text = Option.value ~default:"" (Json.to_string_option (Json.member "value" arguments)) in
          match Debug_session.set_variable s reference name text with
          | s, Ok v ->
              ok { state with session = Some s }
                (Json.Object
                   [
                     ("value", Json.String v.value);
                     ("type", Json.String v.vtype);
                     ("variablesReference", int v.reference);
                   ])
          | s, Error text -> refuse { state with session = Some s } text)
  | "evaluate" ->
      with_session (fun s ->
          let text = Option.value ~default:"" (Json.to_string_option (Json.member "expression" arguments)) in
          let fid = Json.to_int_option (Json.member "frameId" arguments) in
          match Debug_session.evaluate s fid text with
          | s, Ok v ->
              ok { state with session = Some s }
                (Json.Object
                   [
                     ("result", Json.String v.value);
                     ("type", Json.String v.vtype);
                     ("variablesReference", int v.reference);
                   ])
          | s, Error text -> refuse { state with session = Some s } text)
  | "continue" ->
      with_session (fun s ->
          ok
            { state with session = Some (Debug_session.resume s Debug_session.Continue) }
            (Json.Object [ ("allThreadsContinued", Json.Bool true) ]))
  | "next" -> go state Debug_session.Next
  | "stepIn" -> go state Debug_session.Step_in
  | "stepOut" -> go state Debug_session.Step_out
  | "pause" -> go state Debug_session.Pause
  | "terminate" ->
      (* The program ends here; the adapter waits for `disconnect`. *)
      let state, answer = ok state (Json.Object []) in
      let state, fin = ended state 0 in
      (state, answer @ fin)
  | "disconnect" ->
      let state, answer = ok state (Json.Object []) in
      ({ state with phase = Disconnected 0 }, answer)
  | _ -> refuse state (Printf.sprintf "pyk dap does not handle '%s'" command)

(** One message received, and what to send back. `output` hands over
    what the program wrote while the message was handled, which an
    expression evaluated may do. state -> string -> (() -> [(string,
    string)]) -> (state, [string]) *)
let handle state text output =
  match Json.parse text with
  | exception Json.Parse_error _ -> (state, [])
  | msg -> (
      match Json.to_string_option (Json.member "type" msg) with
      | Some "request" ->
          let command = Option.value ~default:"" (Json.to_string_option (Json.member "command" msg)) in
          let state, out = request state msg command (Json.member "arguments" msg) in
          let state, written = outputs state (output ()) in
          (state, written @ out)
      | _ -> (state, []))
