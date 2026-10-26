(** The type checker, in a functional style, over one module -- or a
    whole one-file program, which is the same thing. A function whose
    type was not written down is worked out the first time something
    calls it, from its own body: its parameters go in as metavariables
    and the body's demands solve them, which is Hindley-Milner's rule
    reached without a constraint solver. See docs/typesystem.md and
    docs/type_inference.md.

    `type_check stmts sigmaps` is the entry point, and the only one the
    driver, the OCaml backend and the playground use: everything
    inference does -- metavariables, unification, generalising, the
    re-check that keeps a reported type one the checker enforces -- is
    private to this module.

    What is public besides is what checking a session one entry at a
    time needs, which is src/repl.ml's alone: an entry is checked
    against the environment and the store the entries before it left
    behind, so both are threaded out here rather than made and dropped
    inside `type_check`.

    Data structures:
      Type_error -- a type failure, with the source position.
      env -- a name's type, in scope; a name not in it is not in scope.
      sigmap -- what one module exports, and at what type.
      given -- one `return`, or the value a body ends in.
      frame -- what the current inference has gathered.
      expected -- what a `return` is checked against.
      store -- everything inference has worked out, threaded as a value.
      SMap -- the map from a name that `env` is made of.

    Functions:
      type_check stmts sigmaps -- checks a whole module; answers its tmap.
      builtin_env () -- the environment a program starts in.
      empty_store sigmaps -- the store a program starts checking in.
      declare_functions stmts env store -- binds every def of a block.
      import_env stmts env store -- binds what a block's imports bring in.
      check_stmt / check_expr -- one statement, one expression.
      same_type a b -- whether two types are the same type.
      declare_datatypes stmts store -- the datatypes a module declares
        and imports.
      check_matches stmts store -- refuses a non-exhaustive `match`.
      zonk type_ store -- a type read back through what was solved.
      displayed type_ store -- the same, with what is still open named.
      settled_type type_ store -- what a deferred function turned out
        to be. *)

open Lexer
open Syntax

(** A type-check failure, or a refusal of an unsupported construct, with
    the source position. *)
exception Type_error of info * string

module SMap : Map.S with type key = string

(** What a name denotes: its type, and whether the binding was written
    `implicit`, which is what an implicit argument may be resolved to. *)
type binding = { btype : typ; bimplicit : bool }

(** A name's denotation, in scope. `env` maps a name to one and to
    nothing else: a name it does not hold is a name that is not in
    scope. The host operations are in it under TBuiltin, which is a type
    like any other here. *)
type env = binding SMap.t

(** What one module exports, at what type, and whether it is implicit --
    all of it another module sees (Module.make_sigmap). *)
type sigmap = (string * typ * bool) list

(** What one node denotes once overloading and implicits are resolved. *)
type resolution =
  | Call of (string * typ) option * argument list
      (** a call: the name overload resolution chose for it and that
          definition's type, and one argument per implicit parameter *)
  | Adapted of typ * int * argument list
      (** an argument whose implicit parameters are not the ones wanted:
          a lambda of that type stands in its place, passing the first
          `int` of its own parameters to what was written *)

and argument =
  | Direct of string * typ  (** a name in scope, used at this type *)
  | Wrapped of string * typ * int * argument list
      (** a lambda of that function type, passing the first `int` of its
          own parameters to the name and then these *)

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
    value: where each definition was written and what it was worked out
    to be, which metavariables are solved and to what, the definitions
    being checked right now, the `def name : type` lines and the block
    each definition was written in, what could not be generalised, the
    signature of every module this one imports, and `tmap` -- symbol ->
    the type worked out for that node, which is the pass's result.

    None of it is written to: a function given a store answers with one,
    because what it worked out is knowledge its caller needs. The fields
    are visible because src/repl.ml carries a session's store from one
    entry to the next and starts each entry's table empty; nothing else
    reads them. docs/type_inference.md describes each. *)
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
  pending_plus : (typ * info) list;
}

