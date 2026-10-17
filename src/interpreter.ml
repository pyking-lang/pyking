(** The interpreter: a resumable small-step machine that runs a Pyking
    program directly from the AST, instead of translating it to a host
    language. It runs the fragment typesystem.ml accepts, and pyk.ml
    type-checks before handing a program here -- that is the whole of
    the gate, so there is no second list of supported constructs to keep
    in step. Values are 32-bit signed integers, wrapping on overflow.
    This is the reference implementation of Pyking's runtime semantics.
    See docs/interpreter.md.

    Data structures:
      Runtime_error -- a runtime failure, with the source position.
      value -- what a Pyking expression evaluates to.
      env -- a persistent chain of frames.
      control -- what the machine does next.
      kont -- what to do with the value that is about to arrive.
      frame -- one Pyking call in progress.
      loop -- one `loop` in progress.
      runtime -- what a run never changes.
      state -- a machine state.
      host -- where print and debug go.

    Functions:
      run_program stmts host -- runs a whole program to completion.
      initial_state stmts host -- a machine about to run stmts.
      step state -- one small step.
      run state steps -- steps until the machine stops or steps run out.
      apply state callee args -- a function value called in a finished
        machine, which is how a host delivers an event.
      callback state info callee args -- the same, answering the value,
        for a host calling back during an external call.
      run_modules units host -- runs a program of several modules, each
        in a top level of its own, in dependency order.
      load_modules state units exports -- the same, into a machine
        already running.
      bind_imports state stmts exports -- an entry's imports, bound.
      with_host state host -- the machine with another host.
      eval_statement state stmt -- runs one statement in an existing
        machine's environment (for the REPL).
      format_value value / display_value value -- formats a value as
        print emits it / as a value is shown. *)

open Lexer
open Syntax

