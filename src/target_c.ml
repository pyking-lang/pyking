(** The C code-generation backend, serving both the c89 and c23 targets
    -- one translation; the standard is a printer parameter for where
    the two differ (comments, declaration placement, booleans). C is
    statically typed and this backend infers no polymorphism, so it
    works out a type (Int, String, or Bool) for every binding, parameter
    and function; where inference is not enough it refuses with a source
    position. C also leaves the order of an operator's operands and a
    call's arguments unspecified, so operands that can print are pinned
    down with temporaries. See
    docs/target_c.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      ctype -- the three kinds of value this subset can hold, plus unit.
      cexpr / cstmt -- the C AST; every cexpr also carries its ctype.
      cprogram -- a translated module.
      scope -- Pyking name -> (C name, ctype).
      state -- what the whole-program walk accumulates.

    Functions:
      translate_program stmts context -- translates a whole module.
      pprint_c_program program standard source -- the translation unit.
      pprint_c_header program standard source -- the header a module the
        program imports is included through. *)

open Lexer
open Syntax

(* What a module the program imports declares itself in, beside its own
   translation unit. *)
let header_extension = ".h"

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of info * string

module SMap = Map.Make (String)

(* What each unsupported construct is called in an error message, so a
   message names what the programmer wrote rather than the node the
   parser built for it. *)
let construct_names =
  [
    ("EList", "list literals");
    ("ETuple", "tuples");
    ("EListComp", "list comprehensions");
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

   The three kinds of value a Pyking program in this subset can hold.
   They are kept as their own names rather than as C spellings because
   the C spelling of a boolean is one of the things the standards
   disagree about. *)

type ctype = Int | Float | Bool | String | Unit

(** What a module implemented in C exports, as this translation unit has
    to declare it: a function with its parameter and return types, or a
    file-scope value. *)
type cextern =
  | CExternFunc of string * ctype list * ctype
  | CExternValue of string * ctype

let ctype_name t =
  match t with
  | Int -> "Int"
  | Float -> "Float"
  | Bool -> "Bool"
  | String -> "String"
  | Unit -> "Unit"

let c_type_text standard t =
  match (standard, t) with
  | _, Int -> "int"
  | _, Float -> "double"
  (* C89 has no boolean type; C99 gained `bool` through <stdbool.h>,
     which `headers` adds, and C23 made it a keyword. *)
  | "c89", Bool -> "int"
  | _, Bool -> "bool"
  | _, String -> "const char *"
  | _, Unit -> "void"

(* printf conversion per type (docs/target_c.md, "Booleans"): a Bool
   argument becomes a conditional expression, since neither standard's
   spelling prints directly with %d/%s. *)
let format_of t =
  match t with
  | Int -> "%d"
  (* A double is written by pyk_float_str rather than by a conversion:
     no printf format spells a Float the way Pyking does. *)
  | Float -> "%s"
  | Bool -> "%s"
  | String -> "%s"
  | Unit -> "%s"

(** The type an annotation names, or None for one C cannot represent
    (docs/target_c.md, "How types are inferred"). typ option -> ctype
    option *)
let annotated_type annotation =
  match annotation with
  | Some (TInt _) -> Some Int
  | Some (TFloat _) -> Some Float
  | Some (TString _) -> Some String
  | Some (TBool _) -> Some Bool
  | _ -> None

(** Whether a written type names a type variable anywhere inside it.
    typ -> bool *)
let rec mentions_type_variable annotation =
  match annotation with
  | TVar _ | TForall _ -> true
  | TList (_, element, _) -> mentions_type_variable element
  | TTuple (_, elements, _) -> List.exists mentions_type_variable elements
  | TFunction (_, params, result, _, _, _) ->
      List.exists mentions_type_variable params || mentions_type_variable result
  | _ -> false

(** Refuses a def whose annotations name a type variable. C infers one
    concrete type per function, so a type the caller chooses has nothing
    here to become -- and guessing `Int` would compile a call at any
    other type into code that is quietly wrong. stmt -> () *)
let reject_type_variables node =
  match node with
  | SFunctionDef (_, _, params, _, return_type, _, _) ->
      List.iter
        (fun annotation ->
          match annotation with
          | Some annotation when mentions_type_variable annotation ->
              unsupported (type_info annotation)
                "a type variable -- C needs one concrete type per function, \
                 and this backend infers no polymorphism"
          | _ -> ())
        (List.map (fun (Param (_, _, t, _)) -> t) params @ [ return_type ])
  | _ -> ()

(* --- C AST ---

   Every expression node carries its type: the printer needs it to
   choose a `printf` conversion, and the translator needs it to declare
   variables and to tell string `+` (concatenation) from integer
   `+`. *)