(** Type-checks one module -- or a whole one-file program, which is the
    same thing. `sigmaps` pairs the name of every module this one imports
    with what that module exports and at what type, which is all of it
    this check can see (module.ml). Raises Type_error for the first thing
    that does not check out, and Analyses.Analysis_error for a name that
    is not in scope, since this pass is the one that checks names.
    `declared` is the module's own declaration half -- the names a
    target's own source provides -- which are in scope here unqualified,
    since the two files are one module.
    Answers the types it worked out and, beside them, what every call
    it resolved denotes -- which is what `elaborate.ml` rewrites the
    program by (docs/implicits.md).
    [(string, typ)] -> [stmt] -> [(string, sigmap)]
    -> (typ IntMap.t, resolution IntMap.t) *)
val type_check :
  ?declared:(string * typ) list ->
  stmt list ->
  (string * sigmap) list ->
  typ IntMap.t * resolution IntMap.t

(** The environment a program starts in: every name in
    Builtin.names, at its TBuiltin type. () -> env *)
val builtin_env : unit -> env

(** The store a program starts checking in, holding the signature of
    every module it imports. [(string, sigmap)] -> store *)
val empty_store : (string * sigmap) list -> store

(** env with every def of a block bound, and the store recording where
    each deferred one was written. Not recursive: a def inside a branch
    is declared when that branch's block is checked.
    [stmt] -> env -> store -> (env, store) *)
val declare_functions : stmt list -> env -> store -> env * store

(** store knowing the datatypes these statements declare and the ones
    their imports bring in: every name spelled as the source may spell
    it, every constructor, and each field's type. What an entry at the
    prompt does before it is checked. [stmt] -> store -> store *)
val declare_datatypes : stmt list -> store -> store

(** Refuses a `match` in these statements that does not match every
    value, or that has a case no value can reach (exhaustive.ml). Run
    once the statements are checked. [stmt] -> store -> () *)
val check_matches : stmt list -> store -> unit

(** env extended with everything a module's imports bring into scope: a
    selected name under the name it is known by here, and a field of a
    plain import under `alias.field`. Every module imported has to be in
    the store's `modules`. What an entry at the prompt does with its
    imports before it is checked. [stmt] -> env -> store -> env *)
val import_env : stmt list -> env -> store -> env

(** Checks one statement. Answers what it supplies, the environment the
    statements after it should see, and the store.
    stmt -> env -> expected -> typ option -> store
    -> (typ option, env, store) *)
val check_stmt :
  stmt -> env -> expected -> typ option -> store -> typ option * env * store

(** The type of one expression, recorded in the store's table under its
    symbol. expr -> env -> store -> (typ, store) *)
val check_expr : expr -> env -> store -> typ * store

val without_implicits : typ -> typ
(** The type a definition has once its implicit parameters are ordinary
    ones: what every stage after `elaborate.ml` sees of it. typ -> typ *)

(** Whether two types are the same type, structurally -- never OCaml's
    own equality, since a type node carries an info and a symbol that
    also differ. typ -> typ -> bool *)
val same_type : typ -> typ -> bool


(** type_ with every metavariable in it replaced by what it was solved
    to, as deep as the solutions go. This is what turns a type the
    checker was still working on into one it can report.
    typ -> store -> typ *)
val zonk : typ -> store -> typ

(** type_ with the metavariables nothing solved named `a`, `b`, ... A
    metavariable is not a type anyone can write, but one left open
    stands for a type nothing decided -- which is what a variable says.
    typ -> store -> typ *)
val displayed : typ -> store -> typ

(** What a deferred function turned out to be, once something has worked
    it out. A definition is worked out once, so from the second call on
    it is an ordinary scheme, read back through whatever has since been
    solved. typ -> store -> typ *)
val settled_type : typ -> store -> typ
