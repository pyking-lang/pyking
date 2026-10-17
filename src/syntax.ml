(** The Pyking AST: one constructor per node kind, plus a pretty printer
    that prints it back out as Pyking source. Every stage after parsing
    (analyses, type checker) consumes exactly this. See
    docs/architecture.md.

    Every node carries the source span it was parsed from and its symbol
    (0 until analyses.symbolize hands one out), in that order: the info
    first and the sym last.

    Data structures:
      expr, typ, pattern, comp_clause, assign_target, stmt -- the six
        alternatives-types of the AST.
      param, list_rest, loop_iter, match_case -- the nodes with one
        constructor each.
      config -- what the printers show: symbols, the checker's types.

    Functions:
      pprint_program stmts symbols tmap -- the whole program as source;
        the only entry point callers use.
      pprint_expr / pprint_stmt / pprint_type / pprint_pattern /
        pprint_param / pprint_target -- print one node of that kind.
      expr_info / stmt_info / ... -- the span a node carries.
      expr_sym / stmt_sym / ... -- the symbol a node carries.
      set_expr_info / set_type_info / set_pattern_info /
        set_target_info -- one node with its span replaced. *)

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
         source. *)
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
let expr_info e =
  match e with
  | EInt (i, _, _) -> i
  | EFloat (i, _, _) -> i
  | EString (i, _, _) -> i
  | EBool (i, _, _) -> i
  | EVar (i, _, _) -> i
  | EAdd (i, _, _, _) -> i
  | ESub (i, _, _, _) -> i
  | EMul (i, _, _, _) -> i
  | EDiv (i, _, _, _) -> i
  | ENeg (i, _, _) -> i
  | EConcat (i, _, _, _) -> i
  | ELessThan (i, _, _, _) -> i
  | ELessThanEq (i, _, _, _) -> i
  | EGreatThan (i, _, _, _) -> i
  | EGreatThanEq (i, _, _, _) -> i
  | EEq (i, _, _, _) -> i
  | ECall (i, _, _, _) -> i
  | EList (i, _, _) -> i
  | ETuple (i, _, _) -> i
  | EIf (i, _, _, _, _) -> i
  | EListComp (i, _, _, _) -> i
  | ELambda (i, _, _, _) -> i
  | EQualified (i, _, _, _) -> i
  | EConstruct (i, _, _, _, _) -> i
  | EField (i, _, _, _) -> i

(** The symbol of one expression. expr -> int *)
let expr_sym e =
  match e with
  | EInt (_, _, s) -> s
  | EFloat (_, _, s) -> s
  | EString (_, _, s) -> s
  | EBool (_, _, s) -> s
  | EVar (_, _, s) -> s
  | EAdd (_, _, _, s) -> s
  | ESub (_, _, _, s) -> s
  | EMul (_, _, _, s) -> s
  | EDiv (_, _, _, s) -> s
  | ENeg (_, _, s) -> s
  | EConcat (_, _, _, s) -> s
  | ELessThan (_, _, _, s) -> s
  | ELessThanEq (_, _, _, s) -> s
  | EGreatThan (_, _, _, s) -> s
  | EGreatThanEq (_, _, _, s) -> s
  | EEq (_, _, _, s) -> s
  | ECall (_, _, _, s) -> s
  | EList (_, _, s) -> s
  | ETuple (_, _, s) -> s
  | EIf (_, _, _, _, s) -> s
  | EListComp (_, _, _, s) -> s
  | ELambda (_, _, _, s) -> s
  | EQualified (_, _, _, s) -> s
  | EConstruct (_, _, _, _, s) -> s
  | EField (_, _, _, s) -> s

(** The source span of one type. typ -> info *)
let type_info t =
  match t with
  | TInt (i, _) -> i
  | TFloat (i, _) -> i
  | TString (i, _) -> i
  | TBool (i, _) -> i
  | TList (i, _, _) -> i
  | TTuple (i, _, _) -> i
  | TUnknown (i, _) -> i
  | TBuiltin (i, _, _) -> i
  | TFunction (i, _, _, _, _, _, _) -> i
  | TVar (i, _, _, _) -> i
  | TForall (i, _, _, _) -> i
  | TCon (i, _, _, _) -> i
  | TData (i, _, _) -> i

(** The symbol of one type. typ -> int *)
let type_sym t =
  match t with
  | TInt (_, s) -> s
  | TFloat (_, s) -> s
  | TString (_, s) -> s
  | TBool (_, s) -> s
  | TList (_, _, s) -> s
  | TTuple (_, _, s) -> s
  | TUnknown (_, s) -> s
  | TBuiltin (_, _, s) -> s
  | TFunction (_, _, _, s, _, _, _) -> s
  | TVar (_, _, s, _) -> s
  | TForall (_, _, _, s) -> s
  | TCon (_, _, _, s) -> s
  | TData (_, _, s) -> s

(** The source span of one pattern. pattern -> info *)
let pattern_info p =
  match p with
  | PInt (i, _, _) -> i
  | PString (i, _, _) -> i
  | PBool (i, _, _) -> i
  | PWildcard (i, _) -> i
  | PCapture (i, _, _) -> i
  | PTuple (i, _, _) -> i
  | PList (i, _, _, _, _) -> i
  | PText (i, _, _, _, _) -> i
  | PConstructor (i, _, _, _, _, _) -> i
  | POr (i, _, _) -> i
  | PAs (i, _, _, _) -> i