(** A Pyking runtime error, with the source position. The machine never
    raises it -- a failing step produces a CFailed state holding one
    instead -- but the driver reports it like every other stage's. *)
exception Runtime_error of info * string

(** How the direct evaluator and the operator rules report a failure to
    their caller. Caught before it crosses `step`'s boundary and turned
    into a CFailed state. *)
exception Trap of info * string

module SMap = Map.Make (String)

let unsupported_message = "Construct is not supported"

(* --- integers ---

   A Pyking `Int` holds at least the signed 32-bit range; what a program
   may *write down* stops there (src/lexer.ml refuses a wider literal),
   but what arithmetic may *produce* is not bounded by the language --
   past that range the result is undefined (see PYKING.md, "Integers").
   So nothing here narrows a result: an Int is the host's own int, which
   is 63 bits natively and 32 under js_of_ocaml, and the two may
   therefore disagree about a program that overflows. Both are right,
   because the language promises nothing there. *)

(* --- values and environments --- *)

(** What a Pyking expression evaluates to. These hold no host objects:
    the representation has to survive the rewrite into Pyking. *)
type value =
  | VInt of int (* always within 32 signed bits *)
  | VFloat of float (* IEEE 754 binary64 *)
  | VString of string
  | VBool of bool
  | VUnit (* `()`: what a statement, a print and a program produce *)
  | VList of value list
  | VTuple of value list
  | VClosure of string * string list * stmt list * env
      (* a function and the environment it was written in *)
  | VBuiltin of string (* one of Builtin.names, callable as a value *)
  | VHostFun of string * string
      (* <module>.<field> of an external module: a function the host
         implements in a target language, called through host.externals
         rather than by interpreting a body. *)
  | VUndefined of string (* a hoisted `def` whose definition has not run *)
  | VData of string * (string option * value) list
      (* a value of a datatype: its constructor, and each field with its
         name where it has one *)

(** A persistent chain of frames: the names this frame introduces, and
    the frame outside it. A binding is a cell rather than a value, which
    is what lets a `var` be written to and a closure over the frame
    holding it see what was written -- the only two places anything here
    changes (`define` and `mutate`). *)
and env = { bindings : value ref SMap.t; parent : env option }

let unit_value = VUnit
let boolean b = VBool b

(* --- formatting --- *)

let escape_char c =
  match c with
  | '\\' -> "\\\\"
  | '\'' -> "\\'"
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

let quote text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '\'';
  String.iter (fun c -> Buffer.add_string buffer (escape_char c)) text;
  Buffer.add_char buffer '\'';
  Buffer.contents buffer

(* What `display_value` walks: a value still to be written, or a literal
   piece of text already decided on. *)
type piece = Item of value | Text of string

(** Formats a value as it appears inside a larger one, or as a
    prompt/debugger shows it: like format_value, but a string is quoted.
    Iterative, so nesting cannot overflow the host stack.
    value -> string *)
let display_value value =
  let out = Buffer.create 32 in
  let rec go stack =
    match stack with
    | [] -> ()
    | Text text :: rest ->
        Buffer.add_string out text;
        go rest
    | Item item :: rest -> (
        let commas elements closing =
          (* Each element, with ", " between them, then the closing
             bracket -- pushed so the walk meets them in order. *)
          let rec spread index elements =
            match elements with
            | [] -> [ Text closing ]
            | [ last ] -> Item last :: [ Text closing ]
            | one :: more -> Item one :: Text ", " :: spread (index + 1) more
          in
          spread 0 elements
        in
        match item with
        | VInt n ->
            Buffer.add_string out (string_of_int n);
            go rest
        | VFloat x ->
            Buffer.add_string out (Builtin.float_text x);
            go rest
        | VString text ->
            Buffer.add_string out (quote text);
            go rest
        | VBool b ->
            Buffer.add_string out (if b then "true" else "false");
            go rest
        | VUnit ->
            Buffer.add_string out "()";
            go rest
        | VList elements ->
            Buffer.add_string out "[";
            go (commas elements "]" @ rest)
        | VTuple elements ->
            (* A singleton keeps the comma that tells it from a
               parenthesized value, exactly as the source form does. *)
            Buffer.add_string out "(";
            go
              (commas elements
                 (if List.length elements = 1 then ",)" else ")")
              @ rest)
        | VClosure (name, _, _, _) ->
            Buffer.add_string out (Printf.sprintf "<function %s>" name);
            go rest
        | VBuiltin name ->
            Buffer.add_string out (Printf.sprintf "<builtin %s>" name);
            go rest
        | VHostFun (module_, field) ->
            Buffer.add_string out (Printf.sprintf "<%s.%s>" module_ field);
            go rest
        | VData (name, []) ->
            Buffer.add_string out name;
            go rest
        | VData (name, fields) ->
            (* Every field, by position, as a constructor is written. *)
            Buffer.add_string out (name ^ "(");
            go (commas (List.map snd fields) ")" @ rest)
        | VUndefined _ -> go rest)
  in
  go [ Item value ];
  Buffer.contents out

(** Formats a value as print writes it (builtin.ml's rules): a
    string bare, everything else as display_value. value -> string *)
let format_value value =
  match value with VString text -> text | value -> display_value value

(** A value's type name, as Pyking spells it, for an error message.
    value -> string *)
let describe value =
  match value with
  | VInt _ -> "Int"
  | VFloat _ -> "Float"
  | VString _ -> "String"
  | VBool _ -> "Bool"
  | VUnit -> "()"
  | VList _ -> "a list"
  | VTuple elements -> Printf.sprintf "a tuple of %d" (List.length elements)
  | VClosure _ | VBuiltin _ | VHostFun _ -> "a function"
  | VData (name, _) -> "a value built by '" ^ name ^ "'"
  | VUndefined _ -> "a value"

(* --- hosts --- *)

(** How a host reaches a module implemented in a target language: what
    one of its value exports is, and how to call one of its functions.
    Both take the module's name and the field's; `call` is handed
    first how to call back a Pyking function it was given. *)
type externals = {
  field : string -> string -> value;
  call : (value -> value list -> value) -> string -> string -> value list -> value;
}

type host = {
  print_line : string -> unit;
  (* Where `debug` writes: the host's diagnostic channel, kept apart
     from what the program prints. *)
  debug_line : string -> unit;
  (* A module implemented in a target language has no AST to interpret,
     so a host that cannot call into that language leaves this None and
     a program importing one is refused before it runs (docs/modules.md,
     "Running one"). The browser can: `iweb` interprets a program whose
     external modules are JavaScript. *)
  externals : externals option;
}

(** Writes to standard output, and reaches no external module: nothing
    in a terminal can call a target language's own code. host *)
let console_host =
  {
    print_line = (fun text -> print_string text; print_newline ());
    debug_line = (fun text -> prerr_string text; prerr_newline ());
    externals = None;
  }

(** A host that hands each printed line to a function, and each `debug`
    line to another -- standard error unless one is given.
    externals? -> (string -> ())? -> (string -> ()) -> host *)
let callback_host ?externals ?debug_line write_line =
  let debug_line =
    match debug_line with
    | Some debug_line -> debug_line
    | None -> fun text -> prerr_string text; prerr_newline ()
  in
  { print_line = write_line; debug_line; externals }

(* --- environments --- *)

(** env with name bound to value, as a new frame.
    env -> string -> value -> env *)
let extend env name value =
  { bindings = SMap.singleton name (ref value); parent = Some env }

(** env with a whole group of names bound at once, as a new frame.
    env -> [(string, value)] -> env *)
let extend_all env bindings =
  {
    bindings =
      List.fold_left
        (fun map (name, value) -> SMap.add name (ref value) map)
        SMap.empty bindings;
    parent = Some env;
  }

(** The cell name denotes in env, or None. Walks outward, so the
    innermost binding wins. env -> string -> value ref option *)
let rec cell env name =
  match SMap.find_opt name env.bindings with
  | Some found -> Some found
  | None -> (
      match env.parent with None -> None | Some parent -> cell parent name)

(** The value name denotes in env, or None. env -> string -> value option *)
let lookup env name = Option.map ( ! ) (cell env name)

(** Every name visible from env, as name -> value, innermost first.
    env -> [(string, value)] *)
let bindings_in_scope env =
  let rec go env seen =
    match env with
    | None -> seen
    | Some env ->
        let seen =
          SMap.fold
            (fun name held seen ->
              if List.mem_assoc name seen then seen else seen @ [ (name, !held) ])
            env.bindings seen
        in
        go env.parent seen
  in
  go (Some env) []

(** The environment a program starts in: the builtins, nothing else.
    () -> env *)
let top_level_env () =
  {
    bindings =
      List.fold_left
        (fun map name -> SMap.add name (ref (VBuiltin name)) map)
        SMap.empty Builtin.names;
    parent = None;
  }

(** env with every def at the top of this block bound as a name
    (VUndefined, not yet a function; see PYKING.md, "Names and
    scoping"). [stmt] -> env -> env *)
let declare stmts env =
  match Analyses.block_functions stmts with
  | [] -> env
  | functions ->
      {
        bindings =
          List.fold_left
            (fun map (name, _) -> SMap.add name (ref (VUndefined name)) map)
            SMap.empty functions;
        parent = Some env;
      }

(** The closure a def denotes, capturing env. stmt -> env -> value *)
let closure node env =
  match node with
  | SFunctionDef (_, name, params, body, _, _, _, _, _) ->
      VClosure (name, List.map (fun (Param (_, n, _, _, _)) -> n) params, body, env)
  | _ -> VUnit

(** Fills in the cell `declare` made for this def, with the closure it
    denotes here. The first of this module's two writes.
    env -> stmt -> env *)
let define env node =
  let name = match node with SFunctionDef (_, name, _, _, _, _, _, _, _) -> name | _ -> "" in
  match cell env name with
  (* A `def` whose name `declare` never saw: only reachable if a caller
     ran a statement without declaring its block first. *)
  | None -> extend env name (closure node env)
  | Some held ->
      held := closure node env;
      env

(** Writes value into the cell that holds name, and answers whether one
    did. The second of this module's two writes: a `var` is one cell, so
    a closure over the environment holding it sees what is written there
    afterwards. env -> string -> value -> bool *)
let mutate env name value =
  match cell env name with
  | None -> false
  | Some held ->
      held := value;
      true

(* --- control, continuations, frames, state --- *)

(** What the machine is in the middle of doing. *)
type control =
  | CEval of expr (* evaluate an expression *)
  | CStmt of stmt (* execute one statement *)
  | CApply of value (* hand a value to the continuation *)
  | CDone of value (* finished; nothing is pending *)
  | CFailed of info * string (* stopped on a runtime error *)

(** What a comprehension is waiting for. *)
type want = WSequence | WTest | WElement

(** What to do with the value that is about to arrive. Each holds the
    rest of the chain, so pushing and popping are one allocation and no
    copying, and two states can share a tail -- which is what makes a
    paused state cheap to keep.

    Most of them also hold the env their remaining work runs in, and the
    machine restores it when the continuation is popped. That is the
    rule that keeps scopes straight: an expression is evaluated in the
    environment it is *written* in, whatever the value being delivered
    was computed in. `KSeq` is the single deliberate exception -- it
    adopts the environment it is handed, because that is exactly how a
    binding becomes visible to the statements after it. *)
type kont =
  | KSeq of stmt array * int * env * kont option
      (* run stmts from index onwards, then deliver the last one's value
         with exit_env restored. The index is what keeps a block from
         growing the continuation chain. *)
  | KBind of assign_target * env * kont option
  | KVarBind of string * env * kont option
  | KMutate of string * info * env * kont option
  | KBinaryLeft of expr * expr * env * kont option
  | KBinaryRight of expr * value * env * kont option
  | KCallee of expr * env * kont option
  | KArgument of expr * value * value list * expr list * env * kont option
  | KElement of expr * value list * expr list * env * kont option
  | KNegate of expr * env * kont option
  | KField of expr * env * kont option (* the value whose field is read *)
  | KScrutinee of stmt * env * kont option
  | KGuard of value * match_case list * stmt list * env * env * kont option
      (* a case's guard: the subject, the cases after this one, this
         case's body, the environment its pattern bound and the one the
         `match` is written in *)
  | KComprehend of
      expr
      * want
      * int
      * (int * value list * env) list
      * value list
      * env
      * env
      * kont option
      (* one value of a comprehension has arrived. The frames are the
         iteration in progress, innermost last; `done` is what has been
         collected so far; the two envs are where the awaited value is
         evaluated and where the whole comprehension was written. *)
  | KBranch of stmt * env * kont option
  | KChoose of expr * env * kont option
  | KDiscard of env * kont option
      (* throw the incoming value away and deliver unit instead: what an
         `if` with no `else` supplies. *)
  | KStartLoop of loop
  | KSequence of loop (* a `for`'s sequence *)
  | KTest of loop (* a `while`'s condition *)
  | KIterate of loop
      (* a turn of the body has produced its value: that value is the
         accumulator for the next turn. This replaces itself rather than
         stacking, which is what lets a loop run for ever in constant
         memory. *)
  | KReturnTo of frame

(** One Pyking call in progress. Pyking's call stack, held in the
    machine's own data rather than the host's. `frame_loops` is the
    caller's loop stack: a call enters with none of its own, since a
    `break` may not cross a `def`. *)
and frame = {
  frame_name : string;
  frame_info : info;
  frame_kont : kont option;
  frame_env : env;
  frame_parent : frame option;
  depth : int;
  frame_loops : loop option;
}

(** One `loop` in progress: what a `break`/`continue` in its body needs
    in order to leave it or go round again. `accumulator` is what the
    current turn started with (a `break` yields exactly that), `loop_env`
    the environment the loop is written in -- where each turn binds the
    accumulator afresh -- and `loop_kont` where the loop's own value goes
    when it ends. *)
and loop = {
  loop_node : stmt;
  accumulator : value;
  loop_env : env;
  loop_kont : kont option;
  loop_parent : loop option;
  remaining : value list; (* what a `for` has left to walk *)
}

(* Maximum Pyking call depth before the machine raises a runtime
   error. *)
let max_call_depth = 10_000

(** The part of a state that never changes while it runs: the host, the
    call-free symbol table (see `evaluate`), and the depth limit. *)
type runtime = { host : host; simple : IntSet.t; max_depth : int }

(** A machine state: what it is doing, the environment, the pending
    continuation, the call stack, the run's settings, and the loops it
    is inside. A plain value; keeping one is how a debugger pauses. *)
type state = {
  control : control;
  env : env;
  kont : kont option;
  stack : frame option;
  runtime : runtime;
  loops : loop option;
}

(** state with error in the control position; nothing else changed or
    unwound. state -> info -> string -> state *)
let failed state info message = { state with control = CFailed (info, message) }

(* --- the call-free fast path ---

   An expression containing no call can neither suspend nor reach the
   host, so the machine has nothing to gain from taking it apart one
   continuation at a time: it can be evaluated in one go. Which
   expressions those are is worked out once, before the program runs,
   and carried in `runtime.simple`.

   The recursion in `evaluate` is bounded by how deeply the *source*
   nests expressions, not by anything the program computes at run time,
   so it cannot be driven deep by a long-running program the way a
   recursive evaluator could. *)

(** Whether this subtree is free of calls, and the symbols of every
    expression in it that is. Walk.node -> IntSet.t -> (bool, IntSet.t) *)
let rec call_free_walk n found =
  match n with
  | Walk.NExpr (ECall _) ->
      ( false,
        List.fold_left
          (fun found child -> snd (call_free_walk child found))
          found (Walk.children n) )
  | Walk.NExpr (ELambda (_, _, body, _) as lambda) ->
      (* Building a closure calls nothing, whatever its body holds -- the
         body runs when the lambda is applied, not here. Its symbols are
         still collected, since the body is stepped later. *)
      let found = snd (call_free_walk (Walk.NExpr body) found) in
      (true, IntSet.add (expr_sym lambda) found)
  | n ->
      let free, found =
        List.fold_left
          (fun (free, found) child ->
            let child_free, found = call_free_walk child found in
            (free && child_free, found))
          (true, found) (Walk.children n)
      in
      let found =
        match n with
        | Walk.NExpr e when free -> IntSet.add (expr_sym e) found
        | _ -> found
      in
      (free, found)

(** The symbols of every expression in a program that contains no call.
    [stmt] -> IntSet.t *)
let call_free_symbols stmts =
  List.fold_left
    (fun found s -> snd (call_free_walk (Walk.NStmt s) found))
    IntSet.empty stmts

(* --- operators ---

   What each operator does. The rule takes the two values and gives back
   a value, or None when the operator does not apply to them -- which,
   after type checking, only a program that reached the machine another
   way can manage. The table is deliberately shaped like
   Typesystem's: the same operators, with what they *compute* here
   beside what they *accept* there. *)

(* A division that fails has no node to hand, so it raises with this and
   `apply_binary` puts the real position in. Every other rule answers
   None and lets the operand message below do the reporting. *)
let divide_info = { file = "<division>"; row1 = 0; col1 = 0; row2 = 0; col2 = 0 }

let arith op float_op left right =
  match (left, right) with
  | VInt a, VInt b -> Some (VInt (op a b))
  | VFloat a, VFloat b -> Some (VFloat (float_op a b))
  | _ -> None

(* Every Float comparison unwraps to two floats first. OCaml's
   polymorphic `=` on a value that holds one is `compare`, which reports
   two NaNs equal; the primitive on two floats is IEEE's, which does
   not. *)
let compare_with op float_op left right =
  match (left, right) with
  | VInt a, VInt b -> Some (boolean (op a b))
  | VFloat a, VFloat b -> Some (boolean (float_op a b))
  | _ -> None

(** Integer division, truncating toward zero. Division by zero is a
    Pyking error rather than a crash: `step` is total
    (docs/interpreter.md). value -> value -> value option *)
let divide left right =
  match (left, right) with
  | VInt _, VInt 0 -> raise (Trap (divide_info, "division by zero"))
  | VInt a, VInt b ->
      let quotient = abs a / abs b in
      Some (VInt (if a < 0 = (b < 0) then quotient else -quotient))
  (* Float division never traps: dividing by zero is an infinity or a
     NaN, which is IEEE's own answer (PYKING.md, "Floats"). *)
  | VFloat a, VFloat b -> Some (VFloat (a /. b))
  | _ -> None

let concat left right =
  match (left, right) with
  | VString a, VString b -> Some (VString (a ^ b))
  | VList a, VList b -> Some (VList (a @ b))
  | _ -> None

let equals left right =
  match (left, right) with
  | VInt a, VInt b -> Some (boolean (a = b))
  (* IEEE's, so two NaNs are not equal and the two zeros are. *)
  | VFloat a, VFloat b -> Some (boolean (a = b))
  | VString a, VString b -> Some (boolean (a = b))
  | VBool a, VBool b -> Some (boolean (a = b))
  | _ -> None

(** An operator's spelling and what it computes, or None for an
    expression that is not one.
    expr -> (string, value -> value -> value option) option *)
let operator_rule e =
  match e with
  | EAdd _ -> Some ("+", arith (fun a b -> a + b) (fun a b -> a +. b))
  | EConcat _ -> Some ("++", concat)
  | ESub _ -> Some ("-", arith (fun a b -> a - b) (fun a b -> a -. b))
  | EMul _ -> Some ("*", arith (fun a b -> a * b) (fun a b -> a *. b))
  | EDiv _ -> Some ("/", divide)
  | ELessThan _ ->
      Some ("<", compare_with (fun a b -> a < b) (fun a b -> a < b))
  | ELessThanEq _ ->
      Some ("<=", compare_with (fun a b -> a <= b) (fun a b -> a <= b))
  | EGreatThan _ ->
      Some (">", compare_with (fun a b -> a > b) (fun a b -> a > b))
  | EGreatThanEq _ ->
      Some (">=", compare_with (fun a b -> a >= b) (fun a b -> a >= b))
  | EEq _ -> Some ("==", equals)
  | _ -> None

(** The two operands of a binary operator application.
    expr -> (expr, expr) option *)
let binary_operands e =
  match e with
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

(** The value of one binary operator application. Raises Trap for
    operands the operator does not accept. expr -> value -> value -> value *)
let apply_binary node left right =
  match operator_rule node with
  | None -> raise (Trap (expr_info node, unsupported_message))
  | Some (spelling, rule) -> (
      let answer =
        try rule left right
        with Trap (_, message) -> raise (Trap (expr_info node, message))
      in
      match answer with
      | Some value -> value
      | None ->
          raise
            (Trap
               ( expr_info node,
                 Printf.sprintf "`%s` cannot be applied to %s and %s" spelling
                   (describe left) (describe right) )))

(** The value of a unary operator application. Raises Trap for an
    operand the operator does not accept. expr -> value -> value *)
let apply_unary node operand =
  match (node, operand) with
  | ENeg _, VInt a -> VInt (-a)
  | ENeg _, VFloat a -> VFloat (-.a)
  | _ ->
      raise
        (Trap
           ( expr_info node,
             Printf.sprintf "`-` cannot be applied to %s" (describe operand) ))

(* --- builtins --- *)

(** `range` builds a *list*: Pyking has lists and no lazy-sequence type,
    and the checker says so. int -> int -> int -> info -> value *)
let range_list start stop step info =
  if step = 0 then raise (Trap (info, "'range' step must not be zero"));
  let rec go n out =
    if (step > 0 && n >= stop) || (step < 0 && n <= stop) then List.rev out
    else go (n + step) (VInt n :: out)
  in
  VList (go start [])

(** Applies one of Builtin.names. print crosses the host boundary
    through host; the rest are pure.
    string -> [value] -> info -> host -> value *)
let apply_builtin name args info host =
  match (name, args) with
  | name, _ when Builtin.crosses_host name ->
      let line = String.concat " " (List.map format_value args) in
      if Builtin.is_debug name then host.debug_line line
      else host.print_line line;
      unit_value
  | "string", [ value ] -> VString (format_value value)
  (* The conversions answer a default where there is no right answer,
     by the rules builtin.ml states. *)
  | "int", [ VInt n ] -> VInt n
  | "int", [ VFloat x ] -> VInt (Builtin.truncate_float x)
  | "int", [ VBool b ] -> VInt (if b then 1 else 0)
  | "int", [ VString text ] ->
      VInt (Option.value (Builtin.parse_int text) ~default:0)
  | "float", [ VInt n ] -> VFloat (float_of_int n)
  | "float", [ VFloat x ] -> VFloat x
  | "float", [ VBool b ] -> VFloat (if b then 1.0 else 0.0)
  | "float", [ VString text ] ->
      VFloat (Option.value (Builtin.parse_float text) ~default:Float.nan)
  | "bool", [ VBool b ] -> VBool b
  | "bool", [ VInt n ] -> VBool (n = 1)
  | "bool", [ VFloat x ] -> VBool (x = 1.0)
  | "bool", [ VString text ] -> VBool (text = "true")
  | "len", [ VString text ] -> VInt (String.length text)
  | "len", [ VList elements ] -> VInt (List.length elements)
  | "range", [ VInt stop ] -> range_list 0 stop 1 info
  | "range", [ VInt start; VInt stop ] -> range_list start stop 1 info
  | "range", [ VInt start; VInt stop; VInt step ] ->
      range_list start stop step info
  | _ ->
      raise
        (Trap
           ( info,
             Printf.sprintf "'%s' cannot be applied to (%s)" name
               (String.concat ", " (List.map describe args)) ))

(* --- matching --- *)

(** A list pattern against a list's items: the prefix from the front,
    the suffix from the back, and the rest marker whatever is left over.
    Without a rest marker the length must be exact.
    env -> [pattern] -> list_rest option -> [pattern] -> [value]
    -> env option *)
let rec match_list env prefix rest suffix items =
  let count = List.length items in
  let taken, middle, fits =
    match rest with
    | None ->
        if count <> List.length prefix then ([], [], false)
        else (items, [], true)
    | Some _ ->
        if count < List.length prefix + List.length suffix then ([], [], false)
        else
          let front = List.filteri (fun i _ -> i < List.length prefix) items in
          let back =
            List.filteri (fun i _ -> i >= count - List.length suffix) items
          in
          let middle =
            List.filteri
              (fun i _ ->
                i >= List.length prefix && i < count - List.length suffix)
              items
          in
          if suffix = [] then (front, middle, true)
          else (front @ back, middle, true)
  in
  if not fits then None
  else
    let rec walk env patterns values =
      match (patterns, values) with
      | [], _ | _, [] -> Some env
      | pattern :: patterns, item :: values -> (
          match match_pattern env pattern item with
          | None -> None
          | Some env -> walk env patterns values)
    in
    match walk env (prefix @ suffix) taken with
    | None -> None
    | Some env -> (
        match rest with
        | Some (ListRest (_, Some name, _)) ->
            Some (extend env name (VList middle))
        | _ -> Some env)

(** The environment a pattern binds when it matches value, or None when
    it does not. Nothing here evaluates, so matching can neither suspend
    nor fail at run time -- a pattern that cannot match simply says so.
    env -> pattern -> value -> env option *)
and match_pattern env pattern value =
  match (pattern, value) with
  | PWildcard _, _ -> Some env
  | PCapture (_, name, _), _ -> Some (extend env name value)
  | PInt (_, wanted, _), VInt got -> if wanted = got then Some env else None
  | PString (_, wanted, _), VString got ->
      if wanted = got then Some env else None
  | PBool (_, wanted, _), VBool got -> if wanted = got then Some env else None
  | PTuple (_, elements, _), VTuple parts
    when List.length elements = List.length parts ->
      List.fold_left2
        (fun env element part ->
          match env with
          | None -> None
          | Some env -> match_pattern env element part)
        (Some env) elements parts
  | PText (_, prefix, name, suffix, _), VString text ->
      let starts =
        String.length text >= String.length prefix
        && String.sub text 0 (String.length prefix) = prefix
      in
      let ends =
        String.length text >= String.length suffix
        && String.sub text
             (String.length text - String.length suffix)
             (String.length suffix)
           = suffix
      in
      if
        String.length text < String.length prefix + String.length suffix
        || (not starts) || not ends
      then None
      else
        let middle =
          String.sub text (String.length prefix)
            (String.length text - String.length suffix - String.length prefix)
        in
        (match name with
        | None -> Some env
        | Some name -> Some (extend env name (VString middle)))
  | PList (_, prefix, rest, suffix, _), VList items ->
      match_list env prefix rest suffix items
  | PConstructor (_, _, name, patterns, _, _), VData (built, fields)
    when name = built && List.length patterns = List.length fields ->
      List.fold_left2
        (fun env one (_, part) ->
          match env with None -> None | Some env -> match_pattern env one part)
        (Some env) patterns fields
  | POr (_, alternatives, _), _ ->
      List.fold_left
        (fun found one ->
          match found with
          | Some _ -> found
          | None -> match_pattern env one value)
        None alternatives
  | PAs (_, inner, name, _), _ -> (
      match match_pattern env inner value with
      | None -> None
      | Some env -> Some (extend env name value))
  | _ -> None

(** The value of a named field. Raises Trap where the value has no such
    field, which only a program that reached the machine unchecked can
    manage. info -> value -> string -> value *)
let field_of info value name =
  match value with
  | VData (_, fields) -> (
      match List.find_opt (fun (label, _) -> label = Some name) fields with
      | Some (_, v) -> v
      | None ->
          raise
            (Trap
               (info, Printf.sprintf "%s has no field '%s'" (describe value) name)))
  | _ ->
      raise
        (Trap (info, Printf.sprintf "%s has no field '%s'" (describe value) name))

(** env with every name in an assignment target bound to its part of
    value. Raises Trap if a destructuring target does not fit the value
    it was given. env -> assign_target -> value -> env *)
let rec bind_target env target value =
  match target with
  | TargetName (_, name, _) -> extend env name value
  | TargetTuple (info, elements, _) -> (
      match value with
      | VTuple parts when List.length parts = List.length elements ->
          List.fold_left2
            (fun env element part -> bind_target env element part)
            env elements parts
      | _ ->
          raise
            (Trap
               ( info,
                 Printf.sprintf
                   "this binding takes %d values apart, but it was given %s"
                   (List.length elements) (describe value) )))

(* --- evaluating a call-free expression in one go --- *)

(** A call-free expression's value, computed directly (only called for
    an expression in `runtime.simple`). expr -> env -> value *)
let rec evaluate e env =
  match e with
  | EInt (_, value, _) -> VInt value
  | EFloat (_, value, _) -> VFloat value
  | EString (_, value, _) -> VString value
  | EBool (_, value, _) -> boolean value
  | EQualified (info, module_, name, _) -> (
      (* A public name of an imported module, bound under its qualified
         spelling when this module's environment was built, so the
         lookup is the one below. *)
      match lookup env (Printf.sprintf "%s.%s" module_ name) with
      | None ->
          raise
            (Trap
               ( info,
                 Printf.sprintf "unbound name '%s.%s'" module_ name ))
      | Some value -> value)
  | EVar (info, name, _) -> (
      match lookup env name with
      | None -> raise (Trap (info, Printf.sprintf "unbound name '%s'" name))
      (* In scope -- its `def` is in this block -- but the definition has
         not run yet, which is a different mistake from naming something
         that does not exist, and worth saying so. *)
      | Some (VUndefined _) ->
          raise
            (Trap
               ( info,
                 Printf.sprintf
                   "'%s' is in scope, but its 'def' has not run yet" name ))
      | Some value -> value)
  | ETuple (_, elements, _) ->
      VTuple (List.map (fun element -> evaluate element env) elements)
  | EList (_, elements, _) ->
      VList (List.map (fun element -> evaluate element env) elements)
  | EConstruct (_, _, name, args, _) ->
      VData (name, List.map (fun (label, a) -> (label, evaluate a env)) args)
  | EField (info, record, name, _) -> field_of info (evaluate record env) name
  | EListComp (_, element, clauses, _) ->
      VList
        (List.map
           (fun inner -> evaluate element inner)
           (comprehension_envs clauses env))
  | ELambda (_, params, body, _) ->
      (* The body is one expression, so the closure holds the one
         statement that supplies it -- `VClosure` is then applied by the
         machinery every other function goes through. *)
      VClosure
        ( "lambda",
          List.map (fun (Param (_, n, _, _, _)) -> n) params,
          [ SExprStmt (expr_info body, body, 0) ],
          env )
  | ENeg (_, operand, _) -> apply_unary e (evaluate operand env)
  | EIf (_, cond, then_expr, else_expr, _) -> (
      (* Only the branch that is chosen is evaluated, here as in the
         machine: an `if` expression chooses, it does not compute both
         and pick. *)
      match evaluate cond env with
      | VBool true -> evaluate then_expr env
      | VBool false -> evaluate else_expr env
      | other ->
          raise
            (Trap
               ( expr_info cond,
                 Printf.sprintf
                   "the condition of an 'if' must be Bool, not %s"
                   (describe other) )))
  | e -> (
      match binary_operands e with
      | Some (left, right) ->
          let left = evaluate left env in
          let right = evaluate right env in
          apply_binary e left right
      | None -> raise (Trap (expr_info e, unsupported_message)))

(** Every environment a comprehension's clauses produce, in order. Used
    only where the whole comprehension is call-free, so nothing here can
    suspend or print. [comp_clause] -> env -> [env] *)
and comprehension_envs clauses env =
  match clauses with
  | [] -> [ env ]
  | CompFor (info, pattern, sequence, _) :: rest -> (
      match evaluate sequence env with
      | VList items ->
          List.concat_map
            (fun item ->
              match match_pattern env pattern item with
              | None -> []
              | Some inner -> comprehension_envs rest inner)
            items
      | other ->
          raise
            (Trap
               ( info,
                 Printf.sprintf "a comprehension walks a list, not %s"
                   (describe other) )))
  | CompIf (info, condition, _) :: rest -> (
      match evaluate condition env with
      | VBool true -> comprehension_envs rest env
      | VBool false -> []
      | other ->
          raise
            (Trap
               ( info,
                 Printf.sprintf
                   "the condition of a comprehension must be Bool, not %s"
                   (describe other) )))

(* --- the machine --- *)

(** Enters a block: declares its defs, then runs its statements in
    order, delivering the last one's value to rest.
    state -> [stmt] -> env -> kont option -> state *)
let enter_block state stmts env rest =
  {
    state with
    control = CApply unit_value;
    env = declare stmts env;
    kont = Some (KSeq (Array.of_list stmts, 0, env, rest));
  }

(** Ends loop with value: the loop's own value, delivered where the loop
    statement stood. state -> loop -> value -> state *)
let leave state loop value =
  {
    state with
    control = CApply value;
    env = loop.loop_env;
    kont = loop.loop_kont;
    loops = loop.loop_parent;
  }

(** The loop has run out of turns, so it is worth the accumulator it
    stopped with. state -> loop -> state *)
let finish state loop = leave state loop loop.accumulator

(** The iteration clause a loop was written with.
    loop -> loop_iter option *)
let loop_iterate loop =
  match loop.loop_node with
  | SLoop (_, _, _, _, iterate, _, _) -> iterate
  | _ -> None

(** The accumulator target a loop was written with.
    loop -> assign_target option *)
let loop_target loop =
  match loop.loop_node with
  | SLoop (_, target, _, _, _, _, _) -> target
  | _ -> None

(** The body a loop was written with. loop -> [stmt] *)
let loop_body loop =
  match loop.loop_node with SLoop (_, _, _, _, _, body, _) -> body | _ -> []

(** Starts a turn of loop's body, with the accumulator bound afresh. The
    body's value goes to KIterate, which comes back here -- so a turn
    costs no continuation chain, however many turns there are.
    state -> loop -> state *)
let turn state loop =
  match
    try
      let env =
        match loop_target loop with
        | None -> loop.loop_env
        | Some target -> bind_target loop.loop_env target loop.accumulator
      in
      Ok env
    with Trap (info, message) -> Error (info, message)
  with
  | Error (info, message) -> failed state info message
  | Ok env ->
      let env, loop =
        match (loop_iterate loop, loop.remaining) with
        (* Each turn binds the element afresh, and the loop keeps what is
           left for the next one. *)
        | Some (ForIn (_, name, _, _)), first :: rest ->
            (extend env name first, { loop with remaining = rest })
        | _ -> (env, loop)
      in
      enter_block { state with loops = Some loop } (loop_body loop) env
        (Some (KIterate loop))

(** Decides whether the loop takes another turn, and starts it. A `for`
    takes the next item, a `while` asks its condition, and a bare `loop:`
    goes round unconditionally. state -> loop -> state *)
let begin_turn state loop =
  match loop_iterate loop with
  | Some (ForIn _) ->
      if loop.remaining = [] then finish state loop else turn state loop
  | Some (WhileTest (_, condition, _)) -> (
      (* The condition can ask about the accumulator, so it is evaluated
         where the accumulator is bound. *)
      match
        try
          Ok
            (match loop_target loop with
            | None -> loop.loop_env
            | Some target ->
                bind_target loop.loop_env target loop.accumulator)
        with Trap (info, message) -> Error (info, message)
      with
      | Error (info, message) -> failed state info message
      | Ok env ->
          {
            state with
            control = CEval condition;
            env;
            kont = Some (KTest loop);
            loops = loop.loop_parent;
          })
  | None -> turn state loop

(** The first thing a loop needs: a `for`'s sequence, evaluated once
    before any turn. state -> loop -> state *)
let start_loop state loop =
  match loop_iterate loop with
  | Some (ForIn (_, _, sequence, _)) ->
      {
        state with
        control = CEval sequence;
        env = loop.loop_env;
        kont = Some (KSequence loop);
        loops = loop.loop_parent;
      }
  | _ -> begin_turn state loop

(** Applies callee (a builtin or closure) to args.
    state -> expr -> value -> [value] -> env -> kont option -> state *)
let rec call state call_node callee args env rest =
  let info = expr_info call_node in
  match callee with
  | VBuiltin name -> (
      match
        try Ok (apply_builtin name args info state.runtime.host)
        with Trap (info, message) -> Error (info, message)
      with
      | Error (info, message) -> failed state info message
      | Ok value -> { state with control = CApply value; env; kont = rest })
  | VHostFun (module_, field) -> (
      (* A function an external module implements: there is no body to
         interpret, so the host runs it and answers with a value. Only a
         host that can reach the target language has one, and a program
         importing such a module is refused before it runs otherwise. *)
      match state.runtime.host.externals with
      | None ->
          failed state info
            (Printf.sprintf
               "'%s.%s' is implemented in a target language, which this host \
                cannot call"
               module_ field)
      | Some externals -> (
          match
            try Ok (externals.call (callback state info) module_ field args)
            with
            (* A refusal the host made itself is written nowhere in the
               program, so it is reported at the call. *)
            | Trap (where, message) when where.file = "<host>" -> Error (info, message)
            | Trap (info, message) | Runtime_error (info, message) ->
                Error (info, message)
          with
          | Error (info, message) -> failed state info message
          | Ok value -> { state with control = CApply value; env; kont = rest }))
  | VClosure (name, params, body, captured) ->
      if List.length args <> List.length params then
        failed state info
          (Printf.sprintf "'%s' takes %d argument%s, but %d %s given" name
             (List.length params)
             (if List.length params = 1 then "" else "s")
             (List.length args)
             (if List.length args = 1 then "was" else "were"))
      else
        let depth =
          (match state.stack with None -> 0 | Some frame -> frame.depth) + 1
        in
        if depth > state.runtime.max_depth then
          failed state info
            (Printf.sprintf
               "maximum call depth of %d exceeded; this is what a recursion \
                that never ends looks like"
               state.runtime.max_depth)
        else
          let frame =
            {
              frame_name = name;
              frame_info = info;
              frame_kont = rest;
              frame_env = env;
              frame_parent = state.stack;
              depth;
              frame_loops = state.loops;
            }
          in
          let call_env = extend_all captured (List.combine params args) in
          (* The frame is pushed here; `KReturnTo` is what pops it, and
             what puts the caller's own environment, continuation and
             loops back when the call produces its value. The callee runs
             inside none of the caller's loops, which is the same thing
             parser.ml says statically about a `break`. *)
          enter_block
            {
              state with
              control = CApply unit_value;
              stack = Some frame;
              loops = None;
            }
            body call_env (Some (KReturnTo frame))
  | callee ->
      failed state info
        (Printf.sprintf "this call applies %s, which is not a function"
           (describe callee))

(** Applies callee to args in a machine of its own, sharing state's
    runtime, and answers the value -- how a host calls back a Pyking
    function it was handed. A failure raises Runtime_error.
    state -> info -> value -> [value] -> value *)
and callback state info callee args =
  let rec drive state =
    match state.control with
    | CDone value -> value
    | CFailed (info, message) -> raise (Runtime_error (info, message))
    | _ -> drive (step state)
  in
  drive
    (call
       { state with control = CApply unit_value; kont = None; stack = None; loops = None }
       (ETuple (info, [], 0)) callee args state.env None)

(** Evaluates the next argument, or makes the call if todo is empty.
    state -> expr -> value -> [value] -> [expr] -> env -> kont option
    -> state *)
and start_arguments state call_node callee done_ todo env rest =
  match todo with
  | next :: more ->
      {
        state with
        control = CEval next;
        env;
        kont = Some (KArgument (call_node, callee, done_, more, env, rest));
      }
  | [] -> call state call_node callee done_ env rest

(** Evaluates the next element of a tuple or a list literal, or builds it
    if todo is empty. The two are one path because they differ only in
    what is built at the end.
    state -> expr -> [value] -> [expr] -> env -> kont option -> state *)
and start_elements state node done_ todo env rest =
  match todo with
  | next :: more ->
      {
        state with
        control = CEval next;
        env;
        kont = Some (KElement (node, done_, more, env, rest));
      }
  | [] ->
      let built =
        match node with
        | EList _ -> VList done_
        | EConstruct (_, _, name, args, _) ->
            VData (name, List.combine (List.map fst args) done_)
        | _ -> VTuple done_
      in
      { state with control = CApply built; env; kont = rest }

(** Tries a `match`'s cases on its subject in order and runs the body of
    the first whose pattern fits -- once its guard, where it has one, has
    been evaluated to true. A `match` that fits none supplies unit, which
    exhaustive.ml makes unreachable.
    state -> value -> [match_case] -> env -> kont option -> state *)
and try_cases state value cases env rest =
  match cases with
  | [] -> { state with control = CApply unit_value; env; kont = rest }
  | MatchCase (_, pattern, guard, body, _) :: more -> (
      match match_pattern env pattern value with
      | None -> try_cases state value more env rest
      | Some inner -> (
          match guard with
          | None ->
              {
                state with
                control = CApply unit_value;
                env = inner;
                kont = Some (KSeq (Array.of_list body, 0, env, rest));
              }
          | Some g ->
              {
                state with
                control = CEval g;
                env = inner;
                kont = Some (KGuard (value, more, body, inner, env, rest));
              }))

(* A comprehension is a nested loop that builds a list, and the machine
   runs it as one: `frames` is the loop stack, innermost *first* (the
   Python keeps it innermost last; a list is cheaper to push and pop at
   the head), each frame holding which clause it belongs to, the items it
   has left, and the environment that clause was entered in.
   `comprehend` asks for the next thing to be evaluated; `comprehended`
   receives it. Everything that can suspend -- a sequence, a condition,
   an element -- goes round that pair, which is what lets a
   comprehension calling a printing function interleave correctly. *)

(** The clauses a comprehension was written with. expr -> [comp_clause] *)
and comp_clauses node =
  match node with EListComp (_, _, clauses, _) -> clauses | _ -> []

(** The element expression a comprehension was written with. expr -> expr *)
and comp_element node =
  match node with EListComp (_, element, _, _) -> element | _ -> node

(** Drives a comprehension one step: enters the next clause, or takes the
    next item, or builds the list when nothing is left.
    state -> expr -> [(int, [value], env)] -> [value] -> env -> env
    -> kont option -> state *)
and comprehend state node frames done_ env outer rest =
  let clauses = comp_clauses node in
  let index = List.length frames in
  if index = List.length clauses then
    (* Every clause is entered: this environment yields one element. *)
    {
      state with
      control = CEval (comp_element node);
      env;
      kont =
        Some (KComprehend (node, WElement, index, frames, done_, env, outer, rest));
    }
  else
    match List.nth clauses index with
    | CompFor (_, _, sequence, _) ->
        {
          state with
          control = CEval sequence;
          env;
          kont =
            Some
              (KComprehend
                 (node, WSequence, index, frames, done_, env, outer, rest));
        }
    | CompIf (_, condition, _) ->
        {
          state with
          control = CEval condition;
          env;
          kont =
            Some
              (KComprehend (node, WTest, index, frames, done_, env, outer, rest));
        }

(** Takes the next item of the innermost `for`, skipping items its
    pattern does not match, and unwinds a frame that has run out.
    state -> expr -> [(int, [value], env)] -> [value] -> env
    -> kont option -> state *)
and take state node frames done_ outer rest =
  match frames with
  | [] ->
      { state with control = CApply (VList done_); env = outer; kont = rest }
  | (index, items, entered) :: outer_frames -> (
      match List.nth (comp_clauses node) index with
      (* A test's frame holds no items; it is a marker that the test
         passed, and unwinding it is all there is to do. *)
      | CompIf _ -> take state node outer_frames done_ outer rest
      | CompFor (_, pattern, _, _) -> (
          match items with
          | [] -> take state node outer_frames done_ outer rest
          | first :: more -> (
              let frames = (index, more, entered) :: outer_frames in
              match match_pattern entered pattern first with
              (* the pattern filters it out *)
              | None -> take state node frames done_ outer rest
              | Some inner -> comprehend state node frames done_ inner outer rest)))

(** One value a comprehension asked for has arrived.
    state -> expr -> want -> int -> [(int, [value], env)] -> [value]
    -> value -> env -> env -> kont option -> state *)
and comprehended state node want index frames done_ value env outer rest =
  let clause_info () =
    match List.nth (comp_clauses node) index with
    | CompFor (info, _, _, _) | CompIf (info, _, _) -> info
  in
  match want with
  | WElement -> take state node frames (done_ @ [ value ]) outer rest
  | WTest -> (
      match value with
      | VBool true ->
          comprehend state node ((index, [], env) :: frames) done_ env outer rest
      | VBool false -> take state node frames done_ outer rest
      | value ->
          failed state (clause_info ())
            (Printf.sprintf
               "the condition of a comprehension must be Bool, not %s"
               (describe value)))
  | WSequence -> (
      match value with
      | VList items ->
          take state node ((index, items, env) :: frames) done_ outer rest
      | value ->
          failed state (clause_info ())
            (Printf.sprintf "a comprehension walks a list, not %s"
               (describe value)))

(** Starts on an expression: evaluates it directly if call-free,
    otherwise pushes the first continuation it needs.
    state -> expr -> state *)
and step_eval state e =
  if IntSet.mem (expr_sym e) state.runtime.simple then
    match evaluate e state.env with
    | value -> { state with control = CApply value }
    | exception Trap (info, message) -> failed state info message
  else
    match e with
    | ECall (_, func, _, _) ->
        {
          state with
          control = CEval func;
          kont = Some (KCallee (e, state.env, state.kont));
        }
    | ETuple (_, elements, _) | EList (_, elements, _) ->
        start_elements state e [] elements state.env state.kont
    | EConstruct (_, _, _, args, _) ->
        start_elements state e [] (arg_exprs args) state.env state.kont
    | EField (_, record, _, _) ->
        {
          state with
          control = CEval record;
          kont = Some (KField (e, state.env, state.kont));
        }
    | ENeg (_, operand, _) ->
        {
          state with
          control = CEval operand;
          kont = Some (KNegate (e, state.env, state.kont));
        }
    | EListComp _ -> comprehend state e [] [] state.env state.env state.kont
    | EIf (_, cond, _, _, _) ->
        {
          state with
          control = CEval cond;
          kont = Some (KChoose (e, state.env, state.kont));
        }
    | e -> (
        match binary_operands e with
        | Some (left, right) ->
            {
              state with
              control = CEval left;
              kont = Some (KBinaryLeft (e, right, state.env, state.kont));
            }
        (* A literal or a name: call-free, so the fast path above has
           already dealt with it. Anything else is outside the
           fragment. *)
        | None -> failed state (expr_info e) unsupported_message)

(** Starts on a statement: delivers what it supplies (PYKING.md, "Tail
    position") to its continuation. state -> stmt -> state *)
and step_stmt state stmt =
  match stmt with
  | SLet (_, target, e, _, _, _, _) ->
      {
        state with
        control = CEval e;
        kont = Some (KBind (target, state.env, state.kont));
      }
  | SLetStmt (_, target, inner, _, _, _) ->
      (* `x = if c: ...` binds whatever the branch that runs yields;
         `x = loop ...` the accumulator it stopped with. *)
      {
        state with
        control = CStmt inner;
        kont = Some (KBind (target, state.env, state.kont));
      }
  | SVar (_, name, e, _) ->
      {
        state with
        control = CEval e;
        kont = Some (KVarBind (name, state.env, state.kont));
      }
  | SMutate (info, name, e, _) ->
      {
        state with
        control = CEval e;
        kont = Some (KMutate (name, info, state.env, state.kont));
      }
  | SExprStmt (_, e, _) ->
      (* Supplies its expression's value, and binds nothing, so its
         continuation is simply the one that was already there. *)
      { state with control = CEval e }
  | SIf (_, cond, _, _, _) ->
      {
        state with
        control = CEval cond;
        kont = Some (KBranch (stmt, state.env, state.kont));
      }
  | SLoop (_, target, init, _, _, _, _) -> (
      let loop =
        {
          loop_node = stmt;
          accumulator = unit_value;
          loop_env = state.env;
          loop_kont = state.kont;
          loop_parent = state.loops;
          remaining = [];
        }
      in
      match (target, init) with
      (* No accumulator to work out: go straight on to whatever decides
         the first turn. Every turn carries unit. *)
      | None, _ -> start_loop state loop
      | Some _, None -> start_loop state loop
      | Some _, Some init ->
          { state with control = CEval init; kont = Some (KStartLoop loop) })
  | SBreak (info, _) | SContinue (info, _) -> (
      match state.loops with
      | None ->
          let keyword =
            match stmt with SBreak _ -> "break" | _ -> "continue"
          in
          failed state info (Printf.sprintf "'%s' outside a loop" keyword)
      (* A `break` leaves with the accumulator this turn started with,
         which is what the loop is worth. A `continue` goes round with
         that same accumulator -- through `begin_turn` like every other
         way round, since what comes next may be the end of a `for`'s
         list rather than another turn. *)
      | Some loop -> (
          match stmt with
          | SBreak _ -> leave state loop loop.accumulator
          | _ -> begin_turn state loop))
  | SReturn (info, e, _) -> (
      match state.stack with
      | None -> failed state info "'return' outside a function"
      | Some frame ->
          { state with control = CEval e; kont = Some (KReturnTo frame) })
  | SReturnStmt (info, inner, _) -> (
      match state.stack with
      | None -> failed state info "'return' outside a function"
      | Some frame ->
          { state with control = CStmt inner; kont = Some (KReturnTo frame) })
  | SMatch (_, subject, _, _) ->
      {
        state with
        control = CEval subject;
        kont = Some (KScrutinee (stmt, state.env, state.kont));
      }
  (* What an import brings in was bound before the module's first
     statement ran (see `run_modules`), so there is nothing to do here.
     It supplies unit. And a signature says what a `def` in this block
     is: the checker has read it, there is nothing to run, and it
     supplies unit too. *)
  | SImport _ | SFunctionSig _ | SDatatype _ ->
      { state with control = CApply unit_value }
  | SFunctionDef _ ->
      (* The name has been in scope since the block began; this is where
         it becomes a function, capturing what is bound here. The
         statement itself supplies unit. *)
      { state with control = CApply unit_value; env = define state.env stmt }

(** Hands value to whatever was waiting for it (state.kont).
    state -> value -> state *)
and step_apply state value =
  match state.kont with
  | None -> { state with control = CDone value }
  | Some (KSeq (stmts, index, exit_env, rest)) ->
      (* The one continuation that adopts the environment it is handed:
         that is how a binding reaches the statements after it. When the
         block is done, `exit_env` puts the enclosing scope back, which
         is what keeps the block's bindings inside it. *)
      if index < Array.length stmts then
        {
          state with
          control = CStmt stmts.(index);
          kont = Some (KSeq (stmts, index + 1, exit_env, rest));
        }
      else { state with control = CApply value; env = exit_env; kont = rest }
  | Some (KBind (target, env, rest)) -> (
      match bind_target env target value with
      | bound -> { state with control = CApply unit_value; env = bound; kont = rest }
      | exception Trap (info, message) -> failed state info message)
  | Some (KVarBind (name, env, rest)) ->
      {
        state with
        control = CApply unit_value;
        env = extend env name value;
        kont = rest;
      }
  | Some (KMutate (name, info, env, rest)) ->
      if not (mutate env name value) then
        failed state info (Printf.sprintf "unbound name '%s'" name)
      else { state with control = CApply unit_value; env; kont = rest }
  | Some (KBinaryLeft (node, right, env, rest)) ->
      {
        state with
        control = CEval right;
        env;
        kont = Some (KBinaryRight (node, value, env, rest));
      }
  | Some (KBinaryRight (node, left, env, rest)) -> (
      match apply_binary node left value with
      | answer -> { state with control = CApply answer; env; kont = rest }
      | exception Trap (info, message) -> failed state info message)
  | Some (KCallee (call_node, env, rest)) ->
      let args =
        match call_node with
        | ECall (_, _, args, _) -> arg_exprs args
        | _ -> []
      in
      start_arguments state call_node value [] args env rest
  | Some (KArgument (call_node, callee, done_, todo, env, rest)) ->
      start_arguments state call_node callee (done_ @ [ value ]) todo env rest
  | Some (KElement (node, done_, todo, env, rest)) ->
      start_elements state node (done_ @ [ value ]) todo env rest
  | Some (KBranch (stmt, env, rest)) -> (
      let cond, then_body, else_body =
        match stmt with
        | SIf (_, cond, then_body, else_body, _) -> (cond, then_body, else_body)
        | _ -> (EBool (stmt_info stmt, true, 0), [], None)
      in
      match value with
      | VBool chosen -> (
          let body = if chosen then Some then_body else else_body in
          match body with
          | None -> { state with control = CApply unit_value; env; kont = rest }
          | Some body ->
              (* An `if` with no `else` supplies nothing, whatever the
                 branch it does have ends in -- so the branch's value is
                 discarded. *)
              let after =
                if else_body <> None then rest else Some (KDiscard (env, rest))
              in
              enter_block state body env after)
      | value ->
          failed state (expr_info cond)
            (Printf.sprintf "the condition of an 'if' must be Bool, not %s"
               (describe value)))
  | Some (KChoose (node, env, rest)) -> (
      let cond, then_expr, else_expr =
        match node with
        | EIf (_, cond, then_expr, else_expr, _) -> (cond, then_expr, else_expr)
        | _ -> (node, node, node)
      in
      match value with
      | VBool chosen ->
          {
            state with
            control = CEval (if chosen then then_expr else else_expr);
            env;
            kont = rest;
          }
      | value ->
          failed state (expr_info cond)
            (Printf.sprintf "the condition of an 'if' must be Bool, not %s"
               (describe value)))
  | Some (KDiscard (env, rest)) ->
      { state with control = CApply unit_value; env; kont = rest }
  | Some (KStartLoop loop) ->
      start_loop state { loop with accumulator = value }
  | Some (KSequence loop) -> (
      match value with
      | VList items -> begin_turn state { loop with remaining = items }
      | value ->
          failed state
            (match loop_iterate loop with
            | Some it -> loop_iter_info it
            | None -> stmt_info loop.loop_node)
            (Printf.sprintf "a 'for' loop walks a list, not %s"
               (describe value)))
  | Some (KTest loop) -> (
      match value with
      | VBool true -> turn state loop
      | VBool false -> finish state loop
      | value ->
          failed state
            (match loop_iterate loop with
            | Some it -> loop_iter_info it
            | None -> stmt_info loop.loop_node)
            (Printf.sprintf "the condition of a 'while' must be Bool, not %s"
               (describe value)))
  | Some (KIterate loop) ->
      (* What the body produced is the next turn's accumulator -- unless
         the loop carries none, in which case it is thrown away and every
         turn starts from unit again. *)
      if loop_target loop = None then begin_turn state loop
      else begin_turn state { loop with accumulator = value }
  | Some (KNegate (node, env, rest)) -> (
      match apply_unary node value with
      | answer -> { state with control = CApply answer; env; kont = rest }
      | exception Trap (info, message) -> failed state info message)
  | Some (KScrutinee (stmt, env, rest)) -> (
      (* Matching evaluates nothing, so every arm is tried here and the
         first that fits has its body run. A `match` that fits none does
         nothing and supplies unit (PYKING.md). *)
      let cases = match stmt with SMatch (_, _, cases, _) -> cases | _ -> [] in
      try_cases state value cases env rest)
  | Some (KGuard (subject, more, body, inner, env, rest)) -> (
      match value with
      | VBool true ->
          {
            state with
            control = CApply unit_value;
            env = inner;
            kont = Some (KSeq (Array.of_list body, 0, env, rest));
          }
      | VBool false -> try_cases state subject more env rest
      | other ->
          failed state
            (match body with first :: _ -> stmt_info first | [] -> divide_info)
            (Printf.sprintf "the guard of a 'case' must be Bool, not %s"
               (describe other)))
  | Some (KField (node, env, rest)) -> (
      match node with
      | EField (info, _, name, _) -> (
          match field_of info value name with
          | answer -> { state with control = CApply answer; env; kont = rest }
          | exception Trap (info, message) -> failed state info message)
      | _ -> failed state (expr_info node) unsupported_message)
  | Some (KComprehend (node, want, index, frames, done_, env, outer, rest)) ->
      comprehended state node want index frames done_ value env outer rest
  | Some (KReturnTo frame) ->
      {
        state with
        control = CApply value;
        env = frame.frame_env;
        kont = frame.frame_kont;
        stack = frame.frame_parent;
        loops = frame.frame_loops;
      }

(** One small step. Total: every state, including a finished or failed
    one, has a successor. state -> state *)
and step state =
  match state.control with
  | CEval e -> step_eval state e
  | CStmt stmt -> step_stmt state stmt
  | CApply value -> step_apply state value
  | CDone _ | CFailed _ -> state

(* --- driving the machine --- *)

(** The symbols of every call-free expression in one statement.
    stmt -> IntSet.t *)
let call_free_of_stmt stmt = snd (call_free_walk (Walk.NStmt stmt) IntSet.empty)

(** A machine about to run stmts, not yet stepped. `env`, if given, lets
    a caller continue an earlier session (default: a fresh top level).
    [stmt] -> host -> env option -> int -> state *)
let initial_state ?env ?(max_depth = max_call_depth) stmts host =
  let start = match env with None -> top_level_env () | Some env -> env in
  let runtime = { host; simple = call_free_symbols stmts; max_depth } in
  let state =
    {
      control = CApply unit_value;
      env = start;
      kont = None;
      stack = None;
      runtime;
      loops = None;
    }
  in
  enter_block state stmts start None

(** Whether the machine has stopped (done or failed). state -> bool *)
let finished state =
  match state.control with CDone _ | CFailed _ -> true | _ -> false

(** Steps until the machine stops or `steps` steps have been taken,
    whichever comes first. state -> int option -> state *)
let run ?steps state =
  let rec go state taken =
    if finished state then state
    else
      match steps with
      | Some limit when taken >= limit -> state
      | _ -> go (step state) (taken + 1)
  in
  go state 0

(** The value a finished machine produced, or None if it failed or has
    not finished. state -> value option *)
let result state =
  match state.control with CDone value -> Some value | _ -> None

(** The error a machine stopped on, or None. state -> exn option *)
let failure state =
  match state.control with
  | CFailed (info, message) -> Some (Runtime_error (info, message))
  | _ -> None

(** The calls in progress, innermost first. state -> [(string, info)] *)
let stack_trace state =
  let rec go frame trace =
    match frame with
    | None -> List.rev trace
    | Some frame ->
        go frame.frame_parent ((frame.frame_name, frame.frame_info) :: trace)
  in
  go state.stack []

(** Applies callee to args in finished machine's environment, as a
    machine of its own run to completion: how a host delivers an event
    to a callback after the program's top level has ended.
    state -> value -> [value] -> state *)
let apply state callee args =
  let info = { Lexer.file = "<callback>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } in
  run
    (call
       { state with control = CApply unit_value; kont = None; stack = None; loops = None }
       (ETuple (info, [], 0)) callee args state.env None)

(** Runs a whole (already checked and symbolized) program to completion.
    [stmt] -> host -> state *)
let run_program ?(max_depth = max_call_depth) stmts host =
  run (initial_state ~max_depth stmts host)

(** state with every def in stmts declared, as one group (their names
    come into scope together). state -> [stmt] -> state *)
let declare_entry state stmts = { state with env = declare stmts state.env }

(** Runs one statement in state's environment as it stands (nothing is
    declared first), with a continuation chain of its own. Answers the
    state it leaves behind. state -> stmt -> state *)
let eval_in state stmt =
  let runtime =
    {
      state.runtime with
      simple = IntSet.union state.runtime.simple (call_free_of_stmt stmt);
    }
  in
  run
    {
      control = CStmt stmt;
      env = state.env;
      kont = None;
      stack = None;
      runtime;
      loops = None;
    }

(** Declares and runs one statement: `eval_in` for a group of one.
    state -> stmt -> state *)
let eval_statement state stmt = eval_in (declare_entry state [ stmt ]) stmt

(** Runs a group of statements in state's environment and keeps what
    they bind, which `enter_block` does not: a block puts the enclosing
    scope back when it ends, and a module's top level has no enclosing
    scope to go back to -- what it bound is what it exports. The same
    thing the REPL does with one entry. state -> [stmt] -> state *)
let run_entry state stmts =
  let rec go state stmts =
    match stmts with
    | [] -> state
    | statement :: rest ->
        let state = eval_in state statement in
        if failure state <> None then state else go state rest
  in
  go (declare_entry state stmts) stmts

(** The top level a module runs in: the builtins, and everything its
    imports bring in -- each selected name under the name it is known by
    here, and each field of a plain import under `alias.field`, which is
    the spelling `EQualified` looks up. The same environment the checker
    builds for the same statements (Typesystem.import_env).
    [stmt] -> [(string, [(string, value)])] -> env *)
let rec module_env stmts exports =
  let brought = imported_bindings stmts exports in
  if brought = [] then top_level_env ()
  else
    {
      bindings =
        List.fold_left
          (fun map (name, value) -> SMap.add name (ref value) map)
          SMap.empty brought;
      parent = Some (top_level_env ());
    }

(** What a module's imports bring in, as each name it is known by here
    and its value: a selected name under its local name, and a field of a
    plain import under `alias.field`.
    [stmt] -> [(string, [(string, value)])] -> [(string, value)] *)
and imported_bindings stmts exports =
    List.fold_left
      (fun brought statement ->
        match statement with
        | SImport (_, module_, name, selected, fields, _) ->
            List.fold_left
              (fun brought (exported, local) ->
                let bound =
                  if selected then local
                  else Printf.sprintf "%s.%s" name exported
                in
                (* A datatype and its constructors are no value of the
                   module's: a constructor is applied where it is
                   written. *)
                match List.assoc_opt exported (List.assoc module_ exports) with
                | Some value -> brought @ [ (bound, value) ]
                | None -> brought)
              brought fields
        | _ -> brought)
      [] stmts

(** What a module leaves for the modules that import it: the value each
    of its public names ended up with. Read from the environment the
    module's top level left behind, so a `def` gives its closure and a
    binding its value. [stmt] -> state -> [(string, value)] *)
let exported_values stmts state =
  let visible = bindings_in_scope state.env in
  List.filter_map
    (fun (name, _) ->
      match List.assoc_opt name visible with
      | Some value -> Some (name, value)
      | None -> None)
    (Module.public_names stmts)

(** What an external module exports, for a host that can reach one: a
    function becomes a VHostFun the host runs when it is called, and
    anything else is asked of the host now. The declaration is what says
    which is which -- there is no body here to look at.
    [stmt] -> string -> host -> [(string, value)] *)
let host_values signatures name host =
  match host.externals with
  | None -> []
  | Some externals ->
      List.map
        (fun (field, type_) ->
          match type_ with
          | TFunction _ -> (field, VHostFun (name, field))
          | _ -> (field, externals.field name field))
        signatures

(** Runs modules into a machine that is already running -- what a REPL
    entry's imports do -- each in a top level of its own and in the order
    given, against the modules `exports` already holds. Answers the
    machine, with the modules' call-free table added to its own, and the
    exports with theirs added; where one failed, the failed machine, so
    `failure` and `stack_trace` report it.
    state -> [(string, [stmt], [stmt])] -> [(string, [(string, value)])]
    -> (state, [(string, [(string, value)])]) *)
let load_modules machine units exports =
  (* One call-free table for the whole program, not one per module: a
     closure a module exports is called from the module that imported
     it, and the table it is read against is the calling machine's.
     Symbols are unique across a program (Analyses.symbolize), so the
     union is exactly right. *)
  let simple =
    List.fold_left
      (fun simple (_, stmts, _) -> IntSet.union simple (call_free_symbols stmts))
      machine.runtime.simple units
  in
  let runtime = { machine.runtime with simple } in
  let host = runtime.host in
  let rec go units exports =
    match units with
    | [] -> ({ machine with runtime }, exports)
    | (name, [], declarations) :: rest ->
        (* Only a declaration half: there is no top level to run, and
           what it exports is the host's, bound here for the modules
           that import it. *)
        go rest
          (exports
          @ [ (name, host_values (Module.external_signatures declarations) name host) ])
    | (name, stmts, declarations) :: rest ->
        (* A module's own declaration half is in scope in its Pyking
           half, unqualified and private ones included: the two files
           are one module. What it *exports* is the public ones only. *)
        let env =
          List.fold_left
            (fun env (field, value) -> extend env field value)
            (module_env stmts exports)
            (host_values (Module.external_signatures declarations) name host)
        in
        let state =
          run_entry
            {
              control = CApply unit_value;
              env;
              kont = None;
              stack = None;
              runtime;
              loops = None;
            }
            stmts
        in
        if failure state <> None then (state, exports)
        else
          go rest
            (exports
            @ [
                ( name,
                  exported_values stmts state
                  @ host_values
                      (List.map
                         (fun (n, t, _) -> (n, t))
                         (Module.public_declarations declarations))
                      name host );
              ])
  in
  go units exports

(** Runs a program of several modules, each in a top level of its own,
    in the order given -- which is dependency order, so a module runs
    after everything it imports (docs/modules.md, "Running a program of
    several modules"). The state answered is the last module's, so
    `failure` and `stack_trace` report a failure in whichever module hit
    it and the run stops there.
    Each unit is a module's name, its Pyking half and its declaration
    half -- a module is up to two files, and both are needed here: the
    declarations are what the host answers for.
    [(string, [stmt], [stmt])] -> host -> state *)
let run_modules ?(max_depth = max_call_depth) units host =
  fst (load_modules (run (initial_state ~max_depth [] host)) units [])

(** machine with an entry's imports bound: each selected name under the
    name it is known by here, and each field of a plain import under
    `alias.field`, from the modules `exports` holds.
    state -> [stmt] -> [(string, [(string, value)])] -> state *)
let bind_imports machine stmts exports =
  match imported_bindings stmts exports with
  | [] -> machine
  | brought -> { machine with env = extend_all machine.env brought }

(** machine with host in place of the one it had: how a REPL gives the
    machine a module implemented in a target language once an entry has
    imported one. state -> host -> state *)
let with_host machine host = { machine with runtime = { machine.runtime with host } }
