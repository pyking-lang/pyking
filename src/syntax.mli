(** The Pyking AST: one constructor per node kind, plus a pretty printer
    that prints it back out as Pyking source. Every stage after parsing
    (analyses, type checker, every backend) consumes exactly this. See
    docs/architecture.md.

    Every node carries the source span it was parsed from and its symbol
    (0 until analyses.symbolize hands one out), in that order: the info
    first and the sym last. The accessors below are how a pass reads
    either without matching the node itself.

    `config` is abstract: what the printers show is settled by
    `pprint_program`, and `default_config` -- no symbols, no inferred
    types -- is what a caller printing one node for an error message
    wants.

    Data structures:
      expr, typ, pattern, comp_clause, assign_target, stmt -- the six
        alternatives-types of the AST.
      param, list_rest, loop_iter, match_case -- the nodes with one
        constructor each.
      config -- what the printers show.
      IntMap / IntSet / StringSet -- the maps and sets the compiler keys
        by symbol and by name; a `tmap` is a `typ IntMap.t`.

    Functions:
      pprint_program stmts symbols tmap -- the whole program as source.
      pprint_expr / pprint_stmt / pprint_type / pprint_type_nested /
        pprint_pattern -- one node of that kind, for an error message
        or for a prompt.
      default_config -- the config those five start from.
      expr_info / stmt_info / ... -- the span a node carries.
      expr_sym / stmt_sym / ... -- the symbol a node carries.
      rest_name / case_pattern / case_body -- the other fields of the
        one-constructor nodes.
      set_expr_info / set_type_info / set_pattern_info /
        set_target_info -- one node with its span replaced.
      strip s -- a string with leading and trailing blanks removed. *)

open Lexer

(* --- the AST --- *)

