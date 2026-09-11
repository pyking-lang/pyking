(** The JavaScript code-generation core: a JS AST, a translation from
    syntax.ml, and a printer. Knows nothing about packaging (node
    script, ES module, or HTML page): that is target_js_packaging.ml's
    job. See docs/target_js.md
    for how each construct compiles and where the output is not
    optimal.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      jsexpr / jsstmt / jstarget -- the JavaScript AST; see the comment
        on each variant for its shape.
      jshost -- everything the packager decides and the core only names.
      scope -- Pyking name -> JavaScript name, threaded through
        translation.

    Functions:
      translate_program stmts taken -- translates a whole module.
      translate_expr e scope -- translates one expression.
      translate_stmt s scope -- translates one statement.
      pprint_js_program stmts runtime -- the AST as JavaScript source
        text; runtime is the jshost the packager supplies.
      js_helpers stmts -- the generated program's own runtime helpers. *)

open Lexer
open Syntax

(** Raised for a Pyking construct this backend cannot compile yet;
    carries the source position, like the front end's errors do for
    their stages. *)
exception Unsupported of info * string

module SMap = Map.Make (String)

(* --- JavaScript AST ---

   One constructor per statement form, as in syntax.ml, but a single
   node for binary and unary operators carrying the JS operator as a
   string. The Python backend mirrors Pyking's one-node-per-operator
   shape because it translates each node to a matching one; here the
   operators are already a table (the printer needs one anyway, for
   precedence), and spelling out nine near-identical constructors would
   say nothing the table does not. *)

type jsexpr =
  | JsNum of info * int
  | JsStr of info * string
  | JsBool of info * bool
  | JsVar of info * string
  | JsUnary of info * string * jsexpr (* op operand *)
  | JsBinary of info * string * jsexpr * jsexpr (* left op right *)
  | JsCall of info * jsexpr * jsexpr list (* func(args...) *)
  | JsArray of info * jsexpr list (* [e1, e2, ...] -- a Pyking tuple *)
  | JsList of info * jsexpr list
      (* pykList([e1, e2, ...]) -- a Pyking list. A tuple is a plain
         array, so a list is an array with a marker: every array
         operation still works, and `pykFormat` can tell the two
         apart. *)
  | JsArrow of info * string list * jsstmt list * jsexpr
      (* (params) => { body; return result; } *)
  | JsPlain of info * jsexpr list
      (* [e1, e2, ...] with no marker -- a piece of a comprehension,
         which `flatMap` flattens away before the result is marked as a
         list. *)
  | JsConcat of info * jsexpr * jsexpr (* pykConcat(left, right) *)
  | JsSpread of info * jsexpr list (* [...a, ...b] *)
  | JsIndex of info * jsexpr * jsexpr (* target[index] *)
  | JsMember of info * jsexpr * string (* target.name *)
  | JsCond of info * jsexpr * jsexpr * jsexpr (* cond ? a : b *)
  | JsRuntimeCall of info * string * jsexpr list
      (* A call that crosses the runtime interface, e.g. `print`. The
         operation is named, not spelled: the packager decides whether
         it reads `print(...)` or `runtime.print(...)` in the emitted
         file. *)

and jstarget =
  | JsTargetName of info * string (* name *)
  | JsTargetArray of info * jstarget list (* [t1, t2, ...] *)

and jsstmt =
  | JsConst of info * jstarget * jsexpr (* const target = expr; *)
  | JsLet of info * jstarget * jsexpr (* let target = expr; *)
  | JsAssign of info * jstarget * jsexpr (* target = expr; *)
  | JsExprStmt of info * jsexpr (* expr; *)
  | JsIf of info * jsexpr * jsstmt list * jsstmt list option
  | JsForOf of info * string * jsexpr * jsstmt list
  | JsWhile of info * jsexpr * jsstmt list
  | JsBreak of info
  | JsContinue of info
  | JsImport of info * string * string * bool * (string * string) list
      (* What an import brings in, named rather than spelled: the three
         packagings write it three ways -- `require`, an ES `import`, or
         a reference to the module already built above it on the page --
         so the line itself comes from the packager (`importing`),
         exactly as a JsRuntimeCall's spelling does. The fields mirror
         syntax.ml's SImport. *)
  | JsFunc of info * string * string list * jsstmt list
  | JsReturn of info * jsexpr

(** Everything the packager decides and the core only names: how each
    runtime operation is called, and how what crosses a module boundary
    is written. One value rather than two parameters, since it is
    threaded through every printer here. *)
type jshost = {
  operations : (string * string) list;
  importing : (jsstmt -> string) option;
}

(* --- scope ---

   Renames only where JavaScript's own const rules force it
   (redeclaration, the temporal dead zone); see docs/target_js.md,
   "Scope and renaming". *)

(** Pyking name -> the JavaScript name standing in for it, plus the
    names the current block binds (a rename is needed for those too, and
    only the block itself can tell), plus every JavaScript name already
    spoken for here. The last of those is what `names` cannot say: it
    maps each Pyking name to its *current* JavaScript name, so a name
    rebound three times would otherwise offer the second one's spelling
    back to the fourth binding -- and JavaScript refuses a `const`
    declared twice. *)
type scope = {
  names : string SMap.t;
  block : StringSet.t;
  taken : StringSet.t;
  (* Which of each module's names the target's own source provides, and
     which modules have no Pyking half at all. A qualified name reaches
     the implementation where the field is one of the first, and a
     module in the second has no generated file to import. *)
  external_fields : (string * string list) list;
  externals : string list;
  (* This module's own name, and the names it declared rather than
     defined -- the host's half of it. *)
  own_module : string;
  own_external : string list;
  (* What each name a module was imported under actually names, so that
     a qualified name can be asked which half provides it. *)
  module_aliases : (string * string) list;
}

(** A scope for a nested block: it sees the enclosing names, and what it
    binds is dropped when the caller carries on with its own scope.
    scope -> scope *)
let block_scope scope = { scope with block = StringSet.empty }

(** The JavaScript name a Pyking name reads as. Names bound nowhere are
    runtime operations or builtins, and pass through unchanged.
    string -> scope -> string *)
let lookup name scope =
  match SMap.find_opt name scope.names with Some found -> found | None -> name

(* Legal Pyking identifiers that are reserved words in JavaScript (see
   docs/target_js.md, "Names that are keywords in JavaScript").

   `Array` and `document` are there with `console` and `String`: globals
   the prelude itself calls (`Array.isArray`,
   `document.getElementById`), so a Pyking binding of one shadows it out
   from under the helper rather than breaking the program's own syntax
   -- a `TypeError` at run time, which is harder to see than a parse
   error.

   The second group is the generated program's *own* runtime: the
   helpers this module calls by name (`pykList`, `pykConcat`) and the
   ones each packaging writes around it. A binding of one of those names
   would be a second `const` of it in the same scope, which is a
   SyntaxError rather than a shadow -- so they are spoken for here
   exactly as JavaScript's own words are. *)
let reserved =
  List.fold_left
    (fun set name -> StringSet.add name set)
    StringSet.empty
    (String.split_on_char ' '
       "await break case catch class const continue debugger default \
        delete do else enum export extends false finally for function if \
        implements import in instanceof interface let new null package \
        private protected public return static super switch this throw \
        true try typeof var void while with yield arguments eval \
        undefined NaN Infinity console String Array document print \
        pykConcat pykFormat pykList pykOutput pykQuote pykWrite require \
        exports run runtime init")

(** `name2`, `name3`, ... -- the first not already spoken for here.
    string -> scope -> string *)
let fresh_js_name name scope =
  let taken =
    SMap.fold
      (fun key value set -> StringSet.add key (StringSet.add value set))
      scope.names scope.taken
  in
  let rec go n =
    let candidate = Printf.sprintf "%s%d" name n in
    if StringSet.mem candidate taken || StringSet.mem candidate reserved then
      go (n + 1)
    else candidate
  in
  go 2

(** Binds a Pyking name, answering (js_name, extended_scope).
    string -> scope -> (string, scope) *)
let bind name scope =
  let js_name =
    if
      StringSet.mem name reserved
      || SMap.mem name scope.names
      || SMap.exists (fun _ value -> value = name) scope.names
      || StringSet.mem name scope.taken
    then fresh_js_name name scope
    else name
  in
  ( js_name,
    {
      scope with
      names = SMap.add name js_name scope.names;
      block = StringSet.add name scope.block;
      taken = StringSet.add js_name scope.taken;
    } )

(** scope with these JavaScript names spoken for, but meaning nothing:
    what a loop does with its accumulator, which is declared in this
    block and in scope only in the loop's own body.
    [string] -> scope -> scope *)
let reserve names scope =
  {
    scope with
    taken = List.fold_left (fun set name -> StringSet.add name set) scope.taken names;
  }

(* What each unsupported construct is called in an error message.
   Nothing here is load-bearing -- an entry missing just falls back to
   the node's own name -- but a message naming what the programmer wrote
   beats one naming the node the parser built for it. *)
let construct_names =
  [
    ("EList", "list literals");
    ("EListComp", "list comprehensions");
    ("SMatch", "`match` statements");
    ("SLetStmt", "value-form `if`/`match` bindings");
  ]

(** Raises Unsupported naming what (a construct or a node's own name) at
    info. `what` is the plural noun the sentence is built around -- a
    caller with more to say than a name uses `unsupported_because`
    instead, so that the two are not glued into one ungrammatical
    sentence. info -> string -> 'a *)
let unsupported info what =
  let name =
    match List.assoc_opt what construct_names with Some name -> name | None -> what
  in
  raise
    (Unsupported
       ( info,
         Printf.sprintf "%s are not supported by the JavaScript backends yet"
           name ))

(** Raises Unsupported with a whole message of its own, for a refusal
    that has a reason worth giving. info -> string -> 'a *)
let unsupported_because info message = raise (Unsupported (info, message))

(* --- translation: Pyking AST (syntax.ml) -> JavaScript AST --- *)

(** The JavaScript operator a Pyking binary node becomes, or None.
    expr -> string option *)
let binary_op e =
  match e with
  | EAdd _ -> Some "+"
  (* JavaScript's `+` concatenates strings. It does not concatenate
     arrays, but `EConcat` has a case of its own before this. *)
  | EConcat _ -> Some "+"
  | ESub _ -> Some "-"
  | EMul _ -> Some "*"
  | ELessThan _ -> Some "<"
  | ELessThanEq _ -> Some "<="
  | EGreatThan _ -> Some ">"
  | EGreatThanEq _ -> Some ">="
  (* `===`, not `==`: Pyking compares integers, strings and booleans,
     and JavaScript's loose equality would relate values across those
     types. *)
  | EEq _ -> Some "==="
  | _ -> None

(** The name of the statement node kind, for a refusal that has nothing
    better to say. stmt -> string *)
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
  | _ -> "Expr"

(** Translates one expression. Raises Unsupported for a construct
    outside this backend's subset. expr -> scope -> jsexpr *)
let rec translate_expr e scope =
  match e with
  | EInt (info, v, _) -> JsNum (info, v)
  | EString (info, s, _) -> JsStr (info, s)
  | EBool (info, v, _) -> JsBool (info, v)
  | EVar (info, name, _) ->
      (* A name this module *declared* rather than defined is the host's,
         and lives in the implementation beside this file -- the two
         halves are one module, so it is written unqualified here and
         reached through `<module>_external` in the output. *)
      if List.mem name scope.own_external then
        JsMember (info, JsVar (info, scope.own_module ^ "_external"), name)
      else JsVar (info, lookup name scope)
  | ENeg (info, operand, _) -> JsUnary (info, "-", translate_expr operand scope)
  | EIf (info, cond, then_expr, else_expr, _) ->
      (* Pyking's `if c then a else b` is JavaScript's conditional
         expression, in the same operand order. *)
      JsCond
        ( info,
          translate_expr cond scope,
          translate_expr then_expr scope,
          translate_expr else_expr scope )
  | EConcat (info, left, right, _) ->
      (* JavaScript's `+` joins strings but not arrays, and a Pyking list
         is an array. This backend infers no types, so which of the two
         `++` means is decided at run time by `pykConcat` -- the same
         answer `pykFormat` gives for printing. *)
      JsConcat (info, translate_expr left scope, translate_expr right scope)
  | EDiv (info, l, r, _) ->
      (* JavaScript's `/` is float division, so the quotient is truncated
         toward zero -- Pyking's rule, and what `Math.trunc` does for
         either sign. *)
      JsCall
        ( info,
          JsMember (info, JsVar (info, "Math"), "trunc"),
          [ JsBinary (info, "/", translate_expr l scope, translate_expr r scope) ]
        )
  | EList (info, elements, _) ->
      JsList (info, List.map (fun el -> translate_expr el scope) elements)
  | EListComp (info, element, clauses, _) ->
      (* The chain's pieces are plain arrays that `flatMap` folds
         together; the finished list is what carries the marker. *)
      JsCall
        ( info,
          JsVar (info, "pykList"),
          [ translate_comprehension info element clauses scope ] )
  | ETuple (info, elements, _) ->
      (* A tuple is a JavaScript array: it is built, taken apart and
         printed as one (docs/target_js.md, "Tuples"). *)
      JsArray (info, List.map (fun el -> translate_expr el scope) elements)
  | EQualified (info, module_name, name, _) ->
      (* `m.f` is a property of the object the module was brought in as,
         whichever way the packager brought it in -- and a module is up
         to two objects, since a name the target's own source provides
         lives in the implementation. *)
      let alias = lookup module_name scope in
      let real =
        Option.value
          (List.assoc_opt module_name scope.module_aliases)
          ~default:module_name
      in
      let reached =
        if Module.reached_module scope.external_fields real name <> real then
          alias ^ "_external"
        else alias
      in
      JsMember (info, JsVar (info, reached), name)
  | ECall (info, EVar (_, name, _), args, _)
    when Builtin.crosses_host name ->
      (* A call that leaves the program: see builtin.ml. *)
      JsRuntimeCall (info, name, List.map (fun a -> translate_expr a scope) args)
  | ECall (info, EVar (_, name, _), _, _)
    when List.mem name Builtin.pure_names && lookup name scope = name ->
      ignore info;
      unsupported_because (expr_info e)
        (Printf.sprintf
           "the builtin `%s` is not supported by the JavaScript backends yet"
           name)
  | ECall (info, func, args, _) ->
      JsCall
        ( info,
          translate_expr func scope,
          List.map (fun a -> translate_expr a scope) args )
  | e -> (
      match (binary_op e, Interpreter.binary_operands e) with
      | Some op, Some (left, right) ->
          JsBinary (expr_info e, op, translate_expr left scope, translate_expr right scope)
      | _ -> unsupported (expr_info e) (expr_kind_name e))

(** `[e for p in seq if c ...]` as a chain of `flatMap`s: each `for`
    maps its sequence and flattens, each `if` and each pattern that does
    not match contributes nothing.
    info -> expr -> [comp_clause] -> scope -> jsexpr *)
and translate_comprehension info element clauses scope =
  match clauses with
  | [] -> JsPlain (info, [ translate_expr element scope ])
  | CompFor (clause_info, pattern, sequence, _) :: rest ->
      let item, inner_scope = bind "__item" (block_scope scope) in
      let test, bindings, inner_scope =
        pattern_test pattern (JsVar (clause_info, item)) inner_scope
      in
      let body = translate_comprehension info element rest inner_scope in
      let guarded =
        match test with
        | None -> body
        | Some test -> JsCond (clause_info, test, body, JsPlain (clause_info, []))
      in
      JsCall
        ( clause_info,
          JsMember (clause_info, translate_expr sequence scope, "flatMap"),
          [ JsArrow (clause_info, [ item ], bindings, guarded) ] )
  | CompIf (clause_info, condition, _) :: rest ->
      JsCond
        ( clause_info,
          translate_expr condition scope,
          translate_comprehension info element rest scope,
          JsPlain (clause_info, []) )

(* --- patterns ---

   A pattern becomes a test and some bindings over an expression that
   already holds the value. The checker has settled the types, so
   nothing here checks one: a tuple's length is fixed by its type, and
   only a list's has to be looked at. *)

(** (test, bindings, scope) for matching `pattern` against `subject`.
    `test` is None when the pattern always matches.
    pattern -> jsexpr -> scope -> (jsexpr option, [jsstmt], scope) *)
and pattern_test pattern subject scope =
  let info = pattern_info pattern in
  match pattern with
  | PWildcard _ -> (None, [], scope)
  | PCapture (_, name, _) ->
      let js_name, scope = bind name scope in
      (None, [ JsConst (info, JsTargetName (info, js_name), subject) ], scope)
  | PInt (_, value, _) ->
      (Some (JsBinary (info, "===", subject, JsNum (info, value))), [], scope)
  | PString (_, value, _) ->
      (Some (JsBinary (info, "===", subject, JsStr (info, value))), [], scope)
  | PBool (_, value, _) ->
      (Some (JsBinary (info, "===", subject, JsBool (info, value))), [], scope)
  | PTuple (_, elements, _) ->
      pattern_parts elements
        (List.mapi (fun i _ -> JsIndex (info, subject, JsNum (info, i))) elements)
        None scope
  | PText (_, prefix, name, suffix, _) ->
      (* A string split around a fixed beginning and end. *)
      let length = JsMember (info, subject, "length") in
      let tests =
        (if prefix = "" then []
         else
           [
             JsCall
               ( info,
                 JsMember (info, subject, "startsWith"),
                 [ JsStr (info, prefix) ] );
           ])
        @ (if suffix = "" then []
           else
             [
               JsCall
                 ( info,
                   JsMember (info, subject, "endsWith"),
                   [ JsStr (info, suffix) ] );
             ])
        @
        if prefix <> "" && suffix <> "" then
          (* A prefix and a suffix that overlap would each match on their
             own; the length is what keeps them apart. *)
          [
            JsBinary
              ( info,
                ">=",
                length,
                JsNum (info, String.length prefix + String.length suffix) );
          ]
        else []
      in
      let test =
        List.fold_left
          (fun test one ->
            match test with
            | None -> Some one
            | Some test -> Some (JsBinary (info, "&&", test, one)))
          None tests
      in
      let bindings, scope =
        match name with
        | None -> ([], scope)
        | Some name ->
            let js_name, scope = bind name scope in
            let middle =
              JsCall
                ( info,
                  JsMember (info, subject, "slice"),
                  JsNum (info, String.length prefix)
                  :: (if suffix = "" then []
                      else
                        [
                          JsBinary
                            (info, "-", length, JsNum (info, String.length suffix));
                        ]) )
            in
            ([ JsConst (info, JsTargetName (info, js_name), middle) ], scope)
      in
      (test, bindings, scope)
  | PList (_, prefix, rest, suffix, _) ->
      let fixed = prefix @ suffix in
      let length = JsMember (info, subject, "length") in
      let size =
        match rest with
        | None ->
            JsBinary (info, "===", length, JsNum (info, List.length prefix))
        | Some _ ->
            JsBinary (info, ">=", length, JsNum (info, List.length fixed))
      in
      let places =
        List.mapi (fun i _ -> JsIndex (info, subject, JsNum (info, i))) prefix
        @ List.mapi
            (fun i _ ->
              JsIndex
                ( info,
                  subject,
                  JsBinary
                    ( info,
                      "-",
                      length,
                      JsNum (info, List.length suffix - i) ) ))
            suffix
      in
      let test, bindings, scope = pattern_parts fixed places (Some size) scope in
      let bindings, scope =
        match rest with
        | Some (ListRest (_, Some name, _)) ->
            let js_name, scope = bind name scope in
            let middle =
              JsCall
                ( info,
                  JsVar (info, "pykList"),
                  [
                    JsCall
                      ( info,
                        JsMember (info, subject, "slice"),
                        [
                          JsNum (info, List.length prefix);
                          JsBinary
                            (info, "-", length, JsNum (info, List.length suffix));
                        ] );
                  ] )
            in
            ( bindings @ [ JsConst (info, JsTargetName (info, js_name), middle) ],
              scope )
        | _ -> (bindings, scope)
      in
      (test, bindings, scope)

(** Every sub-pattern's test and bindings, joined with `&&`.
    [pattern] -> [jsexpr] -> jsexpr option -> scope
    -> (jsexpr option, [jsstmt], scope) *)
and pattern_parts patterns places test scope =
  let rec go patterns places test bindings scope =
    match (patterns, places) with
    | pattern :: patterns, place :: places ->
        let inner, made, scope = pattern_test pattern place scope in
        let test =
          match inner with
          | None -> test
          | Some inner -> (
              match test with
              | None -> Some inner
              | Some test ->
                  Some (JsBinary (pattern_info pattern, "&&", test, inner)))
        in
        go patterns places test (bindings @ made) scope
    | _ -> (test, bindings, scope)
  in
  go patterns places test [] scope

(** Whether `e` is a call across the runtime interface (`print`). Those
    yield unit, so a function whose tail is one needs no `return`:
    JavaScript's own implicit `undefined` already is it. expr -> bool *)
let yields_unit e =
  match e with
  | ECall (_, EVar (_, name, _), _, _) -> Builtin.crosses_host name
  | _ -> false

(** Whether a `def` is written anywhere in these statements, at any
    depth. A loop whose body defines one has to give every turn its own
    accumulator, since the function outlives the turn and JavaScript's
    `let` outside the loop is one binding for all of them (see
    `translate_loop`). [stmt] -> bool *)
let defines_function stmts =
  Walk.exists_stmts
    (fun node ->
      match node with Walk.NStmt (SFunctionDef _) -> true | _ -> false)
    stmts

(** A name for a loop-result variable that nothing here uses.
    scope -> string *)
let fresh_result_name scope =
  let rec go n =
    let candidate = Printf.sprintf "tmp%d" n in
    if
      StringSet.mem candidate scope.taken
      || SMap.exists (fun _ value -> value = candidate) scope.names
    then go (n + 1)
    else candidate
  in
  go 1

(** Every JavaScript name a target declares. jstarget -> [string] *)
let rec target_names target =
  match target with
  | JsTargetName (_, name) -> [ name ]
  | JsTargetArray (_, elements) -> List.concat_map target_names elements

(** A target read back as an expression: what a loop's accumulator holds
    once the loop has stopped. jstarget -> jsexpr *)
let rec target_as_expr target =
  match target with
  | JsTargetName (info, name) -> JsVar (info, name)
  | JsTargetArray (info, elements) ->
      JsArray (info, List.map target_as_expr elements)

(** The names one import binds where it is written: each selected name
    under the name it is known by here, or the module's own local name.
    stmt -> [string] *)
let import_names statement =
  match statement with
  | SImport (_, _, name, selected, fields, _) ->
      if selected then List.map (fun (_, local) -> local) fields else [ name ]
  | _ -> []

(** Binds every def in this block, and everything an import brings into
    it, before any of it is translated (docs/target_js.md, "Functions
    used before they are written"). Both are visible throughout the
    block they are written in, so both are bound ahead of it.
    [stmt] -> scope -> scope *)
let declare_functions stmts scope =
  List.fold_left
    (fun scope s ->
      match s with
      | SFunctionDef (_, name, _, _, _, _, _)
        when not (StringSet.mem name scope.block) ->
          snd (bind name scope)
      | SImport _ ->
          List.fold_left
            (fun scope name ->
              if StringSet.mem name scope.block then scope else snd (bind name scope))
            scope (import_names s)
      | _ -> scope)
    scope stmts

(** Binds every name in an assignment target, giving the JavaScript
    target that stands for it -- a name, or the array pattern that takes
    a tuple apart. assign_target -> scope -> (jstarget, scope) *)
let rec translate_target target scope =
  match target with
  | TargetName (info, name, _) ->
      let js_name, scope = bind name scope in
      (JsTargetName (info, js_name), scope)
  | TargetTuple (info, elements, _) ->
      let js_elements, scope =
        List.fold_left
          (fun (out, scope) element ->
            let js_element, scope = translate_target element scope in
            (out @ [ js_element ], scope))
          ([], scope) elements
      in
      (JsTargetArray (info, js_elements), scope)

(** Translates a statement sequence, threading the scope through it.
    [stmt] -> scope -> ([jsstmt], scope) *)
let rec translate_stmts stmts scope =
  let scope = declare_functions stmts scope in
  List.fold_left
    (fun (translated, scope) s ->
      let js_stmts, scope = translate_stmt s scope in
      (translated @ js_stmts, scope))
    ([], scope) stmts

(** A statement list, for a caller that wants only the statements.
    [stmt] -> scope -> [jsstmt] *)
and translate_stmts_only stmts scope = fst (translate_stmts stmts scope)

(** Translates a statement list whose last statement is in tail position
    (PYKING.md, "Tail position"; docs/target_js.md, "Tail position").
    [stmt] -> scope -> [jsstmt] *)
and translate_tail_stmts stmts scope =
  match stmts with
  | [] -> []
  | stmts ->
      (* The whole block, last statement included: a `def` in tail
         position is still visible to everything above it. *)
      let scope = declare_functions stmts scope in
      let count = List.length stmts in
      let front = List.filteri (fun i _ -> i < count - 1) stmts in
      let body, tail_scope = translate_stmts front scope in
      body @ translate_tail_stmt (List.nth stmts (count - 1)) tail_scope

(** A `match` as an if/else chain over the subject, held in a name of
    its own so it is evaluated once. `translate_body` decides what an
    arm's body becomes -- plain statements, or a tail block whose value
    is returned. An arm whose pattern always matches becomes the `else`,
    so a `match` that fits no arm does nothing.
    stmt -> scope -> ([stmt] -> scope -> [jsstmt]) -> ([jsstmt], scope) *)
and translate_match s scope translate_body =
  match s with
  | SMatch (info, subject, cases, _) ->
      let name, scope = bind "__subject" scope in
      let chain =
        List.fold_left
          (fun chain (MatchCase (case_info, pattern, body, _)) ->
            let arm_scope = block_scope scope in
            let test, bindings, arm_scope =
              pattern_test pattern (JsVar (info, name)) arm_scope
            in
            let body = translate_body body arm_scope in
            match test with
            | None -> Some (bindings @ body)
            | Some test -> Some [ JsIf (case_info, test, bindings @ body, chain) ])
          None (List.rev cases)
      in
      let held =
        JsConst (info, JsTargetName (info, name), translate_expr subject scope)
      in
      ((held :: Option.value chain ~default:[]), scope)
  | _ -> ([], scope)

(** The last statement of a body in tail position, as a list of JS
    statements. stmt -> scope -> [jsstmt] *)
and translate_tail_stmt s scope =
  match s with
  | SMatch _ ->
      (* Every arm is in tail position too, so each one's value is the
         function's -- without this the arms would be plain expression
         statements and the function would return nothing. *)
      fst (translate_match s scope translate_tail_stmts)
  | SExprStmt (_, e, _) when yields_unit e -> fst (translate_stmt s scope)
  | SExprStmt (info, e, _) -> [ JsReturn (info, translate_expr e scope) ]
  | SIf (_, _, _, None, _) ->
      (* An `if` with no `else` supplies unit whatever its one branch
         ends in (PYKING.md, "Type checking"): a path runs no branch at
         all, so there is no value the statement can be counted on for.
         Translated as an ordinary statement, so the function falls out
         of its end. *)
      fst (translate_stmt s scope)
  | SIf (info, cond, then_body, Some else_body, _) ->
      [
        JsIf
          ( info,
            translate_expr cond scope,
            translate_tail_stmts then_body (block_scope scope),
            Some (translate_tail_stmts else_body (block_scope scope)) );
      ]
  | SLoop (info, _, _, _, _, _, _) ->
      (* A function ending in a loop returns what the loop produced: the
         accumulator it stopped with. *)
      let js_stmts, value, _ = translate_loop s scope in
      js_stmts @ [ JsReturn (info, value) ]
  | s -> fst (translate_stmt s scope)

(** Translates one statement, answering it with the scope it leaves
    behind. A loop answers with several statements.
    stmt -> scope -> ([jsstmt], scope) *)
and translate_stmt s scope =
  match s with
  | SLet (info, target, e, _, _, _) ->
      let js_expr = translate_expr e scope in
      let js_target, scope = translate_target target scope in
      ([ JsConst (info, js_target, js_expr) ], scope)
  | SMatch _ -> translate_match s scope translate_stmts_only
  | SLetStmt (info, target, (SLoop _ as loop), _, _, _) ->
      (* `x = loop ...` -- the loop's value is the accumulator it
         stopped with, so the binding is one assignment after it. *)
      let js_stmts, value, scope = translate_loop loop scope in
      let js_target, scope = translate_target target scope in
      (js_stmts @ [ JsConst (info, js_target, value) ], scope)
  | SVar (info, name, e, _) ->
      let js_expr = translate_expr e scope in
      let js_name, scope = bind name scope in
      ([ JsLet (info, JsTargetName (info, js_name), js_expr) ], scope)
  | SMutate (info, name, e, _) ->
      (* An update, not a binding: it reuses whatever name the variable
         was given when it was declared. *)
      ( [
          JsAssign
            ( info,
              JsTargetName (info, lookup name scope),
              translate_expr e scope );
        ],
        scope )
  | SReturn (info, e, _) -> ([ JsReturn (info, translate_expr e scope) ], scope)
  | SReturnStmt (_, inner, _) ->
      (* `return if c:` -- the same push-down as a tail-position `if`,
         written explicitly so it also works before the end of the body.
         A loop answers with several statements. *)
      (translate_tail_stmt inner scope, scope)
  | SExprStmt (info, e, _) ->
      ([ JsExprStmt (info, translate_expr e scope) ], scope)
  | SLoop _ ->
      let js_stmts, _, scope = translate_loop s scope in
      (js_stmts, scope)
  | SBreak (info, _) ->
      (* JavaScript's own: the variable the loop carries is left holding
         what this turn started with, which is what the loop is
         worth. *)
      ([ JsBreak info ], scope)
  | SContinue (info, _) -> ([ JsContinue info ], scope)
  | SIf (info, cond, then_body, else_body, _) ->
      let js_then, _ = translate_stmts then_body (block_scope scope) in
      let js_else =
        match else_body with
        | None -> None
        | Some else_body -> Some (fst (translate_stmts else_body (block_scope scope)))
      in
      ([ JsIf (info, translate_expr cond scope, js_then, js_else) ], scope)
  | SImport (info, module_name, local, selected, fields, _) ->
      (* Named, not spelled: what a `require`, an ES `import` or a
         reference to a module already built on the page reads like is
         the packager's (see JsImport). The names were bound by
         `declare_functions`, so a renamed one is read back here. *)
      let alias = lookup local scope in
      let external_here = Option.value (List.assoc_opt module_name scope.external_fields) ~default:[] in
      let from_half half =
        List.filter
          (fun (exported, _) -> List.mem exported external_here = half)
          fields
      in
      let named half =
        List.map (fun (exported, name) -> (exported, lookup name scope)) (from_half half)
      in
      (* The generated file, unless this module is only a declaration
         half; then the implementation, under an alias of its own. *)
      let own =
        if List.mem module_name scope.externals then []
        else if selected && named false = [] && fields <> [] then []
        else [ JsImport (info, module_name, alias, selected, named false) ]
      in
      let implementation =
        if external_here = [] then []
        else if selected && named true = [] then []
        else
          [
            JsImport
              ( info,
                module_name ^ "_external",
                alias ^ "_external",
                selected,
                named true );
          ]
      in
      (own @ implementation, scope)
  | SFunctionDef (info, name, params, body, _, _, _) ->
      (* The name was bound by `declare_functions`; read it back rather
         than binding again, which would rename it twice. *)
      let js_name = lookup name scope in
      let body_scope = block_scope scope in
      let param_names, body_scope =
        List.fold_left
          (fun (out, body_scope) (Param (_, param_name, _, _)) ->
            let js_param, body_scope = bind param_name body_scope in
            (out @ [ js_param ], body_scope))
          ([], body_scope) params
      in
      ([ JsFunc (info, js_name, param_names, translate_tail_stmts body body_scope) ], scope)
  | s -> unsupported (stmt_info s) (stmt_kind_name s)

(** Translates a loop into `while (true)` over a `let` accumulator
    (docs/target_js.md, "loop"): the initializer is the accumulator's
    first value and every tail of the body assigns the next one, so the
    variable holds what the loop is worth however it stops -- a `break`
    is JavaScript's own, and leaves this turn's value where it is.
    Answers the statements, the expression holding the loop's value
    afterwards, and the scope: the accumulator is in scope only in the
    loop's own body, but its `let` is declared in the block around it,
    so that name stays spoken for there -- a second loop reusing the
    Pyking name gets a fresh one rather than a duplicate declaration.
    stmt -> scope -> ([jsstmt], jsexpr, scope) *)
and translate_loop s scope =
  match s with
  | SLoop (info, target, init, _, iterate, body, _) ->
      let body_scope = block_scope scope in
      let setup, carried, per_turn, value, scope, body_scope =
        match (target, init) with
        | Some target, Some init ->
            (* The initializer is translated before the accumulator
               binds, so `loop x = x + 1:` reads the enclosing `x`. *)
            let js_init = translate_expr init scope in
            let js_target, body_scope = translate_target target body_scope in
            let scope = reserve (target_names js_target) scope in
            if defines_function body then
              (* Pyking binds the accumulator afresh on every turn, and a
                 function written in the body outlives the turn -- so one
                 `let` around the loop would give every one of them the
                 last turn's value. The `let` becomes a carrier holding
                 what the next turn starts with, and the accumulator
                 itself becomes a `const` inside the body: one binding
                 per turn, which is what each function closes over. See
                 docs/target_js.md, "A def inside a loop". *)
              let name = fresh_result_name scope in
              let carrier = JsTargetName (info, name) in
              let scope = reserve [ name ] scope in
              let body_scope = reserve [ name ] body_scope in
              ( [ JsLet (info, carrier, js_init) ],
                Some carrier,
                [ JsConst (info, js_target, JsVar (info, name)) ],
                JsVar (info, name),
                scope,
                body_scope )
            else
              (* `let`, not `const`: one JavaScript variable carries what
                 Pyking binds afresh on every turn. *)
              ( [ JsLet (info, js_target, js_init) ],
                Some js_target,
                [],
                target_as_expr js_target,
                scope,
                body_scope )
        (* A loop carrying nothing yields unit, which is the empty
           tuple. *)
        | _ -> ([], None, [], JsArray (info, []), scope, body_scope)
      in
      (* A `for` binds its element in the body's scope; a `while` becomes
         the loop's own test. *)
      let js_name, js_sequence, body_scope =
        match iterate with
        | Some (ForIn (_, name, sequence, _)) ->
            let js_sequence = translate_expr sequence scope in
            let js_name, body_scope = bind name body_scope in
            (Some js_name, Some js_sequence, body_scope)
        | _ -> (None, None, body_scope)
      in
      let js_body = per_turn @ translate_loop_block body carried body_scope in
      let loop =
        match iterate with
        | Some (ForIn _) ->
            JsForOf (info, Option.get js_name, Option.get js_sequence, js_body)
        | Some (WhileTest (_, condition, _)) ->
            JsWhile (info, translate_expr condition body_scope, js_body)
        | None -> JsWhile (info, JsBool (info, true), js_body)
      in
      (setup @ [ loop ], value, scope)
  | s -> ([], JsArray (stmt_info s, []), scope)

(** Translates a loop body: whatever a path ends in is the next turn's
    accumulator, so every tail becomes an assignment to js_target --
    except a `break`/`continue`, which has already said what happens
    next. js_target is None for a loop carrying nothing, where the
    body's value is discarded.
    [stmt] -> jstarget option -> scope -> [jsstmt] *)
and translate_loop_block stmts js_target scope =
  match stmts with
  | [] -> []
  | stmts ->
      let scope = declare_functions stmts scope in
      let count = List.length stmts in
      let front = List.filteri (fun i _ -> i < count - 1) stmts in
      let body, scope = translate_stmts front scope in
      body
      @ translate_loop_tail (List.nth stmts (count - 1)) js_target scope

(** The last statement of a loop body, or of one branch of one.
    stmt -> jstarget option -> scope -> [jsstmt] *)
and translate_loop_tail s js_target scope =
  match js_target with
  | None -> fst (translate_stmt s scope)
  | Some target -> (
      match s with
      | SExprStmt (info, e, _) ->
          [ JsAssign (info, target, translate_expr e scope) ]
      | SIf (info, cond, then_body, else_body, _) ->
          let js_then =
            translate_loop_block then_body js_target (block_scope scope)
          in
          let js_else =
            match else_body with
            (* A path that runs no branch produces nothing, and nothing
               is unit (PYKING.md, "Tail position"). *)
            | None -> [ JsAssign (info, target, JsArray (info, [])) ]
            | Some else_body ->
                translate_loop_block else_body js_target (block_scope scope)
          in
          [ JsIf (info, translate_expr cond scope, js_then, Some js_else) ]
      | SMatch _ ->
          (* Every arm ends the turn, so each one's value is the next
             accumulator -- without this the arms would be plain
             expression statements and the turn would carry nothing. *)
          fst
            (translate_match s scope (fun body inner ->
                 translate_loop_block body js_target inner))
      (* Each of these says by itself what happens next: two leave the
         loop, one leaves the whole function. *)
      | SBreak _ | SContinue _ | SReturn _ | SReturnStmt _ ->
          fst (translate_stmt s scope)
      | s ->
          fst (translate_stmt s scope)
          @ [ JsAssign (stmt_info s, target, JsArray (stmt_info s, [])) ])

(** A whole Pyking module as JavaScript statements, ready for a packager
    to wrap. `taken` names JavaScript the packager will write around it
    -- the one it calls a module's `init` by -- so a Pyking binding of
    that name is renamed rather than shadowing it, exactly as `reserved`
    does for the names written here.
    Answers the statements and every top-level name this module had to
    rename -- a Pyking name that is a word JavaScript reserves is bound
    under another one, and a packaging that exports it has to say which
    (`export { arguments2 as arguments }`), or it writes a name nothing
    declared.
    [stmt] -> [string] -> ([jsstmt], [(string, string)]) *)
let translate_program ?(taken = []) ?(external_fields = []) ?(externals = [])
    ?(own = "") stmts =
  let statements, scope =
    translate_stmts stmts
      {
        names = SMap.empty;
        block = StringSet.empty;
        taken =
          List.fold_left
            (fun set name -> StringSet.add name set)
            StringSet.empty
            (* The alias each implementation is brought in under is
               written by this backend, so a Pyking binding may not take
               it. *)
            (taken @ List.map (fun (name, _) -> name ^ "_external") external_fields);
        external_fields;
        externals;
        own_module = own;
        own_external =
          Option.value (List.assoc_opt own external_fields) ~default:[];
        module_aliases =
          List.filter_map
            (function
              | SImport (_, module_, local, false, _, _) -> Some (local, module_)
              | _ -> None)
            stmts;
      }
  in
  (* The implementation of this module's own declaration half, imported
     so that a name declared here can be called here. *)
  let own_external =
    Option.value (List.assoc_opt own external_fields) ~default:[]
  in
  let own_import =
    if own_external = [] then []
    else
      [
        JsImport
          ( Lexer.{ file = ""; row1 = 1; col1 = 0; row2 = 1; col2 = 0 },
            own ^ "_external",
            own ^ "_external",
            false,
            [] );
      ]
  in
  ( own_import @ statements,
    List.filter
      (fun (pyking, js) -> pyking <> js)
      (SMap.bindings scope.names) )

(* --- printer: JavaScript AST -> JavaScript source text ---

   Precedences are JavaScript's own, spaced so that a child printed at
   `prec + 1` is parenthesized when it binds looser than its parent. *)

let precedence op =
  match op with
  | "*" | "/" -> 12
  | "+" | "-" -> 11
  | "<" | "<=" | ">" | ">=" -> 9
  | "===" -> 8
  (* `&&` joins the tests a pattern is compiled into; looser than every
     comparison above it, which is what lets those go
     unparenthesized. *)
  | "&&" -> 4
  | _ -> 0

let unary_precedence = 14
let conditional_precedence = 3
let call_precedence = 17

let escape_char c =
  match c with
  | '\\' -> "\\\\"
  | '\'' -> "\\'"
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(** s as a single-quoted JavaScript string literal. string -> string *)
let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '\'';
  String.iter (fun c -> Buffer.add_string buffer (escape_char c)) s;
  Buffer.add_char buffer '\'';
  Buffer.contents buffer

(** text, parenthesized if prec is below min_prec.
    int -> int -> string -> string *)
let parens prec min_prec text =
  if prec < min_prec then "(" ^ text ^ ")" else text

(** target as JavaScript source text: a name, or the array pattern that
    takes a tuple apart. jstarget -> string *)
let rec pprint_js_target target =
  match target with
  | JsTargetName (_, name) -> name
  | JsTargetArray (_, elements) ->
      Printf.sprintf "[%s]" (String.concat ", " (List.map pprint_js_target elements))

(** e as JavaScript source text. `runtime` is what the packager decides:
    the spelling of each runtime operation, and of an import.
    jsexpr -> jshost -> int -> string *)
let rec pprint_js_expr ?(min_prec = 0) e runtime =
  let at prec e = pprint_js_expr ~min_prec:prec e runtime in
  let plain e = pprint_js_expr e runtime in
  match e with
  | JsNum (_, v) -> string_of_int v
  | JsStr (_, s) -> quote s
  | JsBool (_, v) -> if v then "true" else "false"
  | JsVar (_, name) -> name
  | JsUnary (_, op, operand) ->
      parens unary_precedence min_prec
        (Printf.sprintf "%s%s" op (at (unary_precedence + 1) operand))
  | JsBinary (_, op, left, right) ->
      let prec = precedence op in
      (* Left-associative: the right operand needs the tighter bound. *)
      parens prec min_prec
        (Printf.sprintf "%s %s %s" (at prec left) op (at (prec + 1) right))
  | JsCond (_, cond, then_expr, else_expr) ->
      parens conditional_precedence min_prec
        (Printf.sprintf "%s ? %s : %s"
           (at (conditional_precedence + 1) cond)
           (at conditional_precedence then_expr)
           (at conditional_precedence else_expr))
  | JsArray (_, elements) ->
      Printf.sprintf "[%s]" (String.concat ", " (List.map plain elements))
  | JsList (_, elements) ->
      Printf.sprintf "pykList([%s])"
        (String.concat ", " (List.map plain elements))
  | JsPlain (_, elements) ->
      Printf.sprintf "[%s]" (String.concat ", " (List.map plain elements))
  | JsArrow (_, params, body, result) ->
      if body = [] then
        Printf.sprintf "(%s) => %s" (String.concat ", " params) (plain result)
      else
        let lines =
          List.map (fun st -> pprint_js_stmt ~level:1 st runtime) body
          @ [ Printf.sprintf "  return %s;" (plain result) ]
        in
        Printf.sprintf "(%s) => {\n%s\n}" (String.concat ", " params)
          (String.concat "\n" lines)
  | JsConcat (_, left, right) ->
      Printf.sprintf "pykConcat(%s, %s)" (plain left) (plain right)
  | JsSpread (_, parts) ->
      Printf.sprintf "[%s]"
        (String.concat ", " (List.map (fun p -> "..." ^ plain p) parts))
  | JsIndex (_, target, index) ->
      Printf.sprintf "%s[%s]" (at call_precedence target) (plain index)
  | JsMember (_, target, name) ->
      Printf.sprintf "%s.%s" (at call_precedence target) name
  | JsCall (_, func, args) ->
      Printf.sprintf "%s(%s)" (at call_precedence func)
        (String.concat ", " (List.map plain args))
  | JsRuntimeCall (_, operation, args) ->
      Printf.sprintf "%s(%s)"
        (List.assoc operation runtime.operations)
        (String.concat ", " (List.map plain args))

(** Renders a statement list as one string, with a blank line around
    each function definition (never at the block's own start or end).
    [jsstmt] -> jshost -> int -> string *)
and join_stmts stmts runtime level =
  let is_func s = match s with JsFunc _ -> true | _ -> false in
  let lines, _, _ =
    List.fold_left
      (fun (lines, index, previous) stmt ->
        let set_off = is_func stmt || (index > 0 && previous) in
        let lines = if lines <> [] && set_off then lines @ [ "" ] else lines in
        (lines @ [ pprint_js_stmt ~level stmt runtime ], index + 1, is_func stmt))
      ([], 0, false) stmts
  in
  String.concat "\n" lines

(** s as JavaScript source text, indented to level.
    jsstmt -> jshost -> int -> string *)
and pprint_js_stmt ?(level = 0) s runtime =
  let pad = String.concat "" (List.init level (fun _ -> "  ")) in
  let plain e = pprint_js_expr e runtime in
  match s with
  | JsImport _ -> pad ^ (Option.get runtime.importing) s
  | JsConst (_, target, e) ->
      Printf.sprintf "%sconst %s = %s;" pad (pprint_js_target target) (plain e)
  | JsLet (_, target, e) ->
      Printf.sprintf "%slet %s = %s;" pad (pprint_js_target target) (plain e)
  | JsAssign (_, target, e) ->
      Printf.sprintf "%s%s = %s;" pad (pprint_js_target target) (plain e)
  | JsExprStmt (_, e) -> Printf.sprintf "%s%s;" pad (plain e)
  | JsReturn (_, e) -> Printf.sprintf "%sreturn %s;" pad (plain e)
  | JsIf (_, cond, then_body, else_body) ->
      let lines =
        [ Printf.sprintf "%sif (%s) {" pad (plain cond);
          join_stmts then_body runtime (level + 1) ]
      in
      (* An else body of exactly one `if` prints as `else if`, the flat
         form Pyking's own `else if` ladder was written in. *)
      let rec ladder lines else_body =
        match else_body with
        | Some [ JsIf (_, elif_cond, elif_body, else_body2) ] ->
            ladder
              (lines
              @ [ Printf.sprintf "%s} else if (%s) {" pad (plain elif_cond);
                  join_stmts elif_body runtime (level + 1) ])
              else_body2
        | None -> lines
        | Some else_body ->
            lines
            @ [ Printf.sprintf "%s} else {" pad;
                join_stmts else_body runtime (level + 1) ]
      in
      String.concat "\n" (ladder lines else_body @ [ Printf.sprintf "%s}" pad ])
  | JsForOf (_, name, sequence, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%sfor (const %s of %s) {" pad name (plain sequence);
          join_stmts body runtime (level + 1);
          Printf.sprintf "%s}" pad;
        ]
  | JsWhile (_, cond, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%swhile (%s) {" pad (plain cond);
          join_stmts body runtime (level + 1);
          Printf.sprintf "%s}" pad;
        ]
  | JsBreak _ -> Printf.sprintf "%sbreak;" pad
  | JsContinue _ -> Printf.sprintf "%scontinue;" pad
  | JsFunc (_, name, params, body) ->
      String.concat "\n"
        [
          Printf.sprintf "%sfunction %s(%s) {" pad name
            (String.concat ", " params);
          join_stmts body runtime (level + 1);
          Printf.sprintf "%s}" pad;
        ]

let concat_helper =
  String.concat "\n"
    [
      "// Pyking's `++` joins two strings or two lists. A list is an array";
      "// here and JavaScript's `+` would stringify one, so which is meant";
      "// is decided by looking -- this backend infers no types.";
      "function pykConcat(a, b) {";
      "  return Array.isArray(a) ? pykList([...a, ...b]) : a + b;";
      "}";
    ]

let list_helper =
  String.concat "\n"
    [
      "// A Pyking list is a JavaScript array with a marker on it: a tuple";
      "// is an array too, and the two print differently. A property rather";
      "// than a class, so that a formatter in another module can read it.";
      "function pykList(items) {";
      "  items.pykList = true;";
      "  return items;";
      "}";
    ]

(** Whether any expression in the translated program satisfies p, so
    that a helper is emitted only where it is wanted -- as C's
    `pyk_concat` is. (jsexpr -> bool) -> [jsstmt] -> bool *)
let uses p stmts =
  let rec in_expr e =
    p e
    ||
    match e with
    | JsNum _ | JsStr _ | JsBool _ | JsVar _ -> false
    | JsUnary (_, _, operand) -> in_expr operand
    | JsBinary (_, _, left, right) | JsConcat (_, left, right) ->
        in_expr left || in_expr right
    | JsCall (_, func, args) -> in_expr func || List.exists in_expr args
    | JsArray (_, elements) | JsList (_, elements) | JsPlain (_, elements)
    | JsSpread (_, elements) ->
        List.exists in_expr elements
    | JsArrow (_, _, body, result) ->
        List.exists in_stmt body || in_expr result
    | JsIndex (_, target, index) -> in_expr target || in_expr index
    | JsMember (_, target, _) -> in_expr target
    | JsCond (_, cond, then_expr, else_expr) ->
        in_expr cond || in_expr then_expr || in_expr else_expr
    | JsRuntimeCall (_, _, args) -> List.exists in_expr args
  and in_stmt s =
    match s with
    | JsConst (_, _, e) | JsLet (_, _, e) | JsAssign (_, _, e)
    | JsExprStmt (_, e) | JsReturn (_, e) ->
        in_expr e
    | JsIf (_, cond, then_body, else_body) ->
        in_expr cond || List.exists in_stmt then_body
        || (match else_body with
           | None -> false
           | Some body -> List.exists in_stmt body)
    | JsForOf (_, _, sequence, body) ->
        in_expr sequence || List.exists in_stmt body
    | JsWhile (_, cond, body) -> in_expr cond || List.exists in_stmt body
    | JsBreak _ | JsContinue _ | JsImport _ -> false
    | JsFunc (_, _, _, body) -> List.exists in_stmt body
  in
  List.exists in_stmt stmts

(** The generated program's own runtime helpers, for whichever of them
    these statements use, indented to level -- or "" where they use
    none. [jsstmt] -> int -> string *)
let js_helpers ?(level = 0) stmts =
  let pad = String.concat "" (List.init level (fun _ -> "  ")) in
  let uses_list =
    uses
      (function
        (* A list *literal*, and a list a pattern rebuilds: matching
           `case [first] ++ rest` compiles to a `pykList` call rather
           than to a JsList, so looking only for the node would leave
           the helper out of a module whose lists are all in patterns. *)
        | JsList _ | JsVar (_, "pykList") -> true
        | _ -> false)
      stmts
  in
  let uses_concat = uses (function JsConcat _ -> true | _ -> false) stmts in
  let wanted =
    (* `pykConcat` builds a list, so it needs `pykList` beside it. *)
    (if uses_list || uses_concat then [ list_helper ] else [])
    @ if uses_concat then [ concat_helper ] else []
  in
  String.concat "\n\n"
    (List.map
       (fun helper ->
         String.concat "\n"
           (List.map
              (fun line -> if line = "" then line else pad ^ line)
              (String.split_on_char '\n' helper)))
       wanted)

(** stmts as JavaScript source text, with the list helper ahead of them
    where the program builds a list. `helpers` is false where a caller
    emits them itself -- the html packaging, which puts several modules
    on one page and so needs one copy of each rather than one per
    module. [jsstmt] -> jshost -> int -> bool -> string *)
let pprint_js_program ?(level = 0) ?(helpers = true) stmts runtime =
  let body = join_stmts stmts runtime level in
  let wanted = if helpers then js_helpers ~level stmts else "" in
  if wanted <> "" then wanted ^ "\n\n" ^ body else body
