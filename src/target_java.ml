(** The Java code-generation backend, serving java8, java17 and java21
    -- structured like target_c.ml: one translation, and a printer whose
    shape never changes across versions, gated by a small per-version
    feature table. Like target_c.ml, Java is statically typed and this
    backend infers no polymorphism, so it works out a type (Int, String,
    or Bool) for every binding, parameter and function. Unlike C, javac
    requires every non-void method to provably return on every path and
    rejects unreachable code, so this backend checks both. Translated
    See docs/target_java.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      jtype -- the three kinds of value this subset can hold, plus unit.
      jexpr / jstmt -- the Java AST; every jexpr also carries its jtype.
      jprogram -- a translated module.
      scope -- Pyking name -> (Java name, jtype).
      state -- what the whole-program walk accumulates.

    Functions:
      translate_program stmts context -- translates a whole module.
      default_class_name stem -- the Java class name for a source stem.
      pprint_java_program program version class_name source -- the
        compilation unit. *)

open Lexer
open Syntax

(* What each version's printer may use (docs/target_java.md, "The three
   targets"). `var_locals` gates JEP 286 local-variable type inference;
   `release` is the --release value the compile-with comment
   suggests. *)
let release_of version =
  match version with
  | "java8" -> "8"
  | "java17" -> "17"
  | _ -> "21"

let var_locals version = version <> "java8"

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of info * string

module SMap = Map.Make (String)

(* What each unsupported construct is called in an error message. Its own
   copy of target_c.ml's list, so this backend depends on syntax.ml
   alone. *)
let construct_names =
  [
    ("EList", "list literals");
    ("ETuple", "tuples");
    ("EListComp", "list comprehensions");
    ("ELambda", "lambdas, which this backend has no closure semantics for");
    ("SMatch", "`match` statements");
    ("SLetStmt", "value-form `if`/`match` bindings");
  ]