type expr =
  | EInt of info * int * int
  | EFloat of info * float * int
  | EString of info * string * int
  | EBool of info * bool * int (* 'true' / 'false' *)
  | EVar of info * string * int
  | EAdd of info * expr * expr * int (* left + right *)
  | ESub of info * expr * expr * int (* left - right *)
  | EMul of info * expr * expr * int (* left * right *)
  | EDiv of info * expr * expr * int (* left / right *)
  | ENeg of info * expr * int (* -operand (unary minus) *)
  | EConcat of info * expr * expr * int (* left ++ right *)
  | ELessThan of info * expr * expr * int (* left < right *)
  | ELessThanEq of info * expr * expr * int (* left <= right *)
  | EGreatThan of info * expr * expr * int (* left > right *)
  | EGreatThanEq of info * expr * expr * int (* left >= right *)
  | EEq of info * expr * expr * int (* left == right *)
  | ECall of info * expr * (string option * expr) list * int
      (* func(args...). Each argument carries the parameter name it was
         written with, where one was: `f(x, n = 1)`. Desugar_args
         removes every name, so nothing after it sees a Some. *)
  | EList of info * expr list * int (* [elements...] *)
  | ETuple of info * expr list * int (* (e1, e2, ...); () is Unit *)
  | EIf of info * expr * expr * expr * int (* if cond then a else b *)
  | EQualified of info * string * string * int
      (* module.name -- a public name of an imported module, reached
         through the name that module was imported under (its own, or an
         `as` alias). *)
  | EListComp of info * expr * comp_clause list * int
      (* [expr for pattern in seq {for ... | if ...}] *)
  | ELambda of info * param list * expr * int
      (* (x, y) => expr -- one parameter needs no parentheses. The body
         is one expression; nothing here holds statements. *)
  | EConstruct of info * string option * string * (string option * expr) list
                  * int
      (* [module.]Name(args...) / [module.]Name -- a datatype's
         constructor applied to its fields, named where the source named
         them. The option is the module the constructor is reached
         through. Desugar_args puts every field in its position, named
         by the field's own name where it has one. *)
  | EField of info * expr * string * int (* expr.name -- a named field *)

and typ =
  | TInt of info * int (* Int *)
  | TFloat of info * int (* Float *)
  | TString of info * int (* String *)
  | TBool of info * int (* Bool *)
  | TList of info * typ * int (* [element] *)
  | TTuple of info * typ list * int (* (e1, e2, ...); zero elements is () *)
  | TUnknown of info * int
      (* ?  -- a type nothing has decided yet. Never written in source. *)
  | TBuiltin of info * string * int
      (* the type of a name denoting a host operation: print, range,
         string, len. Never written in source, never printed. *)
  | TFunction of info * typ list * typ * int * int * stmt option
                 * implicit_param list
      (* (T1, T2, ..., implicit n: T) -> T. The middle two fields are
         the type checker's alone: the symbol of the definition whose
         body is still to be checked, and that definition. Nothing in
         the source produces them and no printer shows them. The last is
         the implicit parameters, which are trailing and are part of the
         type by name as well as by type (PYKING.md, "Implicits"). *)
  | TVar of info * string * int * bool
      (* a lowercase name: a type the caller chooses. The flag is
         `rigid`: false for a variable the checker made rather than the
         source. A symbol of -1 marks an enclosing definition's
         variable in the type of a definition written inside it, which
         prints as `?`. *)
  | TForall of info * string list * typ * int (* all a b. body *)
  | TCon of info * string * typ list * int
      (* Name / Name(T1, ...) / module.Name(...) -- a datatype applied
         to its parameters. In a type the checker made, the name is the
         canonical one: bare for a datatype of the module being checked,
         `module.Name` for one declared in another module. *)
  | TData of info * datatype * int
      (* what a module's signature says about a datatype it exports.
         Never written in source, never printed. *)

and datatype = Datatype of string * string list * (string * (string option * typ) list) list
(* a datatype as another module sees it: its canonical name, its
   parameters, and each constructor with its fields (the name, where the
   field has one, and the type). *)

and implicit_param = IParam of string * typ
(* `implicit name: type`, in a function type. It carries no info and no
   sym: it is part of a type, and a type is synthesized. *)

and pattern =
  | PInt of info * int * int (* case 0: *)
  | PString of info * string * int (* case "foo": *)
  | PBool of info * bool * int (* case true: / case false: *)
  | PWildcard of info * int (* case _: *)
  | PCapture of info * string * int (* case name: *)
  | PTuple of info * pattern list * int (* case (p1, p2, ...): *)
  | PList of info * pattern list * list_rest option * pattern list * int
      (* case [p1, ..., pk]: at most one rest marker, prefix/suffix
         split around it. *)
  | PText of info * string * string option * string * int
      (* case "ab" ++ rest ++ "z": prefix, the name the middle binds to
         (None where it is discarded), suffix. *)
  | PConstructor of info * string option * string * pattern list
                    * (string * pattern) list * int
      (* case [module.]Name(p1, ..., field = p): positional patterns,
         then named ones. Desugar_args puts every field in its position,
         `_` where none was written, so nothing after it sees a named
         one. *)
  | POr of info * pattern list * int (* case p1 | p2 | ...: *)
  | PAs of info * pattern * string * int (* case p as name: *)

and list_rest = ListRest of info * string option * int
(* the `..` / `..name` rest marker inside a PList *)

and comp_clause =
  | CompFor of info * pattern * expr * int (* for pattern in sequence *)
  | CompIf of info * expr * int (* if condition *)

and assign_target =
  | TargetName of info * string * int (* name *)
  | TargetTuple of info * assign_target list * int (* (t1, t2, ...) *)

and param = Param of info * string * typ option * expr option * int
(* name[: type][= default]. Desugar_args removes every default, so
   nothing after it sees a Some. *)

and constructor = Constructor of info * string * field list * int
(* Name(field, ...) -- one alternative of a datatype *)

and field = Field of info * string option * typ * expr option * int
(* Type / name: Type / name = default / name: Type = default -- a field
   of a constructor. A field written with a literal default and no type
   has the literal's type. Desugar_args removes every default. *)

and loop_iter =
  | ForIn of info * string * expr * int (* for name in sequence *)
  | WhileTest of info * expr * int (* while condition *)

and match_case = MatchCase of info * pattern * expr option * stmt list * int
(* case pattern [if guard]: body *)

and stmt =
  | SLet of info * assign_target * expr * typ option * int * bool * bool
      (* [public] [implicit] target[: type] = expr. The type is the
         binding's as the *source* wrote it; the checker records what it
         inferred in its own table instead. The flags are `public` (the
         module exports this name) and `implicit` (an implicit argument
         may be resolved to it). *)
  | SLetStmt of info * assign_target * stmt * typ option * int * bool
      (* target = <if/match statement in value form> *)
  | SVar of info * string * expr * int (* var name = expr *)
  | SMutate of info * string * expr * int (* name := expr *)
  | SReturn of info * expr * int (* return expr *)
  | SReturnStmt of info * stmt * int
      (* return <if/match statement in value form> *)
  | SExprStmt of info * expr * int (* expr used as a statement *)
  | SLoop of
      info
      * assign_target option
      * expr option
      * typ option
      * loop_iter option
      * stmt list
      * int
      (* [loop target[: type] = init] [for n in e | while c] : body.
         Every loop in the language is this one node with different
         halves written. *)
  | SBreak of info * int (* break *)
  | SContinue of info * int (* continue *)
  | SIf of info * expr * stmt list * stmt list option * int
      (* if cond: then_body [else: else_body] *)
  | SFunctionDef of
      info
      * string
      * param list
      * stmt list
      * typ option
      * int
      * bool
      * param list
      * bool
      (* [public] [implicit] def name(params... [, implicit n: T]...)
         [-> return_type]: body. The last two fields are the implicit
         parameters, which are trailing, and whether the definition is
         itself implicit. *)
  | SFunctionSig of info * string * typ * int * bool
      (* [public] def name : type -- a def's type on a line of its own *)
  | SMatch of info * expr * match_case list * int
      (* match subject: case pattern: body ... *)
  | SDatatype of info * string * string list * constructor list * int * bool
      (* [public] datatype Name(a, b): one constructor per line. The
         flag is `public`. *)
  | SImport of info * string * string * bool * (string * string) list * int
      (* import module [as name] / from module import field [as name].
         The fields are the module's own name for each thing taken and
         the name it is known by here; for the plain form the list is
         what a qualified name reaches, filled in by the module
         system. *)

(* --- the span and the symbol each node carries --- *)

(** The source span of one expression. expr -> info *)
val expr_info : expr -> info

(** The symbol of one expression. expr -> int *)
val expr_sym : expr -> int

(** The source span of one type. typ -> info *)
val type_info : typ -> info

(** The symbol of one type. typ -> int *)
val type_sym : typ -> int

(** The source span of one pattern. pattern -> info *)
val pattern_info : pattern -> info

(** The symbol of one pattern. pattern -> int *)
val pattern_sym : pattern -> int

(** The source span of a list pattern's rest marker. list_rest -> info *)
val rest_info : list_rest -> info

(** The name a rest marker captures, or None for a bare `..`.
    list_rest -> string option *)
val rest_name : list_rest -> string option

(** The symbol of one comprehension clause. comp_clause -> int *)
val comp_sym : comp_clause -> int

(** The source span of one assignment target. assign_target -> info *)
val target_info : assign_target -> info

(** The symbol of one assignment target. assign_target -> int *)
val target_sym : assign_target -> int

(** The expressions of a call's arguments, dropping any parameter names
    the caller wrote. After Desugar_args there are none.
    [(String?, expr)] -> [expr] *)
val arg_exprs : (string option * expr) list -> expr list

(** A call's arguments with no parameter name written on any of them.
    [expr] -> [(String?, expr)] *)
val plain_args : expr list -> (string option * expr) list

(** The source span of one parameter. param -> info *)
val param_info : param -> info

(** The symbol of one parameter. param -> int *)
val param_sym : param -> int

(** The source span of a loop's iteration clause. loop_iter -> info *)
val loop_iter_info : loop_iter -> info

(** The source span of one match case. match_case -> info *)
val case_info : match_case -> info

(** The pattern of one match case. match_case -> pattern *)
val case_pattern : match_case -> pattern

(** The body of one match case. match_case -> [stmt] *)
val case_body : match_case -> stmt list

(** The guard of one case clause, where it has one.
    match_case -> expr option *)
val case_guard : match_case -> expr option

(** The source span of one statement. stmt -> info *)
val stmt_info : stmt -> info

(** The symbol of one statement. stmt -> int *)
val stmt_sym : stmt -> int

(** One expression with its span replaced. info -> expr -> expr *)
val set_expr_info : info -> expr -> expr

(** One type with its span replaced. info -> typ -> typ *)
val set_type_info : info -> typ -> typ

(** One pattern with its span replaced. info -> pattern -> pattern *)
val set_pattern_info : info -> pattern -> pattern

(** One assignment target with its span replaced.
    info -> assign_target -> assign_target *)
val set_target_info : info -> assign_target -> assign_target

(* --- the printers --- *)

module IntMap : Map.S with type key = int
module IntSet : Set.S with type elt = int
module StringSet : Set.S with type elt = string

(** What the printers show: whether each node's symbol is appended as
    @n, the type checker's symbol -> type table where one was given, and
    which definitions carry their type on a line of their own. Built by
    `pprint_program`; a caller printing one node starts from
    `default_config`. *)
type config

(** What every printer starts from: no symbols, no inferred types.
    config *)
val default_config : config

(** One type as source text. config -> typ -> string *)
val pprint_type : config -> typ -> string

(** One type as source text, parenthesised where a bare function type
    would read wrongly beside other text. config -> typ -> string *)
val pprint_type_nested : config -> typ -> string

(** One expression as source text, bracketed where its precedence is
    below min_prec. config -> expr -> int -> string *)
val pprint_expr : config -> expr -> int -> string

(** One pattern as source text. config -> pattern -> string *)
val pprint_pattern : config -> pattern -> string

(** One statement as source text, indented `level` levels in.
    config -> stmt -> int -> string *)
val pprint_stmt : config -> stmt -> int -> string

(** A whole program as Pyking source: the only entry point a caller
    printing a program uses. `symbols` appends each node's symbol as @n,
    and every annotation printed comes from `tmap` where one is given
    and from nothing at all where it is not.
    [stmt] -> bool -> typ IntMap.t option -> string *)
val pprint_program : stmt list -> bool -> typ IntMap.t option -> string

(** A string with leading and trailing blanks removed.
    string -> string *)
val strip : string -> string
