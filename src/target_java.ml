(** The Java code-generation backend, serving java8, java17 and java21.
    Like target_ocaml.ml it infers no types of its own: every type it
    writes is read out of the checker's tmap, so Pyking's polymorphism is
    Java's generics, a list is a `java.util.List`, a tuple a class of the
    shared runtime, a datatype a class per constructor, and a function
    value a `java.util.function` interface. The three versions are three
    shapes of output: plain classes and casts for java8, records, sealed
    interfaces and `instanceof` patterns for java17, and records with a
    pattern `switch` for every `match` on java21.
    See docs/target_java.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      shape -- which of the three outputs is being written.
      jexpr / jstmt -- the Java AST: an expression is its text, its
        precedence and whether its static type is boxed.
      binding / scope -- what a Pyking name stands for in Java.
      state -- what the translation of one module accumulates.
      jprogram -- a translated module.

    Functions:
      translate_program stmts tmap context version -- one module.
      default_class_name stem -- the Java class name for a source stem.
      pprint_java_program program version class_name source -- the
        compilation unit.
      runtime_source programs version -- the shared PykRuntime.java. *)

open Lexer
open Syntax

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of info * string

(** Raises Unsupported at info with message. info -> string -> 'a *)
let unsupported info message = raise (Unsupported (info, message))

module SMap = Map.Make (String)

(* --- versions --- *)

type shape = Java8 | Java17 | Java21

(** The shape a target's output takes. string -> shape *)
let shape_of version =
  match version with "java8" -> Java8 | "java17" -> Java17 | _ -> Java21

(** The `--release` a target compiles with. string -> string *)
let release_of version =
  match version with "java8" -> "8" | "java17" -> "17" | _ -> "21"

let default_class_name = Module.class_name

(* The class every module of a program shares: tuples, the value
   printer, the conversions. *)
let runtime_class = "PykRuntime"
let runtime_file = runtime_class ^ ".java"

(* --- Java expressions ---
   Text with the precedence of its outermost operator, and whether its
   static type is a boxed one: `==` on two Integers compares objects, so
   a boxed operand is unboxed first. *)

type jexpr = { text : string; prec : int; boxed : bool }

let p_lambda = 1
let p_cond = 3
let p_or = 4
let p_and = 5
let p_eq = 9
let p_rel = 10
let p_add = 12
let p_mul = 13
let p_unary = 14
let p_atom = 16

let mk ?(boxed = false) prec text = { text; prec; boxed }
let atom ?(boxed = false) text = mk ~boxed p_atom text

(** e's text, parenthesized where its precedence is below prec.
    int -> jexpr -> string *)
let at prec e = if e.prec < prec then "(" ^ e.text ^ ")" else e.text

(** A left-associative binary operation. int -> string -> jexpr -> jexpr
    -> jexpr *)
let binary prec op l r = mk prec (at prec l ^ " " ^ op ^ " " ^ at (prec + 1) r)

(** The conjunction of conditions, or "true" for none. [jexpr] -> jexpr *)
let conjunction conds =
  match conds with
  | [] -> atom "true"
  | first :: rest -> List.fold_left (fun acc c -> binary p_and "&&" acc c) first rest

let null_expr = atom ~boxed:true "null"

(* --- Java statements --- *)

type jstmt =
  | JLine of string (* one simple statement, with its `;` *)
  | JIf of string * jstmt list * jstmt list option
  | JWhile of string * string option * jstmt list
      (* label (printed only if a break names it), condition (None is
         `true`), body *)
  | JFor of string * string * jstmt list (* label, `T x : xs`, body *)
  | JBlock of string option * jstmt list (* [label:] { ... } *)
  | JSwitch of string * (string * jstmt list) list
      (* selector, then each arm's label and body *)
  | JReturn of string option
  | JThrow
  | JBreak of string option
  | JContinue

(** Whether an unlabeled break in stmts leaves the statement holding
    them (one inside a nested loop or switch leaves that instead).
    [jstmt] -> bool *)
let rec breaks_plain stmts =
  List.exists
    (fun s ->
      match s with
      | JBreak None -> true
      | JIf (_, t, e) -> breaks_plain t || (match e with Some e -> breaks_plain e | None -> false)
      | JBlock (_, b) -> breaks_plain b
      | _ -> false)
    stmts

(** Whether a break naming label is anywhere in stmts. string -> [jstmt]
    -> bool *)
let rec breaks_label label stmts =
  List.exists
    (fun s ->
      match s with
      | JBreak (Some l) -> l = label
      | JIf (_, t, e) ->
          breaks_label label t
          || (match e with Some e -> breaks_label label e | None -> false)
      | JBlock (_, b) | JWhile (_, _, b) | JFor (_, _, b) -> breaks_label label b
      | JSwitch (_, arms) -> List.exists (fun (_, b) -> breaks_label label b) arms
      | _ -> false)
    stmts

(** Whether s can complete normally, as javac decides it (JLS 14.22).
    jstmt -> bool *)
let rec completes s =
  match s with
  | JLine _ -> true
  | JIf (_, _, None) -> true
  | JIf (_, t, Some e) -> block_completes t || block_completes e
  | JWhile (label, None, body) -> breaks_plain body || breaks_label label body
  | JWhile (_, Some _, _) | JFor _ -> true
  | JBlock (label, body) ->
      block_completes body
      || (match label with Some l -> breaks_label l body | None -> false)
  | JSwitch (_, arms) ->
      List.exists (fun (_, b) -> block_completes b || breaks_plain b) arms
  | JReturn _ | JThrow | JBreak _ | JContinue -> false

and block_completes stmts = List.for_all completes stmts

(** stmts up to and including the first that cannot complete: javac
    refuses a statement it can prove unreachable. [jstmt] -> [jstmt] *)
let rec reachable stmts =
  match stmts with
  | [] -> []
  | s :: rest -> if completes s then s :: reachable rest else [ s ]

(* --- names --- *)

let java_keywords =
  StringSet.of_list
    (String.split_on_char ' '
       "abstract assert boolean break byte case catch char class const \
        continue default do double else enum extends final finally float for \
        goto if implements import instanceof int interface long native new \
        package private protected public return short static strictfp super \
        switch synchronized this throw throws transient try void volatile \
        while true false null var yield record sealed permits when exports \
        module open requires _")

(* The java.lang names this backend writes unqualified, which a class of
   the program's own must not take. *)
let java_lang =
  StringSet.of_list
    (String.split_on_char ' '
       "String Integer Double Boolean Object Void System Math \
        IllegalStateException Override Long StringBuilder Character Thread \
        Runnable PykRuntime Error Exception Iterable Number Comparable Record \
        Enum Class Throwable RuntimeException SuppressWarnings")

(** name as a legal Java identifier. string -> string *)
let java_ident name = if StringSet.mem name java_keywords then name ^ "$" else name

(** What a datatype's constructor is called in Java, in the module whose
    class is module_class. string -> string -> string *)
let ctor_class module_class name =
  if StringSet.mem name java_lang || name = module_class then name ^ "_" else name

(** What a datatype's own type is called in Java: its name, unless one of
    its constructors already is. string -> datatype -> string *)
let type_class module_class (Datatype (canonical, _, ctors)) =
  let name =
    match String.rindex_opt canonical '.' with
    | Some at -> String.sub canonical (at + 1) (String.length canonical - at - 1)
    | None -> canonical
  in
  let base = ctor_class module_class name in
  if List.exists (fun (c, _) -> ctor_class module_class c = base) ctors then base ^ "$T"
  else base

(** The Java name of a constructor's field: its own, or `f$k` for the k-th
    field where it has none. string option -> int -> string *)
let field_name label index =
  match label with
  | Some l when String.length l > 0 && l.[0] <> '#' ->
      if
        StringSet.mem l java_keywords
        || List.mem l [ "pykTag"; "pykFields"; "hashCode"; "toString"; "equals"; "getClass"; "notify"; "wait"; "clone"; "finalize" ]
      then l ^ "$"
      else l
  | _ -> Printf.sprintf "f$%d" index

(** A canonical datatype name split into its module, where it is
    another's, and its own name. string -> (string?, string) *)
let split_canonical canonical =
  match String.rindex_opt canonical '.' with
  | Some at ->
      ( Some (String.sub canonical 0 at),
        String.sub canonical (at + 1) (String.length canonical - at - 1) )
  | None -> (None, canonical)

(* --- polymorphic parameters ---
   A parameter of a type `all a. ...` is an interface with one generic
   method, shared by the whole program through the runtime; two
   parameter types of one shape share it. *)

(** Every type variable named in a type. typ -> [string] *)
let rec type_vars type_ =
  match type_ with
  | TVar (_, v, _, _) -> [ v ]
  | TList (_, e, _) -> type_vars e
  | TTuple (_, es, _) | TCon (_, _, es, _) -> List.concat_map type_vars es
  | TFunction (_, ps, r, _, _, _, _) -> List.concat_map type_vars ps @ type_vars r
  | TForall (_, _, b, _) -> type_vars b
  | _ -> []

let no_info = { file = "<java>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** A polymorphic parameter type's body with its own variables renamed
    `b0`, `b1`, ... and every part naming none of them a hole `h0`, `h1`,
    ...; answers that body, the holes in order and how many variables it
    binds. typ -> (typ, [typ], int) *)
let poly_split forall =
  let index v bound =
    let rec go i = function [] -> 0 | x :: rest -> if x = v then i else go (i + 1) rest in
    go 0 bound
  in
  let rec shape bound holes t =
    if not (List.exists (fun v -> List.mem v bound) (type_vars t)) then
      (TVar (no_info, Printf.sprintf "h%d" (List.length holes), 0, true), holes @ [ t ])
    else
      match t with
      | TVar (i, v, s, r) -> (TVar (i, Printf.sprintf "b%d" (index v bound), s, r), holes)
      | TList (i, e, s) ->
          let e, holes = shape bound holes e in
          (TList (i, e, s), holes)
      | TTuple (i, es, s) ->
          let es, holes = shape_all bound holes es in
          (TTuple (i, es, s), holes)
      | TCon (i, c, es, s) ->
          let es, holes = shape_all bound holes es in
          (TCon (i, c, es, s), holes)
      | TFunction (i, ps, r, a, b, c, d) ->
          let ps, holes = shape_all bound holes ps in
          let r, holes = shape bound holes r in
          (TFunction (i, ps, r, a, b, c, d), holes)
      | t -> (t, holes)
  and shape_all bound holes ts =
    List.fold_left
      (fun (out, holes) t ->
        let t, holes = shape bound holes t in
        (out @ [ t ], holes))
      ([], holes) ts
  in
  match forall with
  | TForall (_, vs, body, _) ->
      let shaped, holes = shape vs [] body in
      (shaped, holes, List.length vs)
  | t -> (t, [], 0)

(** The runtime interface a polymorphic parameter type is passed as.
    typ -> string *)
let poly_name forall =
  let shaped, _, count = poly_split forall in
  let key = Printf.sprintf "%d.%s" count (pprint_type default_config shaped) in
  "Poly$" ^ String.sub (Digest.to_hex (Digest.string key)) 0 8

(* --- what a translation reads --- *)

type ctx = {
  tmap : typ IntMap.t;
  shape : shape;
  context : Module.context;
  own_class : string;
  (* Every datatype this module can see, by canonical name. *)
  datatypes : datatype SMap.t;
  (* What each name a module was imported under names. *)
  modules : (string * string) list;
  (* The simple names a type parameter must not take. *)
  class_names : StringSet.t;
  (* Translating the top level, which declares no type variables: every
     one is written Object. *)
  erase : bool;
}

(** A type variable's Java name. ctx -> string -> string *)
let tvar ctx v =
  let c = String.capitalize_ascii v in
  if StringSet.mem c ctx.class_names || StringSet.mem c java_lang then "T$" ^ v else c

(** How the class of another module is written. string -> string *)
let module_class name = default_class_name name

(** A datatype's type as written here. ctx -> string -> string *)
let datatype_ref ctx canonical =
  match (SMap.find_opt canonical ctx.datatypes, split_canonical canonical) with
  | Some d, (Some m, _) -> module_class m ^ "." ^ type_class (module_class m) d
  | Some d, (None, _) -> type_class ctx.own_class d
  | None, (Some m, n) -> module_class m ^ "." ^ n
  | None, (None, n) -> n

(** A constructor's class as written here. ctx -> string -> string -> string *)
let ctor_ref ctx canonical name =
  match split_canonical canonical with
  | Some m, _ -> module_class m ^ "." ^ ctor_class (module_class m) name
  | None, _ -> ctor_class ctx.own_class name

(** A Pyking type as Java writes it; `boxed` where Java needs a reference
    type, as a type argument does. ctx -> bool? -> typ -> string *)
let rec jt ctx ?(boxed = false) ?(erase = false) t =
  let erase = erase || ctx.erase in
  let jt ctx ?(boxed = false) t = jt ctx ~boxed ~erase t in
  let targs ctx ts = String.concat ", " (List.map (jt ctx ~boxed:true) ts) in
  let fn_type ctx ps r = fn_type_with (fun t -> jt ctx ~boxed:true t) ps r in
  match t with
  | TInt _ -> if boxed then "Integer" else "int"
  | TFloat _ -> if boxed then "Double" else "double"
  | TBool _ -> if boxed then "Boolean" else "boolean"
  | TString _ -> "String"
  | TTuple (_, [], _) -> "Void"
  | TTuple (_, es, _) -> Printf.sprintf "%s.T%d<%s>" runtime_class (List.length es) (targs ctx es)
  | TList (_, e, _) -> "java.util.List<" ^ jt ctx ~boxed:true e ^ ">"
  | TFunction (_, ps, r, _, _, _, imps) -> fn_type ctx (ps @ List.map (fun (IParam (_, t)) -> t) imps) r
  | TVar (_, v, _, _) -> if erase || (String.length v > 0 && (v.[0] = '?' || v.[0] = '_')) then "Object" else tvar ctx v
  | TCon (_, canonical, args, _) ->
      datatype_ref ctx canonical ^ if args = [] then "" else "<" ^ targs ctx args ^ ">"
  | TForall _ as p ->
      let _, holes, _ = poly_split p in
      runtime_class ^ "." ^ poly_name p
      ^ if holes = [] then "" else "<" ^ targs ctx holes ^ ">"
  | _ -> "Object"

and targs ctx ts = String.concat ", " (List.map (jt ctx ~boxed:true) ts)

(** A function type's interface, each type written by write:
    java.util.function's for up to two parameters, the runtime's beyond.
    (typ -> string) -> [typ] -> typ -> string *)
and fn_type_with write ps r =
  let r = write r in
  match ps with
  | [] -> "java.util.function.Supplier<" ^ r ^ ">"
  | [ a ] -> "java.util.function.Function<" ^ write a ^ ", " ^ r ^ ">"
  | [ a; b ] -> "java.util.function.BiFunction<" ^ write a ^ ", " ^ write b ^ ", " ^ r ^ ">"
  | ps -> Printf.sprintf "%s.Fn%d<%s, %s>" runtime_class (List.length ps) (String.concat ", " (List.map write ps)) r

(** The method a function value is called through. int -> string *)
let apply_method arity = if arity = 0 then "get" else "apply"

let is_unit t = match t with TTuple (_, [], _) -> true | _ -> false
let is_scalar t = match t with TInt _ | TFloat _ | TBool _ -> true | _ -> false

(** A def's function type, its own type variables and its implicit
    parameters made ordinary. typ -> ([string], [typ], typ) *)
let function_parts t =
  let vars, t =
    match t with TForall (_, vs, body, _) -> (vs, body) | t -> ([], t)
  in
  match Typesystem.without_implicits t with
  | TFunction (_, ps, r, _, _, _, _) -> (vars, ps, r)
  | _ -> (vars, [], t)

(** Every type variable of a type that a method must declare.
    typ -> [string] *)
let declared_vars t =
  List.filter (fun v -> String.length v > 0 && v.[0] <> '?' && v.[0] <> '_') (type_vars t)

(** Whether nothing has worked a type out: a def nothing calls, whose
    body the checker never reached. typ -> bool *)
let rec has_unknown t =
  match t with
  | TUnknown _ -> true
  | TList (_, e, _) -> has_unknown e
  | TTuple (_, es, _) | TCon (_, _, es, _) -> List.exists has_unknown es
  | TFunction (_, ps, r, _, _, _, _) -> List.exists has_unknown ps || has_unknown r
  | TForall (_, _, b, _) -> has_unknown b
  | _ -> false

(** Whether a def is dead: nothing in its block reaches it but defs that
    are dead themselves. The checker works out a def's types the first
    time something calls it, so it never reached one of these, and
    nothing needs one. stmt -> [stmt] -> bool *)
let unreferenced def block =
  let names_in stmts =
    Walk.fold_stmts
      (fun found node -> match node with Walk.NExpr (EVar (_, n, _)) -> StringSet.add n found | _ -> found)
      StringSet.empty stmts
  in
  let defs =
    List.filter_map
      (fun s -> match s with SFunctionDef (_, n, _, _, _, _, false, _, _) -> Some (n, s) | _ -> None)
      block
  in
  let roots =
    List.fold_left
      (fun found s ->
        match s with
        | SFunctionDef (_, _, _, _, _, _, false, _, _) -> found
        | s -> StringSet.union found (names_in [ s ]))
      StringSet.empty block
  in
  let rec grow live =
    let more =
      List.fold_left
        (fun live (n, s) -> if StringSet.mem n live then StringSet.union live (names_in [ s ]) else live)
        live defs
    in
    if StringSet.equal more live then live else grow more
  in
  match def with
  | SFunctionDef (_, name, _, _, _, _, false, _, _) -> not (StringSet.mem name (grow roots))
  | _ -> false

(** names once each, in order. [string] -> [string] *)
let distinct names =
  List.fold_left (fun out n -> if List.mem n out then out else out @ [ n ]) [] names

(* --- what a Pyking name stands for --- *)

type meth = {
  jname : string; (* the method, qualified where it is another class's *)
  lifted : bool; (* a nested def, taking what it captures first *)
  void : bool;
  mtype : typ; (* its function type, as declared *)
  external_ : bool; (* the host's: callbacks cross as java.util.function *)
}

type kind =
  | BLocal (* a final local or a parameter *)
  | BMutable (* a local that is reassigned: a `var` or an accumulator *)
  | BCell (* a `var` a closure captures: a one-element array *)
  | BStatic (* a static field *)
  | BErased (* a static field whose type has variables Java cannot give it *)
  | BMethod of meth
  | BExpr (* a name a pattern bound to a place in a value *)

type binding = { value : jexpr; kind : kind; btype : typ; jname_ : string }

type loopinfo = {
  label : string;
  slots : (string * typ) list; (* the Java locals the next turn's values go in *)
}

type scope = {
  names : binding SMap.t;
  loops : loopinfo list; (* innermost last *)
  in_switch : bool; (* a `break` here would leave a switch, not the loop *)
  tvars : string list; (* the type variables in scope, as Pyking names *)
  cells : StringSet.t; (* `var`s a closure captures, so held in a cell *)
  block : stmt list; (* the block being translated, for a def nothing names *)
}

(* A lifted method's captures: what its own body reads from around it,
   and the other lifted methods it reaches, whose captures are its too.
   Worked out once the whole module is translated. *)
type capture = {
  direct : (string * string) list; (* name, Java type *)
  reaches : string list;
  inside : string; (* the method it was written in *)
}

type jmethod = {
  m_name : string;
  m_public : bool;
  m_tparams : string list;
  m_result : string; (* `void` or a type *)
  m_params : (string * string) list; (* type, name *)
  m_captures : bool; (* lifted: its captures go first *)
  m_body : jstmt list;
}

type state = {
  taken : StringSet.t; (* Java names in use in the method family *)
  counter : int;
  lifted : jmethod list;
  captures : (string * capture) list;
  tuples : int list;
  fns : int list;
  polys : (string * string) list; (* interface name, its declaration *)
  current : string; (* the method being translated *)
  methods_taken : StringSet.t;
}

(** A name nothing in the method family has taken, from base.
    state -> string -> (string, state) *)
let fresh st base =
  let base = java_ident base in
  let rec go candidate n =
    if StringSet.mem candidate st.taken then go (Printf.sprintf "%s%d" base n) (n + 1)
    else candidate
  in
  let name = go base 2 in
  (name, { st with taken = StringSet.add name st.taken })

(** A generated name: prefix$n. state -> string -> (string, state) *)
let temp st prefix =
  let name = Printf.sprintf "%s$%d" prefix (st.counter + 1) in
  (name, { st with counter = st.counter + 1; taken = StringSet.add name st.taken })

let need_tuple st n = if List.mem n st.tuples then st else { st with tuples = st.tuples @ [ n ] }
let need_fn st n = if n < 3 || List.mem n st.fns then st else { st with fns = st.fns @ [ n ] }

(** state noting every runtime class a type's text names.
    state -> typ -> state *)
let rec need_type st t =
  match t with
  | TTuple (_, es, _) ->
      let st = if es = [] then st else need_tuple st (List.length es) in
      List.fold_left need_type st es
  | TList (_, e, _) -> need_type st e
  | TFunction (_, ps, r, _, _, _, _) ->
      List.fold_left need_type (need_fn st (List.length ps)) (r :: ps)
  | TCon (_, _, es, _) -> List.fold_left need_type st es
  | _ -> st

let bind_value scope name b = { scope with names = SMap.add name b scope.names }

(** The binding of a name, or a refusal naming it. scope -> info ->
    string -> binding *)
let lookup scope info name =
  match SMap.find_opt name scope.names with
  | Some b -> b
  | None -> unsupported info (Printf.sprintf "'%s' is not a name this backend knows" name)

(** state unchanged: a capture's type is read off its binding.
    state -> string -> string -> state *)
let note_local st _name _type_text = st

(** Binds a Pyking name to a new final local of type t. ctx -> state ->
    scope -> string -> typ -> (string, scope, state) *)
let new_local ctx st scope name t =
  let jname, st = fresh st name in
  let st = note_local st jname (jt ctx t) in
  (jname, bind_value scope name { value = atom jname; kind = BLocal; btype = t; jname_ = jname }, st)

(* --- types of expressions --- *)

(** The type the checker worked out for e, or one read off its shape for
    a node the tail-call pass built. ctx -> scope -> expr -> typ *)
let rec type_of ctx scope e =
  match IntMap.find_opt (expr_sym e) ctx.tmap with
  | Some t -> t
  | None -> (
      match e with
      | EInt (i, _, _) -> TInt (i, 0)
      | EFloat (i, _, _) -> TFloat (i, 0)
      | EString (i, _, _) -> TString (i, 0)
      | EBool (i, _, _) | EEq (i, _, _, _) | ELessThan (i, _, _, _)
      | ELessThanEq (i, _, _, _) | EGreatThan (i, _, _, _) | EGreatThanEq (i, _, _, _) ->
          TBool (i, 0)
      | EVar (i, name, _) -> (
          match SMap.find_opt name scope.names with
          | Some b -> b.btype
          | None -> TUnknown (i, 0))
      | ETuple (i, es, _) -> TTuple (i, List.map (type_of ctx scope) es, 0)
      | EList (i, e :: _, _) -> TList (i, type_of ctx scope e, 0)
      | EAdd (_, l, _, _) | ESub (_, l, _, _) | EMul (_, l, _, _) | EDiv (_, l, _, _)
      | ENeg (_, l, _) | EConcat (_, l, _, _) ->
          type_of ctx scope l
      | EIf (_, _, t, _, _) -> type_of ctx scope t
      | ECall (i, f, _, _) -> (
          match type_of ctx scope f with
          | TFunction (_, _, r, _, _, _, _) -> r
          | TForall (_, _, TFunction (_, _, r, _, _, _, _), _) -> r
          | _ -> TUnknown (i, 0))
      | e -> TUnknown (expr_info e, 0))

(* --- the shared runtime's pieces a translation names --- *)

let rt name = runtime_class ^ "." ^ name

(** A tuple's i-th element. ctx -> jexpr -> int -> jexpr *)
let tuple_get ctx s i =
  match ctx.shape with
  | Java8 -> atom ~boxed:true (Printf.sprintf "%s.a%d" (at p_atom s) i)
  | _ -> atom ~boxed:true (Printf.sprintf "%s.a%d()" (at p_atom s) i)

(** A constructor's field. ctx -> jexpr -> string -> jexpr *)
let field_get ctx s name =
  match ctx.shape with
  | Java8 -> atom ~boxed:true (Printf.sprintf "%s.%s" (at p_atom s) name)
  | _ -> atom ~boxed:true (Printf.sprintf "%s.%s()" (at p_atom s) name)

(** v unboxed where its static type is a boxed one and t is a scalar:
    what `==` needs. ctx -> typ -> jexpr -> jexpr *)
let unboxed ctx t v =
  if v.boxed && is_scalar t then mk p_unary (Printf.sprintf "(%s) %s" (jt ctx t) (at p_unary v))
  else v

(** `a == b` at type t. ctx -> typ -> jexpr -> jexpr -> jexpr *)
let equal ctx t a b =
  match t with
  | TString _ -> atom (Printf.sprintf "%s.equals(%s)" (at p_atom a) b.text)
  | t when is_scalar t -> binary p_eq "==" (unboxed ctx t a) (unboxed ctx t b)
  | _ -> atom (Printf.sprintf "java.util.Objects.equals(%s, %s)" a.text b.text)

(** A Java string literal. string -> string *)
let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c when Char.code c < 32 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(** A Float literal. float -> jexpr *)
let float_literal v =
  if v <> v then atom "Double.NaN"
  else if v = infinity then atom "Double.POSITIVE_INFINITY"
  else if v = neg_infinity then atom "Double.NEGATIVE_INFINITY"
  else
    let text = Builtin.float_text v in
    let text =
      if String.contains text '.' || String.contains text 'e' || String.contains text 'n' then text
      else text ^ ".0"
    in
    if v < 0.0 then mk p_unary text else atom text

(** What print writes for v, a value of type t. ctx -> typ -> jexpr ->
    jexpr *)
let printed _ctx t v =
  match t with
  | TString _ -> if v.boxed then mk p_unary ("(String) " ^ at p_unary v) else v
  | TFloat _ -> atom (Printf.sprintf "%s(%s)" (rt "floatStr") (if v.boxed then "(double) " ^ at p_unary v else v.text))
  | TInt _ | TBool _ ->
      atom (Printf.sprintf "String.valueOf(%s)" (if v.boxed then "(Object) " ^ at p_unary v else v.text))
  | _ -> atom (Printf.sprintf "%s(%s)" (rt "str") v.text)

(* --- capture markers ---
   A lifted method's captures are known only once the module is
   translated, so a call names them by a marker `expand_captures`
   replaces: \001A:name:k\001 for the arguments (k: whether arguments
   follow), \001P:name:k\001 for the parameters. *)

let capture_args name more = Printf.sprintf "\001A:%s:%d\001" name (if more then 1 else 0)
let capture_params name more = Printf.sprintf "\001P:%s:%d\001" name (if more then 1 else 0)

(* --- free names, for what a nested def captures --- *)

(** Every name read or written anywhere in stmts. [stmt] -> StringSet.t *)
let mentioned stmts =
  Walk.fold_stmts
    (fun found node ->
      match node with
      | Walk.NExpr (EVar (_, n, _)) -> StringSet.add n found
      | Walk.NStmt (SMutate (_, n, _, _)) -> StringSet.add n found
      | _ -> found)
    StringSet.empty stmts

(** The `var`s of a body that something it writes as a closure -- a
    nested def, a lambda, a comprehension -- mentions: those live in a
    cell. [stmt] -> StringSet.t *)
let captured_vars body =
  let vars =
    Walk.fold_stmts
      (fun found node ->
        match node with Walk.NStmt (SVar (_, n, _, _)) -> StringSet.add n found | _ -> found)
      StringSet.empty body
  in
  if StringSet.is_empty vars then vars
  else
    let inner =
      Walk.fold_stmts
        (fun found node ->
          match node with
          | Walk.NStmt (SFunctionDef (_, _, _, b, _, _, _, _, _)) ->
              StringSet.union found (mentioned b)
          | Walk.NExpr (ELambda (_, _, b, _)) ->
              StringSet.union found (mentioned [ SExprStmt (no_info, b, 0) ])
          | Walk.NExpr (EListComp (_, b, clauses, _)) ->
              let found = StringSet.union found (mentioned [ SExprStmt (no_info, b, 0) ]) in
              List.fold_left
                (fun found c ->
                  match c with
                  | CompIf (_, e, _) | CompFor (_, _, e, _) ->
                      StringSet.union found (mentioned [ SExprStmt (no_info, e, 0) ]))
                found clauses
          | _ -> found)
        StringSet.empty body
    in
    StringSet.inter vars inner

(** Whether stmts write a closure anywhere: a def, a lambda, a
    comprehension. A loop whose body does gives every turn its own final
    accumulator. [stmt] -> bool *)
let writes_closure stmts =
  Walk.exists_stmts
    (fun node ->
      match node with
      | Walk.NStmt (SFunctionDef _) | Walk.NExpr (ELambda _) | Walk.NExpr (EListComp _) -> true
      | _ -> false)
    stmts

(* --- the datatype a type names --- *)

(** The datatype of a type, its parameters bound to the type's
    arguments. ctx -> info -> typ -> (datatype, [(string, typ)]) *)
let datatype_of ctx info t =
  match t with
  | TCon (_, canonical, args, _) -> (
      match SMap.find_opt canonical ctx.datatypes with
      | Some (Datatype (_, params, _) as d) ->
          let bound = if List.length params = List.length args then List.combine params args else [] in
          (d, bound)
      | None -> unsupported info (Printf.sprintf "the datatype %s is not one this module can see" canonical))
  | _ -> unsupported info "a constructor pattern on a value that is not a datatype"

(** t with each variable `bound` names replaced. [(string, typ)] -> typ
    -> typ *)
let rec substitute bound t =
  match t with
  | TVar (_, v, _, _) -> ( match List.assoc_opt v bound with Some t -> t | None -> t)
  | TList (i, e, s) -> TList (i, substitute bound e, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (substitute bound) es, s)
  | TCon (i, c, es, s) -> TCon (i, c, List.map (substitute bound) es, s)
  | TFunction (i, ps, r, a, b, c, d) ->
      TFunction (i, List.map (substitute bound) ps, substitute bound r, a, b, c, d)
  | TForall (i, vs, body, s) ->
      TForall (i, vs, substitute (List.filter (fun (v, _) -> not (List.mem v vs)) bound) body, s)
  | t -> t

(** What each variable of a declared type stands for, read off a type of
    the same shape. [(string, typ)] -> typ -> typ -> [(string, typ)] *)
let rec matching bound declared actual =
  match (declared, actual) with
  | TVar (_, v, _, _), t when not (List.mem_assoc v bound) -> (
      match t with TVar (_, w, _, _) when w = v -> bound | TUnknown _ -> bound | t -> (v, t) :: bound)
  | TList (_, a, _), TList (_, b, _) -> matching bound a b
  | (TTuple (_, xs, _), TTuple (_, ys, _) | TCon (_, _, xs, _), TCon (_, _, ys, _))
    when List.length xs = List.length ys ->
      List.fold_left2 matching bound xs ys
  | TFunction (_, ps, r, _, _, _, _), TFunction (_, qs, q, _, _, _, _)
    when List.length ps = List.length qs ->
      List.fold_left2 matching (matching bound r q) ps qs
  | TForall (_, vs, b, _), TForall (_, _, c, _) ->
      let inner = matching (List.map (fun v -> (v, TVar (no_info, v, 0, true))) vs @ bound) b c in
      List.filter (fun (v, _) -> not (List.mem v vs)) inner
  | _ -> bound

(** A constructor's fields: each Java name and its type at this
    instance. ctx -> info -> typ -> string -> [(string, typ)] *)
let ctor_fields ctx info t name =
  let Datatype (_, _, ctors), bound = datatype_of ctx info t in
  match List.assoc_opt name ctors with
  | Some fields -> List.mapi (fun i (label, ft) -> (field_name label i, substitute bound ft)) fields
  | None -> unsupported info (Printf.sprintf "no constructor %s" name)

(* --- patterns ---
   A pattern is the tests that decide it and the names it binds, each to
   a place in the subject -- an expression that can be read twice, since
   the subject is held in a name of its own. `binding` says whether a
   constructor test may introduce a pattern variable (java17's
   `instanceof Leaf l`), which it may not inside an or-pattern, where it
   would not be definitely matched. *)

let rec pattern ctx st p (s : jexpr) (t : typ) binding =
  let info = pattern_info p in
  match p with
  | PWildcard _ -> ([], [], st)
  | PCapture (_, name, _) -> ([], [ (name, s, t) ], st)
  | PInt (_, v, _) ->
      ([ equal ctx (TInt (info, 0)) s (if v < 0 then mk p_unary (string_of_int v) else atom (string_of_int v)) ], [], st)
  | PBool (_, v, _) ->
      let s = unboxed ctx (TBool (info, 0)) s in
      ([ (if v then s else mk p_unary ("!" ^ at p_unary s)) ], [], st)
  | PString (_, v, _) -> ([ atom (Printf.sprintf "%s.equals(%s)" (quote v) s.text) ], [], st)
  | PTuple (_, ps, _) ->
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> t) ps in
      parts ctx st ps (List.mapi (fun i _ -> tuple_get ctx s i) ps) types binding
  | PList (_, prefix, rest, suffix, _) ->
      let element = match t with TList (_, e, _) -> e | _ -> t in
      let size = atom (at p_atom s ^ ".size()") in
      let n = List.length prefix and m = List.length suffix in
      let size_test =
        match rest with
        | None -> binary p_eq "==" size (atom (string_of_int n))
        | Some _ -> binary p_rel ">=" size (atom (string_of_int (n + m)))
      in
      let places =
        List.mapi (fun i _ -> atom ~boxed:true (Printf.sprintf "%s.get(%d)" (at p_atom s) i)) prefix
        @ List.mapi
            (fun i _ -> atom ~boxed:true (Printf.sprintf "%s.get(%s.size() - %d)" (at p_atom s) (at p_atom s) (m - i)))
            suffix
      in
      let conds, binds, st =
        parts ctx st (prefix @ suffix) places (List.map (fun _ -> element) (prefix @ suffix)) binding
      in
      let binds =
        match rest with
        | Some (ListRest (_, Some name, _)) ->
            binds
            @ [ ( name,
                  atom (Printf.sprintf "%s.subList(%d, %s.size() - %d)" (at p_atom s) n (at p_atom s) m),
                  t ) ]
        | _ -> binds
      in
      (size_test :: conds, binds, st)
  | PText (_, prefix, name, suffix, _) ->
      let conds =
        (if prefix = "" then [] else [ atom (Printf.sprintf "%s.startsWith(%s)" (at p_atom s) (quote prefix)) ])
        @ (if suffix = "" then [] else [ atom (Printf.sprintf "%s.endsWith(%s)" (at p_atom s) (quote suffix)) ])
        @
        if prefix <> "" && suffix <> "" then
          [ binary p_rel ">=" (atom (at p_atom s ^ ".length()")) (atom (string_of_int (String.length prefix + String.length suffix))) ]
        else []
      in
      let binds =
        match name with
        | None -> []
        | Some name ->
            [ ( name,
                atom
                  (Printf.sprintf "%s.substring(%d, %s.length() - %d)" (at p_atom s) (String.length prefix)
                     (at p_atom s) (String.length suffix)),
                t ) ]
      in
      (conds, binds, st)
  | PConstructor (_, _, name, fields, _, _) -> (
      let canonical = match t with TCon (_, c, _, _) -> c | _ -> "" in
      let args = match t with TCon (_, _, a, _) -> a | _ -> [] in
      let cls = ctor_ref ctx canonical name in
      let typed = cls ^ if args = [] then "" else "<" ^ targs ctx args ^ ">" in
      let declared = ctor_fields ctx info t name in
      let fields_of holder =
        List.map (fun (fname, _) -> field_get ctx holder fname) declared
      in
      let types = List.map snd declared in
      match (ctx.shape, binding) with
      | (Java17 | Java21), true ->
          let held, st = temp st "t" in
          let test = mk p_rel (Printf.sprintf "%s instanceof %s %s" (at p_rel s) typed held) in
          let conds, binds, st = parts ctx st fields (fields_of (atom held)) types binding in
          (test :: conds, binds, st)
      | _ ->
          let test = mk p_rel (Printf.sprintf "%s instanceof %s" (at p_rel s) cls) in
          let cast = atom (Printf.sprintf "((%s) %s)" typed (at p_unary s)) in
          let conds, binds, st = parts ctx st fields (fields_of cast) types binding in
          (test :: conds, binds, st))
  | PAs (_, inner, name, _) ->
      let conds, binds, st = pattern ctx st inner s t binding in
      (conds, binds @ [ (name, s, t) ], st)
  | POr (_, alternatives, _) ->
      let names = match alternatives with first :: _ -> List.map fst (Analyses.pattern_bindings first) | [] -> [] in
      let each, st =
        List.fold_left
          (fun (out, st) alt ->
            let conds, binds, st = pattern ctx st alt s t false in
            (out @ [ (conds, binds) ], st))
          ([], st) alternatives
      in
      let cond =
        if List.exists (fun (c, _) -> c = []) each then []
        else
          match List.map (fun (c, _) -> conjunction c) each with
          | first :: rest -> [ List.fold_left (fun acc c -> binary p_or "||" acc c) first rest ]
          | [] -> []
      in
      let binds =
        List.map
          (fun name ->
            let value_in binds = List.find_map (fun (n, v, ty) -> if n = name then Some (v, ty) else None) binds in
            let rec chosen = function
              | [] -> (null_expr, t)
              | [ (_, binds) ] -> Option.value (value_in binds) ~default:(null_expr, t)
              | ([], binds) :: _ -> Option.value (value_in binds) ~default:(null_expr, t)
              | (conds, binds) :: rest ->
                  let v, ty = Option.value (value_in binds) ~default:(null_expr, t) in
                  let other, _ = chosen rest in
                  ( mk ~boxed:true p_cond
                      (Printf.sprintf "%s ? %s : %s" (at (p_cond + 1) (conjunction conds)) (at p_cond v) (at p_cond other)),
                    ty )
            in
            let v, ty = chosen each in
            (name, v, ty))
          names
      in
      (cond, binds, st)

(** Each sub-pattern against its place, tests and bindings joined.
    ctx -> state -> [pattern] -> [jexpr] -> [typ] -> bool
    -> ([jexpr], [(string, jexpr, typ)], state) *)
and parts ctx st ps places types binding =
  let rec go ps places types conds binds st =
    match (ps, places, types) with
    | p :: ps, place :: places, ty :: types ->
        let c, b, st = pattern ctx st p place ty binding in
        go ps places types (conds @ c) (binds @ b) st
    | _ -> (conds, binds, st)
  in
  go ps places types [] [] st

(* --- the program's own java.lang printing --- *)

(** The local declaration's type: `var` from java17 on where it says
    what the value is, the type spelled out otherwise. ctx -> typ ->
    jexpr -> string *)
let local_type ctx t (v : jexpr) =
  match (ctx.shape, t) with
  | Java8, _ -> jt ctx t
  | _, (TTuple (_, [], _) | TFunction _ | TForall _) -> jt ctx t
  | _, t when is_scalar t && v.boxed -> jt ctx t
  | _, (TList _ | TTuple _ | TCon (_, _, _ :: _, _) | TVar _ | TUnknown _) -> jt ctx t
  | _, _ -> if v.text = "null" then jt ctx t else "var"

(** `final T name = v;`. ctx -> string -> typ -> jexpr -> jstmt *)
let declare ctx name t v = JLine (Printf.sprintf "final %s %s = %s;" (local_type ctx t v) name v.text)

(** The pattern's bindings as finals, each name bound in scope.
    ctx -> state -> scope -> [(string, jexpr, typ)] -> ([jstmt], scope, state) *)
let bind_all ctx st scope binds =
  List.fold_left
    (fun (out, scope, st) (name, v, t) ->
      let jname, scope, st = new_local ctx st scope name t in
      (out @ [ declare ctx jname t v ], scope, st))
    ([], scope, st) binds

(** The pattern's bindings as places, with no locals: what a guard on
    java21 reads. scope -> [(string, jexpr, typ)] -> scope *)
let bind_places scope binds =
  List.fold_left
    (fun scope (name, v, t) -> bind_value scope name { value = v; kind = BExpr; btype = t; jname_ = "" })
    scope binds

(* --- expressions --- *)

(** Translates one expression. ctx -> state -> scope -> expr -> (jexpr, state) *)
let rec expr ctx st scope e =
  match e with
  | EInt (_, v, _) -> ((if v < 0 then mk p_unary (string_of_int v) else atom (string_of_int v)), st)
  | EFloat (_, v, _) -> (float_literal v, st)
  | EString (_, s, _) -> (atom (quote s), st)
  | EBool (_, b, _) -> (atom (if b then "true" else "false"), st)
  | ETuple (_, [], _) -> (null_expr, st)
  | ETuple (_, es, _) ->
      let t = type_of ctx scope e in
      let st = need_type st t in
      let values, st = exprs ctx st scope es in
      ( atom
          (Printf.sprintf "new %s.T%d<>(%s)" runtime_class (List.length es)
             (String.concat ", " (List.map (fun v -> v.text) values))),
        st )
  | EList (_, es, _) ->
      let t = type_of ctx scope e in
      let st = need_type st t in
      let values, st = exprs ctx st scope es in
      (* Java infers the element type, from the elements or from where
         the list goes. *)
      if es = [] then (atom "java.util.Collections.emptyList()", st)
      else
        ( atom
            (Printf.sprintf "java.util.Arrays.asList(%s)"
               (String.concat ", " (List.map (fun v -> v.text) values))),
          st )
  | EVar (_, name, _) -> variable ctx st scope e name
  | EQualified (_, alias, field, _) -> qualified ctx st scope e alias field
  | EIf (_, c, a, b, _) ->
      let c, st = expr ctx st scope c in
      let a, st = expr ctx st scope a in
      let b, st = expr ctx st scope b in
      ( mk ~boxed:(a.boxed || b.boxed) p_cond
          (Printf.sprintf "%s ? %s : %s" (at (p_cond + 1) c) (at p_cond a) (at p_cond b)),
        st )
  | ENeg (_, operand, _) ->
      let v, st = expr ctx st scope operand in
      let text = at p_unary v in
      (mk p_unary ("-" ^ if String.length text > 0 && text.[0] = '-' then "(" ^ text ^ ")" else text), st)
  | EAdd (_, l, r, _) -> arithmetic ctx st scope p_add "+" l r
  | ESub (_, l, r, _) -> arithmetic ctx st scope p_add "-" l r
  | EMul (_, l, r, _) -> arithmetic ctx st scope p_mul "*" l r
  | EDiv (_, l, r, _) -> arithmetic ctx st scope p_mul "/" l r
  | EConcat (_, l, r, _) -> (
      let a, st = expr ctx st scope l in
      let b, st = expr ctx st scope r in
      match type_of ctx scope e with
      | TList _ -> (atom (Printf.sprintf "%s(%s, %s)" (rt "concat") a.text b.text), st)
      | _ -> (binary p_add "+" a b, st))
  | EEq (_, l, r, _) ->
      let a, st = expr ctx st scope l in
      let b, st = expr ctx st scope r in
      (equal ctx (type_of ctx scope l) a b, st)
  | ELessThan (_, l, r, _) -> comparison ctx st scope "<" l r
  | ELessThanEq (_, l, r, _) -> comparison ctx st scope "<=" l r
  | EGreatThan (_, l, r, _) -> comparison ctx st scope ">" l r
  | EGreatThanEq (_, l, r, _) -> comparison ctx st scope ">=" l r
  | ECall (_, EVar (_, name, callee), args, _)
    when Builtin.crosses_host name && not (IntMap.mem callee ctx.tmap) ->
      let line, st = print_text ctx st scope (arg_exprs args) in
      ( atom
          (Printf.sprintf "%s(%s)" (rt (if Builtin.is_debug name then "debugLine" else "printLine")) line.text),
        st )
  | ECall (_, EVar (_, name, _), args, _)
    when List.mem name Builtin.pure_names && not (SMap.mem name scope.names) ->
      builtin ctx st scope e name (arg_exprs args)
  | ECall (_, func, args, _) -> call ctx st scope e func (arg_exprs args)
  | EConstruct (_, _, name, args, _) ->
      let t = type_of ctx scope e in
      let canonical, targs_ = match t with TCon (_, c, a, _) -> (c, a) | _ -> ("", []) in
      let st = need_type st t in
      let values, st = exprs ctx st scope (arg_exprs args) in
      ignore targs_;
      (* A constructor's factory answers the datatype's own type, which is
         what Java has to infer a call's type variables from. *)
      let cls = ctor_ref ctx canonical name in
      (atom (Printf.sprintf "%s(%s)" cls (String.concat ", " (List.map (fun v -> v.text) values))), st)
  | EField (_, record, name, _) ->
      let v, st = expr ctx st scope record in
      (atom ~boxed:true (Printf.sprintf "%s.%s()" (at p_atom v) (field_name (Some name) 0)), st)
  | ELambda (_, params, body, _) -> lambda ctx st scope e params body
  | EListComp (_, element, clauses, _) -> comprehension ctx st scope e element clauses

and exprs ctx st scope es =
  List.fold_left
    (fun (out, st) e ->
      let v, st = expr ctx st scope e in
      (out @ [ v ], st))
    ([], st) es

and arithmetic ctx st scope prec op l r =
  let a, st = expr ctx st scope l in
  let b, st = expr ctx st scope r in
  (binary prec op a b, st)

and comparison ctx st scope op l r =
  let a, st = expr ctx st scope l in
  let b, st = expr ctx st scope r in
  (binary p_rel op a b, st)

(** A name read as a value. ctx -> state -> scope -> expr -> string ->
    (jexpr, state) *)
and variable ctx st scope e name =
  let info = expr_info e in
  let b = lookup scope info name in
  match b.kind with
  | BMethod m -> (function_value ctx st scope e m, st)
  | BErased ->
      let t, ctx = match type_of ctx scope e with TForall (_, _, body, _) -> (body, { ctx with erase = true }) | t -> (t, ctx) in
      (atom ~boxed:true (Printf.sprintf "((%s) (Object) %s)" (jt ctx ~boxed:true t) b.value.text), st)
  | _ -> (b.value, st)

(** A def used as a value: a lambda calling its method, of the interface
    its type at this use says. ctx -> state -> scope -> expr -> meth ->
    jexpr *)
and function_value ctx st scope e m =
  let t = type_of ctx scope e in
  let _, ps, _ = function_parts (match t with TFunction _ | TForall _ -> t | _ -> m.mtype) in
  let params = List.mapi (fun i _ -> Printf.sprintf "p$%d" (i + 1)) ps in
  let args = String.concat ", " params in
  let call =
    if m.lifted then Printf.sprintf "%s(%s%s)" m.jname (capture_args m.jname (params <> [])) args
    else Printf.sprintf "%s(%s)" m.jname args
  in
  let head = match params with [ p ] -> p | ps -> "(" ^ String.concat ", " ps ^ ")" in
  ignore st;
  if m.void then mk p_lambda (Printf.sprintf "%s -> { %s; return null; }" head call)
  else mk p_lambda (Printf.sprintf "%s -> %s" head call)

(** `m.field` of another module. ctx -> state -> scope -> expr -> string
    -> string -> (jexpr, state) *)
and qualified ctx st scope e alias field =
  match qualified_method ctx alias field with
  | Some m -> (function_value ctx st scope e m, st)
  | None ->
      let module_ = Option.value (List.assoc_opt alias ctx.modules) ~default:alias in
      let reached = Module.reached_module ctx.context.external_fields module_ field in
      (atom (Printf.sprintf "%s.%s" (module_class reached) (java_ident field)), st)

(** The method `alias.field` names, where it is a function.
    ctx -> string -> string -> meth? *)
and qualified_method ctx alias field =
  let module_ = Option.value (List.assoc_opt alias ctx.modules) ~default:alias in
  let sigmap = Option.value (List.assoc_opt module_ ctx.context.sigmaps) ~default:[] in
  match List.find_map (fun (n, t, _) -> if n = field then Some t else None) sigmap with
  | Some ((TFunction _ | TForall (_, _, TFunction _, _)) as t) ->
      let reached = Module.reached_module ctx.context.external_fields module_ field in
      let _, _, r = function_parts t in
      Some
        {
          jname = module_class reached ^ "." ^ java_ident field;
          lifted = false;
          void = is_unit r;
          mtype = t;
          external_ = reached <> module_ || List.mem module_ ctx.context.externals;
        }
  | _ -> None

(** A call. ctx -> state -> scope -> expr -> expr -> [expr] -> (jexpr, state) *)
and call ctx st scope e func args =
  let info = expr_info e in
  let meth =
    match func with
    | EVar (_, name, _) -> (
        match SMap.find_opt name scope.names with Some { kind = BMethod m; _ } -> Some m | _ -> None)
    | EQualified (_, alias, field, _) -> qualified_method ctx alias field
    | _ -> None
  in
  let result = type_of ctx scope e in
  match meth with
  | Some m ->
      let _, ps, r = function_parts m.mtype in
      (* The parameters as this call instantiates them, where the checker
         recorded that. *)
      let ps =
        match type_of ctx scope func with
        | (TFunction _ as t) when not (has_unknown t) ->
            let _, used, _ = function_parts t in
            if List.length used = List.length ps then used else ps
        | _ -> ps
      in
      (* Where the recorded parameters still name the definition's own
         variables, what this call makes them is read off its result and
         its arguments. *)
      let ps =
        if not (List.exists (fun p -> declared_vars p <> []) ps) || List.length ps <> List.length args then ps
        else
          let bound = matching [] r (type_of ctx scope e) in
          let bound =
            List.fold_left2
              (fun bound p a -> match p with TForall _ -> bound | p -> matching bound p (type_of ctx scope a))
              bound ps args
          in
          List.map (substitute bound) ps
      in
      let values, st = arguments ctx st scope m ps args in
      let texts = List.map (fun v -> v.text) values in
      let text =
        if m.lifted then Printf.sprintf "%s(%s%s)" m.jname (capture_args m.jname (texts <> [])) (String.concat ", " texts)
        else Printf.sprintf "%s(%s)" m.jname (String.concat ", " texts)
      in
      if m.void then (atom (Printf.sprintf "%s(() -> %s)" (rt "unit") text), st)
      else if has_unknown r then
        (* A nested def's type may hold its enclosing function's variable
           as one the checker left open: written Object there, and given
           back the type it has at this call. *)
        (atom ~boxed:true (Printf.sprintf "((%s) (Object) %s)" (jt ctx ~boxed:true result) text), st)
      else
        (* A result of a type variable is boxed whatever it is at this
           call. *)
        let boxed = match r with TVar _ -> true | _ -> false in
        (atom ~boxed text, st)
  | None ->
      let f, st = expr ctx st scope func in
      let ft = type_of ctx scope func in
      (* A lambda has no type of its own until something gives it one. *)
      let f = match func with ELambda _ -> atom (Printf.sprintf "((%s) %s)" (jt ctx ft) (at p_unary f)) | _ -> f in
      let ps = match ft with TFunction _ | TForall (_, _, TFunction _, _) -> (let _, ps, _ = function_parts ft in ps) | _ -> List.map (fun _ -> TUnknown (info, 0)) args in
      let values, st =
        List.fold_left2
          (fun (out, st) a p ->
            let v, st = poly_argument ctx st scope a p in
            (out @ [ v ], st))
          ([], st) args
          (if List.length ps = List.length args then ps else List.map (fun _ -> TUnknown (info, 0)) args)
      in
      ignore result;
      ( atom ~boxed:true
          (Printf.sprintf "%s.%s(%s)" (at p_atom f) (apply_method (List.length args))
             (String.concat ", " (List.map (fun v -> v.text) values))),
        st )

(** The arguments of a call to a method, each as its parameter wants it:
    a polymorphic one in its interface, a callback for the host as the
    host's own interface. ctx -> state -> scope -> meth -> [typ] ->
    [expr] -> ([jexpr], state) *)
and arguments ctx st scope m ps args =
  List.fold_left
    (fun (out, st) (i, a) ->
      let p = List.nth_opt ps i in
      let v, st =
        match p with
        | Some (TFunction (_, fps, fr, _, _, _, _)) when m.external_ -> callback ctx st scope a fps fr
        | Some p -> poly_argument ctx st scope a p
        | None -> expr ctx st scope a
      in
      (out @ [ v ], st))
    ([], st)
    (List.mapi (fun i a -> (i, a)) args)

(** A function value handed to the host, which takes java.util.function's
    own interfaces: `Runnable` and `Consumer` for one answering unit.
    ctx -> state -> scope -> expr -> [typ] -> typ -> (jexpr, state) *)
and callback ctx st scope a ps r =
  let params = List.mapi (fun i _ -> Printf.sprintf "c$%d" (i + 1)) ps in
  let head = match params with [ p ] -> p | ps -> "(" ^ String.concat ", " ps ^ ")" in
  match a with
  | EVar (_, name, _) when (match SMap.find_opt name scope.names with Some { kind = BMethod _; _ } -> true | _ -> false) -> (
      match SMap.find_opt name scope.names with
      | Some { kind = BMethod m; _ } ->
          let call =
            if m.lifted then Printf.sprintf "%s(%s%s)" m.jname (capture_args m.jname (params <> [])) (String.concat ", " params)
            else Printf.sprintf "%s(%s)" m.jname (String.concat ", " params)
          in
          (mk p_lambda (Printf.sprintf "%s -> %s" head call), st)
      | _ -> expr ctx st scope a)
  | ELambda (_, lparams, body, _) when is_unit r ->
      (* The host's interface answers nothing, so neither does the
         lambda. *)
      let names, inner, st =
        List.fold_left2
          (fun (names, inner, st) (Param (_, n, _, _, _)) pt ->
            let jname, st = fresh st n in
            (names @ [ jname ], bind_value inner n { value = atom ~boxed:true jname; kind = BLocal; btype = pt; jname_ = jname }, st))
          ([], scope, st) lparams
          (if List.length ps = List.length lparams then ps else List.map (fun _ -> TUnknown (no_info, 0)) lparams)
      in
      let head = match names with [ n ] -> n | ns -> "(" ^ String.concat ", " ns ^ ")" in
      let body_stmts, st = effect_of ctx st inner body in
      (mk p_lambda (Printf.sprintf "%s -> { %s }" head (flat body_stmts)), st)
  | ELambda _ -> expr ctx st scope a
  | _ ->
      let v, st = expr ctx st scope a in
      (atom (Printf.sprintf "%s::%s" (at p_atom v) (apply_method (List.length ps))), st)

(** An argument for a parameter of type p: wrapped in its interface where
    p is polymorphic. ctx -> state -> scope -> expr -> typ -> (jexpr, state) *)
and poly_argument ctx st scope a p =
  match p with
  | TForall _ -> poly_wrap ctx st scope a p
  | _ -> expr ctx st scope a

(** A polymorphic function handed to a parameter of type p: an object of
    p's interface whose one generic method calls it.
    ctx -> state -> scope -> expr -> typ -> (jexpr, state) *)
and poly_wrap ctx st scope a p =
  let ctx = { ctx with erase = false } in
  let info = expr_info a in
  let iface = poly_name p in
  let shaped, holes, count = poly_split p in
  let st = { st with polys = (if List.mem_assoc iface st.polys then st.polys else st.polys @ [ (iface, poly_declaration ctx p) ]) } in
  let st = List.fold_left need_type st holes in
  let hole_bound = List.mapi (fun i h -> (Printf.sprintf "h%d" i, h)) holes in
  let ps, r = match shaped with TFunction (_, ps, r, _, _, _, _) -> (ps, r) | _ -> unsupported info "a polymorphic parameter that is not a function" in
  let ps = List.map (substitute hole_bound) ps and r = substitute hole_bound r in
  let bvars = List.init count (fun i -> Printf.sprintf "B%d" i) in
  let params = List.mapi (fun i _ -> Printf.sprintf "q$%d" (i + 1)) ps in
  let typed = List.map2 (fun t n -> jt ctx ~boxed:true t ^ " " ^ n) ps params in
  let args = String.concat ", " params in
  let target =
    match a with
    | EVar (_, name, _) -> (
        match SMap.find_opt name scope.names with
        | Some { kind = BMethod m; _ } ->
            if m.lifted then Printf.sprintf "%s(%s%s)" m.jname (capture_args m.jname (params <> [])) args
            else Printf.sprintf "%s(%s)" m.jname args
        | Some b -> (
            match b.btype with
            | TForall _ when poly_name b.btype = iface -> ""
            | _ -> Printf.sprintf "%s.%s(%s)" (at p_atom b.value) (apply_method (List.length ps)) args)
        | None -> unsupported info (Printf.sprintf "'%s' is not a name this backend knows" name))
    | EQualified (_, alias, field, _) -> (
        match qualified_method ctx alias field with
        | Some m -> Printf.sprintf "%s(%s)" m.jname args
        | None -> unsupported info "a polymorphic argument that is not a function")
    | _ -> unsupported info "a polymorphic argument that is not a function's own name"
  in
  if target = "" then
    match a with EVar (_, name, _) -> ((lookup scope info name).value, st) | _ -> (null_expr, st)
  else
    let tparams = String.concat ", " bvars in
    let hole_args = if holes = [] then "" else "<" ^ targs ctx holes ^ ">" in
    ( atom
        (Printf.sprintf "new %s%s() { public <%s> %s apply(%s) { return %s; } }" (rt iface) hole_args tparams
           (jt ctx ~boxed:true r) (String.concat ", " typed) target),
      st )

(** The declaration of the runtime interface a polymorphic parameter type
    is passed as. ctx -> typ -> string *)
and poly_declaration ctx p =
  let ctx = { ctx with erase = false } in
  let iface = poly_name p in
  let shaped, holes, count = poly_split p in
  let ps, r = match shaped with TFunction (_, ps, r, _, _, _, _) -> (ps, r) | _ -> ([], shaped) in
  let plain = { ctx with class_names = StringSet.empty } in
  let hparams = List.mapi (fun i _ -> Printf.sprintf "H%d" i) holes in
  let bvars = List.init count (fun i -> Printf.sprintf "B%d" i) in
  Printf.sprintf "    public interface %s%s {\n        <%s> %s apply(%s);\n    }" iface
    (if hparams = [] then "" else "<" ^ String.concat ", " hparams ^ ">")
    (String.concat ", " bvars) (jt plain ~boxed:true r)
    (String.concat ", " (List.mapi (fun i t -> jt plain ~boxed:true t ^ Printf.sprintf " q$%d" (i + 1)) ps))

(** A builtin's call. ctx -> state -> scope -> expr -> string -> [expr]
    -> (jexpr, state) *)
and builtin ctx st scope e name args =
  let info = expr_info e in
  let values, st = exprs ctx st scope args in
  let arg_type i = type_of ctx scope (List.nth args i) in
  let one () = List.hd values in
  let helper h = atom (Printf.sprintf "%s(%s)" (rt h) (one ()).text) in
  match (name, values) with
  | "range", _ -> (atom (Printf.sprintf "%s(%s)" (rt "range") (String.concat ", " (List.map (fun v -> v.text) values))), st)
  | "len", [ v ] -> (
      match arg_type 0 with
      | TString _ -> (helper "len", st)
      | _ -> (atom (at p_atom v ^ ".size()"), st))
  | "string", [ v ] -> (printed ctx (arg_type 0) v, st)
  | "int", [ v ] -> (
      match arg_type 0 with
      | TInt _ -> (v, st)
      | TFloat _ -> (helper "truncate", st)
      | TBool _ -> (mk p_cond (Printf.sprintf "%s ? 1 : 0" (at (p_cond + 1) v)), st)
      | TString _ -> (helper "intOfString", st)
      | _ -> unsupported info "`int` of this type")
  | "float", [ v ] -> (
      match arg_type 0 with
      | TFloat _ -> (v, st)
      | TInt _ -> (mk p_unary (Printf.sprintf "(double) %s" (at p_unary (unboxed ctx (TInt (info, 0)) v))), st)
      | TBool _ -> (mk p_cond (Printf.sprintf "%s ? 1.0 : 0.0" (at (p_cond + 1) v)), st)
      | TString _ -> (helper "floatOfString", st)
      | _ -> unsupported info "`float` of this type")
  | "bool", [ v ] -> (
      match arg_type 0 with
      | TBool _ -> (v, st)
      | TInt _ -> (equal ctx (TInt (info, 0)) v (atom "1"), st)
      | TFloat _ -> (equal ctx (TFloat (info, 0)) v (atom "1.0"), st)
      | TString _ -> (atom (Printf.sprintf "%s.equals(%s)" (quote "true") v.text), st)
      | _ -> unsupported info "`bool` of this type")
  | _ -> unsupported info (Printf.sprintf "the builtin `%s` with these arguments" name)

(** The line a print writes: its arguments' texts, a space between.
    ctx -> state -> scope -> [expr] -> (jexpr, state) *)
and print_text ctx st scope args =
  let values, st = exprs ctx st scope args in
  let texts = List.map2 (fun a v -> printed ctx (type_of ctx scope a) v) args values in
  match texts with
  | [] -> (atom (quote ""), st)
  | [ one ] -> (one, st)
  | first :: rest ->
      (List.fold_left (fun acc t -> binary p_add "+" (binary p_add "+" acc (atom (quote " "))) t) first rest, st)

(** `(x, y) => e` as a Java lambda. ctx -> state -> scope -> expr ->
    [param] -> expr -> (jexpr, state) *)
and lambda ctx st scope e params body =
  let t = type_of ctx scope e in
  let _, ps, r = function_parts t in
  let ps = if List.length ps = List.length params then ps else List.map (fun _ -> TUnknown (expr_info e, 0)) params in
  let names, inner, st =
    List.fold_left2
      (fun (names, inner, st) (Param (_, n, _, _, _)) pt ->
        let jname, st = fresh st n in
        (names @ [ jname ], bind_value inner n { value = atom ~boxed:true jname; kind = BLocal; btype = pt; jname_ = jname }, st))
      ([], scope, st) params ps
  in
  let head = match names with [ n ] -> n | ns -> "(" ^ String.concat ", " ns ^ ")" in
  if is_unit r then
    let stmts, st = effect_of ctx st inner body in
    (mk p_lambda (Printf.sprintf "%s -> { %s return null; }" head (flat stmts)), st)
  else
    let v, st = expr ctx st inner body in
    (mk p_lambda (Printf.sprintf "%s -> %s" head v.text), st)

(** An expression evaluated for its effect_of alone, as statements.
    ctx -> state -> scope -> expr -> ([jstmt], state) *)
and effect_of ctx st scope e =
  match e with
  | ETuple (_, [], _) -> ([], st)
  | ECall (_, EVar (_, name, callee), args, _)
    when Builtin.crosses_host name && not (IntMap.mem callee ctx.tmap) ->
      let line, st = print_text ctx st scope (arg_exprs args) in
      ( [ JLine
            (Printf.sprintf "System.%s.println(%s);" (if Builtin.is_debug name then "err" else "out")
               (if args = [] then "" else line.text)) ],
        st )
  | ECall (_, func, _, _) when not (match func with EVar (_, n, _) -> List.mem n Builtin.pure_names && not (SMap.mem n scope.names) | _ -> false) -> (
      let v, st = expr ctx st scope e in
      (* A call to a method answering nothing is the statement itself. *)
      let prefix = rt "unit" ^ "(() -> " in
      if String.length v.text > String.length prefix && String.sub v.text 0 (String.length prefix) = prefix then
        ([ JLine (String.sub v.text (String.length prefix) (String.length v.text - String.length prefix - 1) ^ ";") ], st)
      else ([ JLine (v.text ^ ";") ], st))
  | e ->
      if
        Walk.exists (fun n -> match n with Walk.NExpr (ECall _) -> true | _ -> false) (Walk.NExpr e)
      then
        let v, st = expr ctx st scope e in
        ([ JLine (Printf.sprintf "%s(%s);" (rt "ignore") v.text) ], st)
      else ([], st)

(** `[e for p in xs if c]`: each `for` a flatMap over its sequence, its
    pattern's test and every `if` after it deciding whether a turn gives
    anything. ctx -> state -> scope -> expr -> expr -> [comp_clause] ->
    (jexpr, state) *)
and comprehension ctx st scope e element clauses =
  let t = type_of ctx scope e in
  let st = need_type st t in
  let empty = Printf.sprintf "%s.empty()" runtime_class in
  let rec build st scope clauses =
    match clauses with
    | [] ->
        let v, st = expr ctx st scope element in
        (Printf.sprintf "%s.single(%s)" runtime_class v.text, st)
    | CompFor (_, p, sequence, _) :: rest ->
        let seq, st = expr ctx st scope sequence in
        let seq_t = type_of ctx scope sequence in
        let element_t = match seq_t with TList (_, el, _) -> el | _ -> TUnknown (no_info, 0) in
        let item, st = temp st "i" in
        let conds, binds, st = pattern ctx st p (atom ~boxed:true item) element_t true in
        let decls, inner, st = bind_all ctx st scope binds in
        let guards, rest = take_ifs rest in
        let guard_texts, st =
          List.fold_left
            (fun (out, st) g ->
              let v, st = expr ctx st inner g in
              (out @ [ v ], st))
            ([], st) guards
        in
        let body, st = build st inner rest in
        let inner_stmts =
          decls
          @ [ (if guard_texts = [] then JReturn (Some body)
               else JIf ((conjunction guard_texts).text, [ JReturn (Some body) ], None)) ]
        in
        let block =
          if conds = [] then inner_stmts else [ JIf ((conjunction conds).text, inner_stmts, None) ]
        in
        let block = reachable (block @ [ JReturn (Some empty) ]) in
        ( Printf.sprintf "%s.flatMap(%s, %s -> { %s })" runtime_class seq.text item (flat block),
          st )
    | CompIf (_, c, _) :: rest ->
        let v, st = expr ctx st scope c in
        let body, st = build st scope rest in
        (Printf.sprintf "(%s ? %s : %s)" (at (p_cond + 1) v) body empty, st)
  in
  let text, st = build st scope clauses in
  (atom text, st)

and take_ifs clauses =
  match clauses with
  | CompIf (_, c, _) :: rest ->
      let more, rest = take_ifs rest in
      (c :: more, rest)
  | rest -> ([], rest)

(** Statements on one line, for a lambda's body. [jstmt] -> string *)
and flat stmts = String.concat " " (List.map flat_stmt stmts)

and flat_stmt s =
  match s with
  | JLine l -> l
  | JIf (c, t, None) -> Printf.sprintf "if (%s) { %s }" c (flat t)
  | JIf (c, t, Some e) -> Printf.sprintf "if (%s) { %s } else { %s }" c (flat t) (flat e)
  | JReturn None -> "return;"
  | JReturn (Some v) -> Printf.sprintf "return %s;" v
  | JThrow -> "throw new IllegalStateException();"
  | JBlock (None, b) -> "{ " ^ flat b ^ " }"
  | JBlock (Some l, b) -> l ^ ": { " ^ flat b ^ " }"
  | JWhile (l, c, b) -> Printf.sprintf "%s: while (%s) { %s }" l (Option.value c ~default:"true") (flat b)
  | JFor (l, h, b) -> Printf.sprintf "%s: for (%s) { %s }" l h (flat b)
  | JSwitch (sel, arms) ->
      Printf.sprintf "switch (%s) { %s }" sel
        (String.concat " " (List.map (fun (lab, b) -> Printf.sprintf "%s -> { %s }" lab (flat b)) arms))
  | JBreak None -> "break;"
  | JBreak (Some l) -> "break " ^ l ^ ";"
  | JContinue -> "continue;"

(* --- statements --- *)

(* What becomes of the value a block ends in. *)
type finish =
  | Return (* a method's: `return v;` *)
  | ReturnVoid (* a method answering nothing *)
  | Assign of string (* a value-form binding's local *)
  | Discard (* a block whose value nobody reads *)
  | Turn of loopinfo (* the next turn of a loop *)

(** The statements a block's last value is finished with.
    ctx -> state -> finish -> typ -> jexpr -> ([jstmt], state) *)
let finished ctx st fin t v =
  ignore ctx;
  match fin with
  | Return -> ([ JReturn (Some v.text) ], st)
  | ReturnVoid | Discard -> ([], st)
  | Assign name -> ([ JLine (Printf.sprintf "%s = %s;" name v.text) ], st)
  | Turn l -> (
      match l.slots with
      | [] -> ([], st)
      | [ (name, _) ] -> ([ JLine (Printf.sprintf "%s = %s;" name v.text) ], st)
      | slots ->
          let held, st = temp st "next" in
          let decl = JLine (Printf.sprintf "final %s %s = %s;" (jt ctx t) held v.text) in
          ( decl
            :: List.mapi
                 (fun i (name, _) -> JLine (Printf.sprintf "%s = %s;" name (tuple_get ctx (atom held) i).text))
                 slots,
            st ))

(** A sequence of statements, each `def` in it declared first.
    ctx -> state -> scope -> [stmt] -> ([jstmt], scope, state) *)
let rec stmts ctx st scope statements =
  let scope = { scope with block = statements } in
  let scope, st = declare_defs ctx st scope statements in
  let out, scope, st =
    List.fold_left
      (fun (out, scope, st) s ->
        let translated, scope, st = stmt ctx st scope s in
        (out @ translated, scope, st))
      ([], scope, st) statements
  in
  (reachable out, scope, st)

(** A block whose last statement's value is finished by fin.
    ctx -> state -> scope -> finish -> [stmt] -> ([jstmt], state) *)
and tail_block ctx st scope fin statements =
  match statements with
  | [] -> finished ctx st fin (TTuple (no_info, [], 0)) null_expr |> fun (s, st) -> (s, st)
  | _ ->
      let scope = { scope with block = statements } in
      let scope, st = declare_defs ctx st scope statements in
      let count = List.length statements in
      let front = List.filteri (fun i _ -> i < count - 1) statements in
      let out, scope, st =
        List.fold_left
          (fun (out, scope, st) s ->
            let translated, scope, st = stmt ctx st scope s in
            (out @ translated, scope, st))
          ([], scope, st) front
      in
      let last, st = tail ctx st scope fin (List.nth statements (count - 1)) in
      (reachable (out @ last), st)

(** The last statement of a block, its value finished by fin.
    ctx -> state -> scope -> finish -> stmt -> ([jstmt], state) *)
and tail ctx st scope fin s =
  match s with
  | SExprStmt (_, e, _) -> (
      let t = type_of ctx scope e in
      match fin with
      | ReturnVoid | Discard | Turn { slots = []; _ } -> effect_then ctx st scope e []
      | _ when is_unit t ->
          let after, st = finished ctx st fin t null_expr in
          effect_then ctx st scope e after
      | _ ->
          let v, st = expr ctx st scope e in
          finished ctx st fin t v)
  | SIf (_, c, then_body, else_body, _) -> (
      let cond, st = expr ctx st scope c in
      match else_body with
      | Some else_body ->
          let t_stmts, st = tail_block ctx st scope fin then_body in
          let e_stmts, st = tail_block ctx st scope fin else_body in
          ([ JIf (cond.text, t_stmts, Some e_stmts) ], st)
      | None ->
          (* No `else`: the statement supplies unit whichever way it
             goes. *)
          let plain, _, st = stmts ctx st scope then_body in
          let after, st = finished ctx st fin (TTuple (no_info, [], 0)) null_expr in
          (JIf (cond.text, plain, None) :: after, st))
  | SMatch (_, subject, cases, _) -> match_stmt ctx st scope subject cases fin
  | SLoop _ -> (
      let loop_stmts, value, t, st = loop ctx st scope s in
      let rest, st =
        match (value, fin) with
        | _, (ReturnVoid | Discard) -> ([], st)
        | Some v, _ -> finished ctx st fin t v
        | None, _ -> finished ctx st fin (TTuple (no_info, [], 0)) null_expr
      in
      if block_completes loop_stmts then (loop_stmts @ rest, st) else (loop_stmts, st))
  | SReturn _ | SReturnStmt _ | SBreak _ | SContinue _ ->
      let translated, _, st = stmt ctx st scope s in
      (translated, st)
  | s -> (
      let translated, _, st = stmt ctx st scope s in
      match fin with
      | Return | Assign _ | Turn _ ->
          let unit_fin, st = finished ctx st fin (TTuple (no_info, [], 0)) null_expr in
          (translated @ unit_fin, st)
      | _ -> (translated, st))

and effect_then ctx st scope e after =
  let s, st = effect_of ctx st scope e in
  (s @ after, st)

(** Translates one statement. ctx -> state -> scope -> stmt ->
    ([jstmt], scope, state) *)
and stmt ctx st scope s =
  match s with
  | SLet (_, target, e, _, _, _, _) ->
      let v, st = expr ctx st scope e in
      let t = type_of ctx scope e in
      destructure ctx st scope target v t
  | SLetStmt (_, target, inner, _, _, _) -> (
      let t =
        match IntMap.find_opt (stmt_sym s) ctx.tmap with
        | Some t -> t
        | None -> (match inner with SLoop _ -> TUnknown (no_info, 0) | _ -> TUnknown (no_info, 0))
      in
      match inner with
      | SLoop _ ->
          let loop_stmts, value, lt, st = loop ctx st scope inner in
          let v = Option.value value ~default:null_expr in
          let decls, scope, st = destructure ctx st scope target v (match t with TUnknown _ -> lt | t -> t) in
          (loop_stmts @ decls, scope, st)
      | _ -> (
          let t = match t with TUnknown _ -> target_type ctx scope target | t -> t in
          match target with
          | TargetName (_, name, _) ->
              let jname, st = fresh st name in
              let st = note_local st jname (jt ctx t) in
              let body, st = tail ctx st scope (Assign jname) inner in
              let scope =
                bind_value scope name { value = atom jname; kind = BLocal; btype = t; jname_ = jname }
              in
              (JLine (Printf.sprintf "final %s %s;" (jt ctx t) jname) :: body, scope, st)
          | target ->
              let held, st = temp st "v" in
              let body, st = tail ctx st scope (Assign held) inner in
              let decls, scope, st = destructure ctx st scope target (atom held) t in
              ((JLine (Printf.sprintf "final %s %s;" (jt ctx t) held) :: body) @ decls, scope, st)))
  | SVar (_, name, e, _) ->
      let v, st = expr ctx st scope e in
      let t = type_of ctx scope e in
      let jname, st = fresh st name in
      if StringSet.mem name scope.cells then
        let st = note_local st jname (jt ctx t ^ "[]") in
        let created =
          if String.contains (jt ctx t) '<' then Printf.sprintf "%s.cell(%s)" runtime_class v.text
          else Printf.sprintf "{ %s }" v.text
        in
        ( [ JLine (Printf.sprintf "final %s[] %s = %s;" (jt ctx t) jname created) ],
          bind_value scope name { value = atom (jname ^ "[0]"); kind = BCell; btype = t; jname_ = jname },
          st )
      else
        let st = note_local st jname (jt ctx t) in
        ( [ JLine (Printf.sprintf "%s %s = %s;" (jt ctx t) jname v.text) ],
          bind_value scope name { value = atom jname; kind = BMutable; btype = t; jname_ = jname },
          st )
  | SMutate (info, name, e, _) ->
      let v, st = expr ctx st scope e in
      let b = lookup scope info name in
      ([ JLine (Printf.sprintf "%s = %s;" b.value.text v.text) ], scope, st)
  | SReturn (_, e, _) ->
      let t = type_of ctx scope e in
      if is_unit t && current_void ctx st then
        let s, st = effect_of ctx st scope e in
        (s @ [ JReturn None ], scope, st)
      else
        let v, st = expr ctx st scope e in
        ([ JReturn (Some v.text) ], scope, st)
  | SReturnStmt (_, inner, _) ->
      let fin = if current_void ctx st then ReturnVoid else Return in
      let body, st = tail ctx st scope fin inner in
      let body = if fin = ReturnVoid && block_completes body then body @ [ JReturn None ] else body in
      (body, scope, st)
  | SExprStmt (_, e, _) ->
      let s, st = effect_of ctx st scope e in
      (s, scope, st)
  | SLoop _ ->
      let loop_stmts, _, _, st = loop ctx st scope s in
      (loop_stmts, scope, st)
  | SBreak _ -> (
      match List.rev scope.loops with
      | l :: _ when scope.in_switch -> ([ JBreak (Some l.label) ], scope, st)
      | _ -> ([ JBreak None ], scope, st))
  | SContinue _ -> ([ JContinue ], scope, st)
  | SIf (_, c, then_body, else_body, _) ->
      let cond, st = expr ctx st scope c in
      let t_stmts, _, st = stmts ctx st scope then_body in
      let e_stmts, st =
        match else_body with
        | None -> (None, st)
        | Some b ->
            let e_stmts, _, st = stmts ctx st scope b in
            (Some e_stmts, st)
      in
      ([ JIf (cond.text, t_stmts, e_stmts) ], scope, st)
  | SMatch (_, subject, cases, _) ->
      let out, st = match_stmt ctx st scope subject cases Discard in
      (out, scope, st)
  | SFunctionDef _ ->
      let st = lift ctx st scope s in
      ([], scope, st)
  | SFunctionSig _ | SImport _ | SDatatype _ -> ([], scope, st)

(** Whether the method being translated answers nothing.
    ctx -> state -> bool *)
and current_void _ctx st = String.length st.current > 0 && st.current.[0] = '!'

(** The type an assignment target binds, from the names the checker
    recorded. ctx -> scope -> assign_target -> typ *)
and target_type ctx scope target =
  match target with
  | TargetName (i, _, sym) -> (
      match IntMap.find_opt sym ctx.tmap with Some t -> t | None -> TUnknown (i, 0))
  | TargetTuple (i, ts, _) -> TTuple (i, List.map (target_type ctx scope) ts, 0)

(** A target bound to v, a value of type t. ctx -> state -> scope ->
    assign_target -> jexpr -> typ -> ([jstmt], scope, state) *)
and destructure ctx st scope target v t =
  match target with
  | TargetName (_, name, _) ->
      let jname, scope, st = new_local ctx st scope name t in
      ([ declare ctx jname t v ], scope, st)
  | TargetTuple (_, targets, _) ->
      let held, st = temp st "t" in
      let st = need_type st t in
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> TUnknown (no_info, 0)) targets in
      let first = declare ctx held t v in
      let out, scope, st =
        List.fold_left
          (fun (out, scope, st) (i, (target, ty)) ->
            let s, scope, st = destructure ctx st scope target (tuple_get ctx (atom held) i) ty in
            (out @ s, scope, st))
          ([ first ], scope, st)
          (List.mapi (fun i x -> (i, x)) (List.combine targets types))
      in
      (out, scope, st)

(** A `match`, its every case's body finished by fin: an if/else chain on
    java8 and java17, a labelled block where a case has a guard, and a
    pattern switch on java21.
    ctx -> state -> scope -> expr -> [match_case] -> finish -> ([jstmt], state) *)
and match_stmt ctx st scope subject cases fin =
  let v, st = expr ctx st scope subject in
  let t = type_of ctx scope subject in
  let st = need_type st t in
  let held, st = temp st "s" in
  let boxed_type = if ctx.shape = Java21 then jt ctx ~boxed:true t else jt ctx t in
  let hold = JLine (Printf.sprintf "final %s %s = %s;" boxed_type held v.text) in
  let s = atom ~boxed:(ctx.shape = Java21) held in
  match ctx.shape with
  | Java21 -> switch_stmt ctx st scope s t cases fin hold
  | _ ->
      let count = List.length cases in
      let guarded = List.exists (fun c -> case_guard c <> None) cases in
      let arm st i (MatchCase (_, p, guard, body, _)) =
        let last = i = count - 1 in
        let conds, binds, st = pattern ctx st p s t (not last) in
        let decls, inner, st = bind_all ctx st scope binds in
        let body, st = tail_block ctx st inner fin body in
        (last, conds, decls, guard, inner, body, st)
      in
      if not guarded then
        let arms, st =
          List.fold_left
            (fun (out, st) (i, c) ->
              let last, conds, decls, _, _, body, st = arm st i c in
              (out @ [ (last, conds, decls @ body) ], st))
            ([], st)
            (List.mapi (fun i c -> (i, c)) cases)
        in
        let chain =
          List.fold_right
            (fun (last, conds, body) chain ->
              match (last, chain) with
              | true, _ -> Some body
              | false, None -> Some [ JIf ((conjunction conds).text, body, None) ]
              | false, Some rest -> Some [ JIf ((conjunction conds).text, body, Some rest) ])
            arms None
        in
        (hold :: Option.value chain ~default:[], st)
      else
        let label, st = temp st "match" in
        let arms, st =
          List.fold_left
            (fun (out, st) (i, c) ->
              let last, conds, decls, guard, inner, body, st = arm st i c in
              let leave = if block_completes body then body @ [ JBreak (Some label) ] else body in
              let guarded, st =
                match guard with
                | None -> (decls @ leave, st)
                | Some g ->
                    let gv, st = expr ctx st inner g in
                    (decls @ [ JIf (gv.text, leave, None) ], st)
              in
              let one = if last && guard = None then JBlock (None, guarded) else JIf ((conjunction conds).text, guarded, None) in
              (out @ [ one ], st))
            ([], st)
            (List.mapi (fun i c -> (i, c)) cases)
        in
        let arms = if block_completes arms then arms @ [ JThrow ] else arms in
        ([ hold; JBlock (Some label, reachable arms) ], st)

(** A `match` as a java21 pattern switch: a record pattern for a case
    that takes a constructor or a tuple apart, a type pattern otherwise,
    and every other test in its `when`.
    ctx -> state -> scope -> jexpr -> typ -> [match_case] -> finish -> jstmt
    -> ([jstmt], state) *)
and switch_stmt ctx st scope s t cases fin hold =
  (* A guard may read only final locals: a reassigned one it reads is
     copied into one first. *)
  let guarded = List.concat_map (fun c -> match case_guard c with Some g -> [ SExprStmt (no_info, g, 0) ] | None -> []) cases in
  let read = mentioned guarded in
  let copies, scope, st =
    StringSet.fold
      (fun n (copies, scope, st) ->
        match SMap.find_opt n scope.names with
        | Some ({ kind = BMutable; _ } as b) ->
            let jname, st = fresh st n in
            ( copies @ [ JLine (Printf.sprintf "final %s %s = %s;" (jt ctx b.btype) jname b.value.text) ],
              bind_value scope n { b with value = atom jname; kind = BLocal; jname_ = jname },
              st )
        | _ -> (copies, scope, st))
      read ([], scope, st)
  in
  let hold = match copies with [] -> hold | _ -> JBlock (None, []) |> fun _ -> hold in
  let in_switch = { scope with in_switch = true } in
  let arms, total, st =
    List.fold_left
      (fun (out, total, st) (MatchCase (_, p, guard, body, _)) ->
        let label_pattern, conds, binds, st = switch_pattern ctx st p s t true in
        let guard_conds, st =
          match guard with
          | None -> ([], st)
          | Some g ->
              let gv, st = expr ctx st (bind_places in_switch binds) g in
              ([ gv ], st)
        in
        let all = conds @ guard_conds in
        (* javac misreads a guard that opens with a parenthesis. *)
        let guard_text =
          let text = (conjunction all).text in
          if String.length text > 0 && text.[0] = '(' then Printf.sprintf "%s(%s)" (rt "truth") text else text
        in
        let label = "case " ^ label_pattern ^ if all = [] then "" else " when " ^ guard_text in
        let decls, inner, st = bind_all ctx st in_switch binds in
        let body, st = tail_block ctx st inner fin body in
        let is_total = all = [] && String.length label_pattern > 0 && is_type_pattern label_pattern in
        (out @ [ (label, decls @ body) ], total || is_total, st))
      ([], false, st) cases
  in
  let arms = if total then arms else arms @ [ ("default", [ JThrow ]) ] in
  ((hold :: copies) @ [ JSwitch (s.text, arms) ], st)

and is_type_pattern label = not (String.contains label '(')

(** One case's pattern as a switch label: the pattern text, the tests
    left for its `when`, and its bindings.
    ctx -> state -> pattern -> jexpr -> typ -> bool
    -> (string, [jexpr], [(string, jexpr, typ)], state) *)
and switch_pattern ctx st p s t top =
  match p with
  | PConstructor (_, _, name, fields, _, _) ->
      let info = pattern_info p in
      let canonical, args = match t with TCon (_, c, a, _) -> (c, a) | _ -> ("", []) in
      let cls = ctor_ref ctx canonical name ^ if args = [] then "" else "<" ^ targs ctx args ^ ">" in
      let declared = ctor_fields ctx info t name in
      let subs, conds, binds, st = switch_parts ctx st fields (List.map snd declared) in
      (Printf.sprintf "%s(%s)" cls (String.concat ", " subs), conds, binds, st)
  | PTuple (_, ps, _) ->
      let types = match t with TTuple (_, ts, _) -> ts | _ -> [] in
      let subs, conds, binds, st = switch_parts ctx st ps types in
      (Printf.sprintf "%s.T%d<%s>(%s)" runtime_class (List.length ps) (targs ctx types) (String.concat ", " subs), conds, binds, st)
  | PAs (_, inner, name, _) when top ->
      let label, conds, binds, st = switch_pattern ctx st inner s t top in
      (label, conds, binds @ [ (name, s, t) ], st)
  | p ->
      let held, st = temp st "t" in
      let conds, binds, st = pattern ctx st p (atom ~boxed:true held) t false in
      (jt ctx ~boxed:true t ^ " " ^ held, conds, binds, st)

(** The components of a record pattern: a nested record pattern where a
    sub-pattern takes a constructor or a tuple apart, `var` with its
    tests in the `when` otherwise.
    ctx -> state -> [pattern] -> [typ]
    -> ([string], [jexpr], [(string, jexpr, typ)], state) *)
and switch_parts ctx st ps types =
  List.fold_left
    (fun (subs, conds, binds, st) (p, ty) ->
      match p with
      | PConstructor _ | PTuple _ ->
          let label, c, b, st = switch_pattern ctx st p null_expr ty false in
          (subs @ [ label ], conds @ c, binds @ b, st)
      | p ->
          let held, st = temp st "t" in
          let c, b, st = pattern ctx st p (atom ~boxed:true held) ty false in
          (subs @ [ "var " ^ held ], conds @ c, binds @ b, st))
    ([], [], [], st)
    (List.combine ps (if List.length types = List.length ps then types else List.map (fun _ -> TUnknown (no_info, 0)) ps))

(** A loop: its statements, the expression holding its value afterwards
    and that value's type.
    ctx -> state -> scope -> stmt -> ([jstmt], jexpr?, typ, state) *)
and loop ctx st scope s =
  match s with
  | SLoop (info, target, init, _, iterate, body, _) ->
      let label, st = temp st "loop" in
      let carrier = writes_closure body in
      (* The accumulator, worked out before a `for`'s sequence. *)
      let slot_names = match target with Some t -> target_names t | None -> [] in
      let acc_t =
        match (target, init) with
        | Some target, Some init -> (
            match type_of ctx scope init with TUnknown _ -> target_type ctx scope target | t -> t)
        | _ -> TTuple (info, [], 0)
      in
      let st = need_type st acc_t in
      let slot_types =
        match (slot_names, acc_t) with
        | [ _ ], t -> [ t ]
        | names, TTuple (_, ts, _) when List.length ts = List.length names -> ts
        | names, _ -> List.map (fun _ -> TUnknown (info, 0)) names
      in
      let init_values, st =
        match (init, slot_names) with
        | Some (ETuple (_, es, _)), names when List.length es = List.length names && List.length names > 1 -> exprs ctx st scope es
        | Some e, [ _ ] ->
            let v, st = expr ctx st scope e in
            ([ v ], st)
        | Some e, names ->
            let v, st = expr ctx st scope e in
            (List.mapi (fun i _ -> tuple_get ctx v i) names, st)
        | None, _ -> ([], st)
      in
      (* Each slot's local: the one every turn writes, and -- where the
         body writes a closure -- the final one each turn reads. *)
      let slots, setup, st =
        List.fold_left
          (fun (slots, setup, st) ((name, ty), v) ->
            let outer, st = fresh st (if carrier then name ^ "$c" else name) in
            let st = note_local st outer (jt ctx ty) in
            (slots @ [ (outer, ty, name) ], setup @ [ JLine (Printf.sprintf "%s %s = %s;" (jt ctx ty) outer v.text) ], st))
          ([], [], st)
          (List.combine (List.combine slot_names slot_types) init_values)
      in
      let this = { label; slots = List.map (fun (o, ty, _) -> (o, ty)) slots } in
      let inner = { scope with loops = scope.loops @ [ this ]; in_switch = false } in
      let inner, turn_decls, st =
        List.fold_left
          (fun (inner, decls, st) (outer, ty, name) ->
            if carrier then
              let jname, inner, st = new_local ctx st inner name ty in
              (inner, decls @ [ JLine (Printf.sprintf "final %s %s = %s;" (jt ctx ty) jname outer) ], st)
            else
              (bind_value inner name { value = atom outer; kind = BMutable; btype = ty; jname_ = outer }, decls, st))
          (inner, [], st) slots
      in
      let value =
        match slots with
        | [] -> None
        | [ (outer, _, _) ] -> Some (atom outer)
        | slots ->
            Some
              (atom
                 (Printf.sprintf "new %s.T%d<%s>(%s)" runtime_class (List.length slots)
                    (targs ctx (List.map (fun (_, ty, _) -> ty) slots))
                    (String.concat ", " (List.map (fun (o, _, _) -> o) slots))))
      in
      let fin = Turn this in
      let st = if List.length slots > 1 then need_tuple st (List.length slots) else st in
      (match iterate with
      | Some (ForIn (_, element, sequence, _)) ->
          let seq, st = expr ctx st scope sequence in
          let element_t = match type_of ctx scope sequence with TList (_, el, _) -> el | _ -> TUnknown (info, 0) in
          let jname, inner, st = new_local ctx st inner element element_t in
          let body_stmts, st = tail_block ctx st inner fin body in
          ( setup @ [ JFor (label, Printf.sprintf "final %s %s : %s" (jt ctx element_t) jname seq.text, turn_decls @ body_stmts) ],
            value,
            acc_t,
            st )
      | Some (WhileTest (_, condition, _)) ->
          let test_scope =
            List.fold_left
              (fun inner (outer, ty, name) -> bind_value inner name { value = atom outer; kind = BMutable; btype = ty; jname_ = outer })
              inner slots
          in
          let c, st = expr ctx st test_scope condition in
          (* javac reads a constant condition as one it knows, and refuses
             the body of `while (false)`. *)
          let constant =
            not
              (Walk.exists
                 (fun n ->
                   match n with
                   | Walk.NExpr (EVar _ | ECall _ | EQualified _ | EField _) -> true
                   | _ -> false)
                 (Walk.NExpr condition))
          in
          let c = if constant then atom (Printf.sprintf "%s(%s)" (rt "truth") c.text) else c in
          let body_stmts, st = tail_block ctx st inner fin body in
          (setup @ [ JWhile (label, Some c.text, turn_decls @ body_stmts) ], value, acc_t, st)
      | None ->
          let body_stmts, st = tail_block ctx st inner fin body in
          (setup @ [ JWhile (label, None, turn_decls @ body_stmts) ], value, acc_t, st))
  | _ -> ([], None, TTuple (no_info, [], 0), st)

(** The names a loop's accumulator binds, in order. assign_target ->
    [string] *)
and target_names target =
  match target with
  | TargetName (_, n, _) -> [ n ]
  | TargetTuple (_, ts, _) -> List.concat_map target_names ts

(** Every def of a block bound before any statement of it is translated:
    a def is visible throughout its block. A nested one is a lifted
    method. ctx -> state -> scope -> [stmt] -> (scope, state) *)
and declare_defs ctx st scope statements =
  List.fold_left
    (fun (scope, st) s ->
      match s with
      | SFunctionDef (_, name, _, _, _, sym, _, _, _) ->
          let t = Option.value (IntMap.find_opt sym ctx.tmap) ~default:(TUnknown (no_info, 0)) in
          let _, _, r = function_parts t in
          let base = (if st.current = "" then "main" else String.map (fun c -> if c = '!' then '_' else c) st.current) ^ "$" ^ name in
          let base = if String.length base > 0 && base.[0] = '_' then String.sub base 1 (String.length base - 1) else base in
          let rec go candidate n =
            if StringSet.mem candidate st.methods_taken then go (Printf.sprintf "%s%d" base n) (n + 1) else candidate
          in
          let jname = go base 2 in
          let st = { st with methods_taken = StringSet.add jname st.methods_taken } in
          ( bind_value scope name
              {
                value = atom jname;
                kind = BMethod { jname; lifted = true; void = is_unit r; mtype = t; external_ = false };
                btype = t;
                jname_ = jname;
              },
            st )
      | _ -> (scope, st))
    (scope, st) statements

(** A nested def as a static method of its own, taking what it captures
    before its parameters. ctx -> state -> scope -> stmt -> state *)
and lift ctx st scope s =
  match s with
  | SFunctionDef (_, name, params, body, _, _, _, _, _) -> (
      match SMap.find_opt name scope.names with
      | Some { kind = BMethod _; _ } when unreferenced s scope.block -> st
      | Some { kind = BMethod m; _ } ->
          let free = mentioned body in
          let direct, reaches =
            StringSet.fold
              (fun n (direct, reaches) ->
                match SMap.find_opt n scope.names with
                | Some { kind = BCell; jname_; btype; _ } when jname_ <> "" ->
                    (direct @ [ (jname_, jt ctx btype ^ "[]") ], reaches)
                | Some { kind = BLocal | BMutable; jname_; btype; _ } when jname_ <> "" ->
                    (direct @ [ (jname_, jt ctx btype) ], reaches)
                | Some { kind = BMethod { lifted = true; jname; _ }; _ } when jname <> m.jname -> (direct, reaches @ [ jname ])
                | _ -> (direct, reaches))
              free ([], [])
          in
          let inside =
            if String.length st.current > 0 && st.current.[0] = '!' then
              String.sub st.current 1 (String.length st.current - 1)
            else st.current
          in
          let st = { st with captures = st.captures @ [ (m.jname, { direct; reaches; inside }) ] } in
          (* Inside, a captured local is a parameter of the same name. *)
          let inner =
            {
              scope with
              loops = [];
              in_switch = false;
              cells = StringSet.union scope.cells (captured_vars body);
              names =
                SMap.map
                  (fun b ->
                    match b.kind with
                    | BMutable -> { b with kind = BLocal }
                    | _ -> b)
                  scope.names;
            }
          in
          let saved = st.current in
          let st = { st with current = (if m.void then "!" else "") ^ m.jname } in
          let jm, st = method_of ctx st inner m.jname params body m.mtype false true in
          let st = { st with current = saved; lifted = st.lifted @ [ jm ] } in
          st
      | _ -> st)
  | _ -> st

(** One method: its parameters bound and its body finished by returning.
    ctx -> state -> scope -> string -> [param] -> [stmt] -> typ -> bool
    -> bool -> (jmethod, state) *)
and method_of ctx st scope jname params body t public lifted =
  let vars, ps, r = function_parts t in
  let ps = if List.length ps = List.length params then ps else List.map (fun _ -> TUnknown (no_info, 0)) params in
  let st = List.fold_left need_type st (r :: ps) in
  let scope = { scope with tvars = distinct (scope.tvars @ vars); cells = StringSet.union scope.cells (captured_vars body) } in
  let jparams, scope, st =
    List.fold_left2
      (fun (out, scope, st) (Param (_, n, _, _, _)) pt ->
        let pname, st = fresh st n in
        let st = note_local st pname (jt ctx pt) in
        (out @ [ (jt ctx pt, pname) ], bind_value scope n { value = atom pname; kind = BLocal; btype = pt; jname_ = pname }, st))
      ([], scope, st) params ps
  in
  let void = is_unit r in
  let fin = if void then ReturnVoid else Return in
  let body_stmts, st = tail_block ctx st scope fin body in
  let body_stmts =
    if (not void) && block_completes body_stmts then body_stmts @ [ JThrow ] else body_stmts
  in
  let tparams =
    distinct (List.concat_map declared_vars (r :: ps) @ (if lifted then scope.tvars else vars))
  in
  ( {
      m_name = jname;
      m_public = public;
      m_tparams = List.map (tvar ctx) tparams;
      m_result = (if void then "void" else jt ctx r);
      m_params = jparams;
      m_captures = lifted;
      m_body = body_stmts;
    },
    st )

(* --- a module --- *)

type jdatatype = {
  d_type : string;
  d_params : string list;
  d_shared : (string * string) list; (* field, type *)
  d_ctors : (string * string * (string * string) list) list; (* class, Pyking name, fields *)
  d_public : bool;
}

type jprogram = {
  class_name_ : string;
  program_name : string;
  main : bool;
  starts : string list;
  statics : (bool * string * string) list; (* public, type, name *)
  methods : jmethod list;
  main_body : jstmt list;
  datatypes_ : jdatatype list;
  shape_ : shape;
  tuples_ : int list;
  fns_ : int list;
  polys_ : (string * string) list;
  capture_table : (string * capture) list;
  takes_args : bool;
}

(** A datatype of this module as the classes it is declared as.
    ctx -> datatype -> bool -> jdatatype *)
let jdatatype ctx (Datatype (_, params, ctors) as d) public =
  let plain = { ctx with class_names = StringSet.remove "" ctx.class_names } in
  let bound = List.map (fun p -> (p, TVar (no_info, p, 0, true))) params in
  let fields_of fs = List.mapi (fun i (label, t) -> (field_name label i, jt plain ~boxed:false (substitute bound t))) fs in
  let all = List.map (fun (_, fs) -> fields_of fs) ctors in
  let shared =
    match all with
    | first :: rest ->
        List.filter
          (fun (n, ty) -> (not (String.length n > 1 && n.[0] = 'f' && n.[1] = '$')) && List.for_all (fun fs -> List.mem (n, ty) fs) rest)
          first
    | [] -> []
  in
  {
    d_type = type_class ctx.own_class d;
    d_params = List.map (tvar ctx) params;
    d_shared = shared;
    d_ctors = List.map2 (fun (c, _) fs -> (ctor_class ctx.own_class c, c, fs)) ctors all;
    d_public = public;
  }

(** A top-level binding: a static field for each name, assigned in the
    top level's own method. ctx -> state -> scope -> statics ->
    assign_target -> jexpr -> typ -> bool
    -> ([jstmt], statics, scope, state) *)
let rec static_bindings ctx st scope statics target v t public =
  let t = match t with TForall (_, _, body, _) -> body | t -> t in
  match target with
  | TargetName (_, name, _) ->
      let jname, st =
        if public then (java_ident name, { st with taken = StringSet.add (java_ident name) st.taken }) else fresh st name
      in
      let erased = declared_vars t <> [] in
      let type_text = if erased then "Object" else jt ctx t in
      (* A value whose type has variables is held as Object, built at its
         type with the variables erased. *)
      let v = if erased then mk p_unary (Printf.sprintf "(%s) %s" (jt ctx ~erase:true t) (at p_unary v)) else v in
      ( [ JLine (Printf.sprintf "%s = %s;" jname v.text) ],
        statics @ [ (public, type_text, jname) ],
        bind_value scope name
          { value = atom ~boxed:erased jname; kind = (if erased then BErased else BStatic); btype = t; jname_ = "" },
        st )
  | TargetTuple (_, targets, _) ->
      let held, st = temp st "t" in
      let st = need_type st t in
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> TUnknown (no_info, 0)) targets in
      List.fold_left
        (fun (out, statics, scope, st) (i, (target, ty)) ->
          let s, statics, scope, st = static_bindings ctx st scope statics target (tuple_get ctx (atom held) i) ty public in
          (out @ s, statics, scope, st))
        ([ JLine (Printf.sprintf "final %s %s = %s;" (jt ctx t) held v.text) ], statics, scope, st)
        (List.mapi (fun i x -> (i, x)) (List.combine targets types))

(** One module of a program as a jprogram. `context` says what is true of
    it only as part of a program. [stmt] -> typ IntMap.t -> Module.context
    -> string -> jprogram *)
let translate_program stmts tmap (context : Module.context) version =
  let own_class = default_class_name context.context_name in
  if own_class = runtime_class then
    unsupported no_info (Printf.sprintf "a module whose Java class would be %s, which the runtime is" runtime_class);
  let own_datatypes =
    List.filter_map
      (function
        | SDatatype (_, _, _, _, sym, public) -> (
            match IntMap.find_opt sym tmap with Some (TData (_, d, _)) -> Some (d, public) | _ -> None)
        | _ -> None)
      stmts
  in
  let datatypes =
    List.fold_left
      (fun map (_, sigmap) ->
        List.fold_left
          (fun map (_, t, _) ->
            match t with TData (_, (Datatype (c, _, _) as d), _) -> SMap.add c d map | _ -> map)
          map sigmap)
      SMap.empty context.sigmaps
  in
  let datatypes = List.fold_left (fun map ((Datatype (c, _, _) as d), _) -> SMap.add c d map) datatypes own_datatypes in
  let class_names =
    List.fold_left
      (fun set ((Datatype (_, _, ctors) as d), _) ->
        List.fold_left (fun set (c, _) -> StringSet.add (ctor_class own_class c) set) (StringSet.add (type_class own_class d) set) ctors)
      (StringSet.singleton own_class) own_datatypes
  in
  let class_names =
    List.fold_left (fun set (m, _) -> StringSet.add (module_class m) set) class_names context.sigmaps
  in
  let modules =
    List.filter_map (function SImport (_, m, alias, false, _, _) -> Some (alias, m) | _ -> None) stmts
  in
  let ctx = { tmap; shape = shape_of version; context; own_class; datatypes; modules; class_names; erase = false } in
  let top = { ctx with erase = true } in
  let st =
    {
      (* main's own parameter. *)
      taken = StringSet.singleton "args";
      counter = 0;
      lifted = [];
      captures = [];
      tuples = [];
      fns = [];
      polys = [];
      current = "";
      methods_taken = StringSet.empty;
    }
  in
  let scope = { names = SMap.empty; loops = []; in_switch = false; tvars = []; cells = StringSet.empty; block = stmts } in
  (* What the module's own declaration half provides. *)
  let own_external = module_class (context.context_name ^ "_external") in
  let scope =
    List.fold_left
      (fun scope (field, t) ->
        match t with
        | TFunction _ | TForall (_, _, TFunction _, _) ->
            let _, _, r = function_parts t in
            bind_value scope field
              {
                value = atom (own_external ^ "." ^ field);
                kind = BMethod { jname = own_external ^ "." ^ java_ident field; lifted = false; void = is_unit r; mtype = t; external_ = true };
                btype = t;
                jname_ = "";
              }
        | t -> bind_value scope field { value = atom (own_external ^ "." ^ java_ident field); kind = BStatic; btype = t; jname_ = "" })
      scope context.own_declared
  in
  (* What a `from` line brings in. *)
  let scope =
    List.fold_left
      (fun scope s ->
        match s with
        | SImport (_, module_, _, true, fields, _) ->
            let sigmap = Option.value (List.assoc_opt module_ context.sigmaps) ~default:[] in
            List.fold_left
              (fun scope (exported, local) ->
                let reached = Module.reached_module context.external_fields module_ exported in
                let cls = module_class reached in
                match List.find_map (fun (n, t, _) -> if n = exported then Some t else None) sigmap with
                | Some ((TFunction _ | TForall (_, _, TFunction _, _)) as t) ->
                    let _, _, r = function_parts t in
                    bind_value scope local
                      {
                        value = atom (cls ^ "." ^ java_ident exported);
                        kind =
                          BMethod
                            {
                              jname = cls ^ "." ^ java_ident exported;
                              lifted = false;
                              void = is_unit r;
                              mtype = t;
                              external_ = reached <> module_ || List.mem module_ context.externals;
                            };
                        btype = t;
                        jname_ = "";
                      }
                | Some (TData _) -> scope
                | Some t -> bind_value scope local { value = atom (cls ^ "." ^ java_ident exported); kind = BStatic; btype = t; jname_ = "" }
                | None -> scope)
              scope fields
        | _ -> scope)
      scope stmts
  in
  let public_names = List.map fst (Module.public_names stmts) in
  (* Every top-level def is a static method, bound before anything is
     translated. *)
  let scope, st =
    List.fold_left
      (fun (scope, st) s ->
        match s with
        | SFunctionDef (_, name, _, _, _, sym, _, _, _) ->
            let t = Option.value (IntMap.find_opt sym tmap) ~default:(TUnknown (no_info, 0)) in
            let _, _, r = function_parts t in
            let jname = java_ident name in
            ( bind_value scope name
                {
                  value = atom jname;
                  kind = BMethod { jname; lifted = false; void = is_unit r; mtype = t; external_ = false };
                  btype = t;
                  jname_ = jname;
                },
              { st with methods_taken = StringSet.add jname st.methods_taken } )
        | _ -> (scope, st))
      (scope, st) stmts
  in
  let main_cells = captured_vars stmts in
  let scope = { scope with cells = main_cells } in
  (* The top level: a def is a method, a binding a static field assigned
     where it is, and everything else the body of main or init. *)
  let methods, body, statics, _, st =
    List.fold_left
      (fun (methods, body, statics, scope, st) s ->
        match s with
        | SFunctionDef _ when unreferenced s stmts ->
            (* Nothing calls it, so nothing worked its types out, and
               nothing needs it. *)
            (methods, body, statics, scope, st)
        | SFunctionDef (_, name, params, fbody, _, sym, _, _, _) ->
            let t = Option.value (IntMap.find_opt sym tmap) ~default:(TUnknown (no_info, 0)) in
            let _, _, r = function_parts t in
            let saved_taken = st.taken in
            let st = { st with current = (if is_unit r then "!" else "") ^ java_ident name; taken = StringSet.union saved_taken (StringSet.of_list (List.map (fun (_, _, n) -> n) statics)) } in
            let m, st =
              method_of ctx st { scope with cells = StringSet.empty } (java_ident name) params fbody t
                (List.mem name public_names && not context.main)
                false
            in
            (methods @ [ m ], body, statics, scope, { st with current = ""; taken = saved_taken })
        | SImport _ | SFunctionSig _ | SDatatype _ -> (methods, body, statics, scope, st)
        | SLet (_, target, e, _, _, public, _) ->
            let v, st = expr top st scope e in
            let t = type_of ctx scope e in
            let assigns, statics, scope, st = static_bindings ctx st scope statics target v t public in
            (methods, body @ assigns, statics, scope, st)
        | SVar (_, name, e, _) ->
            let v, st = expr top st scope e in
            let t = type_of ctx scope e in
            let jname, st = fresh st name in
            let st = { st with taken = StringSet.add jname st.taken } in
            ( methods,
              body @ [ JLine (Printf.sprintf "%s = %s;" jname v.text) ],
              statics @ [ (false, jt ctx t, jname) ],
              bind_value scope name { value = atom jname; kind = BStatic; btype = t; jname_ = "" },
              st )
        | SLetStmt (_, target, inner, _, _, public) -> (
            let t =
              match IntMap.find_opt (stmt_sym s) tmap with Some t -> t | None -> target_type ctx scope target
            in
            match inner with
            | SLoop _ ->
                let loop_stmts, value, lt, st = loop top st scope inner in
                let t = match t with TUnknown _ -> lt | t -> t in
                let assigns, statics, scope, st =
                  static_bindings ctx st scope statics target (Option.value value ~default:null_expr) t public
                in
                (methods, body @ loop_stmts @ assigns, statics, scope, st)
            | _ ->
                let held, st = temp st "v" in
                let inner_stmts, st = tail top st scope (Assign held) inner in
                let assigns, statics, scope, st = static_bindings ctx st scope statics target (atom held) t public in
                (methods, body @ [ JLine (Printf.sprintf "final %s %s;" (jt top t) held) ] @ inner_stmts @ assigns, statics, scope, st))
        | s ->
            let st = { st with taken = StringSet.union st.taken (StringSet.of_list (List.map (fun (_, _, n) -> n) statics)) } in
            let out, scope, st = stmt top st scope s in
            (methods, body @ out, statics, scope, st))
      ([], [], [], scope, st) stmts
  in
  (* sys reads the program's arguments and its class, which only main is
     given. *)
  let takes_args =
    context.main
    && (List.mem "sys" context.starts
       || List.exists (fun (m, _) -> m = "sys" || m = "sys_external") context.sigmaps)
  in
  {
    class_name_ = own_class;
    program_name = context.context_name;
    main = context.main;
    starts = List.map default_class_name context.starts;
    statics;
    methods = methods @ st.lifted;
    main_body = reachable body;
    datatypes_ = List.map (fun (d, public) -> jdatatype ctx d public) own_datatypes;
    shape_ = ctx.shape;
    tuples_ = st.tuples;
    fns_ = st.fns;
    polys_ = st.polys;
    capture_table = st.captures;
    takes_args;
  }

(* --- the printer --- *)

(** What a lifted method captures: what its own body reads from around
    it, and what every method it reaches captures -- except one written
    inside it, whose captures are its own locals.
    [(string, capture)] -> string -> [(string, string)] *)
let closure table name =
  let rec go seen name =
    if List.mem name seen then []
    else
      match List.assoc_opt name table with
      | None -> []
      | Some c ->
          c.direct
          @ List.concat_map
              (fun r ->
                match List.assoc_opt r table with
                | Some rc when rc.inside = name -> []
                | _ -> go (name :: seen) r)
              c.reaches
  in
  List.sort_uniq (fun (a, _) (b, _) -> compare a b) (go [] name)

(** text with every capture marker replaced by the names it stands for.
    jprogram -> string -> string *)
let expand_captures program text =
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let rec go i =
    if i >= n then ()
    else if text.[i] = '\001' then (
      let j = String.index_from text (i + 1) '\001' in
      let marker = String.sub text (i + 1) (j - i - 1) in
      (match String.split_on_char ':' marker with
      | [ kind; name; more ] ->
          let names = closure program.capture_table name in
          let pieces =
            if kind = "A" then List.map fst names
            else List.map (fun (n, t) -> Printf.sprintf "final %s %s" t n) names
          in
          Buffer.add_string b (String.concat ", " pieces);
          if pieces <> [] && more = "1" then Buffer.add_string b ", "
      | _ -> ());
      go (j + 1))
    else (
      Buffer.add_char b text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(** The labels a break names in stmts. [jstmt] -> [string] *)
let rec labels_used stmts =
  List.concat_map
    (fun s ->
      match s with
      | JBreak (Some l) -> [ l ]
      | JIf (_, t, e) -> labels_used t @ (match e with Some e -> labels_used e | None -> [])
      | JBlock (_, b) | JWhile (_, _, b) | JFor (_, _, b) -> labels_used b
      | JSwitch (_, arms) -> List.concat_map (fun (_, b) -> labels_used b) arms
      | _ -> [])
    stmts

(** s as Java source, indented to level. [string] -> int -> jstmt -> string *)
let rec pprint_stmt used level s =
  let pad = String.make (4 * level) ' ' in
  let block body = String.concat "\n" (List.map (pprint_stmt used (level + 1)) body) in
  let labelled l = if List.mem l used then l ^ ": " else "" in
  match s with
  | JLine l -> pad ^ l
  | JIf (c, t, e) ->
      let rec ladder text e =
        match e with
        | None -> text ^ "\n" ^ pad ^ "}"
        | Some [ JIf (c2, t2, e2) ] -> ladder (text ^ "\n" ^ pad ^ "} else if (" ^ c2 ^ ") {\n" ^ block t2) e2
        | Some body -> text ^ "\n" ^ pad ^ "} else {\n" ^ block body ^ "\n" ^ pad ^ "}"
      in
      ladder (pad ^ "if (" ^ c ^ ") {\n" ^ block t) e
  | JWhile (l, c, body) ->
      Printf.sprintf "%s%swhile (%s) {\n%s\n%s}" pad (labelled l) (Option.value c ~default:"true") (block body) pad
  | JFor (l, h, body) -> Printf.sprintf "%s%sfor (%s) {\n%s\n%s}" pad (labelled l) h (block body) pad
  | JBlock (None, body) -> Printf.sprintf "%s{\n%s\n%s}" pad (block body) pad
  | JBlock (Some l, body) -> Printf.sprintf "%s%s: {\n%s\n%s}" pad l (block body) pad
  | JSwitch (sel, arms) ->
      let arm (label, body) =
        Printf.sprintf "%s    %s -> {\n%s\n%s    }" pad label
          (String.concat "\n" (List.map (pprint_stmt used (level + 2)) body))
          pad
      in
      Printf.sprintf "%sswitch (%s) {\n%s\n%s}" pad sel (String.concat "\n" (List.map arm arms)) pad
  | JReturn None -> pad ^ "return;"
  | JReturn (Some v) -> pad ^ "return " ^ v ^ ";"
  | JThrow -> pad ^ "throw new IllegalStateException();"
  | JBreak None -> pad ^ "break;"
  | JBreak (Some l) -> pad ^ "break " ^ l ^ ";"
  | JContinue -> pad ^ "continue;"

(** A method as Java source. jmethod -> string *)
let pprint_method m =
  let used = labels_used m.m_body in
  let params = List.map (fun (t, n) -> Printf.sprintf "final %s %s" t n) m.m_params in
  let params =
    if m.m_captures then capture_params m.m_name (params <> []) ^ String.concat ", " params
    else String.concat ", " params
  in
  Printf.sprintf "    %s static %s%s %s(%s) {\n%s\n    }"
    (if m.m_public then "public" else "private")
    (if m.m_tparams = [] then "" else "<" ^ String.concat ", " m.m_tparams ^ "> ")
    m.m_result m.m_name params
    (String.concat "\n" (List.map (pprint_stmt used 2) m.m_body))

(** A datatype's classes, in the shape the version gives them.
    shape -> jdatatype -> string *)
let pprint_datatype shape d =
  let params = if d.d_params = [] then "" else "<" ^ String.concat ", " d.d_params ^ ">" in
  let visibility = if d.d_public then "public" else "private" in
  let factory cls fields =
    Printf.sprintf "    %s static %s%s%s %s(%s) {\n        return new %s%s(%s);\n    }" visibility
      (if d.d_params = [] then "" else params ^ " ")
      d.d_type params cls
      (String.concat ", " (List.map (fun (n, t) -> "final " ^ t ^ " " ^ n) fields))
      cls (if d.d_params = [] then "" else "<>")
      (String.concat ", " (List.map fst fields))
  in
  let data_methods name fields =
    [
      Printf.sprintf "        public String pykTag() { return %s; }" (quote name);
      Printf.sprintf "        public Object[] pykFields() { return new Object[] { %s }; }"
        (String.concat ", " (List.map fst fields));
    ]
  in
  match shape with
  | Java8 ->
      let base =
        Printf.sprintf "    %s static abstract class %s%s implements %s.Data {\n%s    }" visibility d.d_type params runtime_class
          (String.concat "" (List.map (fun (n, t) -> Printf.sprintf "        public abstract %s %s();\n" t n) d.d_shared))
      in
      let ctor (cls, name, fields) =
        String.concat "\n"
          ([ factory cls fields; ""; Printf.sprintf "    %s static final class %s%s extends %s%s {" visibility cls params d.d_type params ]
          @ List.map (fun (n, t) -> Printf.sprintf "        public final %s %s;" t n) fields
          @ [
              Printf.sprintf "        public %s(%s) {" cls (String.concat ", " (List.map (fun (n, t) -> t ^ " " ^ n) fields));
            ]
          @ List.map (fun (n, _) -> Printf.sprintf "            this.%s = %s;" n n) fields
          @ [ "        }" ]
          @ List.map (fun (n, t) -> Printf.sprintf "        public %s %s() { return %s; }" t n n) (List.filter (fun f -> List.mem f d.d_shared) fields)
          @ data_methods name fields @ [ "    }" ])
      in
      String.concat "\n\n" (base :: List.map ctor d.d_ctors)
  | _ ->
      let base =
        Printf.sprintf "    %s sealed interface %s%s extends %s.Data permits %s {\n%s    }" visibility d.d_type params runtime_class
          (String.concat ", " (List.map (fun (c, _, _) -> c) d.d_ctors))
          (String.concat "" (List.map (fun (n, t) -> Printf.sprintf "        %s %s();\n" t n) d.d_shared))
      in
      let ctor (cls, name, fields) =
        String.concat "\n"
          ([
             factory cls fields;
             "";
             Printf.sprintf "    %s record %s%s(%s) implements %s%s {" visibility cls params
               (String.concat ", " (List.map (fun (n, t) -> t ^ " " ^ n) fields))
               d.d_type params;
           ]
          @ data_methods name fields @ [ "    }" ])
      in
      String.concat "\n\n" (base :: List.map ctor d.d_ctors)

(** The whole compilation unit. jprogram -> string -> string -> string
    -> string *)
let pprint_java_program (program : jprogram) version class_name source =
  let release = release_of version in
  let header =
    [ Printf.sprintf "// Generated from %s by the Pyking compiler. Do not edit." source ]
    @
    if program.main then
      [
        Printf.sprintf "// Target: %s. Compile with:  javac --release %s %s.java %s" version release class_name runtime_file;
        Printf.sprintf "//         then run with:            java %s" class_name;
      ]
    else [ Printf.sprintf "// Target: %s. The module '%s' of the program; compile it with the others." version program.program_name ]
  in
  let datatypes = List.map (pprint_datatype program.shape_) program.datatypes_ in
  let statics =
    List.map
      (fun (public, t, n) -> Printf.sprintf "    %s static %s %s;" (if public then "public" else "private") t n)
      program.statics
  in
  let methods = List.map pprint_method program.methods in
  let used = labels_used program.main_body in
  let main =
    let header = if program.main then "public static void main(String[] args)" else "public static void init()" in
    String.concat "\n"
      ([ "    " ^ header ^ " {" ]
      @ (if program.takes_args then
           [
             "        System.getProperties().put(\"pyking.args\", args);";
             Printf.sprintf "        System.getProperties().put(\"pyking.main\", %s.class);" class_name;
           ]
         else [])
      @ List.map (fun n -> Printf.sprintf "        %s.init();" n) program.starts
      @ List.map (pprint_stmt used 2) program.main_body
      @ [ "    }" ])
  in
  let sections =
    List.filter (fun s -> s <> "")
      [
        String.concat "\n\n" datatypes;
        String.concat "\n" statics;
        String.concat "\n\n" methods;
        main;
      ]
  in
  let text =
    String.concat "\n" header ^ "\n\n"
    ^ Printf.sprintf "public final class %s {\n\n%s\n}\n" class_name (String.concat "\n\n" sections)
  in
  expand_captures program text

(* --- the runtime --- *)

(** PykRuntime.java for a program of these modules: the tuples, function
    interfaces and polymorphic interfaces they name, and the helpers every
    module may call. [jprogram] -> string -> string *)
let runtime_source programs version =
  let shape = shape_of version in
  let tuples = List.sort_uniq compare (List.init 7 (fun i -> i + 2) @ List.concat_map (fun p -> p.tuples_) programs) in
  let fns = List.sort_uniq compare (List.init 6 (fun i -> i + 3) @ List.concat_map (fun p -> p.fns_) programs) in
  let polys =
    List.fold_left (fun out (n, d) -> if List.mem_assoc n out then out else out @ [ (n, d) ]) [] (List.concat_map (fun p -> p.polys_) programs)
  in
  let tuple n =
    let params = List.init n (fun i -> Printf.sprintf "A%d" i) in
    let items =
      Printf.sprintf "        public Object[] pykItems() { return new Object[] { %s }; }"
        (String.concat ", " (List.mapi (fun i _ -> Printf.sprintf "a%d" i) params))
    in
    match shape with
    | Java8 ->
        String.concat "\n"
          ([ Printf.sprintf "    public static final class T%d<%s> implements Tuple {" n (String.concat ", " params) ]
          @ List.mapi (fun i p -> Printf.sprintf "        public final %s a%d;" p i) params
          @ [
              Printf.sprintf "        public T%d(%s) {" n (String.concat ", " (List.mapi (fun i p -> Printf.sprintf "%s a%d" p i) params));
            ]
          @ List.mapi (fun i _ -> Printf.sprintf "            this.a%d = a%d;" i i) params
          @ [ "        }"; items; "    }" ])
    | _ ->
        Printf.sprintf "    public record T%d<%s>(%s) implements Tuple {\n%s\n    }" n (String.concat ", " params)
          (String.concat ", " (List.mapi (fun i p -> Printf.sprintf "%s a%d" p i) params))
          items
  in
  let fn n =
    let params = List.init n (fun i -> Printf.sprintf "A%d" i) in
    Printf.sprintf "    public interface Fn%d<%s, R> {\n        R apply(%s);\n    }" n (String.concat ", " params)
      (String.concat ", " (List.mapi (fun i p -> Printf.sprintf "%s a%d" p i) params))
  in
  String.concat "\n"
    ([
       "// The runtime every module of a Pyking program compiled to Java shares:";
       "// its tuples, its function interfaces and how a value is written.";
       "// Generated by the Pyking compiler. Do not edit.";
       "";
       Printf.sprintf "public final class %s {" runtime_class;
       "";
       "    // A value of a datatype, as print writes it.";
       "    public interface Data {";
       "        String pykTag();";
       "        Object[] pykFields();";
       "    }";
       "";
       "    // A tuple, as print writes it.";
       "    public interface Tuple {";
       "        Object[] pykItems();";
       "    }";
     ]
    @ List.concat_map (fun n -> [ ""; tuple n ]) tuples
    @ List.concat_map (fun n -> [ ""; fn n ]) fns
    @ List.concat_map (fun (_, d) -> [ ""; d ]) polys
    @ [
        "";
        "    public static Void printLine(String line) {";
        "        System.out.println(line);";
        "        return null;";
        "    }";
        "";
        "    public static Void debugLine(String line) {";
        "        System.err.println(line);";
        "        return null;";
        "    }";
        "";
        "    // A call to a method answering nothing, where a value is wanted.";
        "    public static Void unit(Runnable call) {";
        "        call.run();";
        "        return null;";
        "    }";
        "";
        "    public static void ignore(Object value) {";
        "    }";
        "";
        "    // A condition javac cannot read as a constant.";
        "    public static boolean truth(boolean value) {";
        "        return value;";
        "    }";
        "";
        "    public static <T> java.util.List<T> concat(java.util.List<T> a, java.util.List<T> b) {";
        "        java.util.ArrayList<T> out = new java.util.ArrayList<T>(a.size() + b.size());";
        "        out.addAll(a);";
        "        out.addAll(b);";
        "        return java.util.Collections.unmodifiableList(out);";
        "    }";
        "";
        "    public static <T> java.util.List<T> single(T value) {";
        "        return java.util.Collections.singletonList(value);";
        "    }";
        "";
        "    @SafeVarargs";
        "    public static <T> T[] cell(T... value) {";
        "        return value;";
        "    }";
        "";
        "    public static <T> java.util.List<T> empty() {";
        "        return java.util.Collections.emptyList();";
        "    }";
        "";
        "    public static <A, B> java.util.List<B> flatMap(java.util.List<A> items, java.util.function.Function<A, java.util.List<B>> f) {";
        "        java.util.ArrayList<B> out = new java.util.ArrayList<B>();";
        "        for (A item : items) out.addAll(f.apply(item));";
        "        return java.util.Collections.unmodifiableList(out);";
        "    }";
        "";
        "    public static java.util.List<Integer> range(int stop) {";
        "        return range(0, stop, 1);";
        "    }";
        "";
        "    public static java.util.List<Integer> range(int start, int stop) {";
        "        return range(start, stop, 1);";
        "    }";
        "";
        "    public static java.util.List<Integer> range(int start, int stop, int step) {";
        "        if (step == 0) throw new IllegalArgumentException(\"'range' step must not be zero\");";
        "        java.util.ArrayList<Integer> out = new java.util.ArrayList<Integer>();";
        "        for (int n = start; step > 0 ? n < stop : n > stop; n += step) out.add(n);";
        "        return java.util.Collections.unmodifiableList(out);";
        "    }";
        "";
        "    // A String's length in UTF-8 bytes, as Pyking counts it.";
        "    public static int len(String s) {";
        "        return s.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;";
        "    }";
        "";
        "    // What print writes for a value: a String bare, everything else as";
        "    // it is written inside another value.";
        "    public static String str(Object value) {";
        "        return value instanceof String ? (String) value : show(value);";
        "    }";
        "";
        "    public static String show(Object value) {";
        "        StringBuilder out = new StringBuilder();";
        "        write(out, value);";
        "        return out.toString();";
        "    }";
        "";
        "    private static void write(StringBuilder out, Object value) {";
        "        if (value == null) {";
        "            out.append(\"()\");";
        "        } else if (value instanceof String) {";
        "            out.append(quote((String) value));";
        "        } else if (value instanceof Double) {";
        "            out.append(floatStr((Double) value));";
        "        } else if (value instanceof java.util.List) {";
        "            out.append('[');";
        "            boolean first = true;";
        "            for (Object item : (java.util.List<?>) value) {";
        "                if (!first) out.append(\", \");";
        "                first = false;";
        "                write(out, item);";
        "            }";
        "            out.append(']');";
        "        } else if (value instanceof Data) {";
        "            Data data = (Data) value;";
        "            out.append(data.pykTag());";
        "            Object[] fields = data.pykFields();";
        "            if (fields.length > 0) {";
        "                out.append('(');";
        "                for (int i = 0; i < fields.length; i++) {";
        "                    if (i > 0) out.append(\", \");";
        "                    write(out, fields[i]);";
        "                }";
        "                out.append(')');";
        "            }";
        "        } else if (value instanceof Tuple) {";
        "            Object[] parts = ((Tuple) value).pykItems();";
        "            out.append('(');";
        "            for (int i = 0; i < parts.length; i++) {";
        "                if (i > 0) out.append(\", \");";
        "                write(out, parts[i]);";
        "            }";
        "            out.append(parts.length == 1 ? \",)\" : \")\");";
        "        } else {";
        "            out.append(String.valueOf(value));";
        "        }";
        "    }";
        "";
        "    private static String quote(String text) {";
        "        StringBuilder out = new StringBuilder(\"'\");";
        "        for (int i = 0; i < text.length(); i++) {";
        "            char c = text.charAt(i);";
        "            switch (c) {";
        "                case '\\\\': out.append(\"\\\\\\\\\"); break;";
        "                case '\\'': out.append(\"\\\\'\"); break;";
        "                case '\\n': out.append(\"\\\\n\"); break;";
        "                case '\\t': out.append(\"\\\\t\"); break;";
        "                case '\\r': out.append(\"\\\\r\"); break;";
        "                default: out.append(c);";
        "            }";
        "        }";
        "        return out.append('\\'').toString();";
        "    }";
        "";
        "    // A Float written the way Pyking writes one. Locale.ROOT, since a";
        "    // comma is the decimal separator in some locales.";
        "    public static String floatStr(double x) {";
        "        if (Double.isNaN(x)) return \"nan\";";
        "        if (x == Double.POSITIVE_INFINITY) return \"inf\";";
        "        if (x == Double.NEGATIVE_INFINITY) return \"-inf\";";
        "        String sign = (x < 0.0 || (x == 0.0 && 1.0 / x < 0.0)) ? \"-\" : \"\";";
        "        double a = java.lang.Math.abs(x);";
        "        if (a == 0.0) return sign + \"0.0\";";
        "        String s = \"\";";
        "        for (int p = 0; p <= 16; p++) {";
        "            s = String.format(java.util.Locale.ROOT, \"%.\" + p + \"e\", a);";
        "            if (Double.parseDouble(s) == a) break;";
        "        }";
        "        int at = s.indexOf('e');";
        "        String digits = s.substring(0, at).replace(\".\", \"\");";
        "        int decpt = Integer.parseInt(s.substring(at + 1)) + 1;";
        "        int n = digits.length();";
        "        while (n > 1 && digits.charAt(n - 1) == '0') n--;";
        "        digits = digits.substring(0, n);";
        "        if (decpt <= -4 || decpt > 16) {";
        "            String mantissa = n == 1 ? digits : digits.charAt(0) + \".\" + digits.substring(1);";
        "            return sign + mantissa + \"e\" + (decpt - 1);";
        "        }";
        "        StringBuilder out = new StringBuilder(sign);";
        "        if (decpt <= 0) {";
        "            out.append(\"0.\");";
        "            for (int i = 0; i < -decpt; i++) out.append('0');";
        "            return out.append(digits).toString();";
        "        }";
        "        if (decpt >= n) {";
        "            out.append(digits);";
        "            for (int i = 0; i < decpt - n; i++) out.append('0');";
        "            return out.append(\".0\").toString();";
        "        }";
        "        return out.append(digits, 0, decpt).append('.').append(digits.substring(decpt)).toString();";
        "    }";
        "";
        "    // The conversions Java's own would get wrong (builtin.ml, \"what a";
        "    // conversion reads\").";
        "    public static int intOfString(String s) {";
        "        if (!s.matches(\"[+-]?[0-9]+\")) return 0;";
        "        try {";
        "            long n = Long.parseLong(s.startsWith(\"+\") ? s.substring(1) : s);";
        "            return n >= -2147483648L && n <= 2147483647L ? (int) n : 0;";
        "        } catch (NumberFormatException tooLong) {";
        "            return 0;";
        "        }";
        "    }";
        "";
        "    public static int truncate(double x) {";
        "        if (Double.isNaN(x) || x <= -2147483649.0 || x >= 2147483648.0) return 0;";
        "        return (int) x;";
        "    }";
        "";
        "    public static double floatOfString(String s) {";
        "        if (s.equals(\"inf\") || s.equals(\"+inf\")) return Double.POSITIVE_INFINITY;";
        "        if (s.equals(\"-inf\")) return Double.NEGATIVE_INFINITY;";
        "        if (!s.matches(\"[+-]?[0-9]+(\\\\.[0-9]+)?([eE][+-]?[0-9]+)?\")) return Double.NaN;";
        "        return Double.parseDouble(s);";
        "    }";
        "}";
        "";
      ])
