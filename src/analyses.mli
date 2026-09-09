(** Static analyses over the Pyking AST (syntax.ml): mutability
    checking, symbolizing (giving every node a unique integer id), and
    which expressions can produce output. The first two run after
    parsing and before any backend; the third is asked for by the
    backends whose host language leaves evaluation order unspecified.
    See PYKING.md, "Names and scoping", and docs/analyses.md.

    Names and types are typesystem.ml's, which every mode runs: a name
    that is not in scope is refused there, in this module's words. What
    is left here is the one rule types do not state -- which names may
    be written to with `:=`, and that nothing may shadow one that can
    be.

    `analyze_mutability` is the whole of that check, and the walk it is
    made of -- the per-statement cases, and everything that binds a name
    -- is this module's own. `env` and `binding` are exported because
    the REPL carries a session's bindings between entries.

    Data structures:
      Analysis_error -- a name/scoping failure, with the source position.
      kind -- what kind of binding introduced a name.
      binding -- what the environment records for one name in scope.
      env -- a name's binding, in scope.
      effects -- which calls in a program can end up printing.
      SMap -- the map from a name that `env` is made of.

    Functions:
      analyze_mutability stmts -- checks a whole program's mutability.
      analyze_stmts stmts env -- analyzes a statement sequence and
        answers the environment it leaves behind.
      bound_names stmt -- the (name, info) pairs a statement binds in
        its block.
      block_functions stmts -- the defs of a block, in source order.
      builtins -- the names a program may call without binding them.
      symbolize stmts -- gives every node a unique integer sym.
      highest_sym stmts -- the largest sym anywhere in a program.
      apply_signatures stmts -- folds every `def name : type` line onto
        the definition it describes.
      effects stmts -- which functions in a program can print.
      may_print effects expr -- whether evaluating expr can print. *)

(** A name/scoping failure, with the source position. *)
exception Analysis_error of Lexer.info * string

(** What kind of binding introduced a name. The text `kind_name` gives
    is what an error message calls it. *)
type kind =
  | Mutable (* var name = ... *)
  | Value (* name = ... *)
  | Parameter (* def f(name) *)
  | Loop_var (* for name in ... / loop name = ... *)
  | Pattern_var (* case ...name...: *)
  | Function (* def name(...) *)
  | Builtin (* see `builtins` *)
  | Imported (* import m / from m import name *)

module SMap : Map.S with type key = string

(** What the environment records for one name in scope: how it was
    bound, and where -- None for a builtin, which has no source
    position. *)
type binding = { kind : kind; info : Lexer.info option }

(** A name's binding, in scope. A name not in it is not bound here. *)
type env = binding SMap.t

(** Which functions in a program can print. Built by `effects` and read
    by `may_print`; a backend does neither of those itself. *)
type effects

(** Names that are not bound in a Pyking program but that the generated
    code calls directly. [string] *)
val builtins : string list

(** The names a statement binds in the block it is written in (excludes
    for/pattern/parameter names, and a def's own name), as (name, info)
    pairs. stmt -> [(string, info)] *)
val bound_names : Syntax.stmt -> (string * Lexer.info) list

(** The function definitions written in a block, in source order.
    Raises Analysis_error if two defs in the block share a name, or if
    any other binding in the block shares a def's name.
    [stmt] -> [(string, stmt)] *)
val block_functions : Syntax.stmt list -> (string * Syntax.stmt) list

(** Analyzes a statement sequence and answers the environment it leaves
    behind, which is how a sequence accumulates bindings. Raises
    Analysis_error on the first problem. [stmt] -> env -> env *)
val analyze_stmts : Syntax.stmt list -> env -> env

(** Checks that every `:=` names a `var`, and that nothing shadows one.
    Raises Analysis_error on the first problem; never rewrites the AST.
    [stmt] -> () *)
val analyze_mutability : Syntax.stmt list -> unit

(** The largest sym anywhere in a program, or 0 if none is symbolized.
    [stmt] -> int *)
val highest_sym : Syntax.stmt list -> int

(** Rebuilds stmts so every node has a unique sym, numbered post-order
    starting after `start` (0 means "not symbolized"). A node that
    already has a symbol keeps it; safe to run more than once. A program
    of several modules passes each module the highest symbol the one
    before it reached, so no two nodes in it share a symbol -- which is
    what lets one call-free table and one type table span the whole
    program. int -> [stmt] -> [stmt] *)
val symbolize : ?start:int -> Syntax.stmt list -> Syntax.stmt list

(** Folds every `def name : type` line onto the definition it describes,
    so a printed program shows the type where the source wrote it.
    [stmt] -> [stmt] *)
val apply_signatures : Syntax.stmt list -> Syntax.stmt list

(** Which functions in a program can print, by a fixed-point walk of the
    call graph. [stmt] -> effects *)
val effects : Syntax.stmt list -> effects

(** Whether evaluating an expression can produce output.
    effects -> expr -> bool *)
val may_print : effects -> Syntax.expr -> bool