type cexpr =
  | CInt of info * int
  | CFloat of info * float
  | CStr of info * string
  | CBool of info * bool
  | CVar of info * string * ctype
  | CUnary of info * string * cexpr * ctype (* op operand *)
  | CBinary of info * string * cexpr * cexpr * ctype (* left op right *)
  | CCall of info * string * cexpr list * ctype (* name(args...) *)
  | CCond of info * cexpr * cexpr * cexpr * ctype (* cond ? a : b *)
  | CConcat of info * cexpr * cexpr (* pyk_concat(left, right) *)
  | CStrEq of info * cexpr * cexpr (* strcmp(left, right) == 0 *)
  | CSeq of info * (string * cexpr) list * cexpr * ctype
      (* (name = value, ..., result): the steps computed in the order
         they are written, then result, which is what the whole
         expression is worth. See docs/target_c.md, "Evaluation
         order". *)
  | CCast of info * ctype * cexpr (* (type)operand *)
  | CFloatStr of info * cexpr (* pyk_float_str(operand) *)

type cstmt =
  | CDecl of info * ctype * string * cexpr (* <type> name = init; *)
  | CVarDecl of info * ctype * string (* <type> name; *)
  | CAssign of info * string * cexpr (* name = expr; *)
  | CExprStmt of info * cexpr (* expr; *)
  | CPrint of info * cexpr list (* printf("...", ...); *)
  | CIf of info * cexpr * cstmt list * cstmt list option
  | CWhile of info * cexpr * cstmt list
  | CLoop of info * cstmt list (* while (1) { body } *)
  | CBreak of info
  | CContinue of info
  | CReturn of info * cexpr

(** <ret> name(params) { body } -- `public` says the module's header
    declares it; anything else is `static` where the program has more
    than one translation unit. *)
type cfunc = {
  func_info : info;
  func_name : string;
  func_params : (ctype * string) list;
  func_body : cstmt list;
  ret_type : ctype;
  func_public : bool;
}

(** A public value: file scope here, extern in the header, assigned by
    <module>_init from the local name it worked it out in. *)
type cglobal = {
  global_info : info;
  global_ctype : ctype;
  global_name : string;
  global_from : string;
}

(** A translated module. *)
type cprogram = {
  functions : cfunc list;
  main_body : cstmt list;
  uses_print : bool;
  uses_concat : bool;
  uses_strcmp : bool;
  uses_float : bool;
  uses_infinity : bool;
  program_name : string;
  main : bool;
  separate : bool;
  includes : string list;
  (* An external module is implemented in C rather than compiled from
     Pyking, so there is no generated header to include: its exports are
     declared here instead, from the signatures it wrote. *)
  external_decls : cextern list;
  starts : string list;
  globals : cglobal list;
}

(** The type a C expression carries. cexpr -> ctype *)
let ctype_of e =
  match e with
  | CInt _ -> Int
  | CFloat _ -> Float
  | CStr _ -> String
  | CBool _ -> Bool
  | CVar (_, _, t) -> t
  | CUnary (_, _, _, t) -> t
  | CBinary (_, _, _, _, t) -> t
  | CCall (_, _, _, t) -> t
  | CCond (_, _, _, _, t) -> t
  | CConcat _ -> String
  | CStrEq _ -> Bool
  | CSeq (_, _, _, t) -> t
  | CCast (_, t, _) -> t
  | CFloatStr _ -> String

(** The source position a C expression carries. cexpr -> info *)
let cexpr_info e =
  match e with
  | CInt (i, _) | CFloat (i, _) | CStr (i, _) | CBool (i, _) -> i
  | CCast (i, _, _) | CFloatStr (i, _) -> i
  | CVar (i, _, _) -> i
  | CUnary (i, _, _, _) -> i
  | CBinary (i, _, _, _, _) -> i
  | CCall (i, _, _, _) -> i
  | CCond (i, _, _, _, _) -> i
  | CConcat (i, _, _) -> i
  | CStrEq (i, _, _) -> i
  | CSeq (i, _, _, _) -> i

(* --- scope ---

   C blocks are lexical scopes, as Pyking's are. Rebinding gets a fresh
   C variable, since C cannot declare one name twice in a block and a
   rebinding may hold a different type. *)

(** The names in scope during translation: what is bound in the Pyking
    program but not reachable here (this backend's functions have no
    closures), each Pyking name's C name and type, the names the
    innermost block binds, and every C name already spoken for -- which
    `names` cannot say, since it holds only each Pyking name's *current*
    C name. *)
type scope = {
  outside : StringSet.t;
  names : (string * ctype) SMap.t;
  block : StringSet.t;
  taken : StringSet.t;
}

let empty_scope =
  {
    outside = StringSet.empty;
    names = SMap.empty;
    block = StringSet.empty;
    taken = StringSet.empty;
  }

(** The scope for a nested block: sees outside and names; drops block.
    scope -> scope *)
let block_scope scope = { scope with block = StringSet.empty }

(** scope with these C names spoken for, but meaning nothing: what a loop
    does with its accumulator, which is declared in this block and in
    scope only in the loop's own body. [string] -> scope -> scope *)
let reserve names scope =
  {
    scope with
    taken = List.fold_left (fun set name -> StringSet.add name set) scope.taken names;
  }

(** Binds a Pyking name to a C name chosen elsewhere: an imported name
    keeps the spelling the module that exports it gave it, and a public
    one is spelled so that two modules' `inc` are two names.
    string -> string -> ctype -> scope -> scope *)
let bind_exact name c_name ctype scope =
  {
    scope with
    names = SMap.add name (c_name, ctype) scope.names;
    block = StringSet.add name scope.block;
    taken = StringSet.add c_name scope.taken;
  }

(** Where a generated `<module>_init()` call points: the program's first
    statement, which is what it runs before. [stmt] -> info *)
let start_info stmts =
  match stmts with
  | first :: _ -> stmt_info first
  | [] -> { file = "<program>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** The key an imported name is registered under: what the source wrote
    to reach it. string -> string -> string *)
let reached alias field = Printf.sprintf "%s.%s" alias field

(** The C name a module's public `name` is compiled under. C has one
    namespace for the whole program, so the module's own name is part of
    it. string -> string -> string *)
let module_name module_ name = Printf.sprintf "%s_%s" module_ name

(* Legal Pyking identifiers that are reserved in C (both standards'
   keywords, plus main/printf/the generated helpers, so a shadowing def
   cannot break the file). See docs/target_c.md, "Names that are
   keywords in C". *)
let reserved =
  List.fold_left
    (fun set name -> StringSet.add name set)
    StringSet.empty
    (String.split_on_char ' '
       "auto break case char const continue default do double else enum \
        extern float for goto if inline int long register restrict return \
        short signed sizeof static struct switch typedef union unsigned void \
        volatile while alignas alignof bool constexpr false nullptr \
        static_assert thread_local true typeof _Alignas _Alignof _Atomic \
        _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert \
        _Thread_local main printf strcmp strlen malloc size_t pyk_concat")

(** The (C name, ctype) a Pyking name reads as; raises Unsupported for a
    name out of this function's reach or with no C representation.
    string -> scope -> info -> (string, ctype) *)
let lookup name scope info =
  match SMap.find_opt name scope.names with
  | Some found -> found
  | None ->
      if StringSet.mem name scope.outside then
        unsupported info
          (Printf.sprintf
             "'%s' is bound outside this function -- C has no closures: a \
              function here reads its parameters and calls other functions, \
              nothing else"
             name)
      else
        unsupported info
          (Printf.sprintf "'%s' is not a value this backend can compile" name)

(** name2, name3, ... -- the first not already used.
    string -> scope -> string *)
let fresh_c_name name scope =
  let taken =
    SMap.fold
      (fun key (c_name, _) set -> StringSet.add key (StringSet.add c_name set))
      scope.names scope.taken
  in
  let rec go n =
    let candidate = Printf.sprintf "%s%d" name n in
    if StringSet.mem candidate taken || StringSet.mem candidate reserved then
      go (n + 1)
    else candidate
  in
  go 2

(** Binds a Pyking name at ctype, answering (c_name, extended_scope).
    string -> ctype -> scope -> (string, scope) *)
let bind name ctype scope =
  let c_name =
    if
      StringSet.mem name reserved
      || SMap.mem name scope.names
      || SMap.exists (fun _ (c, _) -> c = name) scope.names
      || StringSet.mem name scope.taken
    then fresh_c_name name scope
    else name
  in
  (c_name, bind_exact name c_name ctype scope)

(** A prefix no name in the program starts with, for the temporaries that
    pin evaluation order down (docs/target_c.md, "Evaluation order").
    [stmt] -> string *)
let unused_prefix stmts =
  let names =
    Walk.fold_stmts
      (fun found node ->
        match Walk.name_field node with
        | Some name -> StringSet.add name found
        | None -> found)
      StringSet.empty stmts
  in
  let rec go prefix =
    if
      StringSet.exists
        (fun name ->
          String.length name >= String.length prefix
          && String.sub name 0 (String.length prefix) = prefix)
        names
    then go (prefix ^ "_")
    else prefix
  in
  go "tmp"

(** The C operator a Pyking binary node becomes, or None.
    expr -> string option *)
let binary_op e =
  match e with
  | EAdd _ -> Some "+"
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

(** One `loop` being translated: one C variable and its type per
    accumulator slot. *)
type cloop = { slots : (string * ctype) list }

(** What the whole-program walk accumulates across functions:
    signatures, which have been defined, and which runtime helpers are
    used. *)
type state = {
  context : Module.context;
  (* Pyking name -> (C name, param ctypes, return ctype) *)
  signatures : (string * (string * ctype list * ctype)) list;
  declared : (string * string) list;
  defined : StringSet.t;
  called_early : StringSet.t;
  uses_print : bool;
  uses_concat : bool;
  uses_strcmp : bool;
  uses_float : bool;
  uses_infinity : bool;
  (* The enclosing `loop`s, innermost last. *)
  loops : cloop list;
  temporaries : int;
  printing : Analyses.effects;
  prefix : string;
  (* The evaluation-order temporaries the function being translated
     needs, as ctype, C name and where they came from. *)
  temps : (ctype * string * info) list;
}

(** An association list with `key` set to `value`, replacing an existing
    entry in place. string -> 'a -> [(string, 'a)] -> [(string, 'a)] *)
let rec set_assoc key value = function
  | [] -> [ (key, value) ]
  | (k, _) :: rest when k = key -> (key, value) :: rest
  | pair :: rest -> pair :: set_assoc key value rest

(** A number no temporary has used yet. state -> (int, state) *)
let temporary state =
  let state = { state with temporaries = state.temporaries + 1 } in
  (state.temporaries, state)

(** A fresh evaluation-order temporary, declared at the top of the
    function being translated.
    ctype -> info -> state -> (string, state) *)
let fresh_temp ctype info state =
  let number, state = temporary state in
  let name = Printf.sprintf "%s%d" state.prefix number in
  (name, { state with temps = state.temps @ [ (ctype, name, info) ] })

(** The temporaries allocated since from_index, as declarations, and
    forgotten. int -> state -> ([cstmt], state) *)
let declarations from_index state =
  let allocated = List.filteri (fun i _ -> i >= from_index) state.temps in
  let kept = List.filteri (fun i _ -> i < from_index) state.temps in
  ( List.map (fun (ctype, name, info) -> CVarDecl (info, ctype, name)) allocated,
    { state with temps = kept } )

(** result, with `in_order`'s assignments computed first -- the comma
    operator, which is where C does fix the order.
    [(string, cexpr)] -> cexpr -> cexpr *)
let sequenced steps result =
  if steps = [] then result
  else CSeq (cexpr_info result, steps, result, ctype_of result)

(** Raises Unsupported if node's ctype is not ctype.
    cexpr -> ctype -> string -> () *)
let require node ctype what =
  if ctype_of node <> ctype then
    unsupported (cexpr_info node)
      (Printf.sprintf "%s needs %s operands here, not %s" what
         (ctype_name ctype)
         (ctype_name (ctype_of node)))

(** Raises Unsupported if node is neither an Int nor a Float, which is
    what every arithmetic operator takes. cexpr -> string -> () *)
let require_numeric node what =
  if ctype_of node <> Int && ctype_of node <> Float then
    unsupported (cexpr_info node)
      (Printf.sprintf "%s needs Int or Float operands here, not %s" what
         (ctype_name (ctype_of node)))

(** One name per accumulator slot, or None if the target is nested
    deeper than C can take apart. assign_target -> [string] option *)
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
    elements for several. Refuses anything else, since C has no tuple to
    take apart at run time. expr option -> int -> stmt -> [expr] *)
let slot_values e slots node =
  match e with
  | Some e when slots = 1 -> [ e ]
  | Some (ETuple (_, elements, _)) when List.length elements = slots -> elements
  | _ ->
      unsupported (stmt_info node)
        (Printf.sprintf
           "this loop carries %d values, so every turn has to give %d of them \
            one by one -- C has no tuple to take apart here"
           slots slots)

(** Refuses a loop whose value C has no room for: one worth `()`, which
    is what a loop carrying no accumulator is, or one carrying several
    slots, whose value is the tuple of them. stmt -> 'a *)
let breakable node =
  match node with
  | SLoop (_, None, _, _, _, _, _) ->
      unsupported (stmt_info node)
        "a loop worth `()` -- a loop with no accumulator is worth unit, and C \
         has no value for one; carry the value the loop is for, or run the \
         loop for what it does rather than what it is worth"
  | _ ->
      unsupported (stmt_info node)
        "a loop that carries several values and is worth all of them -- C has \
         no tuple to hold that; carry the one value the loop is for"

(** Whether body contains a `break` belonging to the loop it is the body
    of -- one inside a nested loop belongs to that one instead.
    [cstmt] -> bool *)
let rec breaks_out body =
  List.exists
    (fun s ->
      match s with
      | CBreak _ -> true
      | CIf (_, _, then_body, else_body) ->
          breaks_out then_body
          || breaks_out (Option.value else_body ~default:[])
      | _ -> false)
    body

(** Whether control can reach the end of body without returning --
    undefined behaviour for a non-void C function. [cstmt] -> bool *)
let rec falls_through body =
  match List.rev body with
  | [] -> true
  | last :: _ -> (
      match last with
      | CReturn _ -> false
      | CIf (_, _, then_body, Some else_body) ->
          falls_through then_body || falls_through else_body
      (* `while (1)` ends only by breaking out of it; with no `break` for
         this loop, nothing after it runs. *)
      | CLoop (_, loop_body) -> breaks_out loop_body
      | _ -> true)

(** Every ctype returned anywhere in body, without repeats.
    [cstmt] -> [ctype] *)
let return_types body =
  let rec go stmts found =
    List.fold_left
      (fun found s ->
        match s with
        | CReturn (_, e) ->
            let t = ctype_of e in
            if List.mem t found then found else found @ [ t ]
        | CIf (_, _, then_body, else_body) ->
            go (Option.value else_body ~default:[]) (go then_body found)
        | CWhile (_, _, inner) | CLoop (_, inner) -> go inner found
        | _ -> found)
      found stmts
  in
  go body []

(** Whether body calls the C function named c_name.
    [cstmt] -> string -> bool *)
let calls body c_name =
  let rec in_expr e =
    match e with
    | CCall (_, name, args, _) -> name = c_name || List.exists in_expr args
    | CUnary (_, _, operand, _) -> in_expr operand
    | CBinary (_, _, left, right, _) | CConcat (_, left, right)
    | CStrEq (_, left, right) ->
        in_expr left || in_expr right
    | CCond (_, cond, then_expr, else_expr, _) ->
        in_expr cond || in_expr then_expr || in_expr else_expr
    | CSeq (_, steps, result, _) ->
        List.exists (fun (_, value) -> in_expr value) steps || in_expr result
    | _ -> false
  in
  let rec in_stmt s =
    match s with
    | CDecl (_, _, _, e) | CAssign (_, _, e) | CExprStmt (_, e) | CReturn (_, e)
      ->
        in_expr e
    | CVarDecl _ | CBreak _ | CContinue _ -> false
    | CPrint (_, args) -> List.exists in_expr args
    | CIf (_, cond, then_body, else_body) ->
        in_expr cond
        || List.exists in_stmt then_body
        || List.exists in_stmt (Option.value else_body ~default:[])
    | CWhile (_, cond, inner) -> in_expr cond || List.exists in_stmt inner
    | CLoop (_, inner) -> List.exists in_stmt inner
  in
  List.exists in_stmt body

(** Whether name is added to, or compared with, a string literal
    anywhere in these statements. string -> [stmt] -> bool *)
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

(** A parameter's type: its annotation when C can represent it, else what
    the body's use of it suggests, else Int (docs/target_c.md, "How types
    are inferred"). stmt -> param -> ctype *)
let param_type func (Param (_, name, annotation, _)) =
  match annotated_type annotation with
  | Some t -> t
  | None ->
      let body = match func with
        | SFunctionDef (_, _, _, body, _, _, _) -> body
        | _ -> []
      in
      if used_as_string name body then String
      else if used_as_float name body then Float
      else Int

(** What a module's own top level is called once it is a function: every
    module of a C program is started by name, in the order the program's
    own module starts them. string -> string *)
let init_name name = module_name name "init"

(* --- translation --- *)

(** Whether name here means a def itself rather than a value.
    state -> string -> scope -> bool *)
let is_function_value state name scope =
  match List.assoc_opt name state.signatures with
  | None -> false
  | Some (c_name, _, _) -> (
      match SMap.find_opt name scope.names with
      | None -> true
      | Some (bound, _) -> bound = c_name)

(** Translates one expression. `allow_unit` permits a call to a void
    function, meaningful only as an expression statement.
    state -> expr -> scope -> bool -> (cexpr, state) *)
let rec expr state e scope allow_unit =
  match e with
  | EInt (info, v, _) -> (CInt (info, v), state)
  | EFloat (info, v, _) ->
      (* A literal is finite unless the source wrote an exponent past
         what a double holds, which overflows to an infinity. *)
      let infinite = v = infinity || v = neg_infinity in
      ( CFloat (info, v),
        {
          state with
          uses_float = true;
          uses_infinity = state.uses_infinity || infinite;
        } )
  | EString (info, s, _) -> (CStr (info, s), state)
  | EBool (info, v, _) -> (CBool (info, v), state)
  | EVar (info, name, _) when is_function_value state name scope ->
      (* A def's own name used as a value (docs/target_c.md, "A function
         used as a value"). *)
      unsupported info
        (Printf.sprintf
           "`%s` is a function used as a value -- C has no function values \
            here: a `def` becomes a C function, and only a call can name one"
           name)
  | EVar (info, name, _) ->
      let c_name, ctype = lookup name scope info in
      (CVar (info, c_name, ctype), state)
  | ENeg (info, operand, _) ->
      let inner, state = expr state operand scope false in
      require_numeric inner "negation";
      (CUnary (info, "-", inner, ctype_of inner), state)
  | EDiv (info, l, r, _) ->
      (* C99 onward truncates an int quotient toward zero, which is
         Pyking's own rule, and a double quotient is IEEE's, which is
         Pyking's other one. Either way this is the host's `/`. *)
      let pieces, steps, state = in_order state [ l; r ] scope in
      let left, right = (List.nth pieces 0, List.nth pieces 1) in
      require_numeric left "`/`";
      require right (ctype_of left) "`/`";
      (sequenced steps (CBinary (info, "/", left, right, ctype_of left)), state)
  | EAdd (info, l, r, _) ->
      let pieces, steps, state = in_order state [ l; r ] scope in
      let left, right = (List.nth pieces 0, List.nth pieces 1) in
      require_numeric left "`+`";
      require right (ctype_of left) "`+`";
      (sequenced steps (CBinary (info, "+", left, right, ctype_of left)), state)
  | EConcat (info, l, r, _) ->
      let pieces, steps, state = in_order state [ l; r ] scope in
      let left, right = (List.nth pieces 0, List.nth pieces 1) in
      require left String "`++`";
      require right String "`++`";
      ( sequenced steps (CConcat (info, left, right)),
        { state with uses_concat = true } )
  | EEq (info, l, r, _) ->
      let pieces, steps, state = in_order state [ l; r ] scope in
      let left, right = (List.nth pieces 0, List.nth pieces 1) in
      if ctype_of left = String && ctype_of right = String then
        ( sequenced steps (CStrEq (info, left, right)),
          { state with uses_strcmp = true } )
      else if ctype_of left <> ctype_of right then
        unsupported (expr_info e) "`==` between values of different types"
      else (sequenced steps (CBinary (info, "==", left, right, Bool)), state)
  | EIf (info, cond, then_expr, else_expr, _) ->
      let c, state = expr state cond scope false in
      let t, state = expr state then_expr scope false in
      let f, state = expr state else_expr scope false in
      if ctype_of t <> ctype_of f then
        unsupported (expr_info e)
          "the branches of an `if` expression must have the same type in C";
      (CCond (info, c, t, f, ctype_of t), state)
  | ECall (_, EVar (_, name, _), _, _) when Builtin.crosses_host name ->
      unsupported (expr_info e)
        (Printf.sprintf "`%s` may only be used as a statement, not as a value"
           name)
  | EQualified (info, alias, field, _) ->
      (* A public name of another module: `declare_imports` bound it
         under the C name that module gives it. *)
      let c_name, ctype = lookup (reached alias field) scope info in
      (CVar (info, c_name, ctype), state)
  (* C's own conversions: widening an int is exact within the range a
     double holds, and narrowing a double truncates toward zero, which
     is the rounding Pyking's `int` and `/` both do. *)
  | ECall (info, EVar (_, "float", _), [ argument ], _)
    when not (List.mem_assoc "float" state.signatures) ->
      let inner, state = expr state argument scope false in
      require inner Int "`float`";
      (CCast (info, Float, inner), { state with uses_float = true })
  | ECall (info, EVar (_, "int", _), [ argument ], _)
    when not (List.mem_assoc "int" state.signatures) ->
      let inner, state = expr state argument scope false in
      require inner Float "`int`";
      (CCast (info, Int, inner), state)
  | ECall (info, EQualified (_, alias, field, _), args, _) ->
      call state e (reached alias field) args scope allow_unit info
  | ECall (info, EVar (_, name, _), args, _) ->
      call state e name args scope allow_unit info
  | ECall _ -> unsupported (expr_info e) "calling anything but a named function"
  | e -> (
      match (binary_op e, Interpreter.binary_operands e) with
      | Some op, Some (l, r) ->
          let pieces, steps, state = in_order state [ l; r ] scope in
          let left, right = (List.nth pieces 0, List.nth pieces 1) in
          require_numeric left (Printf.sprintf "`%s`" op);
          require right (ctype_of left) (Printf.sprintf "`%s`" op);
          let ctype =
            if List.mem op [ "+"; "-"; "*" ] then ctype_of left else Bool
          in
          ( sequenced steps (CBinary (expr_info e, op, left, right, ctype)),
            state )
      | _ -> unsupported (expr_info e) (expr_kind_name e))

(** Translates a call to a named function -- one written here, or one
    another module exports. `name` is the key its signature is registered
    under. state -> expr -> string -> [expr] -> scope -> bool -> info
    -> (cexpr, state) *)
and call state e name args scope allow_unit info =
  match List.assoc_opt name state.signatures with
  | None ->
      unsupported (expr_info e)
        (Printf.sprintf "call to unknown function `%s`" name)
  | Some (c_name, param_types, ret) ->
      let state =
        if StringSet.mem name state.defined then state
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
      let ordered, steps, state = in_order state args scope in
      (* C converts between an int and a double without a word, so an
         argument at the wrong type would compile and be quietly wrong.
         This backend infers each function's parameter types from its
         own body, so a mismatch is a type it could not work out rather
         than a program error -- it is refused here, with the position
         of the call. *)
      List.iteri
        (fun index argument ->
          let wanted = List.nth param_types index in
          if ctype_of argument <> wanted then
            unsupported (cexpr_info argument)
              (Printf.sprintf
                 "argument %d of `%s` is %s where this backend worked out %s"
                 (index + 1) name
                 (ctype_name (ctype_of argument))
                 (ctype_name wanted)))
        ordered;
      (sequenced steps (CCall (info, c_name, ordered, ret)), state)

(** The expressions translated, plus the assignments that pin their
    evaluation order down where two or more of them can print
    (docs/target_c.md, "Evaluation order").
    state -> [expr] -> scope -> ([cexpr], [(string, cexpr)], state) *)
and in_order state exprs scope =
  let translated, state =
    List.fold_left
      (fun (out, state) e ->
        let c, state = expr state e scope false in
        (out @ [ c ], state))
      ([], state) exprs
  in
  let effectful =
    List.concat
      (List.mapi
         (fun index e ->
           if Analyses.may_print state.printing e then [ index ] else [])
         exprs)
  in
  if List.length effectful < 2 then (translated, [], state)
  else
    (* The last one may stay where it is: nothing after it can be pulled
       ahead of something that no longer has anything to say. *)
    let earlier =
      List.filteri (fun i _ -> i < List.length effectful - 1) effectful
    in
    let steps, replacements, state =
      List.fold_left
        (fun (steps, replacements, state) index ->
          let value = List.nth translated index in
          let name, state =
            fresh_temp (ctype_of value) (cexpr_info value) state
          in
          (steps @ [ (name, value) ], replacements @ [ (index, name) ], state))
        ([], [], state) earlier
    in
    let translated =
      List.mapi
        (fun index t ->
          match List.assoc_opt index replacements with
          | Some name -> CVar (cexpr_info t, name, ctype_of t)
          | None -> t)
        translated
    in
    (translated, steps, state)

(** Translates a statement sequence, threading the scope through it.
    state -> [stmt] -> scope -> ([cstmt], scope, state) *)
and stmts state statements scope =
  List.fold_left
    (fun (out, scope, state) s ->
      let translated, scope, state = stmt state s scope in
      (out @ translated, scope, state))
    ([], scope, state) statements

(** Translates a statement list whose last statement is in tail position
    (PYKING.md, "Tail position").
    state -> [stmt] -> scope -> ([cstmt], state) *)
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

(** The last statement of a body in tail position, as a list of C
    statements. state -> stmt -> scope -> ([cstmt], state) *)
and tail_stmt state s scope =
  match s with
  | SExprStmt (_, ECall (_, EVar (_, name, _), _, _), _)
    when Builtin.crosses_host name ->
      let translated, _, state = stmt state s scope in
      (translated, state)
  | SExprStmt (info, e, _) ->
      let value, state = expr state e scope false in
      ([ CReturn (info, value) ], state)
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
      ([ CIf (info, condition, then_branch, else_branch) ], state)
  | SMatch _ ->
      let built, _, state =
        match_chain state s scope (fun state body inner ->
            let translated, state = tail_stmts state body inner in
            (translated, state))
      in
      (built, state)
  | SLoop (info, _, _, _, _, _, _) -> (
      (* A function ending in a loop returns what the loop produced: the
         accumulator it stopped with. A loop nothing breaks out of never
         gets there, so there is nothing to ask for its value. *)
      let c_stmts, value, _, state = loop state s scope in
      let last_body =
        match List.rev c_stmts with
        | CLoop (_, body) :: _ -> body
        | CWhile (_, _, body) :: _ -> body
        | _ -> []
      in
      if not (breaks_out last_body) then (c_stmts, state)
      else
        match value with
        | None -> breakable s
        | Some value -> (c_stmts @ [ CReturn (info, value) ], state))
  | s ->
      let translated, _, state = stmt state s scope in
      (translated, state)

(** Translates a loop into `while (1)` over one mutable variable per
    accumulator slot (docs/target_c.md, "loop"): the initializer declares
    them and every tail of the body assigns the next turn's values, so
    they hold what the loop is worth however it stops -- a `break` is C's
    own, and leaves this turn's values where they are. Answers the
    statements, the expression holding the loop's value afterwards, and
    the scope: the accumulators are in scope only in the loop's own body,
    but their declarations stand in the block around it, so those C names
    stay spoken for there.
    state -> stmt -> scope -> ([cstmt], cexpr option, scope, state) *)
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
      (* `loop:` or `while c:` on its own: no accumulator, so nothing to
         carry and nothing to be worth but unit. Run for what it does. *)
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
                let c, state = expr state e scope false in
                (out @ [ c ], state))
              ([], state)
              (slot_values init (List.length names) s)
          in
          (* One variable per slot, declared where the loop is
             written. *)
          let slots, body_scope =
            List.fold_left2
              (fun (slots, body_scope) name value ->
                let c_name, body_scope = bind name (ctype_of value) body_scope in
                (slots @ [ (c_name, ctype_of value) ], body_scope))
              ([], block_scope scope) names values
          in
          let setup =
            List.map2
              (fun (c_name, _) value -> CDecl (info, ctype_of value, c_name, value))
              slots values
          in
          let inner_state = { state with loops = state.loops @ [ { slots } ] } in
          let body, inner_state = loop_block inner_state loop_body body_scope in
          let state = { inner_state with loops = state.loops } in
          let taken = List.map fst slots in
          let value =
            if List.length slots > 1 then
              (* The answer would be the tuple of its slots, which C has
                 no room for. Nothing may read the value; `tail_stmt` and
                 the binding case both check that before using it. *)
              None
            else
              let c_name, ctype = List.hd slots in
              Some (CVar (info, c_name, ctype))
          in
          (* `while c` becomes the loop's own test, built as the first
             thing the body does: the slots already hold what the loop is
             worth when it runs out, so there is nothing to put in place
             where it is left. *)
          let body, state =
            match iterate with
            | Some (WhileTest (_, condition, _)) ->
                let test, state = expr state condition body_scope false in
                require test Bool "a `while` condition";
                ( CIf (info, CUnary (info, "!", test, Bool), [ CBreak info ], None)
                  :: body,
                  state )
            | _ -> (body, state)
          in
          (setup @ [ CLoop (info, body) ], value, reserve taken scope, state))
  | _ -> ([], None, scope, state)

(** `loop:` or `while c:` with no accumulator: nothing to carry, and
    worth unit, which C has no value for.
    state -> stmt -> scope -> ([cstmt], cexpr option, scope, state) *)
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
          ([ CWhile (info, test, body) ], None, scope, state)
      | _ -> ([ CLoop (info, body) ], None, scope, state))
  | _ -> ([], None, scope, state)

(** The statements that give the innermost loop its next values. With
    more than one slot they go through temporaries, so a slot that reads
    another sees the turn it is still on.
    state -> expr -> scope -> stmt -> ([cstmt], state) *)
and accumulate state e scope node =
  let this = List.nth state.loops (List.length state.loops - 1) in
  let values, state =
    List.fold_left
      (fun (out, state) one ->
        let c, state = expr state one scope false in
        (out @ [ c ], state))
      ([], state)
      (slot_values (Some e) (List.length this.slots) node)
  in
  List.iter2
    (fun (c_name, ctype) value ->
      if ctype_of value <> ctype then
        unsupported (stmt_info node)
          (Printf.sprintf
             "this loop carries %s in `%s`, so it cannot go on with %s in C"
             (ctype_name ctype) c_name
             (ctype_name (ctype_of value))))
    this.slots values;
  if List.length this.slots = 1 then
    ([ CAssign (stmt_info node, fst (List.hd this.slots), List.hd values) ], state)
  else
    let turn, state = temporary state in
    let temporaries =
      List.map
        (fun (c_name, ctype) -> (Printf.sprintf "%s_next%d" c_name turn, ctype))
        this.slots
    in
    ( List.map2
        (fun (name, ctype) value -> CDecl (stmt_info node, ctype, name, value))
        temporaries values
      @ List.map2
          (fun (c_name, _) (name, ctype) ->
            CAssign (stmt_info node, c_name, CVar (stmt_info node, name, ctype)))
          this.slots temporaries,
      state )

(** Translates a loop body: whatever a path ends in is the next turn's
    value, so every tail becomes an assignment to the accumulator --
    except a `break`/`continue`, which has already said what happens
    next. state -> [stmt] -> scope -> ([cstmt], state) *)
and loop_block state statements scope =
  match statements with
  | [] -> ([], state)
  | statements ->
      let count = List.length statements in
      let front = List.filteri (fun i _ -> i < count - 1) statements in
      let body, scope, state = stmts state front scope in
      let tail, state =
        loop_tail state (List.nth statements (count - 1)) scope
      in
      (body @ tail, state)

(** The last statement of a loop body, or of one branch of one.
    state -> stmt -> scope -> ([cstmt], state) *)
and loop_tail state s scope =
  match s with
  | SExprStmt (_, e, _) -> accumulate state e scope s
  | SIf (info, cond, then_body, else_body, _) -> (
      let condition, state = expr state cond scope false in
      require condition Bool "an `if` condition";
      match else_body with
      | None ->
          unsupported (stmt_info s)
            "an `if` with no `else` as the last statement of a loop body -- \
             there would be a turn with no next value, and C has no unit to \
             give it"
      | Some else_body ->
          let then_branch, state =
            loop_block state then_body (block_scope scope)
          in
          let else_branch, state =
            loop_block state else_body (block_scope scope)
          in
          ([ CIf (info, condition, then_branch, Some else_branch) ], state))
  (* Each of these says by itself what happens next: two leave the loop,
     one leaves the whole function. *)
  | SBreak _ | SContinue _ | SReturn _ | SReturnStmt _ ->
      let translated, _, state = stmt state s scope in
      (translated, state)
  | s ->
      unsupported (stmt_info s)
        "a loop body ending in something with no value -- every turn has to \
         say what the next one carries"

(** Translates a nested block; its bindings do not escape.
    state -> [stmt] -> scope -> ([cstmt], state) *)
and block state statements scope =
  let translated, _, state = stmts state statements (block_scope scope) in
  (translated, state)

(** A `match` as an if/else chain over the subject, held in a name of its
    own so it is evaluated once. The subject is a scalar -- this backend
    has neither lists nor tuples -- so a pattern is a literal, a
    wildcard, or a name. A `match` that fits no arm does nothing, which
    an `if` chain with no final `else` already does.
    state -> stmt -> scope
    -> (state -> [stmt] -> scope -> ([cstmt], state))
    -> ([cstmt], scope, state) *)
and match_chain state s scope translate_body =
  match s with
  | SMatch (info, subject_expr, cases, _) ->
      let subject, state = expr state subject_expr scope false in
      let held, scope = bind "__subject" (ctype_of subject) scope in
      let here = CVar (info, held, ctype_of subject) in
      (* Built from the last arm backwards. An arm whose pattern always
         matches becomes the `else` rather than an `if (1)`, so a total
         `match` reads as one -- which is what lets `falls_through` see
         that every path returns. *)
      let chain, state =
        List.fold_left
          (fun (chain, state) (MatchCase (case_info, p, case_body, _)) ->
            let test, bindings, arm_scope, state =
              pattern_test state p here (block_scope scope)
            in
            let body, state = translate_body state case_body arm_scope in
            let body = bindings @ body in
            match test with
            | None -> (Some body, state)
            | Some test -> (Some [ CIf (case_info, test, body, chain) ], state))
          (None, state) (List.rev cases)
      in
      let opening = CDecl (info, ctype_of subject, held, subject) in
      ((opening :: Option.value chain ~default:[]), scope, state)
  | _ -> ([], scope, state)

(** (test, bindings, scope) for one pattern over a scalar subject. The
    test is None when the pattern always matches, and a capture becomes a
    declaration at the top of the arm.
    state -> pattern -> cexpr -> scope
    -> (cexpr option, [cstmt], scope, state) *)
and pattern_test state p subject scope =
  let info = pattern_info p in
  match p with
  | PWildcard _ -> (None, [], scope, state)
  | PCapture (_, name, _) ->
      let c_name, scope = bind name (ctype_of subject) scope in
      (None, [ CDecl (info, ctype_of subject, c_name, subject) ], scope, state)
  | PInt (_, value, _) ->
      require subject Int "an Int pattern";
      ( Some (CBinary (info, "==", subject, CInt (info, value), Bool)),
        [],
        scope,
        state )
  | PBool (_, value, _) ->
      require subject Bool "a Bool pattern";
      ( Some (CBinary (info, "==", subject, CBool (info, value), Bool)),
        [],
        scope,
        state )
  | PText _ ->
      unsupported info
        "a `++` pattern over a string -- taking the middle out means \
         allocating one, which this backend has no value model for"
  | PString (_, value, _) ->
      require subject String "a String pattern";
      ( Some (CStrEq (info, subject, CStr (info, value))),
        [],
        scope,
        { state with uses_strcmp = true } )
  | p -> unsupported (pattern_info p) "this pattern"

(** Translates one statement, answering it with the scope it leaves
    behind. state -> stmt -> scope -> ([cstmt], scope, state) *)
and stmt state s scope =
  match s with
  | SLet (info, TargetName (_, name, _), e, _, _, _) ->
      let value, state = expr state e scope false in
      let c_name, scope = bind name (ctype_of value) scope in
      ([ CDecl (info, ctype_of value, c_name, value) ], scope, state)
  | SLet _ -> unsupported (stmt_info s) "tuple destructuring targets"
  | SLetStmt (info, TargetName (_, name, _), (SLoop _ as inner), _, _, _) -> (
      (* `x = loop ...` -- the loop's value is the accumulator it stopped
         with, so the binding is one declaration after it. *)
      let c_stmts, value, scope, state = loop state inner scope in
      match value with
      | None -> breakable inner
      | Some value ->
          let c_name, scope = bind name (ctype_of value) scope in
          ( c_stmts @ [ CDecl (info, ctype_of value, c_name, value) ],
            scope,
            state ))
  | SMatch _ ->
      match_chain state s scope (fun state body inner ->
          let translated, _, state = stmts state body inner in
          (translated, state))
  | SVar (info, name, e, _) ->
      let value, state = expr state e scope false in
      let c_name, scope = bind name (ctype_of value) scope in
      ([ CDecl (info, ctype_of value, c_name, value) ], scope, state)
  | SMutate (info, name, e, _) ->
      let c_name, ctype = lookup name scope info in
      let value, state = expr state e scope false in
      if ctype_of value <> ctype then
        unsupported (stmt_info s)
          (Printf.sprintf "`:=` cannot change the type of `%s` from %s to %s in C"
             name (ctype_name ctype)
             (ctype_name (ctype_of value)));
      ([ CAssign (info, c_name, value) ], scope, state)
  | SReturn (info, e, _) ->
      let value, state = expr state e scope false in
      ([ CReturn (info, value) ], scope, state)
  | SReturnStmt (_, inner, _) ->
      (* A loop answers with several statements (the accumulator, the
         loop, the return). *)
      let translated, state = tail_stmt state inner scope in
      (translated, scope, state)
  | SExprStmt (info, ECall (_, EVar (_, name, _), args, _), _)
    when Builtin.crosses_host name ->
      (* `printf` is a call like any other, so its arguments are ordered
         the same way -- but this is a statement, and a statement can put
         them in front of itself rather than in a comma expression. *)
      let state = { state with uses_print = true } in
      let ordered, steps, state = in_order state args scope in
      let state =
        if List.exists (fun a -> ctype_of a = Float) ordered then
          { state with uses_float = true }
        else state
      in
      ( List.map (fun (temp, value) -> CAssign (info, temp, value)) steps
        @ [ CPrint (info, ordered) ],
        scope,
        state )
  | SExprStmt (info, e, _) ->
      let value, state = expr state e scope true in
      ([ CExprStmt (info, value) ], scope, state)
  | SLoop _ ->
      let c_stmts, _, scope, state = loop state s scope in
      (c_stmts, scope, state)
  | SBreak (info, _) ->
      (* C's own: the slots are left holding what this turn started with,
         which is what the loop is worth. *)
      ([ CBreak info ], scope, state)
  | SContinue (info, _) -> ([ CContinue info ], scope, state)
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
      ([ CIf (info, condition, then_branch, else_branch) ], scope, state)
  | SFunctionDef _ ->
      unsupported (stmt_info s)
        "a nested function -- C has no nested functions, and one reading its \
         enclosing scope could not be hoisted to file scope without closures"
  | s -> unsupported (stmt_info s) (stmt_kind_name s)

(** Binds everything this module's imports bring in, under the C name the
    module that exports it gives it -- `helper_inc` for `inc` out of
    `helper`, whether it is reached as `helper.inc` or under a name a
    `from` line gave it. A function goes in `signatures` as well, since
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
              let c_name = module_name module_ exported in
              match List.assoc_opt exported sigmap with
              | Some (TFunction (_, params, result, _, _, _)) ->
                  let param_types = List.map (fun p -> annotated_type (Some p)) params in
                  let result = Option.value (annotated_type (Some result)) ~default:Unit in
                  if List.for_all (fun p -> p <> None) param_types then
                    ( scope,
                      {
                        state with
                        signatures =
                          set_assoc key
                            (c_name, List.map Option.get param_types, result)
                            state.signatures;
                        declared = set_assoc key c_name state.declared;
                      } )
                  else (scope, state)
              | found -> (
                  match annotated_type found with
                  | Some ctype -> (bind_exact key c_name ctype scope, state)
                  | None -> (scope, state)))
            (scope, state) fields
      | _ -> (scope, state))
    (scope, state) stmts

(** The modules whose headers this one includes: the ones it imports, in
    source order and without repeats -- and, for the program's own
    module, every module of the program, since that is where each one's
    `<name>_init` is called from and C has to be told a function exists
    before a call names it. state -> [stmt] -> [string] *)
let includes state stmts =
  let names = if state.context.main then state.context.starts else [] in
  List.fold_left
    (fun names statement ->
      match statement with
      | SImport (_, name, _, _, _, _)
        when (not (List.mem name names))
             && not (List.mem name state.context.externals) ->
          names @ [ name ]
      | _ -> names)
    names stmts

(** The C a module implemented in C is reached through: one declaration
    per name it exports, taken from its signatures, so this translation
    unit is told they exist without a header to include. A type C cannot
    represent is refused here rather than emitted.
    state -> [stmt] -> [cextern] *)
let external_declarations state stmts =
  List.concat_map
    (fun statement ->
      match statement with
      | SImport (info, name, _, _, _, _)
        when List.mem name state.context.externals ->
          let signatures =
            try List.assoc name state.context.sigmaps with Not_found -> []
          in
          List.map
            (fun (field, type_) ->
              let qualified = name ^ "_" ^ field in
              let ctype_of t what =
                match t with
                | TTuple (_, [], _) -> Unit
                | t -> (
                    match annotated_type (Some t) with
                    | Some ctype -> ctype
                    | None ->
                        unsupported info
                          (Printf.sprintf
                             "the external module '%s' declares '%s' with %s \
                              this target has no C type for"
                             name field what))
              in
              match type_ with
              | TFunction (_, params, result, _, _, _) ->
                  CExternFunc
                    ( qualified,
                      List.map (fun t -> ctype_of t "a parameter") params,
                      ctype_of result "a return type" )
              | t -> CExternValue (qualified, ctype_of t "a type"))
            signatures
      | _ -> [])
    stmts

(** This module's public bindings as the file-scope variables another
    module reads them through -- nothing for the program's own module,
    which nothing imports. state -> [stmt] -> scope -> [cglobal] *)
let exported_values state stmts scope =
  if state.context.main then []
  else
    List.filter_map
      (fun statement ->
        match statement with
        | SLet (info, TargetName (_, name, _), _, _, _, true)
        | SLetStmt (info, TargetName (_, name, _), _, _, _, true) ->
            let held, ctype = lookup name scope info in
            Some
              {
                global_info = info;
                global_ctype = ctype;
                global_name = module_name state.context.context_name name;
                global_from = held;
              }
        | _ -> None)
      stmts

(** The C name a `def` is compiled under: its own, or the module's name
    and its own where another module can call it -- two modules may each
    define an `inc`, and C has one namespace.
    state -> stmt -> scope -> (string, scope) *)
let public_name state node scope =
  match node with
  | SFunctionDef (_, name, _, _, _, _, true) when not state.context.main ->
      let c_name = module_name state.context.context_name name in
      (c_name, bind_exact name c_name Int scope)
  | SFunctionDef (_, name, _, _, _, _, _) -> bind name Int scope
  | _ -> ("", scope)

(** Registers every top-level def's signature (return type provisional:
    its annotation, or Int) before any body is translated, enabling
    forward references and mutual recursion (docs/target_c.md, "Forward
    references and mutual recursion").
    state -> [stmt] -> scope -> (scope, state) *)
let declare_functions state stmts scope =
  List.fold_left
    (fun (scope, state) s ->
      match s with
      | SFunctionDef (_, name, params, _, return_type, _, _) ->
          reject_type_variables s;
          let c_name, scope = public_name state s scope in
          ( scope,
            {
              state with
              signatures =
                set_assoc name
                  ( c_name,
                    List.map (param_type s) params,
                    Option.value (annotated_type return_type) ~default:Int )
                  state.signatures;
              declared = set_assoc name c_name state.declared;
            } )
      | _ -> (scope, state))
    (scope, state) stmts

(** Translates a def; its signature is already registered
    (`declare_functions`). state -> stmt -> scope -> (cfunc, scope, state) *)
let function_of state func scope =
  match func with
  | SFunctionDef (info, name, params, func_body, return_type, _, public) ->
      let param_types = List.map (param_type func) params in
      let c_name, scope =
        match List.assoc_opt name state.declared with
        | Some c_name -> (c_name, scope)
        | None -> bind name Int scope
      in
      let provisional = Option.value (annotated_type return_type) ~default:Int in
      let state =
        {
          state with
          signatures =
            set_assoc name (c_name, param_types, provisional) state.signatures;
        }
      in
      (* A function body starts from nothing but its own parameters; no
         closures, so `outside` remembers what it cannot see
         (`lookup`). *)
      let body_scope =
        {
          empty_scope with
          outside =
            SMap.fold (fun key _ set -> StringSet.add key set) scope.names
              StringSet.empty;
        }
      in
      let c_params, body_scope =
        List.fold_left2
          (fun (out, body_scope) (Param (_, param_name, _, _)) ctype ->
            let c_param, body_scope = bind param_name ctype body_scope in
            (out @ [ (ctype, c_param) ], body_scope))
          ([], body_scope) params param_types
      in
      (* This function's evaluation-order temporaries are declared at the
         top of it, so that one written in a `while` condition stands
         outside the loop it is tested in. *)
      let outer_temps = List.length state.temps in
      let body, state = tail_stmts state func_body body_scope in
      let temporaries, state = declarations outer_temps state in
      let returned = return_types body in
      let recursive = calls body c_name in
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
          signatures = set_assoc name (c_name, param_types, actual) state.signatures;
        }
      in
      if StringSet.mem name state.called_early && actual <> provisional then
        unsupported info
          (Printf.sprintf
             "`%s` is called before it is defined and does not return %s; a \
              call written above a `def` is typed from the annotation, or Int \
              without one, so annotate the return type (`-> String`, `-> \
              Bool`)"
             name (ctype_name provisional));
      let state = { state with defined = StringSet.add name state.defined } in
      if actual <> Unit && falls_through body then
        unsupported info
          (Printf.sprintf
             "`%s` produces a value on some paths and none on others; C has \
              one return type per function, and falling off the end of a \
              non-`void` one is undefined behaviour, so give every path a \
              value (an `if` needs its `else`)"
             name);
      ( {
          func_info = info;
          func_name = c_name;
          func_params = c_params;
          func_body = temporaries @ body;
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

(** One module of a program as a cprogram. `context` says what is true of
    it only as part of a program -- its name, whether it is the program's
    own module, and what the modules it imports export.
    [stmt] -> Module.context -> cprogram *)
let translate_program stmts context =
  (* A module in two halves needs the generated file to call into the
     implementation beside it, which this backend does not emit yet: an
     external module it can compile is one with no Pyking half. Refused
     here rather than left to the host's own compiler, which would
     report an undeclared name in generated code. *)
  (match
     List.assoc_opt context.Module.context_name context.Module.external_fields
   with
  | Some (field :: _) ->
      unsupported
        (match stmts with
        | statement :: _ -> stmt_info statement
        | [] -> { file = ""; row1 = 1; col1 = 0; row2 = 1; col2 = 0 })
        (Printf.sprintf
           "a module in two halves: '%s' declares '%s' for the host and is \
            written in Pyking beside it, which this backend cannot compile \
            yet -- an external module it can compile has no Pyking half"
           context.Module.context_name field)
  | _ -> ());
  let state =
    {
      context;
      signatures = [];
      declared = [];
      defined = StringSet.empty;
      called_early = StringSet.empty;
      uses_print = false;
      uses_concat = false;
      uses_strcmp = false;
      uses_float = false;
      uses_infinity = false;
      loops = [];
      temporaries = 0;
      printing = Analyses.effects stmts;
      prefix = unused_prefix stmts;
      temps = [];
    }
  in
  let scope = empty_scope in
  let scope, state = declare_imports state stmts scope in
  let scope, state = declare_functions state stmts scope in
  (* What an external module offers is checked before anything is
     translated, so a type C cannot carry is refused where it was
     declared rather than at the first call that trips over it. *)
  let external_decls = external_declarations state stmts in
  let functions, main_body, scope, state =
    List.fold_left
      (fun (functions, main_body, scope, state) s ->
        match s with
        | SFunctionDef _ ->
            let func, scope, state = function_of state s scope in
            (functions @ [ func ], main_body, scope, state)
        (* Its names were bound by `declare_imports`, and what it brings
           in is another translation unit's; the `#include` naming that
           unit is the whole of what it leaves here. *)
        | SImport _ -> (functions, main_body, scope, state)
        | s ->
            let translated, scope, state = stmt state s scope in
            (functions, main_body @ translated, scope, state))
      ([], [], scope, state) stmts
  in
  (* A public value is a file-scope variable the header declares, and the
     module's own top level is where it gets its value: the binding is
     translated as any other, and `<module>_init` ends by handing what it
     worked out to the variable another module can see. *)
  let globals = exported_values state stmts scope in
  let main_body =
    main_body
    @ List.map
        (fun g ->
          CAssign
            ( g.global_info,
              g.global_name,
              CVar (g.global_info, g.global_from, g.global_ctype) ))
        globals
  in
  (* Every module runs its own top level before the program's does, in
     the order they must (docs/modules.md). They are statements of `main`
     rather than lines the printer adds, so that under c89 -- where a
     declaration may not follow a statement -- they land after the
     declarations `emit_block` hoists, which is where C says they
     belong. *)
  let starts =
    List.map
      (fun name ->
        CExprStmt
          ( start_info stmts,
            CCall (start_info stmts, init_name name, [], Unit) ))
      context.starts
  in
  let leftover, _ = declarations 0 state in
  {
    functions;
    main_body = leftover @ starts @ main_body;
    uses_print = state.uses_print;
    uses_concat = state.uses_concat;
    uses_strcmp = state.uses_strcmp;
    uses_float = state.uses_float;
    uses_infinity = state.uses_infinity;
    program_name = context.context_name;
    main = context.main;
    separate = context.separate;
    includes = includes state stmts;
    external_decls;
    starts = context.starts;
    globals;
  }

(* --- printer: C AST -> C source text --- *)

let precedence op =
  match op with
  | "*" | "/" -> 13
  | "+" | "-" -> 12
  | "<" | "<=" | ">" | ">=" -> 10
  | "==" -> 9
  | _ -> 0

let unary_precedence = 14
let conditional_precedence = 3
let assign_precedence = 2

let escape_char c =
  match c with
  | '\\' -> "\\\\"
  | '"' -> "\\\""
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(** s as a double-quoted C string literal. string -> string *)
let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter (fun c -> Buffer.add_string buffer (escape_char c)) s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(** text, parenthesized if prec is below min_prec.
    int -> int -> string -> string *)
let parens prec min_prec text =
  if prec < min_prec then "(" ^ text ^ ")" else text

(** value as this standard's Bool literal. bool -> string -> string *)
let bool_literal value standard =
  if standard = "c23" then if value then "true" else "false"
  else if value then "1"
  else "0"

(** e as C source text. cexpr -> string -> int -> string *)
let rec pprint_c_expr ?(min_prec = 0) e standard =
  let at prec e = pprint_c_expr ~min_prec:prec e standard in
  let plain e = pprint_c_expr e standard in
  match e with
  | CInt (_, v) -> string_of_int v
  (* C reads back every text Builtin.float_text writes but three, and
     only one of those can come from a literal: an exponent past the
     range overflows, which is HUGE_VAL here. *)
  | CFloat (_, v) ->
      if v = infinity then "HUGE_VAL"
      else if v = neg_infinity then "(-HUGE_VAL)"
      else Builtin.float_text v
  | CCast (_, ctype, operand) ->
      parens unary_precedence min_prec
        (Printf.sprintf "(%s)%s" (c_type_text standard ctype)
           (at (unary_precedence + 1) operand))
  | CFloatStr (_, operand) -> Printf.sprintf "pyk_float_str(%s)" (plain operand)
  | CStr (_, s) -> quote s
  | CBool (_, v) -> bool_literal v standard
  | CVar (_, name, _) -> name
  | CUnary (_, op, operand, _) ->
      parens unary_precedence min_prec
        (Printf.sprintf "%s%s" op (at (unary_precedence + 1) operand))
  | CBinary (_, op, left, right, _) ->
      let prec = precedence op in
      parens prec min_prec
        (Printf.sprintf "%s %s %s" (at prec left) op (at (prec + 1) right))
  | CCond (_, cond, then_expr, else_expr, _) ->
      parens conditional_precedence min_prec
        (Printf.sprintf "%s ? %s : %s"
           (at (conditional_precedence + 1) cond)
           (at conditional_precedence then_expr)
           (at conditional_precedence else_expr))
  | CCall (_, name, args, _) ->
      Printf.sprintf "%s(%s)" name (String.concat ", " (List.map plain args))
  | CConcat (_, left, right) ->
      Printf.sprintf "pyk_concat(%s, %s)" (plain left) (plain right)
  | CStrEq (_, left, right) ->
      parens (precedence "==") min_prec
        (Printf.sprintf "strcmp(%s, %s) == 0" (plain left) (plain right))
  | CSeq (_, steps, result, _) ->
      (* Always parenthesized: the comma operator binds looser than
         everything, and a bare comma in an argument list would separate
         arguments instead of sequencing them. *)
      Printf.sprintf "(%s, %s)"
        (String.concat ", "
           (List.map
              (fun (name, value) ->
                Printf.sprintf "%s = %s" name (at assign_precedence value))
              steps))
        (at assign_precedence result)

(** One printf argument; a Bool becomes a conditional expression
    (docs/target_c.md, "Booleans"). cexpr -> string -> string *)
let print_argument arg standard =
  if ctype_of arg = Bool then
    Printf.sprintf "%s ? \"true\" : \"false\""
      (pprint_c_expr ~min_prec:(conditional_precedence + 1) arg standard)
  else if ctype_of arg = Float then
    pprint_c_expr (CFloatStr (cexpr_info arg, arg)) standard
  else pprint_c_expr arg standard

(** A variable declaration, e.g. `int x` or `const char *s`.
    ctype -> string -> string -> string *)
let declaration ctype name standard =
  let text = c_type_text standard ctype in
  if String.length text > 0 && text.[String.length text - 1] = '*' then text ^ name
  else text ^ " " ^ name

(** s as C source text, indented to level. cstmt -> string -> int
    -> string *)
let rec pprint_c_stmt ?(level = 1) s standard =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  match s with
  (* Only reached for c23; c89 splits declarations out (`emit_block`). *)
  | CDecl (_, ctype, name, init) ->
      Printf.sprintf "%s%s = %s;" pad (declaration ctype name standard)
        (pprint_c_expr init standard)
  | CVarDecl (_, ctype, name) ->
      Printf.sprintf "%s%s;" pad (declaration ctype name standard)
  | CAssign (_, name, e) ->
      Printf.sprintf "%s%s = %s;" pad name (pprint_c_expr e standard)
  | CExprStmt (_, e) -> Printf.sprintf "%s%s;" pad (pprint_c_expr e standard)
  | CReturn (_, e) ->
      Printf.sprintf "%sreturn %s;" pad (pprint_c_expr e standard)
  | CPrint (_, args) ->
      Printf.sprintf "%sprintf(\"%s\\n\"%s);" pad
        (String.concat " " (List.map (fun a -> format_of (ctype_of a)) args))
        (String.concat ""
           (List.map (fun a -> ", " ^ print_argument a standard) args))
  | CIf (_, cond, then_body, else_body) ->
      let lines =
        [ Printf.sprintf "%sif (%s) {" pad (pprint_c_expr cond standard);
          emit_block then_body standard (level + 1) ]
      in
      let rec ladder lines else_body =
        match else_body with
        | Some [ CIf (_, elif_cond, elif_body, else_body2) ] ->
            ladder
              (lines
              @ [ Printf.sprintf "%s} else if (%s) {" pad
                    (pprint_c_expr elif_cond standard);
                  emit_block elif_body standard (level + 1) ])
              else_body2
        | None -> lines
        | Some else_body ->
            lines
            @ [ Printf.sprintf "%s} else {" pad;
                emit_block else_body standard (level + 1) ]
      in
      String.concat "\n" (ladder lines else_body @ [ Printf.sprintf "%s}" pad ])
  | CWhile (_, cond, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%swhile (%s) {" pad (pprint_c_expr cond standard);
          emit_block body standard (level + 1);
          Printf.sprintf "%s}" pad;
        ]
  | CLoop (_, body) ->
      (* `while (1)`, not `while (true)`: c89 has no `bool`, and this is
         the spelling both standards read the same way. *)
      String.concat "\n"
        [
          Printf.sprintf "%swhile (1) {" pad;
          emit_block body standard (level + 1);
          Printf.sprintf "%s}" pad;
        ]
  | CBreak _ -> Printf.sprintf "%sbreak;" pad
  | CContinue _ -> Printf.sprintf "%scontinue;" pad

(** A block's statements, indented to level; under c89, declarations are
    hoisted to the top (docs/target_c.md, "Declaration hoisting").
    [cstmt] -> string -> int -> string *)
and emit_block statements standard level =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  if standard <> "c89" then
    String.concat "\n"
      (List.map (fun s -> pprint_c_stmt ~level s standard) statements)
  else
    let declarations =
      List.filter_map
        (fun s ->
          match s with
          | CDecl (_, ctype, name, _) | CVarDecl (_, ctype, name) ->
              Some (Printf.sprintf "%s%s;" pad (declaration ctype name standard))
          | _ -> None)
        statements
    in
    let body =
      List.filter_map
        (fun s ->
          match s with
          | CVarDecl _ -> None
          | CDecl (_, _, name, init) ->
              Some
                (Printf.sprintf "%s%s = %s;" pad name
                   (pprint_c_expr init standard))
          | s -> Some (pprint_c_stmt ~level s standard))
        statements
    in
    if declarations <> [] then String.concat "\n" (declarations @ [ "" ] @ body)
    else String.concat "\n" body

(** text as a comment in this standard's own style.
    string -> string -> string *)
let comment text standard =
  if standard = "c89" then Printf.sprintf "/* %s */" text
  else Printf.sprintf "// %s" text

(* Written in the subset both standards accept, so one copy serves both
   (docs/target_c.md, "Strings"). *)
let concat_helper =
  String.concat "\n"
    [
      "static const char *pyk_concat(const char *a, const char *b)";
      "{";
      "    size_t la = strlen(a);";
      "    size_t lb = strlen(b);";
      "    char *result = malloc(la + lb + 1);";
      "    memcpy(result, a, la);";
      "    memcpy(result + la, b, lb + 1);";
      "    return result;";
      "}";
    ]

(* builtin.ml's rule, in the subset both standards accept, so one copy
   serves both. C89 has neither isnan nor isinf, so a NaN is found with
   `x != x` and an infinity against DBL_MAX. The result is malloc'd
   rather than written into one static buffer: a printf with two Floats
   in it calls this twice before printing either, and one buffer would
   hand back the same text twice. Like pyk_concat, it is never freed
   (docs/target_c.md, "Strings"). *)
let float_helper =
  String.concat "\n"
    [
      "static const char *pyk_float_str(double x)";
      "{";
      "    char buf[64];";
      "    char digits[32];";
      "    char *out = malloc(64);";
      "    double a;";
      "    int negative, p, at, i, n, decpt, k;";
      "    const char *e;";
      "    if (x != x) { strcpy(out, \"nan\"); return out; }";
      "    if (x > DBL_MAX) { strcpy(out, \"inf\"); return out; }";
      "    if (x < -DBL_MAX) { strcpy(out, \"-inf\"); return out; }";
      "    negative = x < 0.0 || (x == 0.0 && 1.0 / x < 0.0);";
      "    a = negative ? -x : x;";
      "    if (a == 0.0) { strcpy(out, negative ? \"-0.0\" : \"0.0\"); return out; }";
      "    for (p = 0; p < 16; p++) {";
      "        sprintf(buf, \"%.*e\", p, a);";
      "        if (strtod(buf, NULL) == a) break;";
      "    }";
      "    if (p == 16) sprintf(buf, \"%.*e\", 16, a);";
      "    e = strchr(buf, 'e');";
      "    at = (int)(e - buf);";
      "    n = 0;";
      "    for (i = 0; i < at; i++) if (buf[i] != '.') digits[n++] = buf[i];";
      "    while (n > 1 && digits[n - 1] == '0') n--;";
      "    digits[n] = '\\0';";
      "    decpt = atoi(e + 1) + 1;";
      "    k = 0;";
      "    if (negative) out[k++] = '-';";
      "    if (decpt <= -4 || decpt > 16) {";
      "        out[k++] = digits[0];";
      "        if (n > 1) { out[k++] = '.'; strcpy(out + k, digits + 1); k += n - 1; }";
      "        sprintf(out + k, \"e%d\", decpt - 1);";
      "        return out;";
      "    }";
      "    if (decpt <= 0) {";
      "        out[k++] = '0';";
      "        out[k++] = '.';";
      "        for (i = 0; i < -decpt; i++) out[k++] = '0';";
      "        strcpy(out + k, digits);";
      "        return out;";
      "    }";
      "    if (decpt >= n) {";
      "        strcpy(out + k, digits);";
      "        k += n;";
      "        for (i = 0; i < decpt - n; i++) out[k++] = '0';";
      "        strcpy(out + k, \".0\");";
      "        return out;";
      "    }";
      "    for (i = 0; i < decpt; i++) out[k++] = digits[i];";
      "    out[k++] = '.';";
      "    strcpy(out + k, digits + decpt);";
      "    return out;";
      "}";
    ]

(** Whether a statement declares a boolean anywhere inside it -- what
    decides, under C99, whether <stdbool.h> is needed.
    cstmt -> bool *)
let rec stmt_declares_bool statement =
  match statement with
  | CDecl (_, ctype, _, _) | CVarDecl (_, ctype, _) -> ctype = Bool
  | CIf (_, _, then_body, else_body) ->
      List.exists stmt_declares_bool then_body
      || (match else_body with
         | Some body -> List.exists stmt_declares_bool body
         | None -> false)
  | CWhile (_, _, body) | CLoop (_, body) -> List.exists stmt_declares_bool body
  | CAssign _ | CExprStmt _ | CPrint _ | CBreak _ | CContinue _ | CReturn _ ->
      false

(** Whether this translation unit writes `bool` anywhere -- in what it
    defines, in what it declares for an external module, or in a local.
    cprogram -> bool *)
let declares_bool (program : cprogram) =
  List.exists (fun g -> g.global_ctype = Bool) program.globals
  || List.exists
       (fun e ->
         match e with
         | CExternFunc (_, params, result) -> result = Bool || List.mem Bool params
         | CExternValue (_, ctype) -> ctype = Bool)
       program.external_decls
  || List.exists
       (fun f ->
         f.ret_type = Bool
         || List.exists (fun (t, _) -> t = Bool) f.func_params
         || List.exists stmt_declares_bool f.func_body)
       program.functions
  || List.exists stmt_declares_bool program.main_body

(** The #include lines the program actually needs.
    cprogram -> string -> [string] *)
let headers (program : cprogram) standard =
  (* C99 spells a boolean `bool`, but only through <stdbool.h>; C89 has
     no boolean type at all and writes `int`, and C23 made `bool` a
     keyword needing no header. So the include is C99's alone, and only
     where a boolean is actually declared. *)
  let needed =
    if standard = "c99" && declares_bool program then [ "stdbool.h" ] else []
  in
  let needed = needed @ if program.uses_print then [ "stdio.h" ] else [] in
  let needed =
    needed @ if program.uses_concat || program.uses_float then [ "stdlib.h" ] else []
  in
  let needed =
    needed
    @
    if program.uses_concat || program.uses_strcmp || program.uses_float then
      [ "string.h" ]
    else []
  in
  (* DBL_MAX, which is how the helper finds an infinity without C99's
     isinf. <float.h> declares no functions, so nothing a program of its
     own defines can collide with it. *)
  let needed = needed @ if program.uses_float then [ "float.h" ] else [] in
  (* HUGE_VAL, which is the only thing <math.h> is here for -- and it is
     kept out otherwise because that header declares a great many
     functions with short names (glibc's `fadd` among them) that a
     Pyking `def` is free to be called. *)
  let needed = needed @ if program.uses_infinity then [ "math.h" ] else [] in
  let unique =
    List.fold_left
      (fun found h -> if List.mem h found then found else found @ [ h ])
      [] needed
  in
  List.map (Printf.sprintf "#include <%s>") unique

(** One function's declarator: what both its prototype and its definition
    open with. cfunc -> string -> string *)
let signature func standard =
  let params =
    match func.func_params with
    | [] -> "void"
    | params ->
        String.concat ", "
          (List.map (fun (ctype, name) -> declaration ctype name standard) params)
  in
  Printf.sprintf "%s(%s)" (declaration func.ret_type func.func_name standard) params

(** `static ` where nothing outside this file may call a function. A
    program of one translation unit says nothing, keeping the output of a
    one-module program what it has always been.
    cfunc -> cprogram -> string *)
let visibility func (program : cprogram) =
  if func.func_public || not program.separate then "" else "static "

(** The macro an include guard is written with. string -> string *)
let guard_of name = Printf.sprintf "PYK_%s_H" (String.uppercase_ascii name)

(** The header a module the program imports is included through: what it
    exports, and the function that runs its top level.
    cprogram -> string -> string -> string *)
let pprint_c_header (program : cprogram) standard source =
  let guard = guard_of program.program_name in
  let parts =
    [
      comment
        (Printf.sprintf "Generated from %s by the Pyking compiler. Do not edit."
           source)
        standard;
      comment
        (Printf.sprintf "What the module '%s' exports." program.program_name)
        standard;
      "";
      Printf.sprintf "#ifndef %s" guard;
      Printf.sprintf "#define %s" guard;
    ]
  in
  (* A header naming a boolean carries its own include: whoever includes
     it may have no reason to have included <stdbool.h> already. *)
  let parts =
    if standard = "c99" && declares_bool program then
      parts @ [ ""; "#include <stdbool.h>" ]
    else parts
  in
  let exported =
    List.map
      (fun g ->
        Printf.sprintf "extern %s;"
          (declaration g.global_ctype g.global_name standard))
      program.globals
  in
  let parts = parts @ if exported = [] then [] else "" :: exported in
  let prototypes =
    List.filter_map
      (fun func ->
        if func.func_public then Some (signature func standard ^ ";") else None)
      program.functions
  in
  let parts = parts @ if prototypes = [] then [] else "" :: prototypes in
  String.concat "\n"
    (parts
    @ [
        "";
        comment
          "Runs the module's own top level; the program calls it once, before \
           any module that imports this one."
          standard;
        Printf.sprintf "void %s(void);" (init_name program.program_name);
        "";
        Printf.sprintf "#endif  %s" (comment guard standard);
        "";
      ])

(** The whole translation unit: headers, the string helper if used, the
    functions, and main -- or, for a module the program imports, the
    function that runs its top level.
    cprogram -> string -> string -> string *)
let pprint_c_program (program : cprogram) standard source =
  let parts =
    [
      comment
        (Printf.sprintf "Generated from %s by the Pyking compiler. Do not edit."
           source)
        standard;
      comment
        (if program.main && not program.separate then
           Printf.sprintf "Target: %s. Compile with:  cc -std=%s <this file>"
             standard standard
         else
           Printf.sprintf
             "Target: %s. One translation unit of the program; compile it with \
              the others."
             standard)
        standard;
    ]
  in
  let found = headers program standard in
  let parts = parts @ if found = [] then [] else "" :: found in
  let included = List.map (Printf.sprintf "#include \"%s.h\"") program.includes in
  let included =
    if program.main then included
    else
      (* A module includes its own header, so the compiler checks the
         definitions here against what the header promises. *)
      Printf.sprintf "#include \"%s.h\"" program.program_name :: included
  in
  let parts = parts @ if included = [] then [] else "" :: included in
  (* A module implemented in C has no generated header, so what it
     exports is declared here (docs/modules.md, "External modules"). *)
  let declared =
    List.map
      (fun ext ->
        match ext with
        | CExternFunc (name, params, result) ->
            let params =
              match params with
              | [] -> "void"
              | params ->
                  String.concat ", "
                    (List.map (fun t -> c_type_text standard t) params)
            in
            Printf.sprintf "%s(%s);" (declaration result name standard) params
        | CExternValue (name, ctype) ->
            Printf.sprintf "extern %s;" (declaration ctype name standard))
      program.external_decls
  in
  let parts =
    parts
    @
    if declared = [] then []
    else
      ""
      :: comment "What the external modules this one imports implement."
           standard
      :: declared
  in
  let parts =
    parts
    @
    if program.uses_concat then
      [
        "";
        comment
          "Concatenation allocates and never frees: Pyking has no ownership to \
           compile into a free."
          standard;
        concat_helper;
      ]
    else []
  in
  let parts =
    parts
    @
    if program.uses_float && program.uses_print then
      [
        "";
        comment
          "A Float is written by this rather than by a printf conversion: no \
           host spells a double the way Pyking does. It allocates and never \
           frees, as concatenation does."
          standard;
        float_helper;
      ]
    else []
  in
  let parts =
    parts
    @
    if program.globals <> [] then
      [
        "";
        comment
          "What this module exports as a value; its own top level below is \
           what fills each of them in."
          standard;
      ]
      @ List.map
          (fun g ->
            Printf.sprintf "%s;" (declaration g.global_ctype g.global_name standard))
          program.globals
    else []
  in
  let parts =
    parts
    @
    if program.functions <> [] then
      (* Prototypes for all of them, ahead of every definition. Pyking
         lets a function be used before it is written -- recursion,
         mutual recursion, a helper at the bottom of the file -- and C
         has to be told a function exists before a call can name it.
         Emitting one for every function rather than only the ones that
         need it keeps this independent of the order the definitions
         happen to be in, which is what the language says does not
         matter. *)
      [
        "";
        comment
          "Declared ahead of their definitions: a Pyking function may be \
           called before it is written."
          standard;
      ]
      @ List.map
          (fun func ->
            Printf.sprintf "%s%s;" (visibility func program) (signature func standard))
          program.functions
    else []
  in
  let parts =
    parts
    @ List.concat_map
        (fun func ->
          [
            "";
            visibility func program ^ signature func standard;
            "{";
            emit_block func.func_body standard 1;
            "}";
          ])
        program.functions
  in
  if not program.main then
    (* A module the program imports has no `main`: its top level is a
       function of its own, which the program calls before it uses
       anything the module exports. *)
    String.concat "\n"
      (parts
      @ [
          "";
          Printf.sprintf "void %s(void)" (init_name program.program_name);
          "{";
          emit_block program.main_body standard 1;
          "}";
          "";
        ])
  else
    String.concat "\n"
      (parts
      @ [ ""; "int main(void)"; "{" ]
      @ [ emit_block program.main_body standard 1 ]
      @ [ ""; "    return 0;"; "}"; "" ])