(** The symbol of one pattern. pattern -> int *)
let pattern_sym p =
  match p with
  | PInt (_, _, s) -> s
  | PString (_, _, s) -> s
  | PBool (_, _, s) -> s
  | PWildcard (_, s) -> s
  | PCapture (_, _, s) -> s
  | PTuple (_, _, s) -> s
  | PList (_, _, _, _, s) -> s
  | PText (_, _, _, _, s) -> s
  | PConstructor (_, _, _, _, _, s) -> s
  | POr (_, _, s) -> s
  | PAs (_, _, _, s) -> s

(** The source span of one list-pattern rest marker. list_rest -> info *)
let rest_info (ListRest (i, _, _)) = i

(** The name a list-pattern rest marker binds, if any.
    list_rest -> string option *)
let rest_name (ListRest (_, name, _)) = name

(** The symbol of one comprehension clause. comp_clause -> int *)
let comp_sym c =
  match c with CompFor (_, _, _, s) -> s | CompIf (_, _, s) -> s

(** The source span of one assignment target. assign_target -> info *)
let target_info t =
  match t with TargetName (i, _, _) -> i | TargetTuple (i, _, _) -> i

(** The symbol of one assignment target. assign_target -> int *)
let target_sym t =
  match t with TargetName (_, _, s) -> s | TargetTuple (_, _, s) -> s

(** The expressions of a call's arguments, dropping any parameter names
    the caller wrote. After Desugar_args there are none.
    [(String?, expr)] -> [expr] *)
let arg_exprs args = List.map snd args

(** A call's arguments with no parameter name written on any of them.
    [expr] -> [(String?, expr)] *)
let plain_args args = List.map (fun e -> (None, e)) args

(** The source span of one parameter. param -> info *)
let param_info (Param (i, _, _, _, _)) = i

(** The symbol of one parameter. param -> int *)
let param_sym (Param (_, _, _, _, s)) = s

(** The source span of one loop iteration clause. loop_iter -> info *)
let loop_iter_info it =
  match it with ForIn (i, _, _, _) -> i | WhileTest (i, _, _) -> i

(** The source span of one case clause. match_case -> info *)
let case_info (MatchCase (i, _, _, _, _)) = i

(** The pattern of one case clause. match_case -> pattern *)
let case_pattern (MatchCase (_, p, _, _, _)) = p

(** The guard of one case clause, where it has one.
    match_case -> expr option *)
let case_guard (MatchCase (_, _, g, _, _)) = g

(** The body of one case clause. match_case -> [stmt] *)
let case_body (MatchCase (_, _, _, b, _)) = b

(** The source span of one statement. stmt -> info *)
let stmt_info s =
  match s with
  | SLet (i, _, _, _, _, _, _) -> i
  | SLetStmt (i, _, _, _, _, _) -> i
  | SVar (i, _, _, _) -> i
  | SMutate (i, _, _, _) -> i
  | SReturn (i, _, _) -> i
  | SReturnStmt (i, _, _) -> i
  | SExprStmt (i, _, _) -> i
  | SLoop (i, _, _, _, _, _, _) -> i
  | SBreak (i, _) -> i
  | SContinue (i, _) -> i
  | SIf (i, _, _, _, _) -> i
  | SFunctionDef (i, _, _, _, _, _, _, _, _) -> i
  | SFunctionSig (i, _, _, _, _) -> i
  | SMatch (i, _, _, _) -> i
  | SImport (i, _, _, _, _, _) -> i
  | SDatatype (i, _, _, _, _, _) -> i

(** The symbol of one statement. stmt -> int *)
let stmt_sym s =
  match s with
  | SLet (_, _, _, _, s, _, _) -> s
  | SLetStmt (_, _, _, _, s, _) -> s
  | SVar (_, _, _, s) -> s
  | SMutate (_, _, _, s) -> s
  | SReturn (_, _, s) -> s
  | SReturnStmt (_, _, s) -> s
  | SExprStmt (_, _, s) -> s
  | SLoop (_, _, _, _, _, _, s) -> s
  | SBreak (_, s) -> s
  | SContinue (_, s) -> s
  | SIf (_, _, _, _, s) -> s
  | SFunctionDef (_, _, _, _, _, s, _, _, _) -> s
  | SFunctionSig (_, _, _, s, _) -> s
  | SMatch (_, _, _, s) -> s
  | SImport (_, _, _, _, _, s) -> s
  | SDatatype (_, _, _, _, s, _) -> s