(** Raises Unsupported at info, naming message (a construct or a node's
    own name). info -> string -> 'a *)
let unsupported info message =
  raise
    (Unsupported
       ( info,
         match List.assoc_opt message construct_names with
         | Some name -> name
         | None -> message ))

(* --- types ---

   The three kinds of value a Pyking program in this subset can hold,
   plus Pyking's unit type (), spelled void in Java. *)

type jtype = Int | Float | Bool | String | Unit | Func of jtype list * jtype

let jtype_name t =
  match t with
  | Int -> "Int"
  | Float -> "Float"
  | Bool -> "Bool"
  | String -> "String"
  | Unit -> "Unit"
  | Func _ -> "a function"

(** A value type as a type argument, which Java writes boxed.
    jtype -> string *)
let boxed t =
  match t with
  | Int -> "Integer"
  | Float -> "Double"
  | Bool -> "Boolean"
  | String -> "String"
  | Unit | Func _ -> "Void"

(** A type's Java spelling. A Pyking function is the java.util.function
    interface of its shape -- `Runnable` for `() -> ()`, `Consumer<A>`
    for `(A) -> ()`, `BiFunction<A, B, R>` for `(A, B) -> R` -- so a
    Java caller can hand one a lambda (docs/target_java.md, "Functions as
    values"). jtype -> string *)
let java_type t =
  match t with
  | Int -> "int"
  | Float -> "double"
  | Bool -> "boolean"
  | String -> "String"
  | Unit -> "void"
  | Func (params, result) -> (
      let args = String.concat ", " (List.map boxed params) in
      let package = "java.util.function." in
      match (params, result) with
      | [], Unit -> "Runnable"
      | [], r -> package ^ "Supplier<" ^ boxed r ^ ">"
      | [ _ ], Unit -> package ^ "Consumer<" ^ args ^ ">"
      | [ _ ], r -> package ^ "Function<" ^ args ^ ", " ^ boxed r ^ ">"
      | _, Unit -> package ^ "BiConsumer<" ^ args ^ ">"
      | _, r -> package ^ "BiFunction<" ^ args ^ ", " ^ boxed r ^ ">")

(** The method a function's interface is called through.
    jtype -> string *)
let apply_method t =
  match t with
  | Func ([], Unit) -> "run"
  | Func ([], _) -> "get"
  | Func (_, Unit) -> "accept"
  | _ -> "apply"

(** The type an annotation names, or None if it names one Java has no
    representation for here (a tuple or list). Nothing checks
    annotations, so an unrepresentable one is ignored in favour of
    inference rather than treated as an error. A function type is one
    of at most two parameters, each a value, answering a value or unit:
    what java.util.function has an interface for.
    typ option -> jtype option *)
let rec annotated_type annotation =
  match annotation with
  | Some (TInt _) -> Some Int
  | Some (TFloat _) -> Some Float
  | Some (TString _) -> Some String
  | Some (TBool _) -> Some Bool
  | Some (TFunction (_, params, result, _, _, _, _)) when List.length params <= 2 -> (
      let value t =
        match annotated_type (Some t) with Some (Func _) | None -> None | found -> found
      in
      let params = List.map value params in
      let result =
        match result with TTuple (_, [], _) -> Some Unit | result -> value result
      in
      match result with
      | Some result when List.for_all Option.is_some params ->
          Some (Func (List.map Option.get params, result))
      | _ -> None)
  | _ -> None

(** Whether a written type names a type variable anywhere inside it.
    typ -> bool *)
let rec mentions_type_variable annotation =
  match annotation with
  | TVar _ | TForall _ -> true
  | TList (_, element, _) -> mentions_type_variable element
  | TTuple (_, elements, _) -> List.exists mentions_type_variable elements
  | TFunction (_, params, result, _, _, _, _) ->
      List.exists mentions_type_variable params || mentions_type_variable result
  | _ -> false

(** Refuses a def whose annotations name a type variable. Java infers one
    concrete type per function, so a type the caller chooses has nothing
    here to become -- and guessing `Int` would compile a call at any
    other type into code that is quietly wrong. stmt -> () *)
let reject_type_variables node =
  match node with
  | SFunctionDef (_, _, params, _, return_type, _, _, _, _) ->
      List.iter
        (fun annotation ->
          match annotation with
          | Some annotation when mentions_type_variable annotation ->
              unsupported (type_info annotation)
                "a type variable -- Java needs one concrete type per \
                 function, and this backend infers no polymorphism"
          | _ -> ())
        (List.map (fun (Param (_, _, t, _, _)) -> t) params @ [ return_type ])
  | _ -> ()

(* --- Java AST ---

   Every expression node carries its type: the translator needs it to
   check operators and to pick `.equals()` over `==`. *)

type jexpr =
  | JInt of info * int
  | JFloat of info * float
  | JStr of info * string
  | JBool of info * bool
  | JVar of info * string * jtype
  | JUnary of info * string * jexpr * jtype (* op operand *)
  | JBinary of info * string * jexpr * jexpr * jtype (* left op right *)
  | JCall of info * string * jexpr list * jtype (* name(args...) *)
  | JCond of info * jexpr * jexpr * jexpr * jtype (* cond ? a : b *)
  | JEquals of info * jexpr * jexpr (* left.equals(right) *)
  | JCast of info * jtype * jexpr (* (type) operand *)
  | JFloatStr of info * jexpr (* pykFloatStr(operand) *)
  | JLambda of info * string * jtype
      (* (p$1, p$2) -> name(p$1, p$2): a method as a value *)

type jstmt =
  | JDecl of info * jtype * string * jexpr * bool
      (* [final] <type|var> name = init; *)
  | JAssign of info * string * jexpr (* name = expr; *)
  | JNoEffect of info * string
      (* // a Pyking statement with nothing to run *)
  | JExprStmt of info * jexpr (* expr; *)
  | JPrint of info * bool * jexpr option
      (* System.out.println(...); -- System.err when the flag is set,
         which is `debug` *)
  | JIf of info * jexpr * jstmt list * jstmt list option
  | JWhile of info * jexpr * jstmt list
  | JLoop of info * jstmt list (* while (true) { body } *)
  | JBreak of info
  | JContinue of info
  | JReturn of info * jexpr

(** <ret> name(params) { body }. `public` says another class of the
    program calls it, so it is `public static` rather than `private
    static`. *)
type jfunc = {
  func_info : info;
  func_name : string;
  func_params : (jtype * string) list;
  func_body : jstmt list;
  ret_type : jtype;
  func_public : bool;
}

(** A public value: a field of the class, which `init` gives its value
    from the local it worked it out in. *)
type jglobal = {
  global_info : info;
  global_jtype : jtype;
  global_name : string;
  global_from : string;
}

(** A translated module. *)
type jprogram = {
  functions : jfunc list;
  main_body : jstmt list;
  program_name : string;
  uses_float : bool;
  conversions : string list;
  main : bool;
  separate : bool;
  starts : string list;
  globals : jglobal list;
  (* The top level's own bindings, as static fields: what every method
     reads them through. *)
  statics : (jtype * string) list;
}

(** The type a Java expression carries. jexpr -> jtype *)
let jtype_of e =
  match e with
  | JInt _ -> Int
  | JFloat _ -> Float
  | JStr _ -> String
  | JBool _ -> Bool
  | JVar (_, _, t) -> t
  | JUnary (_, _, _, t) -> t
  | JBinary (_, _, _, _, t) -> t
  | JCall (_, _, _, t) -> t
  | JCond (_, _, _, _, t) -> t
  | JEquals _ -> Bool
  | JCast (_, t, _) -> t
  | JFloatStr _ -> String
  | JLambda (_, _, t) -> t

(** The source position a Java expression carries. jexpr -> info *)
let jexpr_info e =
  match e with
  | JInt (i, _) | JFloat (i, _) | JStr (i, _) | JBool (i, _) -> i
  | JCast (i, _, _) | JFloatStr (i, _) -> i
  | JVar (i, _, _) | JLambda (i, _, _) -> i
  | JUnary (i, _, _, _) -> i
  | JBinary (i, _, _, _, _) -> i
  | JCall (i, _, _, _) -> i
  | JCond (i, _, _, _, _) -> i
  | JEquals (i, _, _) -> i

(* --- naming the class/file ---

   Only the default name goes through this conversion; an explicit
   --output path is trusted as-is. See docs/target_java.md, "Naming the
   class". *)

(** The Java class (and file) name picked when nothing else says one,
    e.g. foo_bar -> FooBar. The rule lives in module.ml, which owns what
    a module's file is called on each target. string -> string *)
let default_class_name = Module.class_name

(* --- scope ---

   Java blocks are lexical scopes, as Pyking's are. Rebinding gets a
   fresh local, since Java cannot declare one name twice in a block and
   a rebinding may hold a different type. *)

type scope = {
  names : (string * jtype) SMap.t;
  block : StringSet.t;
  taken : StringSet.t;
}

let empty_scope =
  {
    names = SMap.empty;
    block = StringSet.empty;
    taken = StringSet.empty;
  }

let block_scope scope = { scope with block = StringSet.empty }

let reserve names scope =
  {
    scope with
    taken = List.fold_left (fun set name -> StringSet.add name set) scope.taken names;
  }

(* Legal Pyking identifiers that are reserved in Java (keywords,
   literals, and the names generated code leans on). `_` is on the list
   for Java's own reason: it has been a keyword since Java 9. See
   docs/target_java.md, "Names that are keywords in Java". *)
let reserved =
  List.fold_left
    (fun set name -> StringSet.add name set)
    StringSet.empty
    (String.split_on_char ' '
       "abstract assert boolean break byte case catch char class const \
        continue default do double else enum extends final finally float for \
        goto if implements import instanceof int interface long native new \
        package private protected public return short static strictfp super \
        switch synchronized this throw throws transient try void volatile \
        while true false null var record sealed permits yield String System \
        Object Integer Boolean Math args main _")

(** The (Java name, jtype) a Pyking name reads as; raises Unsupported for
    a name out of this method's reach or with no Java representation.
    string -> scope -> info -> (string, jtype) *)
let lookup name scope info =
  match SMap.find_opt name scope.names with
  | Some found -> found
  | None ->
      unsupported info
        (Printf.sprintf "'%s' is not a value this backend can compile" name)

(** name2, name3, ... -- the first not already used.
    string -> scope -> string *)
let fresh_java_name name scope =
  let taken =
    SMap.fold
      (fun key (java_name, _) set -> StringSet.add key (StringSet.add java_name set))
      scope.names scope.taken
  in
  let rec go n =
    let candidate = Printf.sprintf "%s%d" name n in
    if StringSet.mem candidate taken || StringSet.mem candidate reserved then
      go (n + 1)
    else candidate
  in
  go 2

(** Binds a Pyking name to a Java name chosen elsewhere: an imported name
    is a member of the class that exports it, and keeps that spelling.
    string -> string -> jtype -> scope -> scope *)
let bind_exact name java_name jtype scope =
  {
    names = SMap.add name (java_name, jtype) scope.names;
    block = StringSet.add name scope.block;
    taken = StringSet.add java_name scope.taken;
  }

(** The key an imported name is registered under: what the source wrote
    to reach it. string -> string -> string *)
let reached alias field = Printf.sprintf "%s.%s" alias field

(** Binds a Pyking name at jtype, answering (java_name, extended_scope).
    string -> jtype -> scope -> (string, scope) *)
let bind name jtype scope =
  let java_name =
    if
      StringSet.mem name reserved
      || SMap.mem name scope.names
      || SMap.exists (fun _ (n, _) -> n = name) scope.names
      || StringSet.mem name scope.taken
    then fresh_java_name name scope
    else name
  in
  (java_name, bind_exact name java_name jtype scope)

(** The Java operator a Pyking binary node becomes, or None.
    expr -> string option *)
let binary_op e =
  match e with
  | ESub _ -> Some "-"
  | EMul _ -> Some "*"
  | ELessThan _ -> Some "<"
  | ELessThanEq _ -> Some "<="
  | EGreatThan _ -> Some ">"
  | EGreatThanEq _ -> Some ">="
  | _ -> None

let stmt_kind_name s =
  match s with
  | SLet _ -> "SLet"
  | SLetStmt _ -> "SLetStmt"
  | SVar _ -> "SVar"
  | SMutate _ -> "SMutate"
  | SReturn _ -> "SReturn"
  | SReturnStmt _ -> "SReturnStmt"
  | SExprStmt _ -> "SExprStmt"
  | SLoop _ -> "SLoop"
  | SBreak _ -> "SBreak"
  | SContinue _ -> "SContinue"
  | SIf _ -> "SIf"
  | SFunctionDef _ -> "SFunctionDef"
  | SFunctionSig _ -> "SFunctionSig"
  | SMatch _ -> "SMatch"
  | SImport _ -> "SImport"

let expr_kind_name e =
  match e with
  | EInt _ -> "EInt"
  | EFloat _ -> "EFloat"
  | EString _ -> "EString"
  | EBool _ -> "EBool"
  | EVar _ -> "EVar"
  | EQualified _ -> "EQualified"
  | EList _ -> "EList"
  | EListComp _ -> "EListComp"
  | ELambda _ -> "ELambda"
  | ETuple _ -> "ETuple"
  | ECall _ -> "ECall"
  | EIf _ -> "EIf"
  | ENeg _ -> "ENeg"
  | EAdd _ -> "EAdd"
  | ESub _ -> "ESub"
  | EMul _ -> "EMul"
  | EDiv _ -> "EDiv"
  | EConcat _ -> "EConcat"
  | ELessThan _ -> "ELessThan"
  | ELessThanEq _ -> "ELessThanEq"
  | EGreatThan _ -> "EGreatThan"
  | EGreatThanEq _ -> "EGreatThanEq"
  | EEq _ -> "EEq"

(** The expressions directly inside e -- the fields that are themselves
    expressions, and the elements of a list of them. A comprehension's
    clauses are not among them, exactly as in the Python.
    expr -> [expr] *)
let direct_subexprs e =
  match e with
  | EAdd (_, l, r, _) | ESub (_, l, r, _) | EMul (_, l, r, _)
  | EDiv (_, l, r, _) | EConcat (_, l, r, _) | ELessThan (_, l, r, _)
  | ELessThanEq (_, l, r, _) | EGreatThan (_, l, r, _)
  | EGreatThanEq (_, l, r, _) | EEq (_, l, r, _) ->
      [ l; r ]
  | ENeg (_, operand, _) -> [ operand ]
  | ECall (_, func, args, _) -> func :: arg_exprs args
  | EList (_, elements, _) | ETuple (_, elements, _) -> elements
  | EIf (_, cond, then_expr, else_expr, _) -> [ cond; then_expr; else_expr ]
  | EListComp (_, element, _, _) -> [ element ]
  | _ -> []

(** Whether e performs a call anywhere inside it. expr -> bool *)
let rec contains_call e =
  match e with
  | ECall _ -> true
  | e -> List.exists contains_call (direct_subexprs e)

(** Whether name is added to, or compared with, a string literal anywhere
    in these statements -- the one piece of evidence worth chasing, since
    an unannotated parameter is otherwise an integer.
    string -> [stmt] -> bool *)
let used_as_string name stmts =
  Walk.exists_stmts
    (fun node ->
      match node with
      | Walk.NExpr (EConcat (_, EVar (_, n, _), EString _, _))
      | Walk.NExpr (EConcat (_, EString _, EVar (_, n, _), _))
      | Walk.NExpr (EEq (_, EVar (_, n, _), EString _, _))
      | Walk.NExpr (EEq (_, EString _, EVar (_, n, _), _)) ->
          n = name
      | _ -> false)
    stmts

(** Whether name is combined with a float literal anywhere in these
    statements, which is what an arithmetic operator or a comparison
    does with two numbers. string -> [stmt] -> bool *)
let used_as_float name stmts =
  Walk.exists_stmts
    (fun node ->
      match node with
      | Walk.NExpr e -> (
          match Interpreter.binary_operands e with
          | Some (EVar (_, n, _), EFloat _) | Some (EFloat _, EVar (_, n, _)) ->
              n = name
          | _ -> false)
      | _ -> false)
    stmts

(** A parameter's type: its annotation when Java can represent it, else
    what the body's use of it suggests, else Int (docs/target_java.md,
    "How types are inferred"). stmt -> param -> jtype *)
let param_type func (Param (_, name, annotation, _, _)) =
  match annotated_type annotation with
  | Some t -> t
  | None ->
      let body =
        match func with SFunctionDef (_, _, _, body, _, _, _, _, _) -> body | _ -> []
      in
      if used_as_string name body then String
      else if used_as_float name body then Float
      else Int

(** Every jtype returned anywhere in body, without repeats.
    [jstmt] -> [jtype] *)
let return_types body =
  let rec go statements found =
    List.fold_left
      (fun found s ->
        match s with
        | JReturn (_, e) ->
            let t = jtype_of e in
            if List.mem t found then found else found @ [ t ]
        | JIf (_, _, then_body, else_body) ->
            go (Option.value else_body ~default:[]) (go then_body found)
        | JWhile (_, _, inner) | JLoop (_, inner) -> go inner found
        | _ -> found)
      found statements
  in
  go body []

(** Whether body calls the Java method named java_name.
    [jstmt] -> string -> bool *)
let calls body java_name =
  let rec in_expr e =
    match e with
    | JCall (_, name, args, _) -> name = java_name || List.exists in_expr args
    | JUnary (_, _, operand, _) -> in_expr operand
    | JBinary (_, _, left, right, _) | JEquals (_, left, right) ->
        in_expr left || in_expr right
    | JCond (_, cond, then_expr, else_expr, _) ->
        in_expr cond || in_expr then_expr || in_expr else_expr
    | _ -> false
  in
  let rec in_stmt s =
    match s with
    | JDecl (_, _, _, e, _) | JAssign (_, _, e) | JExprStmt (_, e)
    | JReturn (_, e) ->
        in_expr e
    | JPrint (_, _, Some e) -> in_expr e
    | JPrint (_, _, None) | JNoEffect _ | JBreak _ | JContinue _ -> false
    | JIf (_, cond, then_body, else_body) ->
        in_expr cond
        || List.exists in_stmt then_body
        || List.exists in_stmt (Option.value else_body ~default:[])
    | JWhile (_, cond, inner) -> in_expr cond || List.exists in_stmt inner
    | JLoop (_, inner) -> List.exists in_stmt inner
  in
  List.exists in_stmt body

(* --- definite return / reachability ---

   Conservative by construction (docs/target_java.md, "A function that
   does not return on every path"): recognises an unconditional return,
   or an if/else whose both arms definitely return, a subset of what
   javac's own flow analysis accepts. *)

(** Whether body contains a `break` belonging to the loop it is the body
    of -- one inside a nested loop belongs to that one instead.
    [jstmt] -> bool *)
let rec breaks_out body =
  List.exists
    (fun s ->
      match s with
      | JBreak _ -> true
      | JIf (_, _, then_body, else_body) ->
          breaks_out then_body || breaks_out (Option.value else_body ~default:[])
      | _ -> false)
    body

(** Whether s, as the last statement of a block, guarantees a return --
    or, for a `while (true)` nothing breaks out of, never lets the block
    finish at all, which javac treats the same way (JLS 14.21: such a
    statement cannot complete normally). jstmt -> bool *)
let rec stmt_definitely_returns s =
  match s with
  | JReturn _ -> true
  | JIf (_, _, then_body, Some else_body) ->
      definitely_returns then_body && definitely_returns else_body
  | JLoop (_, body) -> not (breaks_out body)
  | _ -> false

(** Whether stmts guarantee a return on every path. [jstmt] -> bool *)
and definitely_returns statements =
  match List.rev statements with
  | [] -> false
  | last :: _ -> stmt_definitely_returns last

(** Raises Unsupported at the first statement after one that definitely
    returns. [jstmt] -> () *)
let check_reachable statements =
  let info_of s =
    match s with
    | JDecl (i, _, _, _, _) | JAssign (i, _, _) | JNoEffect (i, _)
    | JExprStmt (i, _) | JPrint (i, _, _) | JIf (i, _, _, _) | JWhile (i, _, _)
    | JLoop (i, _) | JBreak i | JContinue i | JReturn (i, _) ->
        i
  in
  let count = List.length statements in
  List.iteri
    (fun index s ->
      if index < count - 1 && stmt_definitely_returns s then
        unsupported
          (info_of (List.nth statements (index + 1)))
          "unreachable statement -- javac refuses code after a branch that \
           always returns, where Python would simply never run it; remove it \
           or restructure the function")
    statements

(** One name per accumulator slot, or None if the target is nested deeper
    than Java can take apart. assign_target -> [string] option *)
let slot_names target =
  match target with
  | TargetName (_, name, _) -> Some [ name ]
  | TargetTuple (_, elements, _) ->
      List.fold_left
        (fun names element ->
          match (names, element) with
          | Some names, TargetName (_, name, _) -> Some (names @ [ name ])
          | _ -> None)
        (Some []) elements

(** The expressions filling each slot: expr itself for one slot, its
    elements for several. expr option -> int -> stmt -> [expr] *)
let slot_values e slots node =
  match e with
  | Some e when slots = 1 -> [ e ]
  | Some (ETuple (_, elements, _)) when List.length elements = slots -> elements
  | _ ->
      unsupported (stmt_info node)
        (Printf.sprintf
           "this loop carries %d values, so every turn has to give %d of them \
            one by one -- Java has no tuple to take apart here"
           slots slots)

(** Refuses a loop whose value Java has no room for: one worth `()`,
    which is what a loop carrying no accumulator is, or one carrying
    several slots, whose value is the tuple of them. stmt -> 'a *)
let breakable node =
  match node with
  | SLoop (_, None, _, _, _, _, _) ->
      unsupported (stmt_info node)
        "a loop worth `()` -- a loop with no accumulator is worth unit, and \
         Java has no value for one; carry the value the loop is for, or run \
         the loop for what it does rather than what it is worth"
  | _ ->
      unsupported (stmt_info node)
        "a loop that carries several values and is worth all of them -- Java \
         has no tuple to hold that; carry the one value the loop is for"

(** One jexpr computing the line print(args...) writes, joined with
    single spaces via Java's own +; None for no arguments.
    [jexpr] -> jexpr option *)
let build_print_expr args =
  (* Java writes a double its own way, so a Float becomes its Pyking
     text before it joins the line. *)
  let printed part =
    if jtype_of part = Float then JFloatStr (jexpr_info part, part) else part
  in
  match List.map printed args with
  | [] -> None
  | first :: rest ->
      Some
        (List.fold_left
           (fun result part ->
             let info = jexpr_info part in
             JBinary
               ( info,
                 "+",
                 JBinary (info, "+", result, JStr (info, " "), String),
                 part,
                 String ))
           first rest)

(** One `loop` being translated: one Java local and its type per
    accumulator slot. *)
type jloop = { slots : (string * jtype) list }

(** What the whole-program walk accumulates across functions. *)
type state = {
  context : Module.context;
  signatures : (string * (string * jtype list * jtype)) list;
  declared : (string * string) list;
  defined : StringSet.t;
  called_early : StringSet.t;
  loops : jloop list;
  temporaries : int;
  uses_float : bool;
  conversions : string list;
}

let rec set_assoc key value = function
  | [] -> [ (key, value) ]
  | (k, _) :: rest when k = key -> (key, value) :: rest
  | pair :: rest -> pair :: set_assoc key value rest

(** A number no temporary has used yet. state -> (int, state) *)
let temporary state =
  let state = { state with temporaries = state.temporaries + 1 } in
  (state.temporaries, state)

(** Raises Unsupported if node's jtype is not jtype.
    jexpr -> jtype -> string -> () *)
let require_numeric node what =
  if jtype_of node <> Int && jtype_of node <> Float then
    unsupported (jexpr_info node)
      (Printf.sprintf "%s needs Int or Float operands here, not %s" what
         (jtype_name (jtype_of node)))

let require node jtype what =
  if jtype_of node <> jtype then
    unsupported (jexpr_info node)
      (Printf.sprintf "%s needs %s operands here, not %s" what (jtype_name jtype)
         (jtype_name (jtype_of node)))

(** Whether name here means a def itself rather than a value.
    state -> string -> scope -> bool *)
let is_function_value state name scope =
  match List.assoc_opt name state.signatures with
  | None -> false
  | Some (java_name, _, _) -> (
      match SMap.find_opt name scope.names with
      | None -> true
      | Some (bound, _) -> bound = java_name)

(** Translates one expression. `allow_unit` permits a call to a void
    method, meaningful only as an expression statement.
    state -> expr -> scope -> bool -> (jexpr, state) *)
let rec expr state e scope allow_unit =
  match e with
  | EInt (info, v, _) -> (JInt (info, v), state)
  | EFloat (info, v, _) -> (JFloat (info, v), state)
  | EString (info, s, _) -> (JStr (info, s), state)
  | EBool (info, v, _) -> (JBool (info, v), state)
  | EVar (info, name, _) when is_function_value state name scope ->
      (* A def's own name used as a value is a lambda calling the method
         (docs/target_java.md, "Functions as values"). *)
      function_value state info name
  | EQualified (info, alias, field, _)
    when List.mem_assoc (reached alias field) state.signatures ->
      function_value state info (reached alias field)
  | EVar (info, name, _) ->
      let java_name, jtype = lookup name scope info in
      (JVar (info, java_name, jtype), state)
  | ENeg (info, operand, _) ->
      let inner, state = expr state operand scope false in
      require_numeric inner "negation";
      (JUnary (info, "-", inner, jtype_of inner), state)
  | EDiv (info, l, r, _) ->
      (* Java's `/` on ints truncates toward zero, which is Pyking's own
         rule, and on doubles it is IEEE's, which is Pyking's other
         one. *)
      let left, state = expr state l scope false in
      let right, state = expr state r scope false in
      require_numeric left "`/`";
      require right (jtype_of left) "`/`";
      (JBinary (info, "/", left, right, jtype_of left), state)
  | EAdd (info, l, r, _) ->
      let left, state = expr state l scope false in
      let right, state = expr state r scope false in
      require_numeric left "`+`";
      require right (jtype_of left) "`+`";
      (JBinary (info, "+", left, right, jtype_of left), state)
  (* The conversions, by the argument's type (builtin.ml, "what a
     conversion reads"). Java's own are used where they agree: widening an
     int is exact within the range a double holds, and a cast truncates
     toward zero, which is the rounding Pyking's `int` and `/` both do --
     but a double with no int to truncate to, and every String, go through
     a helper. *)
  | ECall (info, EVar (_, (("string" | "int" | "float" | "bool") as name), _), [ (_, argument) ], _)
    when not (List.mem_assoc name state.signatures) -> (
      let inner, state = expr state argument scope false in
      let helper helper_name result state =
        ( JCall (info, helper_name, [ inner ], result),
          if List.mem helper_name state.conversions then state
          else { state with conversions = state.conversions @ [ helper_name ] } )
      in
      match (name, jtype_of inner) with
      | "string", String | "int", Int | "float", Float | "bool", Bool -> (inner, state)
      | "string", (Int | Bool) -> (JCall (info, "String.valueOf", [ inner ], String), state)
      | "string", Float -> (JFloatStr (info, inner), { state with uses_float = true })
      | "int", Float -> helper "pykTruncate" Int state
      | "int", Bool -> (JCond (info, inner, JInt (info, 1), JInt (info, 0), Int), state)
      | "int", String -> helper "pykIntOfString" Int state
      | "float", Int -> (JCast (info, Float, inner), state)
      | "float", Bool ->
          (JCond (info, inner, JFloat (info, 1.0), JFloat (info, 0.0), Float), state)
      | "float", String -> helper "pykFloatOfString" Float state
      | "bool", Int -> (JBinary (info, "==", inner, JInt (info, 1), Bool), state)
      | "bool", Float -> (JBinary (info, "==", inner, JFloat (info, 1.0), Bool), state)
      | "bool", String -> (JEquals (info, inner, JStr (info, "true")), state)
      | _, jtype ->
          unsupported (expr_info e)
            (Printf.sprintf "`%s` of a value of type %s" name (jtype_name jtype)))
  | EConcat (info, l, r, _) ->
      (* Java spells concatenation `+` too, so the two Pyking operators
         differ here only in the type they demand. *)
      let left, state = expr state l scope false in
      let right, state = expr state r scope false in
      require left String "`++`";
      require right String "`++`";
      (JBinary (info, "+", left, right, String), state)
  | EEq (info, l, r, _) ->
      let left, state = expr state l scope false in
      let right, state = expr state r scope false in
      if jtype_of left = String && jtype_of right = String then
        (JEquals (info, left, right), state)
      else if jtype_of left <> jtype_of right then
        unsupported (expr_info e) "`==` between values of different types"
      else (JBinary (info, "==", left, right, Bool), state)
  | EIf (info, cond, then_expr, else_expr, _) ->
      let c, state = expr state cond scope false in
      let t, state = expr state then_expr scope false in
      let f, state = expr state else_expr scope false in
      if jtype_of t <> jtype_of f then
        unsupported (expr_info e)
          "the branches of an `if` expression must have the same type in Java";
      (JCond (info, c, t, f, jtype_of t), state)
  | ECall (_, EVar (_, name, _), _, _) when Builtin.crosses_host name
         && not (List.mem_assoc name state.signatures) ->
      unsupported (expr_info e)
        (Printf.sprintf "`%s` may only be used as a statement, not as a value"
           name)
  | EQualified (info, alias, field, _) ->
      (* A public name of another module: `declare_imports` bound it
         under the class name that holds it. *)
      let java_name, jtype = lookup (reached alias field) scope info in
      (JVar (info, java_name, jtype), state)
  | ECall (info, EQualified (_, alias, field, _), args, _) ->
      call state e (reached alias field) (arg_exprs args) scope allow_unit info
  | ECall (info, EVar (_, name, _), args, _) ->
      call state e name (arg_exprs args) scope allow_unit info
  | ECall _ -> unsupported (expr_info e) "calling anything but a named function"
  | e -> (
      match (binary_op e, Interpreter.binary_operands e) with
      | Some op, Some (l, r) ->
          let left, state = expr state l scope false in
          let right, state = expr state r scope false in
          require_numeric left (Printf.sprintf "`%s`" op);
          require right (jtype_of left) (Printf.sprintf "`%s`" op);
          let jtype = if op = "-" || op = "*" then jtype_of left else Bool in
          (JBinary (expr_info e, op, left, right, jtype), state)
      | _ -> unsupported (expr_info e) (expr_kind_name e))

(** A def's name as a value: a lambda calling its method, typed by the
    interface of its shape. state -> info -> string -> (jexpr, state) *)
and function_value state info name =
  match List.assoc_opt name state.signatures with
  | None -> unsupported info (Printf.sprintf "'%s' is not a function" name)
  | Some (java_name, param_types, ret) ->
      let state =
        if StringSet.mem name state.defined then state
        else { state with called_early = StringSet.add name state.called_early }
      in
      if List.exists (fun t -> match t with Func _ -> true | _ -> false) (ret :: param_types)
      then
        unsupported info
          (Printf.sprintf
             "`%s` is used as a value and itself takes or answers a function \
              -- this backend has an interface for a function over values, \
              and none for one over functions"
             name);
      if List.length param_types > 2 then
        unsupported info
          (Printf.sprintf
             "`%s` is used as a value and takes %d parameters -- \
              java.util.function has an interface for at most two"
             name (List.length param_types));
      (JLambda (info, java_name, Func (param_types, ret)), state)

(** Translates a call to a named function -- one written here, or one
    another module exports. `name` is the key its signature is registered
    under. state -> expr -> string -> [expr] -> scope -> bool -> info
    -> (jexpr, state) *)
and call state e name args scope allow_unit info =
  let callee, through =
    if is_function_value state name scope then (List.assoc_opt name state.signatures, None)
    else
      (* A name holding a function -- a parameter, or a binding -- is
         called through its interface's method. *)
      match SMap.find_opt name scope.names with
      | Some (java_name, (Func (param_types, ret) as t)) ->
          (Some (java_name ^ "." ^ apply_method t, param_types, ret), Some ret)
      | _ -> (None, None)
  in
  match callee with
  | None ->
      unsupported (expr_info e)
        (Printf.sprintf "call to unknown function `%s`" name)
  | Some (java_name, param_types, ret) ->
      let state =
        if StringSet.mem name state.defined || through <> None then state
        else { state with called_early = StringSet.add name state.called_early }
      in
      if List.length args <> List.length param_types then
        unsupported (expr_info e)
          (Printf.sprintf "`%s` takes %d argument(s)" name
             (List.length param_types));
      if ret = Unit && not allow_unit then
        unsupported (expr_info e)
          (Printf.sprintf
             "`%s` produces no value (it returns unit), so it cannot be used \
              as one; call it as a statement of its own"
             name);
      let translated, state =
        List.fold_left
          (fun (out, state) a ->
            let j, state = expr state a scope false in
            (out @ [ j ], state))
          ([], state) args
      in
      (* Java widens an int to a double without a word, so an argument
         at the wrong type would compile and be quietly wrong. This
         backend infers each method's parameter types from its own body,
         so a mismatch is a type it could not work out rather than a
         program error -- it is refused here, with the position of the
         call. *)
      List.iteri
        (fun index argument ->
          let wanted = List.nth param_types index in
          if jtype_of argument <> wanted then
            unsupported (jexpr_info argument)
              (Printf.sprintf
                 "argument %d of `%s` is %s where this backend worked out %s"
                 (index + 1) name
                 (jtype_name (jtype_of argument))
                 (jtype_name wanted)))
        translated;
      let called = JCall (info, java_name, translated, ret) in
      (* An interface answers its result boxed; a cast unboxes it, so
         that `==` compares values rather than objects. *)
      match through with
      | Some (Int | Float | Bool) -> (JCast (info, ret, called), state)
      | _ -> (called, state)

(** Translates a statement sequence, threading the scope through it;
    raises Unsupported for code after an unconditional return
    (docs/target_java.md, "Unreachable code after a return").
    state -> [stmt] -> scope -> ([jstmt], scope, state) *)
and stmts state statements scope =
  let out, scope, state =
    List.fold_left
      (fun (out, scope, state) s ->
        let translated, scope, state = stmt state s scope in
        (out @ translated, scope, state))
      ([], scope, state) statements
  in
  check_reachable out;
  (out, scope, state)

(** Translates a statement list whose last statement is in tail position
    (PYKING.md, "Tail position").
    state -> [stmt] -> scope -> ([jstmt], state) *)
and tail_stmts state statements scope =
  match statements with
  | [] -> ([], state)
  | statements ->
      let count = List.length statements in
      let front = List.filteri (fun i _ -> i < count - 1) statements in
      let body, tail_scope, state = stmts state front scope in
      let tail, state =
        tail_stmt state (List.nth statements (count - 1)) tail_scope
      in
      (body @ tail, state)

(** The last statement of a body in tail position, as a list of Java
    statements. state -> stmt -> scope -> ([jstmt], state) *)
and tail_stmt state s scope =
  match s with
  (* `()` as a statement is unit, which is nothing to do: what a removed
     `debug` leaves at the end of a body (src/release.ml). *)
  | SExprStmt (_, ETuple (_, [], _), _) -> ([], state)
  | SExprStmt (_, ECall (_, EVar (_, name, _), _, _), _)
    when Builtin.crosses_host name
         && not (List.mem_assoc name state.signatures) ->
      let translated, _, state = stmt state s scope in
      (translated, state)
  | SExprStmt (info, e, _) ->
      (* A call worth unit ends a method that returns nothing: it is a
         statement, not a value to return. *)
      let value, state = expr state e scope true in
      if jtype_of value = Unit then ([ JExprStmt (info, value) ], state)
      else ([ JReturn (info, value) ], state)
  | SMatch _ ->
      let built, _, state =
        match_chain state s scope (fun state body inner ->
            tail_stmts state body inner)
      in
      (built, state)
  | SIf (info, cond, then_body, else_body, _) ->
      let condition, state = expr state cond scope false in
      require condition Bool "an `if` condition";
      let then_branch, state = tail_stmts state then_body (block_scope scope) in
      let else_branch, state =
        match else_body with
        | None -> (None, state)
        | Some else_body ->
            let branch, state = tail_stmts state else_body (block_scope scope) in
            (Some branch, state)
      in
      ([ JIf (info, condition, then_branch, else_branch) ], state)
  | SLoop (info, _, _, _, _, _, _) -> (
      (* A function ending in a loop returns what the loop produced: what
         it broke with. A loop nothing breaks out of never gets there,
         and javac refuses a statement that cannot be reached. *)
      let java_stmts, value, _, state = loop state s scope in
      let last_body =
        match List.rev java_stmts with
        | JLoop (_, body) :: _ -> body
        | JWhile (_, _, body) :: _ -> body
        | _ -> []
      in
      if not (breaks_out last_body) then (java_stmts, state)
      else
        match value with
        | None -> breakable s
        | Some value -> (java_stmts @ [ JReturn (info, value) ], state))
  | s ->
      let translated, _, state = stmt state s scope in
      (translated, state)

(** Translates a loop into `while (true)` over one local per accumulator
    slot (docs/target_java.md, "loop"): the initializer declares them and
    every tail of the body assigns the next turn's values, so they hold
    what the loop is worth however it stops -- a `break` is Java's own,
    and leaves this turn's values where they are.
    state -> stmt -> scope -> ([jstmt], jexpr option, scope, state) *)
and loop state s scope =
  match s with
  | SLoop (info, target, init, _, iterate, loop_body, _) -> (
      (match iterate with
      | Some (ForIn (iter_info, _, _, _)) ->
          unsupported iter_info
            "a `for` loop -- it walks a list, and this backend has no value \
             model for one"
      | _ -> ());
      match target with
      | None -> plain_loop state s scope
      | Some target ->
          let names =
            match slot_names target with
            | Some names -> names
            | None ->
                unsupported info
                  "a loop accumulator that is not one name per slot"
          in
          let values, state =
            List.fold_left
              (fun (out, state) e ->
                let j, state = expr state e scope false in
                (out @ [ j ], state))
              ([], state)
              (slot_values init (List.length names) s)
          in
          let slots, body_scope =
            List.fold_left2
              (fun (slots, body_scope) name value ->
                let java_name, body_scope = bind name (jtype_of value) body_scope in
                (slots @ [ (java_name, jtype_of value) ], body_scope))
              ([], block_scope scope) names values
          in
          let setup =
            List.map2
              (fun (java_name, _) value ->
                JDecl (info, jtype_of value, java_name, value, false))
              slots values
          in
          let inner_state = { state with loops = state.loops @ [ { slots } ] } in
          let body, inner_state = loop_block inner_state loop_body body_scope in
          let state = { inner_state with loops = state.loops } in
          let taken = List.map fst slots in
          let value =
            if List.length slots > 1 then None
            else
              let java_name, jtype = List.hd slots in
              Some (JVar (info, java_name, jtype))
          in
          let body, state =
            match iterate with
            | Some (WhileTest (_, condition, _)) ->
                let test, state = expr state condition body_scope false in
                require test Bool "a `while` condition";
                ( JIf (info, JUnary (info, "!", test, Bool), [ JBreak info ], None)
                  :: body,
                  state )
            | _ -> (body, state)
          in
          (setup @ [ JLoop (info, body) ], value, reserve taken scope, state))
  | _ -> ([], None, scope, state)

(** `loop:` or `while c:` with no accumulator: nothing to carry, and
    worth unit, which Java has no value for.
    state -> stmt -> scope -> ([jstmt], jexpr option, scope, state) *)
and plain_loop state s scope =
  match s with
  | SLoop (info, _, _, _, iterate, loop_body, _) -> (
      let inner_state = { state with loops = state.loops @ [ { slots = [] } ] } in
      let body, inner_state = block inner_state loop_body scope in
      let state = { inner_state with loops = state.loops } in
      match iterate with
      | Some (WhileTest (_, condition, _)) ->
          let test, state = expr state condition scope false in
          require test Bool "a `while` condition";
          ([ JWhile (info, test, body) ], None, scope, state)
      | _ -> ([ JLoop (info, body) ], None, scope, state))
  | _ -> ([], None, scope, state)

(** The statements that give the innermost loop its next values. With
    more than one slot they go through locals, so a slot that reads
    another sees the turn it is still on.
    state -> expr -> scope -> stmt -> ([jstmt], state) *)
and accumulate state e scope node =
  let this = List.nth state.loops (List.length state.loops - 1) in
  let values, state =
    List.fold_left
      (fun (out, state) one ->
        let j, state = expr state one scope false in
        (out @ [ j ], state))
      ([], state)
      (slot_values (Some e) (List.length this.slots) node)
  in
  List.iter2
    (fun (java_name, jtype) value ->
      if jtype_of value <> jtype then
        unsupported (stmt_info node)
          (Printf.sprintf
             "this loop carries %s in `%s`, so it cannot go on with %s in Java"
             (jtype_name jtype) java_name
             (jtype_name (jtype_of value))))
    this.slots values;
  if List.length this.slots = 1 then
    ([ JAssign (stmt_info node, fst (List.hd this.slots), List.hd values) ], state)
  else
    let turn, state = temporary state in
    let temporaries =
      List.map
        (fun (java_name, jtype) ->
          (Printf.sprintf "%s_next%d" java_name turn, jtype))
        this.slots
    in
    ( List.map2
        (fun (name, jtype) value ->
          JDecl (stmt_info node, jtype, name, value, true))
        temporaries values
      @ List.map2
          (fun (java_name, _) (name, jtype) ->
            JAssign (stmt_info node, java_name, JVar (stmt_info node, name, jtype)))
          this.slots temporaries,
      state )

(** Translates a loop body: whatever a path ends in is the next turn's
    value, so every tail becomes an assignment to the accumulator --
    except a `break`/`continue`, which has already said what happens
    next. state -> [stmt] -> scope -> ([jstmt], state) *)
and loop_block state statements scope =
  match statements with
  | [] -> ([], state)
  | statements ->
      let count = List.length statements in
      let front = List.filteri (fun i _ -> i < count - 1) statements in
      let body, scope, state = stmts state front scope in
      let tail, state = loop_tail state (List.nth statements (count - 1)) scope in
      (body @ tail, state)

(** The last statement of a loop body, or of one branch of one.
    state -> stmt -> scope -> ([jstmt], state) *)
and loop_tail state s scope =
  match s with
  | SExprStmt (_, ETuple (_, [], _), _) -> ([], state)
  | SExprStmt (_, e, _) -> accumulate state e scope s
  | SIf (info, cond, then_body, else_body, _) -> (
      let condition, state = expr state cond scope false in
      require condition Bool "an `if` condition";
      match else_body with
      | None ->
          unsupported (stmt_info s)
            "an `if` with no `else` as the last statement of a loop body -- \
             there would be a turn with no next value, and Java has no unit \
             to give it"
      | Some else_body ->
          let then_branch, state = loop_block state then_body (block_scope scope) in
          let else_branch, state = loop_block state else_body (block_scope scope) in
          ([ JIf (info, condition, then_branch, Some else_branch) ], state))
  | SBreak _ | SContinue _ | SReturn _ | SReturnStmt _ ->
      let translated, _, state = stmt state s scope in
      (translated, state)
  | s ->
      unsupported (stmt_info s)
        "a loop body ending in something with no value -- every turn has to \
         say what the next one carries"

(** Translates a nested block; its bindings do not escape.
    state -> [stmt] -> scope -> ([jstmt], state) *)
and block state statements scope =
  let translated, _, state = stmts state statements (block_scope scope) in
  (translated, state)

(** A `match` as an if/else chain over the subject, held in a name of its
    own so it is evaluated once. The subject is a scalar -- this backend
    has neither lists nor tuples -- so a pattern is a literal, a
    wildcard, or a name. An arm whose pattern always matches becomes the
    `else`, which is what lets `definitely_returns` see that a total
    `match` returns.
    state -> stmt -> scope
    -> (state -> [stmt] -> scope -> ([jstmt], state))
    -> ([jstmt], scope, state) *)
and match_chain state s scope translate_body =
  match s with
  | SMatch (info, subject_expr, cases, _) ->
      let subject, state = expr state subject_expr scope false in
      let held, scope = bind "__subject" (jtype_of subject) scope in
      let here = JVar (info, held, jtype_of subject) in
      let chain, state =
        List.fold_left
          (fun (chain, state) (MatchCase (case_info, p, case_body, _)) ->
            let test, bindings, arm_scope = pattern_test p here (block_scope scope) in
            let body, state = translate_body state case_body arm_scope in
            let body = bindings @ body in
            match test with
            | None -> (Some body, state)
            | Some test -> (Some [ JIf (case_info, test, body, chain) ], state))
          (None, state) (List.rev cases)
      in
      let opening = JDecl (info, jtype_of subject, held, subject, false) in
      ((opening :: Option.value chain ~default:[]), scope, state)
  | _ -> ([], scope, state)

(** (test, bindings, scope) for one pattern over a scalar subject. The
    test is None when the pattern always matches, and a capture becomes a
    declaration at the top of the arm.
    pattern -> jexpr -> scope -> (jexpr option, [jstmt], scope) *)
and pattern_test p subject scope =
  let info = pattern_info p in
  match p with
  | PWildcard _ -> (None, [], scope)
  | PCapture (_, name, _) ->
      let java_name, scope = bind name (jtype_of subject) scope in
      (None, [ JDecl (info, jtype_of subject, java_name, subject, false) ], scope)
  | PInt (_, value, _) ->
      require subject Int "an Int pattern";
      (Some (JBinary (info, "==", subject, JInt (info, value), Bool)), [], scope)
  | PBool (_, value, _) ->
      require subject Bool "a Bool pattern";
      (Some (JBinary (info, "==", subject, JBool (info, value), Bool)), [], scope)
  | PText _ ->
      unsupported info
        "a `++` pattern over a string -- taking the middle out means \
         allocating one, which this backend has no value model for"
  | PString (_, value, _) ->
      (* Java's `==` on String compares references, so a string pattern
         goes through `.equals` like `==` does. *)
      require subject String "a String pattern";
      (Some (JEquals (info, subject, JStr (info, value))), [], scope)
  | p -> unsupported (pattern_info p) "this pattern"

(** Translates one statement, answering it with the scope it leaves
    behind. state -> stmt -> scope -> ([jstmt], scope, state) *)
and stmt state s scope =
  match s with
  | SLet (info, TargetName (_, name, _), e, _, _, _, _) ->
      let value, state = expr state e scope false in
      let java_name, scope = bind name (jtype_of value) scope in
      ([ JDecl (info, jtype_of value, java_name, value, true) ], scope, state)
  | SLet _ -> unsupported (stmt_info s) "tuple destructuring targets"
  | SLetStmt (info, TargetName (_, name, _), (SLoop _ as inner), _, _, _) -> (
      (* `x = loop ...` -- the loop's value is the accumulator it stopped
         with, so the binding is one declaration after it. *)
      let java_stmts, value, scope, state = loop state inner scope in
      match value with
      | None -> breakable inner
      | Some value ->
          let java_name, scope = bind name (jtype_of value) scope in
          ( java_stmts @ [ JDecl (info, jtype_of value, java_name, value, true) ],
            scope,
            state ))
  | SVar (info, name, e, _) ->
      let value, state = expr state e scope false in
      let java_name, scope = bind name (jtype_of value) scope in
      ([ JDecl (info, jtype_of value, java_name, value, false) ], scope, state)
  | SMutate (info, name, e, _) ->
      let java_name, jtype = lookup name scope info in
      let value, state = expr state e scope false in
      if jtype_of value <> jtype then
        unsupported (stmt_info s)
          (Printf.sprintf
             "`:=` cannot change the type of `%s` from %s to %s in Java" name
             (jtype_name jtype)
             (jtype_name (jtype_of value)));
      ([ JAssign (info, java_name, value) ], scope, state)
  | SReturnStmt (_, inner, _) ->
      let translated, state = tail_stmt state inner scope in
      (translated, scope, state)
  | SReturn (info, e, _) ->
      let value, state = expr state e scope false in
      ([ JReturn (info, value) ], scope, state)
  | SExprStmt (_, ETuple (_, [], _), _) -> ([], scope, state)
  | SExprStmt (info, ECall (_, EVar (_, name, _), args, _), _)
    when Builtin.crosses_host name
         && not (List.mem_assoc name state.signatures) ->
      let translated, state =
        List.fold_left
          (fun (out, state) a ->
            let j, state = expr state a scope false in
            (out @ [ j ], state))
          ([], state) (arg_exprs args)
      in
      let state =
        if List.exists (fun a -> jtype_of a = Float) translated then
          { state with uses_float = true }
        else state
      in
      ( [ JPrint (info, Builtin.is_debug name, build_print_expr translated) ],
        scope,
        state )
  | SExprStmt (info, e, _) -> (
      (* docs/target_java.md, "An expression statement that is not a
         call". *)
      match e with
      | ECall _ ->
          let value, state = expr state e scope true in
          ([ JExprStmt (info, value) ], scope, state)
      | e ->
          if contains_call e then
            unsupported (stmt_info s)
              "an expression statement that is not itself a call: Java allows \
               only a call, an assignment or an increment to stand as a \
               statement, and dropping this one would skip the call inside it"
          else
            ([ JNoEffect (info, pprint_expr default_config e 0) ], scope, state))
  | SLoop _ ->
      let java_stmts, _, scope, state = loop state s scope in
      (java_stmts, scope, state)
  | SBreak (info, _) ->
      (* Java's own: the locals are left holding what this turn started
         with, which is what the loop is worth. *)
      ([ JBreak info ], scope, state)
  | SContinue (info, _) -> ([ JContinue info ], scope, state)
  | SMatch _ ->
      match_chain state s scope (fun state body inner ->
          let translated, _, state = stmts state body inner in
          (translated, state))
  | SIf (info, cond, then_body, else_body, _) ->
      let condition, state = expr state cond scope false in
      let then_branch, state = block state then_body scope in
      let else_branch, state =
        match else_body with
        | None -> (None, state)
        | Some else_body ->
            let branch, state = block state else_body scope in
            (Some branch, state)
      in
      ([ JIf (info, condition, then_branch, else_branch) ], scope, state)
  | SFunctionDef _ ->
      unsupported (stmt_info s)
        "a nested function -- Java has no local functions with Pyking's \
         closure semantics; a lambda would need a functional-interface type \
         this backend does not infer, and could not mutate a captured \
         variable the way a nested `def` may need to"
  | s -> unsupported (stmt_info s) (stmt_kind_name s)

(** Binds everything this module's imports bring in, under the Java name
    the class that holds it gives it -- `Helper.inc` for `inc` out of
    `helper`, whether it is reached as `helper.inc` or under a name a
    `from` line gave it. A method goes in `signatures` as well, since
    that is where a call finds its parameter and return types.
    state -> [stmt] -> scope -> (scope, state) *)
let declare_imports state stmts scope =
  List.fold_left
    (fun (scope, state) statement ->
      match statement with
      | SImport (_, module_, local_module, selected, fields, _) ->
          let sigmap =
            match List.assoc_opt module_ state.context.sigmaps with
            | Some sigmap -> sigmap
            | None -> []
          in
          List.fold_left
            (fun (scope, state) (exported, local) ->
              let key =
                if selected then local
                else Printf.sprintf "%s.%s" local_module exported
              in
              (* A name the target's own source provides is in the
                 implementation's class, not in the one generated for
                 this module. *)
              let held =
                default_class_name
                  (Module.reached_module state.context.external_fields module_
                     exported)
              in
              let java_name = Printf.sprintf "%s.%s" held exported in
              match
                List.find_map
                  (fun (n, t, _) -> if n = exported then Some t else None)
                  sigmap
              with
              | Some (TFunction (_, params, result, _, _, _, _)) ->
                  let param_types = List.map (fun p -> annotated_type (Some p)) params in
                  let result = Option.value (annotated_type (Some result)) ~default:Unit in
                  if List.for_all (fun p -> p <> None) param_types then
                    ( scope,
                      {
                        state with
                        signatures =
                          set_assoc key
                            (java_name, List.map Option.get param_types, result)
                            state.signatures;
                        declared = set_assoc key java_name state.declared;
                      } )
                  else (scope, state)
              | found -> (
                  match annotated_type found with
                  | Some jtype -> (bind_exact key java_name jtype scope, state)
                  | None -> (scope, state)))
            (scope, state) fields
      | _ -> (scope, state))
    (scope, state) stmts

(** This module's public bindings as the fields another class reads them
    through -- nothing for the program's own module, which nothing
    imports. state -> [stmt] -> scope -> [jglobal] *)
let exported_values state stmts scope =
  if state.context.main then []
  else
    List.filter_map
      (fun statement ->
        match statement with
        | SLet (info, TargetName (_, name, _), _, _, _, true, _)
        | SLetStmt (info, TargetName (_, name, _), _, _, _, true) ->
            let held, jtype = lookup name scope info in
            Some
              {
                global_info = info;
                global_jtype = jtype;
                global_name = name;
                global_from = held;
              }
        | _ -> None)
      stmts

(** How this class's own `init` writes one of its fields. The local that
    worked the value out may have the same name, and a bare assignment
    would then be the local's own. state -> string -> string *)
let field_name state name =
  Printf.sprintf "%s.%s" (default_class_name state.context.context_name) name

(** Registers every top-level def's signature (return type provisional:
    its annotation, or Int) before any body is translated, enabling
    forward references and mutual recursion (docs/target_java.md,
    "Forward references and mutual recursion").
    state -> [stmt] -> scope -> (scope, state) *)
let declare_functions state stmts scope =
  List.fold_left
    (fun (scope, state) s ->
      match s with
      | SFunctionDef (_, name, params, _, return_type, _, _, _, _) ->
          reject_type_variables s;
          let java_name, scope = bind name Int scope in
          ( scope,
            {
              state with
              signatures =
                set_assoc name
                  ( java_name,
                    List.map (param_type s) params,
                    Option.value (annotated_type return_type) ~default:Int )
                  state.signatures;
              declared = set_assoc name java_name state.declared;
            } )
      | _ -> (scope, state))
    (scope, state) stmts

(** Translates a def; its signature is already registered
    (`declare_functions`). state -> stmt -> scope -> (jfunc, scope, state) *)
let function_of state func scope =
  match func with
  | SFunctionDef (info, name, params, func_body, return_type, _, public, _, _) ->
      let param_types = List.map (param_type func) params in
      let java_name, scope =
        match List.assoc_opt name state.declared with
        | Some java_name -> (java_name, scope)
        | None -> bind name Int scope
      in
      let provisional = Option.value (annotated_type return_type) ~default:Int in
      let state =
        {
          state with
          signatures =
            set_assoc name (java_name, param_types, provisional) state.signatures;
        }
      in
      (* A method is written at the top level, and what the top level
         has bound so far is a static field it reads like any other
         (docs/target_java.md, "The top level"). *)
      let body_scope = block_scope scope in
      let java_params, body_scope =
        List.fold_left2
          (fun (out, body_scope) (Param (_, param_name, _, _, _)) jtype ->
            let java_param, body_scope = bind param_name jtype body_scope in
            (out @ [ (jtype, java_param) ], body_scope))
          ([], body_scope) params param_types
      in
      let body, state = tail_stmts state func_body body_scope in
      let returned = return_types body in
      let recursive = calls body java_name in
      if
        List.length returned > 1
        || (returned <> [] && returned <> [ provisional ] && recursive)
      then
        if recursive then
          unsupported info
            (Printf.sprintf
               "`%s` calls itself and does not return Int; a recursive \
                function's return type is assumed Int unless annotated, so \
                annotate it (`-> String`, `-> Bool`)"
               name)
        else unsupported info "a function returning more than one type";
      let actual = match returned with [] -> Unit | t :: _ -> t in
      let state =
        {
          state with
          signatures = set_assoc name (java_name, param_types, actual) state.signatures;
        }
      in
      if StringSet.mem name state.called_early && actual <> provisional then
        unsupported info
          (Printf.sprintf
             "`%s` is called before it is defined and does not return %s; a \
              call written above a `def` is typed from the annotation, or Int \
              without one, so annotate the return type (`-> String`, `-> \
              Bool`)"
             name (jtype_name provisional));
      let state = { state with defined = StringSet.add name state.defined } in
      if actual <> Unit && not (definitely_returns body) then
        unsupported info
          (Printf.sprintf
             "`%s` does not return a value on every path; unlike Python, \
              javac refuses to compile a method that can fall off the end \
              instead of returning, so make sure every branch ends in \
              `return`"
             name);
      ( {
          func_info = info;
          func_name = java_name;
          func_params = java_params;
          func_body = body;
          ret_type = actual;
          func_public = public && not state.context.main;
        },
        scope,
        state )
  | _ ->
      ( {
          func_info = stmt_info func;
          func_name = "";
          func_params = [];
          func_body = [];
          ret_type = Unit;
          func_public = false;
        },
        scope,
        state )

(** Refuses a name an import takes from a module's declaration half --
    any of an external module's, or a declared one of a module in two
    halves -- whose type Java has no representation for. Java calls the
    implementation directly, so there is nothing to declare here -- but
    the type still has to be one this subset can carry, and saying so
    where it was imported beats failing at the first call.
    [stmt] -> Module.context -> () *)
let check_externals stmts (context : Module.context) =
  List.iter
    (fun statement ->
      match statement with
      | SImport (info, name, _, _, fields, _) ->
          let declared =
            Option.value (List.assoc_opt name context.external_fields) ~default:[]
          in
          let signatures =
            try List.assoc name context.sigmaps with Not_found -> []
          in
          List.iter
            (fun (field, type_, _) ->
              let check t what =
                match t with
                | TTuple (_, [], _) -> ()
                | t ->
                    if annotated_type (Some t) = None then
                      unsupported info
                        (Printf.sprintf
                           "the external module '%s' declares '%s' with %s \
                            this target has no Java type for"
                           name field what)
              in
              if
                List.mem_assoc field fields
                && (List.mem name context.externals || List.mem field declared)
              then
                match type_ with
                | TFunction (_, params, result, _, _, _, _) ->
                    List.iter (fun t -> check t "a parameter") params;
                    check result "a return type"
                | t -> check t "a type")
            signatures
      | _ -> ())
    stmts

(** The names this module's own declaration half provides, bound to the
    implementation's class so the Pyking half can call them. One Java
    cannot represent is left out: nothing the program reaches calls it,
    or its caller is refused where it is translated.
    state -> scope -> (scope, state) *)
let declare_own_externals state scope =
  let held = default_class_name (state.context.context_name ^ "_external") in
  List.fold_left
    (fun (scope, state) (field, type_) ->
      let java_name = Printf.sprintf "%s.%s" held field in
      match type_ with
      | TFunction (_, params, result, _, _, _, _) ->
          let param_types = List.map (fun p -> annotated_type (Some p)) params in
          let result = Option.value (annotated_type (Some result)) ~default:Unit in
          if List.for_all (fun p -> p <> None) param_types then
            ( scope,
              {
                state with
                signatures =
                  set_assoc field
                    (java_name, List.map Option.get param_types, result)
                    state.signatures;
                declared = set_assoc field java_name state.declared;
              } )
          else (scope, state)
      | t -> (
          match annotated_type (Some t) with
          | Some jtype -> (bind_exact field java_name jtype scope, state)
          | None -> (scope, state)))
    (scope, state) state.context.own_declared

(** One module of a program as a jprogram. `context` says what is true of
    it only as part of a program -- its name, whether it is the program's
    own module, and what the modules it imports export.
    [stmt] -> Module.context -> jprogram *)
let translate_program stmts context =
  check_externals stmts context;
  let state =
    {
      context;
      signatures = [];
      declared = [];
      defined = StringSet.empty;
      called_early = StringSet.empty;
      loops = [];
      temporaries = 0;
      uses_float = false;
      conversions = [];
    }
  in
  let scope = empty_scope in
  let scope, state = declare_own_externals state scope in
  let scope, state = declare_imports state stmts scope in
  let scope, state = declare_functions state stmts scope in
  let functions, main_body, scope, state =
    List.fold_left
      (fun (functions, main_body, scope, state) s ->
        match s with
        | SFunctionDef _ ->
            let func, scope, state = function_of state s scope in
            (functions @ [ func ], main_body, scope, state)
        (* What it brings in is another class of the program, reached by
           that class's name; there is nothing to emit for it. *)
        | SImport _ -> (functions, main_body, scope, state)
        | s ->
            let translated, scope, state = stmt state s scope in
            (functions, main_body @ translated, scope, state))
      ([], [], scope, state) stmts
  in
  (* A public value is a field of this class, and the module's own top
     level is where it gets its value: the binding is translated as any
     other, and `init` ends by handing what it worked out to the
     field. *)
  let globals = exported_values state stmts scope in
  (* Each binding the top level makes is a static field, assigned where
     the binding is, so that a method can read it. *)
  let statics, main_body =
    List.fold_left
      (fun (statics, out) s ->
        match s with
        | JDecl (info, jtype, name, init, _) ->
            (statics @ [ (jtype, name) ], out @ [ JAssign (info, name, init) ])
        | s -> (statics, out @ [ s ]))
      ([], []) main_body
  in
  (* An exported value whose field is the binding's own needs nothing
     more: the field is public, and the assignment above fills it in. *)
  let own g = g.global_from = g.global_name && List.exists (fun (_, n) -> n = g.global_name) statics in
  let main_body =
    main_body
    @ List.filter_map
        (fun g ->
          if own g then None
          else
            Some
              (JAssign
                 ( g.global_info,
                   field_name state g.global_name,
                   JVar (g.global_info, g.global_from, g.global_jtype) )))
        globals
  in
  let statics =
    List.filter (fun (_, name) -> not (List.exists (fun g -> g.global_name = name) globals)) statics
  in
  check_reachable main_body;
  {
    functions;
    main_body;
    program_name = context.context_name;
    uses_float = state.uses_float;
    conversions = state.conversions;
    main = context.main;
    separate = context.separate;
    starts = List.map default_class_name context.starts;
    globals;
    statics;
  }

(* --- printer: Java AST -> Java source text --- *)

let precedence op =
  match op with
  | "*" | "/" -> 13
  | "+" | "-" -> 12
  | "<" | "<=" | ">" | ">=" -> 10
  | "==" -> 9
  | _ -> 0

let unary_precedence = 14
let conditional_precedence = 3
let call_precedence = 16

let escape_char c =
  match c with
  | '\\' -> "\\\\"
  | '"' -> "\\\""
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(** s as a double-quoted Java string literal. string -> string *)
let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter (fun c -> Buffer.add_string buffer (escape_char c)) s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let parens prec min_prec text =
  if prec < min_prec then "(" ^ text ^ ")" else text

(** e as Java source text. jexpr -> string -> int -> string *)
let rec pprint_java_expr ?(min_prec = 0) e version =
  let at prec e = pprint_java_expr ~min_prec:prec e version in
  let plain e = pprint_java_expr e version in
  match e with
  | JInt (_, v) -> string_of_int v
  (* Java reads back every text Builtin.float_text writes but three, and
     only one of those can come from a literal: an exponent past the
     range overflows to an infinity. *)
  | JFloat (_, v) ->
      if v <> v then "Double.NaN"
      else if v = infinity then "Double.POSITIVE_INFINITY"
      else if v = neg_infinity then "Double.NEGATIVE_INFINITY"
      else Builtin.float_text v
  | JCast (_, jtype, operand) ->
      parens unary_precedence min_prec
        (Printf.sprintf "(%s) %s" (java_type jtype)
           (at (unary_precedence + 1) operand))
  | JFloatStr (_, operand) -> Printf.sprintf "pykFloatStr(%s)" (plain operand)
  (* `$` is in no Pyking name, so the parameters shadow nothing. *)
  | JLambda (_, name, jtype) ->
      let count = match jtype with Func (params, _) -> List.length params | _ -> 0 in
      let params = List.init count (fun i -> Printf.sprintf "p$%d" (i + 1)) in
      parens conditional_precedence min_prec
        (Printf.sprintf "(%s) -> %s(%s)" (String.concat ", " params) name
           (String.concat ", " params))
  | JStr (_, s) -> quote s
  | JBool (_, v) -> if v then "true" else "false"
  | JVar (_, name, _) -> name
  | JUnary (_, op, operand, _) ->
      parens unary_precedence min_prec
        (Printf.sprintf "%s%s" op (at (unary_precedence + 1) operand))
  | JBinary (_, op, left, right, _) ->
      let prec = precedence op in
      parens prec min_prec
        (Printf.sprintf "%s %s %s" (at prec left) op (at (prec + 1) right))
  | JCond (_, cond, then_expr, else_expr, _) ->
      parens conditional_precedence min_prec
        (Printf.sprintf "%s ? %s : %s"
           (at (conditional_precedence + 1) cond)
           (at conditional_precedence then_expr)
           (at conditional_precedence else_expr))
  | JCall (_, name, args, _) ->
      Printf.sprintf "%s(%s)" name (String.concat ", " (List.map plain args))
  | JEquals (_, left, right) ->
      parens call_precedence min_prec
        (Printf.sprintf "%s.equals(%s)" (at call_precedence left) (plain right))

(** The keyword a local declaration uses for its type: `var` from java17
    on, else the type's Java spelling. jtype -> string -> string *)
let local_type jtype version =
  match jtype with
  (* A lambda has no type of its own for `var` to infer. *)
  | Func _ -> java_type jtype
  | _ -> if var_locals version then "var" else java_type jtype

(** s as Java source text, indented to level. jstmt -> string -> int
    -> string *)
let rec pprint_java_stmt ?(level = 1) s version =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  match s with
  | JDecl (_, jtype, name, init, is_final) ->
      Printf.sprintf "%s%s%s %s = %s;" pad
        (if is_final then "final " else "")
        (local_type jtype version) name
        (pprint_java_expr init version)
  | JAssign (_, name, e) ->
      Printf.sprintf "%s%s = %s;" pad name (pprint_java_expr e version)
  | JNoEffect (_, source) ->
      (* docs/target_java.md, "An expression statement that is not a
         call". *)
      Printf.sprintf "%s// %s;   (no effect: value discarded)" pad source
  | JExprStmt (_, e) -> Printf.sprintf "%s%s;" pad (pprint_java_expr e version)
  | JReturn (_, e) ->
      Printf.sprintf "%sreturn %s;" pad (pprint_java_expr e version)
  | JPrint (_, to_stderr, None) ->
      Printf.sprintf "%sSystem.%s.println();" pad
        (if to_stderr then "err" else "out")
  | JPrint (_, to_stderr, Some e) ->
      Printf.sprintf "%sSystem.%s.println(%s);" pad
        (if to_stderr then "err" else "out")
        (pprint_java_expr e version)
  | JIf (_, cond, then_body, else_body) ->
      let lines =
        [ Printf.sprintf "%sif (%s) {" pad (pprint_java_expr cond version);
          emit_block then_body version (level + 1) ]
      in
      let rec ladder lines else_body =
        match else_body with
        | Some [ JIf (_, elif_cond, elif_body, else_body2) ] ->
            ladder
              (lines
              @ [ Printf.sprintf "%s} else if (%s) {" pad
                    (pprint_java_expr elif_cond version);
                  emit_block elif_body version (level + 1) ])
              else_body2
        | None -> lines
        | Some else_body ->
            lines
            @ [ Printf.sprintf "%s} else {" pad;
                emit_block else_body version (level + 1) ]
      in
      String.concat "\n" (ladder lines else_body @ [ Printf.sprintf "%s}" pad ])
  | JLoop (_, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%swhile (true) {" pad;
          emit_block body version (level + 1);
          Printf.sprintf "%s}" pad;
        ]
  | JBreak _ -> Printf.sprintf "%sbreak;" pad
  | JContinue _ -> Printf.sprintf "%scontinue;" pad
  | JWhile (_, cond, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%swhile (%s) {" pad (pprint_java_expr cond version);
          emit_block body version (level + 1);
          Printf.sprintf "%s}" pad;
        ]

(** A block's statements, indented to level.
    [jstmt] -> string -> int -> string *)
and emit_block statements version level =
  String.concat "\n"
    (List.map (fun s -> pprint_java_stmt ~level s version) statements)

(** func as a static method, public where another class of the program
    calls it and private otherwise. jfunc -> string -> int -> string *)
let pprint_method func version level =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  let ret = java_type func.ret_type in
  let params =
    String.concat ", "
      (List.map
         (fun (jtype, name) -> Printf.sprintf "final %s %s" (java_type jtype) name)
         func.func_params)
  in
  let visibility = if func.func_public then "public" else "private" in
  String.concat "\n"
    [
      Printf.sprintf "%s%s static %s %s(%s) {" pad visibility ret func.func_name
        params;
      emit_block func.func_body version (level + 1);
      Printf.sprintf "%s}" pad;
    ]

(** The module's top level as a method: `main` for the program's own
    module, which starts every other module before its own body runs, and
    `init` for a module the program imports, which is what starts it.
    jprogram -> string -> int -> string *)
let pprint_main (program : jprogram) version level =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  let header =
    if program.main then "public static void main(String[] args)"
    else "public static void init()"
  in
  let lines = [ Printf.sprintf "%s%s {" pad header ] in
  let lines =
    if program.starts <> [] then
      (* Every module runs its own top level before the program's does,
         in the order they must: a module runs after everything it
         imports (docs/modules.md). *)
      lines
      @ [
          Printf.sprintf
            "%s    // Every module of the program, in the order they must run."
            pad;
        ]
      @ List.map (fun name -> Printf.sprintf "%s    %s.init();" pad name)
          program.starts
      @ [ "" ]
    else lines
  in
  String.concat "\n"
    (lines
    @ [ emit_block program.main_body version (level + 1); Printf.sprintf "%s}" pad ])

(* builtin.ml's rule, in Java. Locale.ROOT is not optional: the default
   locale writes `1,0e+00` wherever the decimal separator is a comma,
   and one .out file is compared against every target. Double.toString
   is not used either -- it was not the shortest round trip before
   JDK 19, and java8 is the floor here. *)
(* The conversions Java's own would get wrong (builtin.ml, "what a
   conversion reads"): Integer.parseInt and Double.parseDouble read
   strings Pyking does not, and throw where Pyking answers a default. *)
let conversion_helper name =
  String.concat "\n"
    (match name with
    | "pykIntOfString" ->
        [
          "    private static int pykIntOfString(String s) {";
          "        if (!s.matches(\"[+-]?[0-9]+\")) {";
          "            return 0;";
          "        }";
          "        try {";
          "            long n = Long.parseLong(s.startsWith(\"+\") ? s.substring(1) : s);";
          "            return n >= -2147483648L && n <= 2147483647L ? (int) n : 0;";
          "        } catch (NumberFormatException tooLong) {";
          "            return 0;";
          "        }";
          "    }";
        ]
    | "pykTruncate" ->
        [
          "    private static int pykTruncate(double x) {";
          "        if (Double.isNaN(x) || x <= -2147483649.0 || x >= 2147483648.0) {";
          "            return 0;";
          "        }";
          "        return (int) x;";
          "    }";
        ]
    | _ ->
        [
          "    private static double pykFloatOfString(String s) {";
          "        if (s.equals(\"inf\") || s.equals(\"+inf\")) {";
          "            return Double.POSITIVE_INFINITY;";
          "        }";
          "        if (s.equals(\"-inf\")) {";
          "            return Double.NEGATIVE_INFINITY;";
          "        }";
          "        if (!s.matches(\"[+-]?[0-9]+(\\\\.[0-9]+)?([eE][+-]?[0-9]+)?\")) {";
          "            return Double.NaN;";
          "        }";
          "        return Double.parseDouble(s);";
          "    }";
        ])

let float_helper =
  String.concat "\n"
    [
      "    private static String pykFloatStr(double x) {";
      "        if (Double.isNaN(x)) return \"nan\";";
      "        if (x == Double.POSITIVE_INFINITY) return \"inf\";";
      "        if (x == Double.NEGATIVE_INFINITY) return \"-inf\";";
      "        String sign = (x < 0.0 || (x == 0.0 && 1.0 / x < 0.0)) ? \"-\" : \"\";";
      (* java.lang written out: a Pyking module `math` is a class Math. *)
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
      "            String mantissa =";
      "                n == 1 ? digits : digits.charAt(0) + \".\" + digits.substring(1);";
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
      "        return out.append(digits, 0, decpt).append('.')";
      "            .append(digits.substring(decpt)).toString();";
      "    }";
    ]

(** The whole compilation unit: the class holding every function as a
    private static method, and main.
    jprogram -> string -> string -> string -> string *)
let pprint_java_program (program : jprogram) version class_name source =
  let release = release_of version in
  let parts =
    [ Printf.sprintf "// Generated from %s by the Pyking compiler. Do not edit." source ]
  in
  let parts =
    parts
    @
    if program.main then
      [
        Printf.sprintf
          "// Target: %s. Compile with:  javac --release %s %s.java" version
          release class_name;
        Printf.sprintf "//         then run with:            java %s" class_name;
      ]
    else
      [
        Printf.sprintf
          "// Target: %s. The module '%s' of the program; compile it with the \
           others."
          version program.program_name;
      ]
  in
  let parts = parts @ [ ""; Printf.sprintf "public final class %s {" class_name ] in
  let parts =
    parts
    @
    if program.uses_float then
      [
        "";
        "    // A Float written the way Pyking writes one, which is not the \
         way";
        "    // Java writes a double.";
        float_helper;
      ]
    else []
  in
  let parts =
    parts @ List.concat_map (fun name -> [ ""; conversion_helper name ]) program.conversions
  in
  let parts =
    parts
    @
    if program.globals <> [] then
      [
        "";
        "    // What this module exports as a value; `init` below is what \
         fills each of them in.";
      ]
      @ List.map
          (fun g ->
            Printf.sprintf "    public static %s %s;" (java_type g.global_jtype)
              g.global_name)
          program.globals
    else []
  in
  let parts =
    parts
    @
    if program.statics <> [] then
      [
        "";
        "    // What the top level binds, where every method can read it; the";
        Printf.sprintf "    // top level in `%s` below is what fills each of them in."
          (if program.main then "main" else "init");
      ]
      @ List.map
          (fun (jtype, name) ->
            Printf.sprintf "    private static %s %s;" (java_type jtype) name)
          program.statics
    else []
  in
  let parts =
    parts
    @ List.concat_map (fun func -> [ ""; pprint_method func version 1 ]) program.functions
  in
  String.concat "\n" (parts @ [ ""; pprint_main program version 1 ] @ [ "}"; "" ])
