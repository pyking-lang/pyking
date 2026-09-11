(** The interpreter: a resumable small-step machine that runs a Pyking
    program directly from the AST, instead of translating it to a host
    language. It runs the fragment typesystem.ml accepts, and pyk.ml
    type-checks before handing a program here -- that is the whole of
    the gate, so there is no second list of supported constructs to keep
    in step. This is the reference implementation of Pyking's runtime
    semantics. See docs/interpreter.md.

    This interface is the embedding API, and it is meant to be the only
    way in: the debugger, the DAP server and the LSP server planned in
    design/plan-eval-lsp.md sit on exactly these functions. The machine
    itself is private -- one step is `step`, and what a step is made of
    (the continuations, the call frames, the loop records, the direct
    evaluator, the operator rules, pattern matching) is not something a
    caller assembles or inspects.

    `control`, `kont`, `frame`, `loop` and `runtime` are therefore
    abstract: a `state` is a plain value a caller keeps, passes back and
    reads a result out of, and its parts are the machine's own. `value`
    is public, since a prompt and a page have to show one; `env` is
    abstract but named, since a closure holds one and a session's
    bindings are listed from one.

    Data structures:
      Runtime_error -- a runtime failure, with the source position.
      Trap -- how the direct evaluator reports a failure internally;
        seen by a host reading a value out of an external module.
      value -- what a Pyking expression evaluates to.
      env -- a persistent chain of frames.
      externals -- how a host reaches a module implemented in a target
        language.
      host -- where print goes.
      state -- a machine state; control, kont, frame, loop and runtime
        are its opaque parts.

    Functions:
      run_program stmts host -- runs a whole program to completion.
      run_modules units host -- runs a program of several modules, each
        in a top level of its own, in dependency order.
      initial_state stmts host -- a machine about to run stmts.
      step state -- one small step.
      run state steps -- steps until the machine stops or steps run out.
      result state / failure state / stack_trace state -- what a stopped
        machine answers.
      declare_entry state stmts / eval_in state stmt /
        eval_statement state stmt -- running statements in an existing
        machine's environment, which is what a prompt does.
      bindings_in_scope env -- every name visible from a frame.
      format_value value / display_value value -- formats a value as
        print emits it / as a value is shown.
      describe value -- a value's type name, for an error message.
      console_host / callback_host -- the two hosts there are.
      binary_operands e -- the two operands of a binary operator, which
        the backends share rather than re-deriving. *)

open Lexer
open Syntax

(** A Pyking runtime error, with the source position. The machine never
    raises it -- a failing step produces a failed state holding one
    instead -- but the driver reports it like every other stage's. *)
exception Runtime_error of info * string

(** How the direct evaluator and the operator rules report a failure to
    their caller. Caught before it crosses `step`'s boundary; a host
    implementing `externals` raises it for a value it cannot convert. *)
exception Trap of info * string

(** What a Pyking expression evaluates to. Values hold no host objects
    -- no OCaml closure, no array standing in for a Pyking list -- so
    the representation survives the rewrite into Pyking. *)
type value =
  | VInt of int (* at least 32 signed bits; overflow is undefined *)
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
         implements in a target language *)
  | VUndefined of string (* a hoisted `def` whose definition has not run *)

(** A persistent chain of frames. Abstract: `extend`, `lookup` and the
    write-once cell a `def` binds are the machine's own, and
    `bindings_in_scope` is all a caller needs of one. *)
and env

(** How a host reaches a module implemented in a target language: what
    one of its value exports is, and how to call one of its functions.
    Both take the module's name and the field's. *)
type externals = {
  field : string -> string -> value;
  call : string -> string -> value list -> value;
}

(** Where print goes, and how an external module is reached. *)
type host

(** What the machine does next. *)
type control

(** What to do with the value that is about to arrive. *)
type kont

(** One Pyking call in progress. *)
type frame

(** One `loop` in progress. *)
type loop

(** What a run never changes: the host, the call-free symbol table and
    the depth limit. *)
type runtime

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

(* --- hosts --- *)

(** Writes to standard output, and reaches no external module: nothing
    in a terminal can call a target language's own code. host *)
val console_host : host

(** A host that hands each printed line to a function.
    externals? -> (string -> ()) -> host *)
val callback_host : ?externals:externals -> (string -> unit) -> host

(* --- running a program --- *)

(** Runs a whole (already checked and symbolized) program to completion.
    [stmt] -> host -> state *)
val run_program : ?max_depth:int -> stmt list -> host -> state

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
val run_modules :
  ?max_depth:int -> (string * stmt list * stmt list) list -> host -> state

(** A machine about to run stmts, not yet stepped. `env`, if given, lets
    a caller continue an earlier session (default: a fresh top level).
    env? -> int? -> [stmt] -> host -> state *)
val initial_state : ?env:env -> ?max_depth:int -> stmt list -> host -> state

(** One small step. Total: every state, including a finished or failed
    one, has a successor. state -> state *)
val step : state -> state

(** Steps until the machine stops or `steps` steps have been taken,
    whichever comes first. int? -> state -> state *)
val run : ?steps:int -> state -> state

(** The value a finished machine produced, or None if it failed or has
    not finished. state -> value option *)
val result : state -> value option

(** The error a machine stopped on, or None. state -> exn option *)
val failure : state -> exn option

(** The calls in progress, innermost first. state -> [(string, info)] *)
val stack_trace : state -> (string * info) list

(* --- running statements in an existing machine --- *)

(** state with every def in stmts declared, as one group (their names
    come into scope together). state -> [stmt] -> state *)
val declare_entry : state -> stmt list -> state

(** Runs one statement in state's environment as it stands (nothing is
    declared first), with a continuation chain of its own. Answers the
    state it leaves behind. state -> stmt -> state *)
val eval_in : state -> stmt -> state

(** Declares and runs one statement: `eval_in` for a group of one.
    state -> stmt -> state *)
val eval_statement : state -> stmt -> state

(** Every name visible from env, as name -> value, innermost first.
    env -> [(string, value)] *)
val bindings_in_scope : env -> (string * value) list

(* --- showing a value --- *)

(** Formats a value as print writes it (builtin.ml's rules): a
    string bare, everything else as display_value. value -> string *)
val format_value : value -> string

(** Formats a value as it appears inside a larger one, or as a
    prompt/debugger shows it: like format_value, but a string is quoted.
    Iterative, so nesting cannot overflow the host stack.
    value -> string *)
val display_value : value -> string

(** A value's type name, as Pyking spells it, for an error message.
    value -> string *)
val describe : value -> string

(** The two operands of a binary operator application.
    expr -> (expr, expr) option *)
val binary_operands : expr -> (expr * expr) option