(* --- one node with its span replaced ---
   What `dataclasses.replace(node, info=...)` does in src/: a
   parenthesized expression, type, pattern or target is the node inside
   with the parentheses' span. *)

(** One expression with its span replaced. info -> expr -> expr *)
let set_expr_info i e =
  match e with
  | EInt (_, v, s) -> EInt (i, v, s)
  | EFloat (_, v, s) -> EFloat (i, v, s)
  | EString (_, v, s) -> EString (i, v, s)
  | EBool (_, v, s) -> EBool (i, v, s)
  | EVar (_, n, s) -> EVar (i, n, s)
  | EAdd (_, l, r, s) -> EAdd (i, l, r, s)
  | ESub (_, l, r, s) -> ESub (i, l, r, s)
  | EMul (_, l, r, s) -> EMul (i, l, r, s)
  | EDiv (_, l, r, s) -> EDiv (i, l, r, s)
  | ENeg (_, o, s) -> ENeg (i, o, s)
  | EConcat (_, l, r, s) -> EConcat (i, l, r, s)
  | ELessThan (_, l, r, s) -> ELessThan (i, l, r, s)
  | ELessThanEq (_, l, r, s) -> ELessThanEq (i, l, r, s)
  | EGreatThan (_, l, r, s) -> EGreatThan (i, l, r, s)
  | EGreatThanEq (_, l, r, s) -> EGreatThanEq (i, l, r, s)
  | EEq (_, l, r, s) -> EEq (i, l, r, s)
  | ECall (_, f, a, s) -> ECall (i, f, a, s)
  | EList (_, es, s) -> EList (i, es, s)
  | ETuple (_, es, s) -> ETuple (i, es, s)
  | EIf (_, c, t, e2, s) -> EIf (i, c, t, e2, s)
  | EListComp (_, e2, cs, s) -> EListComp (i, e2, cs, s)
  | ELambda (_, ps, b, s) -> ELambda (i, ps, b, s)
  | EQualified (_, m, n, s) -> EQualified (i, m, n, s)
  | EConstruct (_, m, n, a, s) -> EConstruct (i, m, n, a, s)
  | EField (_, e2, n, s) -> EField (i, e2, n, s)

(** One type with its span replaced. info -> typ -> typ *)
let set_type_info i t =
  match t with
  | TInt (_, s) -> TInt (i, s)
  | TFloat (_, s) -> TFloat (i, s)
  | TString (_, s) -> TString (i, s)
  | TBool (_, s) -> TBool (i, s)
  | TList (_, e, s) -> TList (i, e, s)
  | TTuple (_, es, s) -> TTuple (i, es, s)
  | TUnknown (_, s) -> TUnknown (i, s)
  | TBuiltin (_, n, s) -> TBuiltin (i, n, s)
  | TFunction (_, ps, r, s, tm, d, ips) -> TFunction (i, ps, r, s, tm, d, ips)
  | TVar (_, n, s, rigid) -> TVar (i, n, s, rigid)
  | TForall (_, vs, b, s) -> TForall (i, vs, b, s)
  | TCon (_, n, args, s) -> TCon (i, n, args, s)
  | TData (_, d, s) -> TData (i, d, s)

(** One pattern with its span replaced. info -> pattern -> pattern *)
let set_pattern_info i p =
  match p with
  | PInt (_, v, s) -> PInt (i, v, s)
  | PString (_, v, s) -> PString (i, v, s)
  | PBool (_, v, s) -> PBool (i, v, s)
  | PWildcard (_, s) -> PWildcard (i, s)
  | PCapture (_, n, s) -> PCapture (i, n, s)
  | PTuple (_, ps, s) -> PTuple (i, ps, s)
  | PList (_, pre, r, suf, s) -> PList (i, pre, r, suf, s)
  | PText (_, pre, r, suf, s) -> PText (i, pre, r, suf, s)
  | PConstructor (_, m, n, ps, named, s) -> PConstructor (i, m, n, ps, named, s)
  | POr (_, ps, s) -> POr (i, ps, s)
  | PAs (_, p2, n, s) -> PAs (i, p2, n, s)

(** One assignment target with its span replaced.
    info -> assign_target -> assign_target *)
let set_target_info i t =
  match t with
  | TargetName (_, n, s) -> TargetName (i, n, s)
  | TargetTuple (_, ts, s) -> TargetTuple (i, ts, s)

(* --- the printers --- *)

module IntMap = Map.Make (Int)
module IntSet = Set.Make (Int)
module StringSet = Set.Make (String)

(** What the printers show. `symbols` appends each node's symbol as @n
    (`--symbols`). `tmap` is the type checker's symbol -> type table
    when one was given, and every annotation then comes from it instead
    of from the source. `signed` holds the definitions whose type is
    written on a `def name : type` line of their own, which print no
    annotations of their own.

    The three travel as one value the printers pass along, rather than
    as flags something sets before the walk and clears after it. *)
type config = {
  symbols : bool;
  tmap : typ IntMap.t option;
  signed : IntSet.t;
}

(** What every printer starts from: no symbols, no inferred types. *)
let default_config = { symbols = false; tmap = None; signed = IntSet.empty }

(** Appends a node's symbol number to text if symbols were asked for.
    A node whose printed form is not already one token or already
    bracketed is parenthesized first: without that, `1 + 2` would print
    as `1@1 + 2@2@3`, where the last @3 looks like it belongs to the 2.
    config -> int -> bool -> string -> string *)
let with_sym cfg sym self_delimited text =
  if not cfg.symbols then text
  else
    let body = if self_delimited then text else "(" ^ text ^ ")" in
    Printf.sprintf "%s@%d" body sym

let expr_self_delimited e =
  match e with
  | EInt _ | EFloat _ | EString _ | EBool _ | EVar _ | EQualified _ | EList _
  | ETuple _ | EListComp _ | EConstruct _ | EField _ ->
      true
  | _ -> false

let type_self_delimited t =
  match t with
  | TInt _ | TFloat _ | TString _ | TBool _ | TList _ | TTuple _ | TCon _ ->
      true
  | _ -> false

let pattern_self_delimited p =
  match p with PText _ | POr _ | PAs _ -> false | _ -> true

(** The type to print for a node: from tmap if one was given, otherwise
    the node's own annotation.
    config -> int -> typ option -> typ option *)
let node_type cfg sym annotation =
  match cfg.tmap with
  | None -> annotation
  | Some m -> IntMap.find_opt sym m

let wrap_prec prec min_prec s = if prec < min_prec then "(" ^ s ^ ")" else s

let escape_print c =
  match c with
  | '\\' -> "\\\\"
  | '\'' -> "\\'"
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(* Always delimit with single quotes and escape whatever the lexer's
   scan_string can decode back, so the output round-trips. *)
let quote_string s =
  let body =
    String.concat "" (List.map escape_print (List.of_seq (String.to_seq s)))
  in
  "'" ^ body ^ "'"

let rec pprint_type cfg t =
  (* The outermost `all` is not printed: every free variable of a
     written annotation is quantified there, so the quantifier carries
     no information the type does not already show. A nested one is
     printed. *)
  match t with
  | TForall (_, _, body, _) ->
      with_sym cfg (type_sym t) (type_self_delimited t)
        (pprint_type_body cfg body)
  | _ ->
      with_sym cfg (type_sym t) (type_self_delimited t)
        (pprint_type_body cfg t)

(** Formats one type with its outermost `all` shown -- what a type
    *inside* another is printed as. config -> typ -> string *)
and pprint_type_nested cfg t =
  with_sym cfg (type_sym t) (type_self_delimited t) (pprint_type_body cfg t)

(** A type as it must be written where something follows it: an `all`
    reaches to the end of the type, so one used as an element or a
    parameter is parenthesized. config -> typ -> string *)
and grouped cfg t =
  match t with
  | TForall _ -> "(" ^ pprint_type_nested cfg t ^ ")"
  | _ -> pprint_type cfg t

and pprint_type_body cfg t =
  match t with
  | TInt _ -> "Int"
  | TFloat _ -> "Float"
  | TString _ -> "String"
  | TBool _ -> "Bool"
  | TList (_, element, _) -> "[" ^ grouped cfg element ^ "]"
  | TTuple (_, elements, _) ->
      (* A singleton keeps the comma that tells it from a grouping,
         exactly as the singleton *value* `(e,)` does. *)
      let inside = String.concat ", " (List.map (grouped cfg) elements) in
      if List.length elements = 1 then "(" ^ inside ^ ",)" else "(" ^ inside ^ ")"
  | TUnknown _ ->
      (* Only ever printed for something the checker was asked about
         before anything had decided it. Deliberately not spellable. *)
      "?"
  | TBuiltin (_, name, _) -> "builtin " ^ name
  | TFunction (_, params, result, _, _, _, implicits) ->
      (* The parentheses are the parameter *list*'s, not a tuple's, so
         one parameter that happens to be a tuple keeps its own pair.
         An implicit parameter prints its name as well as its type: both
         are part of the type, since both are what resolves it. *)
      let written =
        List.map (grouped cfg) params
        @ List.map
            (fun (IParam (name, t)) ->
              Printf.sprintf "implicit %s: %s" name (grouped cfg t))
            implicits
      in
      Printf.sprintf "(%s) -> %s" (String.concat ", " written)
        (pprint_type cfg result)
  | TVar (_, name, _, _) -> name
  | TForall (_, vars, body, _) ->
      Printf.sprintf "all %s. %s" (String.concat " " vars)
        (pprint_type cfg body)
  | TCon (_, name, [], _) -> name
  | TCon (_, name, args, _) ->
      name ^ "(" ^ String.concat ", " (List.map (grouped cfg) args) ^ ")"
  | TData (_, Datatype (name, _, _), _) -> "datatype " ^ name

(** Formats a type in annotation position, without a symbol suffix when
    it came from tmap (a checker-built type has no symbol of its own).
    config -> typ -> string *)
let pprint_annotation_type cfg t =
  match cfg.tmap with
  | None -> pprint_type cfg t
  | Some _ -> pprint_type { cfg with symbols = false } t

(** Whether a type can be written in Pyking's own syntax. `TUnknown`
    prints as `?`, which the lexer does not accept, and `TBuiltin` names
    an operation rather than a value -- so a type holding one of them
    anywhere is printed as no annotation at all. typ -> bool *)
let rec spellable t =
  match t with
  | TUnknown _ | TBuiltin _ | TData _ -> false
  | TCon (_, _, args, _) -> List.for_all spellable args
  | TList (_, element, _) -> spellable element
  | TTuple (_, elements, _) -> List.for_all spellable elements
  | TFunction (_, params, result, _, _, _, implicits) ->
      List.for_all spellable params
      && List.for_all (fun (IParam (_, t)) -> spellable t) implicits
      && spellable result
  | TForall (_, _, body, _) -> spellable body
  | _ -> true

(** Formats `: Type` for a node whose type is known and writable, ""
    otherwise. config -> int -> typ option -> string *)
let annotation cfg sym type_ =
  match node_type cfg sym type_ with
  | None -> ""
  | Some t -> if spellable t then ": " ^ pprint_annotation_type cfg t else ""

(** Formats one expression, parenthesized if needed for min_prec.
    config -> expr -> int -> string *)
let rec pprint_expr cfg e min_prec =
  with_sym cfg (expr_sym e) (expr_self_delimited e)
    (pprint_expr_body cfg e min_prec)

and pprint_expr_body cfg e min_prec =
  (* min_prec is the precedence required by the surrounding context; a
     sub-expression built from a lower-precedence operator is
     parenthesized so re-parsing reproduces the same AST. *)
  match e with
  | EInt (_, v, _) -> string_of_int v
  (* The canonical text, so `-t pyking` output re-parses to the same
     double and an .ast.out stays stable (docs/builtin.md). *)
  | EFloat (_, v, _) -> Builtin.float_text v
  | EString (_, s, _) -> quote_string s
  | EBool (_, v, _) -> if v then "true" else "false"
  | EVar (_, name, _) -> name
  | EQualified (_, module_name, name, _) -> module_name ^ "." ^ name
  | EConstruct (_, module_, name, args, _) ->
      let reached =
        match module_ with Some m -> m ^ "." ^ name | None -> name
      in
      if args = [] then reached
      else Printf.sprintf "%s(%s)" reached (pprint_args cfg args)
  | EField (_, record, name, _) -> pprint_expr cfg record 5 ^ "." ^ name
  | EAdd (_, l, r, _) ->
      wrap_prec 2 min_prec
        (pprint_expr cfg l 2 ^ " + " ^ pprint_expr cfg r 3)
  | ESub (_, l, r, _) ->
      wrap_prec 2 min_prec
        (pprint_expr cfg l 2 ^ " - " ^ pprint_expr cfg r 3)
  | EMul (_, l, r, _) ->
      wrap_prec 3 min_prec
        (pprint_expr cfg l 3 ^ " * " ^ pprint_expr cfg r 4)
  | EDiv (_, l, r, _) ->
      wrap_prec 3 min_prec
        (pprint_expr cfg l 3 ^ " / " ^ pprint_expr cfg r 4)
  | ENeg (_, operand, _) ->
      (* Unary minus binds tighter than `*`/`/`, which is precedence 4
         here. Its operand prints at 5, one above everything with a
         precedence, so any operator underneath is parenthesized while
         an atom or call stays bare. *)
      wrap_prec 4 min_prec ("-" ^ pprint_expr cfg operand 5)
  | EConcat (_, l, r, _) ->
      (* Concatenation sits at the additive level and associates to the
         left, like `+`; the two never mix. *)
      wrap_prec 2 min_prec
        (pprint_expr cfg l 2 ^ " ++ " ^ pprint_expr cfg r 3)
  | ELessThan (_, l, r, _) ->
      wrap_prec 1 min_prec
        (pprint_expr cfg l 2 ^ " < " ^ pprint_expr cfg r 2)
  | ELessThanEq (_, l, r, _) ->
      wrap_prec 1 min_prec
        (pprint_expr cfg l 2 ^ " <= " ^ pprint_expr cfg r 2)
  | EGreatThan (_, l, r, _) ->
      wrap_prec 1 min_prec
        (pprint_expr cfg l 2 ^ " > " ^ pprint_expr cfg r 2)
  | EGreatThanEq (_, l, r, _) ->
      wrap_prec 1 min_prec
        (pprint_expr cfg l 2 ^ " >= " ^ pprint_expr cfg r 2)
  | EEq (_, l, r, _) ->
      wrap_prec 1 min_prec
        (pprint_expr cfg l 2 ^ " == " ^ pprint_expr cfg r 2)
  | ECall (_, f, args, _) ->
      (* The callee prints at 5 so a negated one keeps its parens:
         `(-f)(x)` calls the negation, `-f(x)` negates the result. *)
      Printf.sprintf "%s(%s)" (pprint_expr cfg f 5) (pprint_args cfg args)
  | EList (_, elements, _) ->
      "["
      ^ String.concat ", " (List.map (fun x -> pprint_expr cfg x 0) elements)
      ^ "]"
  | EListComp (_, expr, clauses, _) ->
      let clauses_str =
        String.concat " " (List.map (pprint_comp_clause cfg) clauses)
      in
      Printf.sprintf "[%s %s]" (pprint_expr cfg expr 0) clauses_str
  | ETuple (_, elements, _) -> (
      (* Canonical printed form is always fully parenthesized, with a
         trailing comma for the singleton case. *)
      match elements with
      | [ single ] -> "(" ^ pprint_expr cfg single 0 ^ ",)"
      | _ ->
          "("
          ^ String.concat ", "
              (List.map (fun x -> pprint_expr cfg x 0) elements)
          ^ ")")
  | EIf (_, cond, then_expr, else_expr, _) ->
      (* Precedence 0: lower than every operator. cond/then_expr print
         at 1 so a nested if expression there is parenthesized too; the
         else branch prints at 0 so an `else if` chain stays flat. *)
      wrap_prec 0 min_prec
        (Printf.sprintf "if %s then %s else %s" (pprint_expr cfg cond 1)
           (pprint_expr cfg then_expr 1)
           (pprint_expr cfg else_expr 0))
  | ELambda (_, params, body, _) ->
      (* The parameter list is always parenthesized, which is the form
         the parser reads whatever was written. The body prints at 0 --
         the lambda is the lowest-precedence expression and associates
         to the right, so `x => y => e` stays flat. *)
      wrap_prec 0 min_prec
        (Printf.sprintf "(%s) => %s"
           (String.concat ", " (List.map (pprint_param cfg) params))
           (pprint_expr cfg body 0))

(** Formats a call's arguments, each with the name it was written with.
    config -> [(String?, expr)] -> string *)
and pprint_args cfg args =
  String.concat ", "
    (List.map
       (fun (name, a) ->
         match name with
         | None -> pprint_expr cfg a 0
         | Some n -> n ^ " = " ^ pprint_expr cfg a 0)
       args)

(** Formats one parameter. config -> param -> string *)
and pprint_param cfg (Param (_, name, type_, default, sym)) =
  let text =
    match node_type cfg sym type_ with
    | None -> name
    | Some t ->
        (* A parameter's own `all` is not the signature's outermost one,
           so it is printed. *)
        let printed =
          match t with
          | TForall _ -> grouped cfg t
          | _ -> pprint_annotation_type cfg t
        in
        name ^ ":" ^ printed
  in
  let text =
    match default with
    | None -> text
    | Some e -> text ^ " = " ^ pprint_expr cfg e 0
  in
  with_sym cfg sym false text

(** Formats one list-comprehension clause. config -> comp_clause -> string *)
and pprint_comp_clause cfg c =
  with_sym cfg (comp_sym c) false (pprint_comp_clause_body cfg c)

and pprint_comp_clause_body cfg c =
  (* Both sub-expressions print at min_prec 1 so that an `EIf` is
     parenthesized here: in a comprehension the surrounding grammar
     already spells `for`/`in`/`if`, so an unparenthesized if expression
     would run straight into it. *)
  match c with
  | CompFor (_, pattern, sequence, _) ->
      Printf.sprintf "for %s in %s" (pprint_pattern cfg pattern)
        (pprint_expr cfg sequence 1)
  | CompIf (_, condition, _) -> "if " ^ pprint_expr cfg condition 1

(** Formats one pattern. config -> pattern -> string *)
and pprint_pattern cfg p =
  with_sym cfg (pattern_sym p) (pattern_self_delimited p)
    (pprint_pattern_body cfg p)

and pprint_pattern_body cfg p =
  match p with
  | PInt (_, v, _) -> string_of_int v
  | PString (_, s, _) -> quote_string s
  | PBool (_, v, _) -> if v then "true" else "false"
  | PWildcard _ -> "_"
  | PCapture (_, name, _) -> name
  | PTuple (_, elements, _) -> (
      match elements with
      | [ single ] -> "(" ^ pprint_pattern cfg single ^ ",)"
      | _ ->
          "("
          ^ String.concat ", " (List.map (pprint_pattern cfg) elements)
          ^ ")")
  | PList (_, prefix, rest, suffix, _) ->
      let parts = List.map (pprint_pattern cfg) prefix in
      let parts =
        match rest with
        | None -> parts
        | Some r -> (
            parts
            @ [ (match rest_name r with Some n -> ".." ^ n | None -> "..") ])
      in
      let parts = parts @ List.map (pprint_pattern cfg) suffix in
      "[" ^ String.concat ", " parts ^ "]"
  | PText (_, prefix, rest, suffix, _) ->
      (* Printed in the `++` form it can only have been written in. *)
      let parts = if prefix <> "" then [ quote_string prefix ] else [] in
      let parts =
        parts @ [ (match rest with Some name -> name | None -> "_") ]
      in
      let parts = parts @ (if suffix <> "" then [ quote_string suffix ] else []) in
      String.concat " ++ " parts
  | PConstructor (_, module_, name, positional, named, _) ->
      let reached =
        match module_ with Some m -> m ^ "." ^ name | None -> name
      in
      let parts =
        List.map (pprint_pattern cfg) positional
        @ List.map (fun (n, p) -> n ^ " = " ^ pprint_pattern cfg p) named
      in
      if parts = [] then reached
      else reached ^ "(" ^ String.concat ", " parts ^ ")"
  | POr (_, alternatives, _) ->
      String.concat " | " (List.map (pprint_alternative cfg) alternatives)
  | PAs (_, inner, name, _) -> pprint_alternative cfg inner ^ " as " ^ name

(** Formats a pattern where `|` or `as` follows or surrounds it, which
    parenthesizes one that is itself an `|` or an `as`.
    config -> pattern -> string *)
and pprint_alternative cfg p =
  match p with
  | POr _ | PAs _ -> "(" ^ pprint_pattern cfg p ^ ")"
  | _ -> pprint_pattern cfg p

(** Formats one assignment target. config -> assign_target -> string *)
let rec pprint_target cfg t =
  with_sym cfg (target_sym t) true (pprint_target_body cfg t)

and pprint_target_body cfg t =
  match t with
  | TargetName (_, name, _) -> name
  | TargetTuple (_, elements, _) -> (
      match elements with
      | [ single ] -> "(" ^ pprint_target cfg single ^ ",)"
      | _ ->
          "(" ^ String.concat ", " (List.map (pprint_target cfg) elements) ^ ")")

(** Formats ` -> Type` for a function whose return type is known, ""
    otherwise. config -> int -> typ option -> string *)
let return_annotation cfg sym return_type =
  let return_type =
    match cfg.tmap with
    | None -> return_type
    | Some m -> (
        (* tmap holds the function's whole type; only its result is
           printed here. An `all` around it binds the whole signature,
           so it is stepped through. *)
        match IntMap.find_opt sym m with
        | None -> None
        | Some t -> (
            let t = match t with TForall (_, _, body, _) -> body | _ -> t in
            match t with
            | TFunction (_, _, result, _, _, _, _) -> Some result
            | _ -> Some t))
  in
  match return_type with
  | None -> ""
  | Some t -> if spellable t then " -> " ^ pprint_annotation_type cfg t else ""

(** The `public ` prefix a statement that exports its name carries, or
    "". bool -> string *)
let public_prefix public = if public then "public " else ""

(** The `implicit ` prefix a definition an implicit argument may resolve
    to carries, or "". bool -> string *)
let implicit_prefix implicit = if implicit then "implicit " else ""

(** Formats `def name(params) -> result`, from tmap where given.
    config -> string -> int -> string -> [param] -> typ option -> bool
    -> string *)
let function_header cfg pad sym name params return_type public implicits
    implicit =
  (* A definition whose type is on a `def name : type` line of its own
     says its type in one place or the other: printing both would give a
     program the checker refuses. *)
  let cfg = if IntSet.mem sym cfg.signed then { cfg with tmap = None } else cfg in
  let written =
    List.map (pprint_param cfg) params
    @ List.map (fun p -> "implicit " ^ pprint_param cfg p) implicits
  in
  Printf.sprintf "%s%s%sdef %s(%s)%s" pad (public_prefix public)
    (implicit_prefix implicit) name
    (String.concat ", " written)
    (return_annotation cfg sym return_type)

let split_lines text = String.split_on_char '\n' text

let head_and_rest text =
  match split_lines text with
  | head :: rest -> (head, rest)
  | [] -> ("", [])

let strip s =
  let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let n = String.length s in
  let rec first i = if i < n && is_space s.[i] then first (i + 1) else i in
  let rec last i = if i > 0 && is_space s.[i - 1] then last (i - 1) else i in
  let b = first 0 in
  let e = last n in
  if e <= b then "" else String.sub s b (e - b)

(** Formats one statement, indented to level. A multi-line statement's
    symbol (under --symbols) goes on its header line.
    config -> stmt -> int -> string *)
let rec pprint_stmt cfg s level =
  let text = pprint_stmt_body cfg s level in
  if not cfg.symbols then text
  else
    let head, rest = head_and_rest text in
    String.concat "\n" ((head ^ Printf.sprintf "  @%d" (stmt_sym s)) :: rest)

and pprint_stmt_body cfg s level =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  match s with
  | SLet (_, target, expr, type_, sym, public, implicit) ->
      Printf.sprintf "%s%s%s%s%s = %s" pad (public_prefix public)
        (implicit_prefix implicit) (pprint_target cfg target)
        (annotation cfg sym type_)
        (pprint_expr cfg expr 0)
  | SLetStmt (_, target, stmt, type_, sym, public) ->
      (* The bound statement prints exactly as it would on its own; only
         its header line gains the `target = ` prefix. *)
      let head, rest = head_and_rest (pprint_stmt cfg stmt level) in
      let prefix =
        Printf.sprintf "%s%s%s%s = " pad (public_prefix public)
          (pprint_target cfg target) (annotation cfg sym type_)
      in
      String.concat "\n" ((prefix ^ strip head) :: rest)
  | SVar (_, name, expr, _) ->
      Printf.sprintf "%svar %s = %s" pad name (pprint_expr cfg expr 0)
  | SMutate (_, name, expr, _) ->
      Printf.sprintf "%s%s := %s" pad name (pprint_expr cfg expr 0)
  | SReturn (_, expr, _) ->
      Printf.sprintf "%sreturn %s" pad (pprint_expr cfg expr 0)
  | SReturnStmt (_, stmt, _) ->
      let head, rest = head_and_rest (pprint_stmt cfg stmt level) in
      String.concat "\n" ((pad ^ "return " ^ strip head) :: rest)
  | SExprStmt (_, expr, _) -> pad ^ pprint_expr cfg expr 0
  | SLoop (_, target, init, type_, iterate, body, sym) ->
      (* Printed in the form it was written: the accumulator half where
         one was written -- annotation and all -- and then the iteration
         half, if any. *)
      let head =
        match (target, init) with
        | Some t, Some e ->
            Printf.sprintf "loop %s%s = %s" (pprint_target cfg t)
              (annotation cfg sym type_) (pprint_expr cfg e 0)
        | Some t, None ->
            Printf.sprintf "loop %s%s = " (pprint_target cfg t)
              (annotation cfg sym type_)
        | None, _ -> ""
      in
      let turn =
        match iterate with
        | Some (ForIn (_, name, sequence, _)) ->
            Printf.sprintf "for %s in %s" name (pprint_expr cfg sequence 0)
        | Some (WhileTest (_, condition, _)) ->
            "while " ^ pprint_expr cfg condition 0
        | None -> if head <> "" then "" else "loop"
      in
      let header =
        String.concat " " (List.filter (fun p -> p <> "") [ head; turn ])
      in
      String.concat "\n"
        ((pad ^ header ^ ":")
        :: List.map (fun st -> pprint_stmt cfg st (level + 1)) body)
  | SBreak (_, _) -> pad ^ "break"
  | SContinue (_, _) -> pad ^ "continue"
  | SIf (_, cond, then_body, else_body, _) ->
      let lines =
        (pad ^ "if " ^ pprint_expr cfg cond 0 ^ ":")
        :: List.map (fun st -> pprint_stmt cfg st (level + 1)) then_body
      in
      (* An else body that is exactly one if statement prints flat, as
         the `else if` ladder form -- which is what the parser desugars
         an `else if` into, so this re-parses to the same AST. *)
      let rec ladder lines else_body =
        match else_body with
        | Some [ SIf (_, elif_cond, elif_body, else_body2, _) ] ->
            let lines =
              lines
              @ ((pad ^ "else if " ^ pprint_expr cfg elif_cond 0 ^ ":")
                 :: List.map (fun st -> pprint_stmt cfg st (level + 1)) elif_body)
            in
            ladder lines else_body2
        | None -> lines
        | Some body ->
            lines
            @ ((pad ^ "else:")
               :: List.map (fun st -> pprint_stmt cfg st (level + 1)) body)
      in
      String.concat "\n" (ladder lines else_body)
  | SFunctionSig (_, name, type_, _, public) ->
      Printf.sprintf "%s%sdef %s : %s" pad (public_prefix public) name
        (pprint_type_nested cfg type_)
  | SFunctionDef
      (_, name, params, body, return_type, sym, public, implicits, implicit) ->
      let header =
        function_header cfg pad sym name params return_type public implicits
          implicit
      in
      String.concat "\n"
        ((header ^ ":")
        :: List.map (fun st -> pprint_stmt cfg st (level + 1)) body)
  | SMatch (_, subject, cases, _) ->
      let lines = [ pad ^ "match " ^ pprint_expr cfg subject 0 ^ ":" ] in
      let case_lines (MatchCase (_, pattern, guard, body, _)) =
        let guard =
          match guard with
          | None -> ""
          | Some g -> " if " ^ pprint_expr cfg g 1
        in
        (pad ^ "    case " ^ pprint_pattern cfg pattern ^ guard ^ ":")
        :: List.map (fun st -> pprint_stmt cfg st (level + 2)) body
      in
      String.concat "\n" (lines @ List.concat_map case_lines cases)
  | SDatatype (_, name, params, constructors, _, public) ->
      let params =
        if params = [] then "" else "(" ^ String.concat ", " params ^ ")"
      in
      String.concat "\n"
        (Printf.sprintf "%s%sdatatype %s%s:" pad (public_prefix public) name
           params
        :: List.map
             (fun c -> pad ^ "    " ^ pprint_constructor cfg c)
             constructors)
  | SImport (_, module_name, name, selected, fields, _) ->
      if selected then
        let taken =
          String.concat ", "
            (List.map
               (fun (field, local) ->
                 if field = local then field else field ^ " as " ^ local)
               fields)
        in
        Printf.sprintf "%sfrom %s import %s" pad module_name taken
      else if name = module_name then Printf.sprintf "%simport %s" pad module_name
      else Printf.sprintf "%simport %s as %s" pad module_name name

(** Formats one constructor of a datatype. config -> constructor -> string *)
and pprint_constructor cfg (Constructor (_, name, fields, _)) =
  if fields = [] then name
  else
    let field (Field (_, label, type_, default, _)) =
      let text =
        match label with
        | None -> pprint_type cfg type_
        | Some n -> n ^ ": " ^ pprint_type cfg type_
      in
      match default with
      | None -> text
      | Some e -> text ^ " = " ^ pprint_expr cfg e 0
    in
    name ^ "(" ^ String.concat ", " (List.map field fields) ^ ")"

(** The symbols of definitions that a signature line in their own block
    describes. Those print no annotations, since writing both is a
    program the checker refuses. [stmt] -> IntSet.t *)
let signed_defs stmts =
  let rec block stmts =
    let names =
      List.fold_left
        (fun acc s ->
          match s with
          | SFunctionSig (_, name, _, _, _) -> StringSet.add name acc
          | _ -> acc)
        StringSet.empty stmts
    in
    let here =
      List.fold_left
        (fun acc s ->
          match s with
          | SFunctionDef (_, name, _, _, _, sym, _, _, _)
            when StringSet.mem name names ->
              IntSet.add sym acc
          | _ -> acc)
        IntSet.empty stmts
    in
    List.fold_left (fun acc s -> IntSet.union acc (inside s)) here stmts
  and inside s =
    match s with
    | SLoop (_, _, _, _, _, body, _) -> block body
    | SIf (_, _, then_body, else_body, _) ->
        IntSet.union (block then_body)
          (match else_body with None -> IntSet.empty | Some b -> block b)
    | SFunctionDef (_, _, _, body, _, _, _, _, _) -> block body
    | SMatch (_, _, cases, _) ->
        List.fold_left
          (fun acc c -> IntSet.union acc (block (case_body c)))
          IntSet.empty cases
    | SLetStmt (_, _, inner, _, _, _) -> inside inner
    | SReturnStmt (_, inner, _) -> inside inner
    | _ -> IntSet.empty
  in
  block stmts

(** Formats a whole program as Pyking source. symbols=true appends each
    node's symbol as @n. tmap, if given, is the type checker's symbol ->
    type table; every annotation then comes from it instead of from the
    source. [stmt] -> bool -> typ IntMap.t option -> string *)
let pprint_program stmts symbols tmap =
  let cfg = { symbols; tmap; signed = signed_defs stmts } in
  String.concat "\n" (List.map (fun s -> pprint_stmt cfg s 0) stmts)
