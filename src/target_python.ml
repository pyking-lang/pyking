(** The Python code-generation backend: Pyking AST (syntax.ml) to a
    Python-shaped AST (the `Py` nodes below) to Python source text.
    See docs/target_python.md for how each
    construct compiles and where the output is not optimal.

    Data structures:
      pyexpr / pypattern / pytarget / pycompclause / pystmt -- the
        Python-target AST; see the comment on each variant for its
        shape.
      pyprogram -- a translated program: the host boilerplate and the
        program itself.
      scope -- Pyking name -> Python name, threaded through translation.
      gen -- what the translation accumulates as it runs: the generated
        helpers and the counters that name them.

    Functions:
      translate_program stmts tmap -- translates a whole program.
      translate_expr e scope gen -- translates one expression.
      translate_stmt s scope gen -- translates one statement.
      translate_pattern p scope / translate_target t scope -- translate
        a match pattern / assignment target.
      pprint_py_program program -- pyprogram to Python source text.
      pprint_py_expr e / pprint_py_stmt s -- one node to source text. *)

open Lexer
open Syntax

(* --- Python target AST ---

   Structurally the same shape as syntax.ml's expr/stmt, with one
   deliberate difference: Pyking's SLet/SVar/SMutate (immutable binding
   vs. mutable declaration vs. mutation) all collapse into a single
   PyAssign, since Python itself has no such distinction -- every one of
   them is just `target = expr`. Only SLet's target can destructure a
   tuple in Pyking; SVar/SMutate keep a plain name, wrapped in
   PyTargetName here so all three still produce the same
   uniformly-shaped PyAssign. *)

type pyexpr =
  | PyInt of info * int
  | PyFloat of info * float
  | PyString of info * string
  | PyBool of info * bool (* True / False *)
  | PyVar of info * string
  | PyAdd of info * pyexpr * pyexpr (* left + right *)
  | PySub of info * pyexpr * pyexpr (* left - right *)
  | PyMul of info * pyexpr * pyexpr (* left * right *)
  | PyFloorDiv of info * pyexpr * pyexpr
      (* left // right. Only the division helper builds one: Pyking's
         `/` truncates and Python's `//` floors, so the helper corrects
         the sign around this. *)
  | PyNeg of info * pyexpr (* -operand (unary minus) *)
  | PyLessThan of info * pyexpr * pyexpr
  | PyLessThanEq of info * pyexpr * pyexpr
  | PyGreatThan of info * pyexpr * pyexpr
  | PyGreatThanEq of info * pyexpr * pyexpr
  | PyEq of info * pyexpr * pyexpr
  | PyAttr of info * pyexpr * string (* target.name *)
  | PyAnd of info * pyexpr * pyexpr (* left and right *)
  | PySlice of info * pyexpr * pyexpr option * pyexpr option
      (* target[start:stop]; either end may be absent *)
  | PyIndex of info * pyexpr * pyexpr (* target[index] *)
  | PyCall of info * pyexpr * pyexpr list (* func(args...) *)
  | PyList of info * pyexpr list (* [elements...] *)
  | PyTuple of info * pyexpr list (* (e1, e2, ...) / (e,) / () *)
  | PyIfExp of info * pyexpr * pyexpr * pyexpr
      (* then_expr if cond else else_expr *)
  | PyListComp of info * pyexpr * pycompclause list
      (* [expr for target in seq {for ... | if ...}] *)

and pypattern =
  | PyPInt of info * int (* case 0: *)
  | PyPString of info * string (* case "foo": *)
  | PyPBool of info * bool (* case True: / case False: *)
  | PyPWildcard of info (* case _: *)
  | PyPCapture of info * string (* case name: *)
  | PyPTuple of info * pypattern list (* case (p1, p2, ...): *)
  | PyPGuarded of info * string * pyexpr option * pystmt list
      (* case str() as name: -- with a guard and the bindings it makes
         possible, put where they belong by `match_case` *)
  | PyPList of info * pypattern list * pylistrest option * pypattern list
      (* case [p1, ..., *rest_or_wildcard, ..., pk]: *)

and pylistrest = PyListRest of info * string option
(* the `*name` / `*_` star sub-pattern of a PyPList *)

and pymatchcase = PyMatchCase of info * pypattern * pystmt list * pyexpr option
(* case pattern [if guard]: body *)

and pytarget =
  | PyTargetName of info * string (* name *)
  | PyTargetTuple of info * pytarget list (* (t1, t2, ...) *)

and pycompclause =
  | PyCompFor of info * pytarget * pyexpr (* for target in sequence *)
  | PyCompIf of info * pyexpr (* if condition *)

and pystmt =
  | PyAssign of info * pytarget * pyexpr (* target = expr *)
  | PyReturn of info * pyexpr (* return expr *)
  | PyExprStmt of info * pyexpr (* expr used as a statement *)
  | PyImport of info * string * string option (* import module [as alias] *)
  | PyFromImport of info * string * (string * string) list
      (* from module import name [as alias], ... *)
  | PyGlobal of info * string list (* global a, b *)
  | PyNonlocal of info * string list (* nonlocal a, b *)
  | PyFor of info * string * pyexpr * pystmt list * pystmt list option
      (* for name in iterable: body [else: orelse] *)
  | PyWhile of info * pyexpr * pystmt list * pystmt list option
      (* while cond: body [else: orelse] *)
  | PyBreak of info
  | PyContinue of info
  | PyIf of info * pyexpr * pystmt list * pystmt list option
      (* if cond: then_body [else: else_body] *)
  | PyFunctionDef of info * string * string list * pystmt list
      (* def name(params...): body *)
  | PyMatch of info * pyexpr * pymatchcase list
      (* match subject: case pattern: body ... *)

(** A translated program: the host boilerplate (e.g. the Bool-printing
    helper; usually empty) and the translated program itself. *)
type pyprogram = {
  prelude : pystmt list;
  formats : bool;  (* whether the prelude holds the Bool walker *)
  floats : bool;  (* whether the prelude holds the Float formatter *)
  float_helper : string;  (* what that formatter is called *)
  stmts : pystmt list;
}

(* --- pretty printer: Python target AST -> Python source text ---

   Two levels beside the arithmetic ones the printers below use (1 for a
   comparison, up to 5 for an atom): `and` is looser than all of them,
   and a call, an attribute or a slice binds tighter, so their target is
   asked for an atom. *)

let and_prec = 0
let call_prec = 5

(** s, parenthesized if prec is below min_prec.
    int -> int -> string -> string *)
let parens prec min_prec s = if prec < min_prec then "(" ^ s ^ ")" else s

let print_escape c =
  match c with
  | '\\' -> "\\\\"
  | '\'' -> "\\'"
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(** s as a single-quoted Python string literal, escapes applied.
    string -> string *)
let quote_string s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '\'';
  String.iter (fun c -> Buffer.add_string buffer (print_escape c)) s;
  Buffer.add_char buffer '\'';
  Buffer.contents buffer

(** e as Python source text, parenthesized if its precedence is below
    min_prec. pyexpr -> int -> string *)
let rec pprint_py_expr ?(min_prec = 0) e =
  let at prec e = pprint_py_expr ~min_prec:prec e in
  let binary prec operand_prec right_prec left spelling right =
    parens prec min_prec
      (Printf.sprintf "%s %s %s" (at operand_prec left) spelling
         (at right_prec right))
  in
  match e with
  | PyInt (_, v) -> string_of_int v
  (* Python reads back every text Builtin.float_text writes but three:
     it spells the two infinities and a NaN as calls. *)
  | PyFloat (_, v) ->
      if v <> v then "float('nan')"
      else if v = infinity then "float('inf')"
      else if v = neg_infinity then "float('-inf')"
      else Builtin.float_text v
  | PyString (_, s) -> quote_string s
  | PyBool (_, v) -> if v then "True" else "False"
  | PyVar (_, name) -> name
  | PyAttr (_, target, name) ->
      Printf.sprintf "%s.%s" (at call_prec target) name
  | PySlice (_, target, start, stop) ->
      Printf.sprintf "%s[%s:%s]" (at call_prec target)
        (match start with None -> "" | Some e -> pprint_py_expr e)
        (match stop with None -> "" | Some e -> pprint_py_expr e)
  | PyIndex (_, target, index) ->
      Printf.sprintf "%s[%s]" (at call_prec target) (pprint_py_expr index)
  (* `and` binds looser than everything built here, so it takes the
     lowest level and its operands are parenthesized where they need to
     be by the rule above. *)
  | PyAnd (_, l, r) -> binary and_prec and_prec (and_prec + 1) l "and" r
  | PyAdd (_, l, r) -> binary 2 2 3 l "+" r
  | PySub (_, l, r) -> binary 2 2 3 l "-" r
  | PyMul (_, l, r) -> binary 3 3 4 l "*" r
  | PyFloorDiv (_, l, r) -> binary 3 3 4 l "//" r
  | PyNeg (_, operand) ->
      (* Python's unary minus binds tighter than `*`/`/` too, so the
         same precedences as Pyking's ENeg apply: 4 for itself, 5 for
         its operand. *)
      parens 4 min_prec (Printf.sprintf "-%s" (at 5 operand))
  | PyLessThan (_, l, r) -> binary 1 2 2 l "<" r
  | PyLessThanEq (_, l, r) -> binary 1 2 2 l "<=" r
  | PyGreatThan (_, l, r) -> binary 1 2 2 l ">" r
  | PyGreatThanEq (_, l, r) -> binary 1 2 2 l ">=" r
  | PyEq (_, l, r) -> binary 1 2 2 l "==" r
  | PyCall (_, f, args) ->
      (* The callee prints at 5 so a negated one keeps its parens:
         `(-f)(x)` calls the negation, `-f(x)` negates the result. *)
      Printf.sprintf "%s(%s)" (at 5 f)
        (String.concat ", " (List.map (fun a -> pprint_py_expr a) args))
  | PyList (_, elements) ->
      Printf.sprintf "[%s]"
        (String.concat ", " (List.map (fun e -> pprint_py_expr e) elements))
  | PyTuple (_, elements) -> (
      match elements with
      | [ single ] -> Printf.sprintf "(%s,)" (pprint_py_expr single)
      | elements ->
          Printf.sprintf "(%s)"
            (String.concat ", " (List.map (fun e -> pprint_py_expr e) elements)))
  | PyListComp (_, e, clauses) ->
      Printf.sprintf "[%s %s]" (pprint_py_expr e)
        (String.concat " " (List.map pprint_py_comp_clause clauses))
  | PyIfExp (_, cond, then_expr, else_expr) ->
      (* Python's conditional expression binds looser than every
         operator here, so precedence 0 -- as an operand of anything it
         gets parenthesized. `then_expr`/`cond` print at 1 so a nested
         conditional there is parenthesized; the else branch prints at
         0, keeping a right-associative `else ... if ... else` chain
         flat, exactly as Python itself associates it. *)
      parens 0 min_prec
        (Printf.sprintf "%s if %s else %s" (at 1 then_expr) (at 1 cond)
           (pprint_py_expr else_expr))

(** c as Python source text. pycompclause -> string *)
and pprint_py_comp_clause c =
  (* min_prec 1 forces parens around a PyIfExp: Python's comprehension
     grammar excludes a bare conditional expression after `in`/`if`. *)
  match c with
  | PyCompFor (_, target, sequence) ->
      Printf.sprintf "for %s in %s" (pprint_py_target target)
        (pprint_py_expr ~min_prec:1 sequence)
  | PyCompIf (_, condition) ->
      Printf.sprintf "if %s" (pprint_py_expr ~min_prec:1 condition)

(** t as Python source text. pytarget -> string *)
and pprint_py_target t =
  match t with
  | PyTargetName (_, name) -> name
  | PyTargetTuple (_, elements) -> (
      match elements with
      | [ single ] -> Printf.sprintf "(%s,)" (pprint_py_target single)
      | elements ->
          Printf.sprintf "(%s)"
            (String.concat ", " (List.map pprint_py_target elements)))

(** p as Python source text. pypattern -> string *)
let rec pprint_py_pattern p =
  match p with
  | PyPInt (_, v) -> string_of_int v
  | PyPString (_, s) -> quote_string s
  (* True/False are value patterns to Python's match (PEP 634). *)
  | PyPBool (_, v) -> if v then "True" else "False"
  | PyPWildcard _ -> "_"
  | PyPCapture (_, name) -> name
  (* `str() as name`: the class test is what makes the guard below it
     safe to run on any subject. *)
  | PyPGuarded (_, name, _, _) -> Printf.sprintf "str() as %s" name
  | PyPTuple (_, elements) -> (
      match elements with
      | [ single ] -> Printf.sprintf "(%s,)" (pprint_py_pattern single)
      | elements ->
          Printf.sprintf "(%s)"
            (String.concat ", " (List.map pprint_py_pattern elements)))
  | PyPList (_, prefix, rest, suffix) ->
      let parts = List.map pprint_py_pattern prefix in
      let parts =
        parts
        @ (match rest with
          | None -> []
          | Some (PyListRest (_, Some name)) -> [ "*" ^ name ]
          | Some (PyListRest (_, None)) -> [ "*_" ])
        @ List.map pprint_py_pattern suffix
      in
      Printf.sprintf "[%s]" (String.concat ", " parts)

(** Renders a statement list as source lines, with a blank line around
    each nested def (never at the block's own start or end).
    [pystmt] -> int -> [string] *)
let rec render_block stmts level =
  let is_def s = match s with PyFunctionDef _ -> true | _ -> false in
  let lines, _, _ =
    List.fold_left
      (fun (lines, index, prev_was_def) s ->
        let lines =
          if index > 0 && (is_def s || prev_was_def) then lines @ [ "" ] else lines
        in
        (lines @ [ pprint_py_stmt ~level s ], index + 1, is_def s))
      ([], 0, false) stmts
  in
  lines

(** s as Python source text, indented to level. pystmt -> int -> string *)
and pprint_py_stmt ?(level = 0) s =
  let pad = String.concat "" (List.init level (fun _ -> "    ")) in
  match s with
  | PyAssign (_, target, e) ->
      Printf.sprintf "%s%s = %s" pad (pprint_py_target target) (pprint_py_expr e)
  | PyReturn (_, e) -> Printf.sprintf "%sreturn %s" pad (pprint_py_expr e)
  | PyExprStmt (_, e) -> Printf.sprintf "%s%s" pad (pprint_py_expr e)
  | PyImport (_, module_, alias) -> (
      match alias with
      | None -> Printf.sprintf "%simport %s" pad module_
      | Some alias -> Printf.sprintf "%simport %s as %s" pad module_ alias)
  | PyFromImport (_, module_, fields) ->
      Printf.sprintf "%sfrom %s import %s" pad module_
        (String.concat ", "
           (List.map
              (fun (name, local) ->
                if name = local then name
                else Printf.sprintf "%s as %s" name local)
              fields))
  | PyGlobal (_, names) ->
      Printf.sprintf "%sglobal %s" pad (String.concat ", " names)
  | PyNonlocal (_, names) ->
      Printf.sprintf "%snonlocal %s" pad (String.concat ", " names)
  | PyFor (_, name, iterable, body, orelse) ->
      let lines =
        [ Printf.sprintf "%sfor %s in %s:" pad name (pprint_py_expr iterable) ]
        @ render_block body (level + 1)
      in
      let lines =
        match orelse with
        | Some (_ :: _ as orelse) ->
            lines @ [ pad ^ "else:" ] @ render_block orelse (level + 1)
        | _ -> lines
      in
      String.concat "\n" lines
  | PyWhile (_, cond, body, orelse) ->
      let lines =
        [ Printf.sprintf "%swhile %s:" pad (pprint_py_expr cond) ]
        @ render_block body (level + 1)
      in
      let lines =
        match orelse with
        | Some (_ :: _ as orelse) ->
            lines @ [ pad ^ "else:" ] @ render_block orelse (level + 1)
        | _ -> lines
      in
      String.concat "\n" lines
  | PyBreak _ -> pad ^ "break"
  | PyContinue _ -> pad ^ "continue"
  | PyIf (_, cond, then_body, else_body) ->
      let lines =
        [ Printf.sprintf "%sif %s:" pad (pprint_py_expr cond) ]
        @ render_block then_body (level + 1)
      in
      (* An else body of exactly one if prints as elif, flattening an
         else-if ladder instead of nesting one indent per branch. *)
      let rec ladder lines else_body =
        match else_body with
        | Some [ PyIf (_, elif_cond, elif_body, else_body2) ] ->
            ladder
              (lines
              @ [ Printf.sprintf "%selif %s:" pad (pprint_py_expr elif_cond) ]
              @ render_block elif_body (level + 1))
              else_body2
        | None -> lines
        | Some else_body ->
            lines @ [ pad ^ "else:" ] @ render_block else_body (level + 1)
      in
      String.concat "\n" (ladder lines else_body)
  | PyFunctionDef (_, name, params, body) ->
      String.concat "\n"
        ([ Printf.sprintf "%sdef %s(%s):" pad name (String.concat ", " params) ]
        @ render_block body (level + 1))
  | PyMatch (_, subject, cases) ->
      String.concat "\n"
        ([ Printf.sprintf "%smatch %s:" pad (pprint_py_expr subject) ]
        @ List.concat_map
            (fun (PyMatchCase (_, pattern, body, guard)) ->
              (Printf.sprintf "%s    case %s%s:" pad (pprint_py_pattern pattern)
                 (match guard with
                 | None -> ""
                 | Some guard -> " if " ^ pprint_py_expr guard)
              :: render_block body (level + 2)))
            cases)

(* Markers around the prelude, separating host boilerplate from the
   translated source (docs/target_python.md, "Booleans"). *)
let prelude_begin = "# --- prelude begins ---"

(* The note belongs to the Bool walker rather than to the prelude, which
   may also hold the division helper or the by-path module loader. It is
   printed only where that walker is. *)
let prelude_format_note =
  String.concat "\n"
    [
      "# Pyking prints a Bool as `true`/`false`, not Python's own capitalised";
      "# `True`/`False`, wherever it sits -- on its own, or inside a list or";
      "# a tuple. This helper exists because at least one value printed below";
      "# isn't provably free of Bools from its Pyking source form alone (a";
      "# variable, a call, or a container), so it is walked at runtime.";
    ]

let prelude_end = "# --- prelude ends; the compiled program follows ---"

(** The name of the Float division helper that goes with a Float
    formatter called `name`. string -> string *)
let float_divide_helper name =
  "__pyk_fdiv" ^ String.sub name (String.length "__pyk_float")
                   (String.length name - String.length "__pyk_float")

(** builtin.ml's rule, in Python, and the division that goes with it.
    Python's own `repr` follows the same thresholds but writes the
    exponent with a sign and a leading zero, so the digits are found
    here rather than read off it; and Python raises where IEEE answers,
    so dividing by zero is spelled out. string -> string *)
let float_helper_def name =
  String.concat "\n"
    [
      Printf.sprintf "def %s(a, b):" (float_divide_helper name);
      "    if b == 0.0:";
      "        # Python raises where IEEE answers. Pyking follows IEEE.";
      "        if a != a or a == 0.0:";
      "            return float('nan')";
      "        below = (a < 0.0) != (repr(b)[0] == '-')";
      "        return float('-inf') if below else float('inf')";
      "    return a / b";
      "";
      "";
      Printf.sprintf "def %s(x):" name;
      "    if x != x:";
      "        return 'nan'";
      "    if x == float('inf'):";
      "        return 'inf'";
      "    if x == float('-inf'):";
      "        return '-inf'";
      "    if x == 0.0:";
      "        # The two zeros compare equal; repr tells them apart.";
      "        return '-0.0' if repr(x)[0] == '-' else '0.0'";
      "    sign = '-' if x < 0.0 else ''";
      "    a = abs(x)";
      "    p = 0";
      "    while p < 16:";
      "        s = '%.*e' % (p, a)";
      "        if float(s) == a:";
      "            break";
      "        p = p + 1";
      "    else:";
      "        s = '%.*e' % (16, a)";
      "    at = s.index('e')";
      "    digits = s[:at].replace('.', '')";
      "    decpt = int(s[at + 1:]) + 1";
      "    digits = digits.rstrip('0') or '0'";
      "    n = len(digits)";
      "    if decpt <= -4 or decpt > 16:";
      "        mantissa = digits if n == 1 else digits[0] + '.' + digits[1:]";
      "        return sign + mantissa + 'e' + str(decpt - 1)";
      "    if decpt <= 0:";
      "        return sign + '0.' + '0' * (-decpt) + digits";
      "    if decpt >= n:";
      "        return sign + digits + '0' * (decpt - n) + '.0'";
      "    return sign + digits[:decpt] + '.' + digits[decpt:]";
    ]

(** program as Python source text. pyprogram -> string *)
let pprint_py_program program =
  let body = String.concat "\n" (render_block program.stmts 0) in
  if program.prelude = [] && not program.floats then body
  else
    let rendered = render_block program.prelude 0 in
    (* The Float formatter is a fixed block of host text, like every
       other backend's, rather than a tree built out of Py* nodes. *)
    let rendered =
      if program.floats then
        rendered @ (if rendered = [] then [] else [ "" ])
        @ [ float_helper_def program.float_helper ]
      else rendered
    in
    let prelude_body = String.concat "\n" rendered in
    let opening =
      if program.formats then [ prelude_begin; prelude_format_note ]
      else [ prelude_begin ]
    in
    String.concat "\n"
      (opening @ [ ""; prelude_body; ""; prelude_end; ""; body ])

(* --- translation: Pyking AST (syntax.ml) -> Python target AST ---

   Refutable comprehension patterns compile to a generated `__pm*`
   helper; see docs/target_python.md, "List comprehensions with
   refutable patterns". *)

module SMap = Map.Make (String)

(** What the translation accumulates as it runs, threaded through it as
    a value: the identifiers the source already uses (so a generated
    name can avoid all of them), the checker's symbol -> type table
    (which is what decides how a print argument is formatted), the
    counters that name the generated helpers, and the helpers
    themselves. It is threaded through the translation rather than
    held anywhere, so nothing has to be reset between programs. *)
type gen = {
  used : StringSet.t;
  types : typ IntMap.t;
  comp_counter : int;
  turn_counter : int;
  pending : pystmt list;
  format_helper : string option;
  format_def : pystmt option;
  floats : bool;  (* whether any type in this module holds a Float *)
  float_name : string;  (* what the Float formatter is called *)
  divide_def : pystmt option;
  import_def : pystmt option;
  (* Which of each module's names the target's own source provides, and
     which modules have no Pyking half at all. A qualified name reaches
     the implementation where the field is one of the first. *)
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

(** Every identifier used anywhere in a program: what a generated name
    has to avoid. [stmt] -> StringSet.t *)
let collect_identifiers stmts =
  Walk.fold_stmts
    (fun found node ->
      match Walk.name_field node with
      | Some name -> StringSet.add name found
      | None -> found)
    StringSet.empty stmts

(** Every identifier an import puts in play that the walk above does not
    see: a module's own name, which is not held in a field named `name`,
    and the local names of a `from` line, which are the second half of a
    pair. [stmt] -> StringSet.t *)
let import_identifiers stmts =
  Walk.fold_stmts
    (fun found node ->
      match node with
      | Walk.NStmt (SImport (_, module_name, _, _, fields, _)) ->
          List.fold_left
            (fun found (_, local) -> StringSet.add local found)
            (StringSet.add module_name found)
            fields
      | Walk.NExpr (EQualified (_, module_name, _, _)) ->
          StringSet.add module_name found
      | _ -> found)
    StringSet.empty stmts

(** A fresh (item_var, helper_name) pair for one refutable comprehension
    clause, e.g. ("item1", "__pm1"), guaranteed not to collide with any
    source identifier. gen -> (string, string, gen) *)
let fresh_comp_names gen =
  let rec go counter =
    let item = Printf.sprintf "item%d" counter in
    let helper = Printf.sprintf "__pm%d" counter in
    if StringSet.mem item gen.used || StringSet.mem helper gen.used then
      go (counter + 1)
    else (item, helper, { gen with comp_counter = counter })
  in
  go (gen.comp_counter + 1)

(** A fresh name for a per-iteration factory (`__pyk_turn1`), guaranteed
    not to collide with any source identifier. gen -> (string, gen) *)
let fresh_turn_name gen =
  let rec go counter =
    let name = Printf.sprintf "__pyk_turn%d" counter in
    if StringSet.mem name gen.used then go (counter + 1)
    else (name, { gen with turn_counter = counter })
  in
  go (gen.turn_counter + 1)

(** The names pattern would bind, in order. pattern -> [string] *)
let rec pattern_captured_names pattern =
  match pattern with
  | PCapture (_, name, _) -> [ name ]
  | PTuple (_, elements, _) -> List.concat_map pattern_captured_names elements
  | PText (_, _, name, _, _) -> (
      match name with None -> [] | Some name -> [ name ])
  | PList (_, prefix, rest, suffix, _) ->
      List.concat_map pattern_captured_names prefix
      @ (match rest with
        | Some (ListRest (_, Some name, _)) -> [ name ]
        | _ -> [])
      @ List.concat_map pattern_captured_names suffix
  | _ -> []

(** Whether pattern matches every value it could be given -- names, `_`,
    and tuples built from those -- so it needs no match helper in a
    comprehension. pattern -> bool *)
let rec is_irrefutable pattern =
  match pattern with
  | PCapture _ | PWildcard _ -> true
  | PTuple (_, elements, _) -> List.for_all is_irrefutable elements
  | _ -> false

(* --- scopes and renaming ---

   Pyking blocks are scopes; Python's are not. A binding is renamed only
   when it would otherwise be confused with a live one in the same
   Python function scope. See docs/target_python.md, "Blocks are scopes;
   Python's are not". *)

(** The names in scope during translation.
    outer -- Pyking name -> Python name, from enclosing Python function
      scopes.
    local -- the same, for the current Python function scope.
    block -- names bound by the innermost Pyking block.
    shadowed -- outer names this Python scope reads (see `free_names`).
    captured -- names functions defined in this scope read from around
      them (see `captured_names`).
    loop_names -- names the nearest enclosing loop rebinds each turn, or
      None outside a loop.
    depth -- how many Python function scopes deep this is; 0 is the
      module.
    mutables -- each `var` in scope, and the depth its declaration sits
      at, which is what decides `global` from `nonlocal`.
    used -- every Python name handed out by an enclosing block of this
      Python function scope; `local` keeps only the newest name per
      Pyking name, so this is what remembers the ones a shadow
      replaced. *)
type scope = {
  outer : string SMap.t;
  local : string SMap.t;
  block : StringSet.t;
  shadowed : StringSet.t;
  captured : StringSet.t;
  loop_names : StringSet.t option;
  depth : int;
  mutables : int SMap.t;
  used : StringSet.t;
}

let empty_scope =
  {
    outer = SMap.empty;
    local = SMap.empty;
    block = StringSet.empty;
    shadowed = StringSet.empty;
    captured = StringSet.empty;
    loop_names = None;
    depth = 0;
    mutables = SMap.empty;
    used = StringSet.empty;
  }

(** The scope for a `def` body or a comprehension: Python opens a fresh
    scope there, so everything visible so far becomes closure state and
    nothing inside it can collide with anything outside.

    `shadowed` is what the body reads from *outside* itself (see
    `free_names`), and so what it may not quietly rebind -- see `bind`.
    `captured` is what the functions *inside* it read from around them.
    scope -> StringSet.t -> StringSet.t -> scope *)
let function_scope scope shadowed captured =
  (* `loop_names` is deliberately dropped: a body's own bindings are per
     *call*, and what it captures from a loop around it was settled
     where the `def` was written. *)
  {
    outer = SMap.union (fun _ _ inner -> Some inner) scope.outer scope.local;
    local = SMap.empty;
    block = StringSet.empty;
    shadowed;
    captured;
    loop_names = None;
    depth = scope.depth + 1;
    mutables = scope.mutables;
    used = StringSet.empty;
  }

(** The scope for a nested Pyking block: the same Python function scope
    -- which is exactly why bindings inside it may need renaming -- but
    its own set of block-local names, and its bindings are dropped when
    the caller keeps using its own scope. scope -> scope *)
let block_scope scope =
  {
    scope with
    block = StringSet.empty;
    (* `used` is inherited rather than reset: a name this block hands
       out must miss every one an enclosing block is still using. It
       deliberately does not travel back out, so two *sibling* blocks
       may reuse a name -- nothing reads the first one once it ends. *)
  }

(** The scope for a loop body: a block scope that also tracks names
    bound afresh each turn (docs/target_python.md, "A def inside a
    loop"). scope -> scope *)
let loop_scope scope =
  let block = block_scope scope in
  {
    block with
    loop_names = Some (Option.value scope.loop_names ~default:StringSet.empty);
  }

(** Whether the program itself binds name, rather than it being a
    builtin passed through untouched. string -> scope -> bool *)
let is_bound name scope =
  SMap.mem name scope.local || SMap.mem name scope.outer

(** The Python name a Pyking name reads as; a name bound nowhere is a
    builtin and passes through unchanged. string -> scope -> string *)
let lookup name scope =
  match SMap.find_opt name scope.local with
  | Some found -> found
  | None -> ( match SMap.find_opt name scope.outer with Some found -> found | None -> name)

(* Legal Pyking identifiers that are reserved words in Python (see
   docs/target_python.md, "Names that are keywords in Python"):
   `keyword.kwlist` and `keyword.softkwlist`, written out since nothing
   here can ask Python. *)
let reserved =
  List.fold_left
    (fun set name -> StringSet.add name set)
    StringSet.empty
    [
      "False"; "None"; "True"; "and"; "as"; "assert"; "async"; "await";
      "break"; "class"; "continue"; "def"; "del"; "elif"; "else"; "except";
      "finally"; "for"; "from"; "global"; "if"; "import"; "in"; "is";
      "lambda"; "nonlocal"; "not"; "or"; "pass"; "raise"; "return"; "try";
      "while"; "with"; "yield"; "_"; "case"; "match"; "type";
    ]

(** name2, or name3, ... -- the first not already used, as a Python name
    or a Pyking one, anywhere in scope. string -> scope -> string *)
let fresh_py_name name scope =
  let add_keys map set = SMap.fold (fun key _ set -> StringSet.add key set) map set in
  let add_values map set =
    SMap.fold (fun _ value set -> StringSet.add value set) map set
  in
  let taken =
    add_values scope.outer
      (add_keys scope.outer
         (add_values scope.local (add_keys scope.local scope.used)))
  in
  let rec go n =
    let candidate = Printf.sprintf "%s%d" name n in
    if StringSet.mem candidate taken || StringSet.mem candidate reserved then
      go (n + 1)
    else candidate
  in
  go 2

(** Binds a Pyking name, renaming only where it would otherwise land on
    a Python name still live in this function scope
    (docs/target_python.md, "Blocks are scopes; Python's are not").
    `rebinding` marks a value binding (`=` or `var`) that may reuse this
    block's own prior binding of name, unless a function already
    captured it; `mutable_` marks a `var`, whose declaring depth is what
    later decides `global` from `nonlocal`.
    string -> scope -> bool -> bool -> bool -> (string, scope) *)
let bind ?(rebinding = false) ?(loop_carried = true) ?(mutable_ = false) name
    scope =
  if StringSet.mem name scope.block && not (rebinding && StringSet.mem name scope.captured)
  then (SMap.find name scope.local, scope)
  else
    let py_name =
      if
        StringSet.mem name reserved
        || SMap.mem name scope.local
        || SMap.exists (fun _ value -> value = name) scope.local
        || StringSet.mem name scope.used
        || StringSet.mem name scope.shadowed
      then fresh_py_name name scope
      else name
    in
    ( py_name,
      {
        scope with
        local = SMap.add name py_name scope.local;
        block = StringSet.add name scope.block;
        (* Inside a loop, this name is bound afresh on every turn --
           unless it is a `var`, which is one location whatever the loop
           does with it. *)
        loop_names =
          (match scope.loop_names with
          | None -> None
          | Some names ->
              Some
                (if loop_carried then StringSet.add name names
                 else StringSet.remove name names));
        (* A `var` records where it was declared; anything else of that
           name is no longer a cell, so it drops out. *)
        mutables =
          (if mutable_ then SMap.add name scope.depth scope.mutables
           else SMap.remove name scope.mutables);
        used = StringSet.add py_name scope.used;
      } )

(** An irrefutable pattern compiled directly to a Python
    assignment/for target. pattern -> scope -> (pytarget, scope) *)
let rec pattern_to_target pattern scope =
  match pattern with
  | PCapture (info, name, _) ->
      let py_name, scope = bind name scope in
      (PyTargetName (info, py_name), scope)
  | PWildcard (info, _) -> (PyTargetName (info, "_"), scope)
  | PTuple (info, elements, _) ->
      let py_elements, scope =
        List.fold_left
          (fun (out, scope) element ->
            let py_element, scope = pattern_to_target element scope in
            (out @ [ py_element ], scope))
          ([], scope) elements
      in
      (PyTargetTuple (info, py_elements), scope)
  | _ -> (PyTargetName (pattern_info pattern, "_"), scope)

(** The names an assignment target binds. assign_target -> [string] *)
let rec target_names target =
  match target with
  | TargetName (_, name, _) -> [ name ]
  | TargetTuple (_, elements, _) -> List.concat_map target_names elements

(* --- what a body reads from outside itself ---

   Any binding inside a Python function makes that name local to the
   whole function, so a block that shadows a name the rest of the
   function still reads cannot keep the plain name either. See
   docs/target_python.md, "Blocks are scopes; Python's are not". *)

let set_of names =
  List.fold_left (fun set name -> StringSet.add name set) StringSet.empty names

(** Adds e's free names to free. expr -> StringSet.t -> StringSet.t
    -> StringSet.t *)
let rec free_in_expr e bound free =
  match e with
  | EVar (_, name, _) -> if StringSet.mem name bound then free else StringSet.add name free
  | EQualified (_, module_name, _, _) ->
      (* What the name reaches is another module's; what is free here is
         the module itself, which the top level bound. *)
      if StringSet.mem module_name bound then free
      else StringSet.add module_name free
  | EInt _ | EString _ | EBool _ -> free
  | ENeg (_, operand, _) -> free_in_expr operand bound free
  | ECall (_, func, args, _) ->
      List.fold_left
        (fun free arg -> free_in_expr arg bound free)
        (free_in_expr func bound free) (arg_exprs args)
  | EList (_, elements, _) | ETuple (_, elements, _) ->
      List.fold_left (fun free e -> free_in_expr e bound free) free elements
  | EIf (_, cond, then_expr, else_expr, _) ->
      List.fold_left
        (fun free e -> free_in_expr e bound free)
        free [ cond; then_expr; else_expr ]
  | EListComp (_, e, clauses, _) ->
      (* A comprehension is its own scope: each `for` binds for the
         clauses after it and for the element expression. *)
      let comp_bound, free =
        List.fold_left
          (fun (comp_bound, free) clause ->
            match clause with
            | CompFor (_, pattern, sequence, _) ->
                ( StringSet.union comp_bound
                    (set_of (pattern_captured_names pattern)),
                  free_in_expr sequence comp_bound free )
            | CompIf (_, condition, _) ->
                (comp_bound, free_in_expr condition comp_bound free))
          (bound, free) clauses
      in
      free_in_expr e comp_bound free
  | e -> (
      match Interpreter.binary_operands e with
      | Some (left, right) -> free_in_expr right bound (free_in_expr left bound free)
      | None -> free)

(** Walks one block, adding to free and extending bound as the block's
    own bindings appear. [stmt] -> StringSet.t -> StringSet.t
    -> StringSet.t *)
and free_in_block stmts bound free =
  (* Every `def` in the block is in scope throughout it (see
     `declare_functions`), so they are bound before anything is
     walked. *)
  let bound =
    List.fold_left
      (fun bound s ->
        match s with
        | SFunctionDef (_, name, _, _, _, _, _) -> StringSet.add name bound
        | _ -> bound)
      bound stmts
  in
  snd
    (List.fold_left
       (fun (bound, free) s -> free_in_stmt s bound free)
       (bound, free) stmts)

(** A nested block: sees bound; what it binds does not escape.
    [stmt] -> StringSet.t -> StringSet.t -> StringSet.t *)
and free_in_nested stmts bound free = free_in_block stmts bound free

(** Adds s's free names to free, and answers the bound set it leaves.
    stmt -> StringSet.t -> StringSet.t -> (StringSet.t, StringSet.t) *)
and free_in_stmt s bound free =
  match s with
  | SLet (_, target, e, _, _, _) ->
      let free = free_in_expr e bound free in
      (StringSet.union bound (set_of (target_names target)), free)
  | SLetStmt (_, target, inner, _, _, _) ->
      let _, free = free_in_stmt inner bound free in
      (StringSet.union bound (set_of (target_names target)), free)
  | SVar (_, name, e, _) ->
      let free = free_in_expr e bound free in
      (StringSet.add name bound, free)
  | SMutate (_, name, e, _) ->
      (* `:=` writes a `var` that is already in scope; it binds nothing,
         so an enclosing one stays what the name means. *)
      let free =
        if StringSet.mem name bound then free else StringSet.add name free
      in
      (bound, free_in_expr e bound free)
  | SReturn (_, e, _) | SExprStmt (_, e, _) -> (bound, free_in_expr e bound free)
  | SReturnStmt (_, inner, _) ->
      let _, free = free_in_stmt inner bound free in
      (bound, free)
  | SLoop (_, target, init, _, iterate, body, _) ->
      (* The initializer is read outside the loop; the accumulator is
         bound in the body and nowhere else. *)
      let inner, free =
        match target with
        | None -> (bound, free)
        | Some target ->
            let free =
              match init with
              | Some init -> free_in_expr init bound free
              | None -> free
            in
            (StringSet.union bound (set_of (target_names target)), free)
      in
      let free =
        match iterate with
        | Some (ForIn (_, name, sequence, _)) ->
            let free = free_in_expr sequence bound free in
            free_in_nested body (StringSet.add name inner) free
        | Some (WhileTest (_, condition, _)) ->
            let free = free_in_expr condition inner free in
            free_in_nested body inner free
        | None -> free_in_nested body inner free
      in
      (bound, free)
  | SBreak _ | SContinue _ -> (bound, free)
  | SIf (_, cond, then_body, else_body, _) ->
      let free = free_in_expr cond bound free in
      let free = free_in_nested then_body bound free in
      let free =
        match else_body with
        | None -> free
        | Some else_body -> free_in_nested else_body bound free
      in
      (bound, free)
  | SFunctionDef (_, name, params, body, _, _, _) ->
      let bound = StringSet.add name bound in
      let free =
        free_in_nested body
          (StringSet.union bound (set_of (List.map (fun (Param (_, n, _, _, _)) -> n) params)))
          free
      in
      (bound, free)
  | SMatch (_, subject, cases, _) ->
      let free = free_in_expr subject bound free in
      let free =
        List.fold_left
          (fun free (MatchCase (_, pattern, body, _)) ->
            free_in_nested body
              (StringSet.union bound (set_of (pattern_captured_names pattern)))
              free)
          free cases
      in
      (bound, free)
  | SImport _ | SFunctionSig _ -> (bound, free)

(** The names stmts read from outside themselves: every name used before
    stmts (or bound) has bound it. [stmt] -> StringSet.t -> StringSet.t *)
let free_names stmts bound = free_in_block stmts bound StringSet.empty

(** Adds to captured every name a function defined in stmts (or a nested
    block) reads from around it.
    [stmt] -> StringSet.t -> StringSet.t -> StringSet.t *)
let rec captured_in_block stmts bound captured =
  let bound =
    List.fold_left
      (fun bound s ->
        match s with
        | SFunctionDef (_, name, _, _, _, _, _) -> StringSet.add name bound
        | _ -> bound)
      bound stmts
  in
  List.fold_left
    (fun captured s ->
      match s with
      | SFunctionDef (_, name, params, body, _, _, _) ->
          let inner =
            StringSet.add name
              (set_of (List.map (fun (Param (_, n, _, _, _)) -> n) params))
          in
          (* A function nested inside this one is part of the same
             question one level down, and is reached when that body is
             translated. *)
          StringSet.union captured (free_names body inner)
      | SLoop (_, target, _, _, iterate, body, _) ->
          let inner =
            match target with
            | None -> bound
            | Some target ->
                StringSet.union bound (set_of (target_names target))
          in
          let inner =
            match iterate with
            | Some (ForIn (_, name, _, _)) -> StringSet.add name inner
            | _ -> inner
          in
          captured_in_block body inner captured
      | SIf (_, _, then_body, else_body, _) ->
          let captured = captured_in_block then_body bound captured in
          (match else_body with
          | None -> captured
          | Some else_body -> captured_in_block else_body bound captured)
      | SLetStmt (_, _, inner, _, _, _) | SReturnStmt (_, inner, _) ->
          captured_in_block [ inner ] bound captured
      | SMatch (_, _, cases, _) ->
          List.fold_left
            (fun captured (MatchCase (_, pattern, body, _)) ->
              captured_in_block body
                (StringSet.union bound (set_of (pattern_captured_names pattern)))
                captured)
            captured cases
      | _ -> captured)
    captured stmts

(** The names the functions defined anywhere in this Python function
    scope read from around them -- a rebinding of one of those names
    needs its own Python variable (docs/target_python.md, "A rebinding
    some function captured"). [stmt] -> StringSet.t -> StringSet.t *)
let captured_names stmts bound =
  captured_in_block stmts bound StringSet.empty

(* --- what a body writes to from outside itself ---

   Python makes any assigned name local to the whole function, so a
   `def` that writes a `var` bound outside it has to say so: `global`
   for one declared at the module level, `nonlocal` for one in an
   enclosing function. Every other backend needs nothing here --
   JavaScript closes over the binding, OCaml over the `ref` -- and C and
   Java refuse such a function outright, having no closures at all. See
   docs/target_python.md, "A `var` written from inside a function". *)

(** Adds to written and declared over one statement list.
    [stmt] -> (StringSet.t, StringSet.t) -> (StringSet.t, StringSet.t) *)
let rec mutated_in_block stmts state =
  List.fold_left
    (fun (written, declared) s ->
      match s with
      | SVar (_, name, _, _) -> (written, StringSet.add name declared)
      | SMutate (_, name, _, _) -> (StringSet.add name written, declared)
      | SIf (_, _, then_body, else_body, _) ->
          let state = mutated_in_block then_body (written, declared) in
          (match else_body with
          | None -> state
          | Some else_body -> mutated_in_block else_body state)
      | SLoop (_, _, _, _, _, body, _) ->
          mutated_in_block body (written, declared)
      | SMatch (_, _, cases, _) ->
          List.fold_left
            (fun state (MatchCase (_, _, body, _)) -> mutated_in_block body state)
            (written, declared) cases
      | SLetStmt (_, _, inner, _, _, _) | SReturnStmt (_, inner, _) ->
          mutated_in_block [ inner ] (written, declared)
      | _ -> (written, declared))
    state stmts

(** The names a body writes with `:=` and does not itself declare with
    `var`. The walk stops at a nested `def`: that body declares its own.
    [stmt] -> StringSet.t *)
let mutated_names stmts =
  let written, declared =
    mutated_in_block stmts (StringSet.empty, StringSet.empty)
  in
  StringSet.diff written declared

(** The `global`/`nonlocal` lines a function body needs for the names it
    writes: `global` for a `var` declared at the module level,
    `nonlocal` for one in an enclosing function. A name no `var` in
    scope owns gets neither -- analyses.ml has already refused a `:=`
    that names anything else.
    StringSet.t -> scope -> info -> [pystmt] *)
let scope_declarations names scope info =
  let outer, enclosing =
    List.fold_left
      (fun (outer, enclosing) name ->
        match SMap.find_opt name scope.mutables with
        | None -> (outer, enclosing)
        | Some 0 -> (outer @ [ lookup name scope ], enclosing)
        | Some _ -> (outer, enclosing @ [ lookup name scope ]))
      ([], []) (StringSet.elements names)
  in
  (if outer = [] then [] else [ PyGlobal (info, outer) ])
  @ if enclosing = [] then [] else [ PyNonlocal (info, enclosing) ]

(* --- the generated helpers --- *)

(** One character of a quoted string, escaped as Pyking escapes it: a
    chain of conditionals rather than a table, since the helper is built
    as Python's own AST. info -> pyexpr -> pyexpr *)
let escaped info char =
  let escapes =
    [ ("\\", "\\\\"); ("'", "\\'"); ("\n", "\\n"); ("\t", "\\t"); ("\r", "\\r") ]
  in
  List.fold_left
    (fun result (literal, escape) ->
      PyIfExp
        (info, PyEq (info, char, PyString (info, literal)), PyString (info, escape), result))
    char (List.rev escapes)

(* Module names CPython has built into the interpreter. `import time`
   finds the frozen `time` before any sibling `time.py`, and no
   `sys.path` order changes it: the builtin importer sits ahead of the
   path finder in `sys.meta_path`. A Pyking module with one of these
   names is loaded by path instead (`build_import_helper`).

   The list is a superset on purpose. Some of these are builtin only on
   some platforms, and loading a Pyking module by path is right whether
   or not the name would have collided -- so a name here that is not
   builtin costs a helper and nothing else. See
   docs/target_python.md, "Module names Python has already taken". *)
let shadowed_modules =
  [
    "array"; "atexit"; "binascii"; "builtins"; "cmath"; "errno";
    "faulthandler"; "fcntl"; "gc"; "grp"; "itertools"; "marshal"; "msvcrt";
    "nt"; "posix"; "pwd"; "pyexpat"; "select"; "sys"; "syslog"; "time";
    "unicodedata"; "winreg"; "zlib";
  ]

(** Whether Python has this module name already, so that an ordinary
    `import` of it could never reach the file beside the program.
    string -> bool *)
let shadowed name = List.mem name shadowed_modules

let import_helper = "__pyk_import"

(** What a shadowed module is bound to before its fields are taken off
    it: a `from` line needs the module itself somewhere, and loading it
    once per field would run its top level once per field.
    string -> string *)
let shadowed_binding module_ = Printf.sprintf "__pyk_mod_%s" module_

(** Synthesizes the loader a module whose name Python has built in
     needs. Emitted only where a program imports such a name, the way
    every other helper here is. info -> pystmt *)
let build_import_helper info =
  let var n = PyVar (info, n) in
  let call f args = PyCall (info, f, args) in
  let attr e n = PyAttr (info, e, n) in
  let path =
    call (var "join")
      [
        call (var "dirname") [ call (var "abspath") [ var "__file__" ] ];
        PyAdd (info, var "name", PyString (info, ".py"));
      ]
  in
  PyFunctionDef
    ( info,
      import_helper,
      [ "name" ],
      [
        PyFromImport
          ( info,
            "importlib.util",
            [
              ("module_from_spec", "module_from_spec");
              ("spec_from_file_location", "spec_from_file_location");
            ] );
        PyFromImport
          ( info,
            "os.path",
            [ ("abspath", "abspath"); ("dirname", "dirname"); ("join", "join") ]
          );
        PyAssign
          ( info,
            PyTargetName (info, "spec"),
            call (var "spec_from_file_location") [ var "name"; path ] );
        PyAssign
          ( info,
            PyTargetName (info, "module"),
            call (var "module_from_spec") [ var "spec" ] );
        PyExprStmt
          ( info,
            call (attr (attr (var "spec") "loader") "exec_module") [ var "module" ]
          );
        PyReturn (info, var "module");
      ] )

let divide_helper = "__pyk_div"

(** Synthesizes Pyking's `/`: integer division truncating toward zero.
    Python's `//` rounds down instead, so the two differ whenever
    exactly one operand is negative -- `-7 // 2` is -4 where every
    Pyking backend gives -3. Division by zero is left to Python, as it
    is left to each host (docs/targets.md). info -> pystmt *)
let build_divide_helper info =
  let var n = PyVar (info, n) in
  let size =
    PyFloorDiv
      ( info,
        PyCall (info, var "abs", [ var "a" ]),
        PyCall (info, var "abs", [ var "b" ]) )
  in
  let same_sign =
    PyEq
      ( info,
        PyLessThan (info, var "a", PyInt (info, 0)),
        PyLessThan (info, var "b", PyInt (info, 0)) )
  in
  PyFunctionDef
    ( info,
      divide_helper,
      [ "a"; "b" ],
      [
        PyAssign (info, PyTargetName (info, "q"), size);
        PyReturn (info, PyIfExp (info, same_sign, var "q", PyNeg (info, var "q")));
      ] )

(** Synthesizes the closure-free formatter Pyking's print needs: a Bool
    spelled `true`/`false` wherever it sits, including inside a list or
    a tuple, which is why this walks a value instead of merely testing
    it. Everything else is left to Python's own spelling, which already
    agrees (builtin.ml's rules). info -> string -> string? -> pystmt *)
let build_format_helper info name floats =
  let var n = PyVar (info, n) in
  let text s = PyString (info, s) in
  let call fn args = PyCall (info, var fn, args) in
  let isa value type_name = call "isinstance" [ value; var type_name ] in
  let joined parts =
    match parts with
    | [] -> text ""
    | first :: rest ->
        List.fold_left (fun result part -> PyAdd (info, result, part)) first rest
  in
  let v, top, out, element = (var "v", var "top", var "out", var "e") in
  let inner = PyCall (info, var name, [ element; PyBool (info, false) ]) in
  (* out = out + (', ' if out != '' else '') + <the element> *)
  let step =
    PyAssign
      ( info,
        PyTargetName (info, "out"),
        joined
          [
            out;
            PyIfExp (info, PyEq (info, out, text ""), text "", text ", ");
            inner;
          ] )
  in
  let body =
    [
      (* A Bool is the whole point of the helper. *)
      PyIf
        ( info,
          isa v "bool",
          [ PyReturn (info, PyIfExp (info, v, text "true", text "false")) ],
          None );
    ]
    (* A Float, where a module has one at all: Python's own spelling of
       a double is not Pyking's. The arm is left out otherwise, so a
       program with no Float carries no Float formatter. *)
    @ (match floats with
      | None -> []
      | Some float_name ->
          [
            PyIf
              ( info,
                isa v "float",
                [ PyReturn (info, call float_name [ v ]) ],
                None );
          ])
    @ [
      (* A string prints bare on its own and quoted inside something --
         quoted the way Pyking quotes, which is not always the way
         Python's own repr does. *)
      PyIf
        ( info,
          isa v "str",
          [
            PyIf (info, top, [ PyReturn (info, v) ], None);
            PyAssign (info, PyTargetName (info, "out"), text "'");
            PyFor
              ( info,
                "c",
                v,
                [
                  PyAssign
                    ( info,
                      PyTargetName (info, "out"),
                      PyAdd (info, out, escaped info (PyVar (info, "c"))) );
                ],
                None );
            PyReturn (info, PyAdd (info, out, text "'"));
          ],
          None );
      PyIf
        ( info,
          isa v "list",
          [
            PyAssign (info, PyTargetName (info, "out"), text "");
            PyFor (info, "e", v, [ step ], None);
            PyReturn (info, joined [ text "["; out; text "]" ]);
          ],
          None );
      PyIf
        ( info,
          isa v "tuple",
          [
            PyAssign (info, PyTargetName (info, "out"), text "");
            PyFor (info, "e", v, [ step ], None);
            (* The singleton keeps the comma that tells it from a
               parenthesized value, exactly as Pyking writes it. *)
            PyIf
              ( info,
                PyEq (info, call "len" [ v ], PyInt (info, 1)),
                [ PyReturn (info, joined [ text "("; out; text ",)" ]) ],
                None );
            PyReturn (info, joined [ text "("; out; text ")" ]);
          ],
          None );
      PyReturn (info, call "str" [ v ]);
    ]
  in
  PyFunctionDef (info, name, [ "v"; "top" ], body)

(** The name of the print-formatting helper for a value that might hold
    a Bool at runtime and cannot be proven either way from its Pyking
    source form (docs/target_python.md, "Booleans"), building and
    recording it the first time this is called.
    info -> gen -> (string, gen) *)
let format_helper_name info gen =
  match gen.format_helper with
  | Some name -> (name, gen)
  | None ->
      let rec go n =
        let candidate =
          if n = 0 then "__pyk_str" else Printf.sprintf "__pyk_str%d" n
        in
        if StringSet.mem candidate gen.used then go (n + 1) else candidate
      in
      let name = go 0 in
      ( name,
        {
          gen with
          format_helper = Some name;
          format_def =
            Some
              (build_format_helper info name
                 (if gen.floats then Some gen.float_name else None));
        } )

(* Pyking's checker gives every expression a type, so whether a given
   expression holds a Bool is read straight off it -- `types`, keyed by
   symbol, which `translate_program` is handed. A `Bool` is spelled
   inline, anything with no `Bool` anywhere inside it is printed as
   Python already prints it, and only a value that really can hold one
   (a `[Bool]`, a `(Int, Bool)`, a type nothing has pinned down) needs
   the runtime walk. That is what keeps an ordinary program's output
   free of a prelude it has no use for. *)

(** Whether the checker settled this expression's type as Float, which
    is what picks Python's `/` over the truncating helper.
    expr -> gen -> bool *)
let is_float_expr e gen =
  match IntMap.find_opt (expr_sym e) gen.types with
  | Some (TFloat _) -> true
  | _ -> false

(** Whether a type is exactly Float, which is the one case a bare
    Python `str` gets wrong. typ option -> bool *)
let is_float_type type_ =
  match type_ with Some (TFloat _) -> true | _ -> false

(** Whether a Float sits anywhere inside a type -- what decides whether
    the runtime walker needs its Float arm at all. typ -> bool *)
let rec holds_float type_ =
  match type_ with
  | TFloat _ -> true
  | TList (_, element, _) -> holds_float element
  | TTuple (_, elements, _) -> List.exists holds_float elements
  | TFunction (_, params, result, _, _, _) ->
      List.exists holds_float params || holds_float result
  | TForall (_, _, body, _) -> holds_float body
  | _ -> false

(** "bool" for a Bool, "not-bool" for a type with no Bool anywhere
    inside it, "unknown" otherwise. typ option -> string *)
let rec bool_kind type_ =
  match type_ with
  | Some (TBool _) -> "bool"
  (* A variable nothing constrained is the element type of a list with
     no elements, so no Bool is ever formatted through it. A *rigid* one
     is a type the caller chose and could be anything, which falls
     through to "unknown". *)
  | Some (TInt _) | Some (TString _) | Some (TVar (_, _, _, false)) -> "not-bool"
  | Some (TList (_, element, _)) ->
      if bool_kind (Some element) = "not-bool" then "not-bool" else "unknown"
  | Some (TTuple (_, elements, _)) ->
      (* `()` is the zero-element tuple, and holds nothing at all. *)
      if List.for_all (fun e -> bool_kind (Some e) = "not-bool") elements then
        "not-bool"
      else "unknown"
  | _ -> "unknown"

(** Whether a String sits anywhere *inside* a list or tuple of this
    type. Such a string is quoted when it is printed, and Python's own
    `repr` picks its quotes for itself -- writing `["it's"]` where every
    other target writes `['it\\'s']` -- so the helper has to spell it
    instead. A String on its own is not one of these: it prints bare,
    which Python already agrees with. typ option -> bool -> bool *)
let rec nests_a_string type_ inside =
  match type_ with
  | Some (TString _) -> inside
  | Some (TList (_, element, _)) -> nests_a_string (Some element) true
  | Some (TTuple (_, elements, _)) ->
      List.exists (fun e -> nests_a_string (Some e) true) elements
  | _ -> false

(** `held[len(prefix):len(held) - len(suffix)]`, with either end left
    off where it is empty.
    info -> string -> string -> string -> pyexpr *)
let slice_middle info held prefix suffix =
  let start =
    if prefix = "" then None else Some (PyInt (info, String.length prefix))
  in
  let stop =
    if suffix = "" then None
    else
      Some
        (PySub
           ( info,
             PyCall (info, PyVar (info, "len"), [ PyVar (info, held) ]),
             PyInt (info, String.length suffix) ))
  in
  PySlice (info, PyVar (info, held), start, stop)

(** The PyPGuarded nodes inside a pattern, outermost first.
    pypattern -> [pypattern] *)
let rec guarded_in py_pattern =
  match py_pattern with
  | PyPGuarded _ -> [ py_pattern ]
  | PyPTuple (_, elements) -> List.concat_map guarded_in elements
  | PyPList (_, prefix, _, suffix) ->
      List.concat_map guarded_in (prefix @ suffix)
  | _ -> []

(** Every guard and binding a pattern carries, in source order: the
    guards joined with `and`, the bindings concatenated.
    pypattern -> (pyexpr option, [pystmt]) *)
let guarded_parts py_pattern =
  List.fold_left
    (fun (guard, bindings) found ->
      match found with
      | PyPGuarded (info, _, found_guard, found_bindings) ->
          let guard =
            match (guard, found_guard) with
            | _, None -> guard
            | None, Some found_guard -> Some found_guard
            | Some guard, Some found_guard -> Some (PyAnd (info, guard, found_guard))
          in
          (guard, bindings @ found_bindings)
      | _ -> (guard, bindings))
    (None, []) (guarded_in py_pattern)

(** One arm, with every guarded pattern's parts put where they belong:
    the tests joined onto the `case`, and the bindings they need at the
    top of the body. A guarded pattern may sit anywhere inside the arm's
    pattern -- `case ("a" ++ x, [n] ++ _)` has one nested in a tuple --
    and Python's guard covers the whole arm, which is what "every part
    matched" means. info -> pypattern -> [pystmt] -> pymatchcase *)
let match_case info py_pattern body =
  let guard, bindings = guarded_parts py_pattern in
  PyMatchCase (info, py_pattern, bindings @ body, guard)

(** Translates a pattern, answering it with the scope its captures
    extend. pattern -> scope -> (pypattern, scope) *)
let rec translate_pattern p scope =
  match p with
  | PInt (info, v, _) -> (PyPInt (info, v), scope)
  | PString (info, s, _) -> (PyPString (info, s), scope)
  | PBool (info, v, _) -> (PyPBool (info, v), scope)
  | PWildcard (info, _) -> (PyPWildcard info, scope)
  | PCapture (info, name, _) ->
      let py_name, scope = bind name scope in
      (PyPCapture (info, py_name), scope)
  | PTuple (info, elements, _) ->
      let py_elements, scope = translate_patterns elements scope in
      (PyPTuple (info, py_elements), scope)
  | PList (info, prefix, rest, suffix, _) ->
      let py_prefix, scope = translate_patterns prefix scope in
      let py_rest, scope =
        match rest with
        | None -> (None, scope)
        | Some (ListRest (rest_info, None, _)) ->
            (Some (PyListRest (rest_info, None)), scope)
        | Some (ListRest (rest_info, Some name, _)) ->
            let py_name, scope = bind name scope in
            (Some (PyListRest (rest_info, Some py_name)), scope)
      in
      let py_suffix, scope = translate_patterns suffix scope in
      (PyPList (info, py_prefix, py_rest, py_suffix), scope)
  | PText (info, prefix, name, suffix, _) ->
      (* Python's `match` cannot split a string, so the arm captures the
         whole and tests it: `case str() as t if t.startswith(...)`,
         with the middle sliced out at the top of the body. *)
      let held, scope = bind "__text" scope in
      let tests =
        (if prefix = "" then []
         else
           [
             PyCall
               ( info,
                 PyAttr (info, PyVar (info, held), "startswith"),
                 [ PyString (info, prefix) ] );
           ])
        @ (if suffix = "" then []
           else
             [
               PyCall
                 ( info,
                   PyAttr (info, PyVar (info, held), "endswith"),
                   [ PyString (info, suffix) ] );
             ])
        @
        if prefix <> "" && suffix <> "" then
          (* A prefix and a suffix that overlap would each match on their
             own; the length is what keeps them apart. *)
          [
            PyGreatThanEq
              ( info,
                PyCall (info, PyVar (info, "len"), [ PyVar (info, held) ]),
                PyInt (info, String.length prefix + String.length suffix) );
          ]
        else []
      in
      let guard =
        List.fold_left
          (fun guard test ->
            match guard with
            | None -> Some test
            | Some guard -> Some (PyAnd (info, guard, test)))
          None tests
      in
      let bindings, scope =
        match name with
        | None -> ([], scope)
        | Some name ->
            let py_name, scope = bind name scope in
            ( [
                PyAssign
                  ( info,
                    PyTargetName (info, py_name),
                    slice_middle info held prefix suffix );
              ],
              scope )
      in
      (PyPGuarded (info, held, guard, bindings), scope)

and translate_patterns patterns scope =
  List.fold_left
    (fun (out, scope) p ->
      let py_p, scope = translate_pattern p scope in
      (out @ [ py_p ], scope))
    ([], scope) patterns

(** Translates an assignment target, answering it with the scope its
    names extend. assign_target -> scope -> bool -> (pytarget, scope) *)
let rec translate_target ?(rebinding = false) t scope =
  match t with
  | TargetName (info, name, _) ->
      let py_name, scope = bind ~rebinding name scope in
      (PyTargetName (info, py_name), scope)
  | TargetTuple (info, elements, _) ->
      let py_elements, scope =
        List.fold_left
          (fun (out, scope) element ->
            let py_element, scope = translate_target ~rebinding element scope in
            (out @ [ py_element ], scope))
          ([], scope) elements
      in
      (PyTargetTuple (info, py_elements), scope)

(** Synthesizes a closure-free PyFunctionDef named helper_name that
    tests one value against pattern -- `[(bound names...)]` on a match,
    `[]` otherwise -- records it among the pending helpers, and answers
    the captured names. pattern -> string -> gen -> ([string], gen) *)
let build_match_helper pattern helper_name gen =
  let info = pattern_info pattern in
  let v = PyVar (info, "v") in
  let names = pattern_captured_names pattern in
  let success =
    PyReturn
      ( info,
        PyList
          (info, [ PyTuple (info, List.map (fun n -> PyVar (info, n)) names) ])
      )
  in
  let py_pattern, _ = translate_pattern pattern empty_scope in
  let match_stmt = PyMatch (info, v, [ match_case info py_pattern [ success ] ]) in
  let failure = PyReturn (info, PyList (info, [])) in
  let helper =
    PyFunctionDef (info, helper_name, [ "v" ], [ match_stmt; failure ])
  in
  (names, { gen with pending = gen.pending @ [ helper ] })

(** Whether e is a call to the builtin range (not a shadowed name).
    expr -> scope -> bool *)
let is_builtin_range e scope =
  match e with
  | ECall (_, EVar (_, "range", _), _, _) -> not (is_bound "range" scope)
  | _ -> false

(** Whether expr is a call that crosses the host boundary (print),
    which needs no return emitted in tail position. expr -> bool *)
let yields_unit e =
  match e with
  | ECall (_, EVar (_, name, _), _, _) -> Builtin.crosses_host name
  | _ -> false

(** A target read back as an expression: what a loop's accumulator holds
    once the loop has stopped. pytarget -> pyexpr *)
let rec target_as_expr target =
  match target with
  | PyTargetName (info, name) -> PyVar (info, name)
  | PyTargetTuple (info, elements) ->
      PyTuple (info, List.map target_as_expr elements)

(** Whether control can reach the end of py_body without returning -- if
    so, an explicit `return ()` is needed, since unit is the empty tuple
    and Python's implicit None is not it. [pystmt] -> bool *)
let rec falls_through py_body =
  match List.rev py_body with
  | [] -> true
  | last :: _ -> (
      match last with
      | PyReturn _ -> false
      | PyIf (_, _, then_body, Some else_body) ->
          falls_through then_body || falls_through else_body
      | PyMatch (_, _, cases)
        when List.exists
               (fun (PyMatchCase (_, pattern, _, _)) ->
                 match pattern with
                 | PyPWildcard _ | PyPCapture _ -> true
                 | _ -> false)
               cases ->
          (* Only a `match` with an irrefutable arm is guaranteed to run
             one; otherwise an unmatched subject falls straight
             through. *)
          List.exists
            (fun (PyMatchCase (_, _, body, _)) -> falls_through body)
            cases
      | _ -> true)

(** The names a statement binds in the block it is written in.
    stmt -> [string] *)
let stmt_bound_names s =
  match s with
  | SLet (_, target, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
      target_names target
  | SVar (_, name, _, _) -> [ name ]
  | SFunctionDef (_, name, _, _, _, _, _) -> [ name ]
  | _ -> []

(** The names a def's body reads freely (own name and parameters
    excluded). stmt -> StringSet.t *)
let def_body_names s =
  match s with
  | SFunctionDef (_, name, params, body, _, _, _) ->
      free_names body
        (StringSet.add name
           (set_of (List.map (fun (Param (_, n, _, _, _)) -> n) params)))
  | _ -> StringSet.empty

(** The loop-carried names a def reads, or an empty set for anything
    else or outside a loop. stmt -> StringSet.t option -> StringSet.t *)
let loop_captures s loop_names =
  match (loop_names, s) with
  | Some loop_names, SFunctionDef _ ->
      StringSet.inter (def_body_names s) loop_names
  | _ -> StringSet.empty

(** Everything a turn of the loop rebinds, as seen positionally from
    index in this block: what the loop already carries, plus what the
    block binds above that point (`var` excluded).
    [stmt] -> int -> scope -> StringSet.t option *)
let loop_names_before stmts index scope =
  match scope.loop_names with
  | None -> None
  | Some names ->
      Some
        (List.fold_left
           (fun names (position, statement) ->
             if position >= index then names
             else
               match statement with
               | SVar _ -> names
               | statement ->
                   StringSet.union names (set_of (stmt_bound_names statement)))
           names
           (List.mapi (fun position statement -> (position, statement)) stmts))

(** Whether a statement may be lifted into a factory: no return (would
    leave the factory, not the enclosing function), no `:=` (would write
    the factory's own local), and no break/continue for a loop the
    factory is not inside -- `in_loop` says a loop moving with it is. A
    nested def's own returns don't count against it.
    stmt -> bool -> bool *)
let rec movable s in_loop =
  match s with
  | SReturn _ | SReturnStmt _ | SMutate _ -> false
  | SBreak _ | SContinue _ -> in_loop
  | SLetStmt (_, _, inner, _, _, _) -> movable inner in_loop
  | SIf (_, _, then_body, else_body, _) ->
      List.for_all (fun st -> movable st in_loop) then_body
      && (match else_body with
         | None -> true
         | Some else_body -> List.for_all (fun st -> movable st in_loop) else_body)
  (* A loop takes its own break/continue with it, wherever it is moved
     to. *)
  | SLoop (_, _, _, _, _, body, _) -> List.for_all (fun st -> movable st true) body
  | SMatch (_, _, cases, _) ->
      List.for_all
        (fun (MatchCase (_, _, body, _)) ->
          List.for_all (fun st -> movable st in_loop) body)
        cases
  | _ -> true

(** The statement indices between a group's defs that have to travel
    with them into the factory (docs/gap.md).
    [stmt] -> [int] -> [int] -> StringSet.t -> [int] *)
let absorbed stmts defs members captures =
  let first = List.hd members in
  let last = List.nth members (List.length members - 1) in
  let between low high =
    List.filter (fun j -> j >= low && j < high) (List.init (List.length stmts) (fun i -> i))
  in
  let needed =
    List.filter
      (fun j ->
        (not (List.mem j defs))
        && (match List.nth stmts j with
           | SLet _ | SLetStmt _ -> true
           | _ -> false)
        && not
             (StringSet.is_empty
                (StringSet.inter captures
                   (set_of (stmt_bound_names (List.nth stmts j))))))
      (between first last)
  in
  if needed = [] then []
  else
    let window =
      List.filter
        (fun j -> not (List.mem j defs))
        (between (first + 1) (List.nth needed (List.length needed - 1) + 1))
    in
    if List.for_all (fun j -> movable (List.nth stmts j) false) window then window
    else needed

(** Which defs of this loop body have to be built together, one turn at
    a time, keyed by the index each group starts at: the connected
    components of "names another def of this block" that capture
    something the loop rebinds (docs/gap.md).
    [stmt] -> scope -> [(int, ([int], [int], StringSet.t))] *)
let turn_groups stmts scope =
  match scope.loop_names with
  | None -> []
  | Some _ ->
      let defs =
        List.filter_map
          (fun (index, s) ->
            match s with SFunctionDef _ -> Some (index, s) | _ -> None)
          (List.mapi (fun index s -> (index, s)) stmts)
      in
      if defs = [] then []
      else
        let name_of s =
          match s with SFunctionDef (_, name, _, _, _, _, _) -> name | _ -> ""
        in
        let index_of = List.map (fun (index, s) -> (name_of s, index)) defs in
        (* Union-find over "def i names def j", in either direction. *)
        let parent =
          List.fold_left
            (fun parent (index, _) -> IntMap.add index index parent)
            IntMap.empty defs
        in
        let rec root parent i =
          let p = IntMap.find i parent in
          if p = i then i else root parent p
        in
        let parent =
          List.fold_left
            (fun parent (index, s) ->
              StringSet.fold
                (fun name parent ->
                  match List.assoc_opt name index_of with
                  | None -> parent
                  | Some other ->
                      let a = root parent index and b = root parent other in
                      if a <> b then IntMap.add a b parent else parent)
                (def_body_names s) parent)
            parent defs
        in
        let components =
          List.fold_left
            (fun components (index, _) ->
              let r = root parent index in
              match List.assoc_opt r components with
              | Some _ ->
                  List.map
                    (fun (key, ms) ->
                      if key = r then (key, ms @ [ index ]) else (key, ms))
                    components
              | None -> components @ [ (r, [ index ]) ])
            [] defs
        in
        (* Each `def` is asked what *it* can see, at its own place in the
           block -- see `loop_names_before`. *)
        let captured_by =
          List.map
            (fun (index, s) ->
              (index, loop_captures s (loop_names_before stmts index scope)))
            defs
        in
        List.filter_map
          (fun (_, members) ->
            let members = List.sort compare members in
            let captures =
              List.fold_left
                (fun captures index ->
                  StringSet.union captures (List.assoc index captured_by))
                StringSet.empty members
            in
            let captures =
              StringSet.diff captures
                (set_of
                   (List.map
                      (fun index -> name_of (List.nth stmts index))
                      members))
            in
            if StringSet.is_empty captures then
              (* Nothing the loop rebinds reaches these, so Python's own
                 scoping is already right and they translate as they
                 are. *)
              None
            else
              let def_indices = List.map fst defs in
              let taken = absorbed stmts def_indices members captures in
              Some
                ( List.hd members,
                  ( members,
                    taken,
                    StringSet.diff captures
                      (set_of
                         (List.concat_map
                            (fun index -> stmt_bound_names (List.nth stmts index))
                            taken)) ) ))
          components

(* --- the translation proper --- *)

(** Translates one expression. expr -> scope -> gen -> (pyexpr, gen) *)
let rec translate_expr e scope gen =
  let binary build info l r =
    let py_l, gen = translate_expr l scope gen in
    let py_r, gen = translate_expr r scope gen in
    (build info py_l py_r, gen)
  in
  match e with
  | EInt (info, v, _) -> (PyInt (info, v), gen)
  | EFloat (info, v, _) -> (PyFloat (info, v), gen)
  | EString (info, s, _) -> (PyString (info, s), gen)
  | EBool (info, v, _) -> (PyBool (info, v), gen)
  | EVar (info, name, _) ->
      (* A name this module *declared* rather than defined is the host's,
         and lives in the implementation beside this file -- the two
         halves are one module, so it is written unqualified here and
         reached through `<module>_external` in the output. *)
      if List.mem name gen.own_external then
        (PyAttr (info, PyVar (info, gen.own_module ^ "_external"), name), gen)
      else (PyVar (info, lookup name scope), gen)
  | EQualified (info, module_name, name, _) ->
      (* `m.f` is Python's own attribute access on the imported module,
         which is what an `import m` above binds -- and a module is up to
         two modules here, since a name the target's own source provides
         lives in the implementation. *)
      let alias = lookup module_name scope in
      let real =
        Option.value
          (List.assoc_opt module_name gen.module_aliases)
          ~default:module_name
      in
      let reached =
        if Module.reached_module gen.external_fields real name <> real then
          alias ^ "_external"
        else alias
      in
      (PyAttr (info, PyVar (info, reached), name), gen)
  | EAdd (info, l, r, _) -> binary (fun i a b -> PyAdd (i, a, b)) info l r
  (* Python's `+` concatenates strings and lists as well as adding, so
     both Pyking operators land on the same node. *)
  | EConcat (info, l, r, _) -> binary (fun i a b -> PyAdd (i, a, b)) info l r
  | ESub (info, l, r, _) -> binary (fun i a b -> PySub (i, a, b)) info l r
  | EMul (info, l, r, _) -> binary (fun i a b -> PyMul (i, a, b)) info l r
  | EDiv (info, l, r, _) when is_float_expr l gen ->
      (* Python is the one host that raises on a zero divisor rather
         than answering with an infinity or a NaN, so a Float division
         goes through a helper as an Int one does. *)
      let py_l, gen = translate_expr l scope gen in
      let py_r, gen = translate_expr r scope gen in
      ( PyCall
          ( info,
            PyVar (info, float_divide_helper gen.float_name),
            [ py_l; py_r ] ),
        gen )
  | EDiv (info, l, r, _) ->
      (* Pyking's `/` truncates toward zero; Python's `//` rounds down,
         so they part company on a negative operand. A helper in the
         prelude does it, rather than the same conditional inlined at
         every division. *)
      let gen =
        match gen.divide_def with
        | Some _ -> gen
        | None -> { gen with divide_def = Some (build_divide_helper info) }
      in
      let py_l, gen = translate_expr l scope gen in
      let py_r, gen = translate_expr r scope gen in
      (PyCall (info, PyVar (info, divide_helper), [ py_l; py_r ]), gen)
  | ENeg (info, operand, _) ->
      let py_operand, gen = translate_expr operand scope gen in
      (PyNeg (info, py_operand), gen)
  | ELessThan (info, l, r, _) ->
      binary (fun i a b -> PyLessThan (i, a, b)) info l r
  | ELessThanEq (info, l, r, _) ->
      binary (fun i a b -> PyLessThanEq (i, a, b)) info l r
  | EGreatThan (info, l, r, _) ->
      binary (fun i a b -> PyGreatThan (i, a, b)) info l r
  | EGreatThanEq (info, l, r, _) ->
      binary (fun i a b -> PyGreatThanEq (i, a, b)) info l r
  | EEq (info, l, r, _) -> binary (fun i a b -> PyEq (i, a, b)) info l r
  | ECall (info, EVar (_, name, _), args, _)
    when Builtin.crosses_host name ->
      (* Python's own `print` answers None, and Pyking's answers unit --
         which this backend spells `()`, as the `return ()` on a
         unit-returning `def` does. In *value* position the two have to
         be made to agree, so the call is followed by the unit it is
         worth; a print written as a statement keeps the bare call (see
         `runtime_call_stmt`). *)
      let call, gen = runtime_call info name (arg_exprs args) scope gen in
      ( PyIndex
          (info, PyTuple (info, [ call; PyTuple (info, []) ]), PyInt (info, 1)),
        gen )
  | ECall (info, EVar (_, "str", _), [ (_, argument) ], _)
    when not (is_bound "str" scope) ->
      (* str follows print's own Bool formatting rule. *)
      let translated, gen = translate_expr argument scope gen in
      let wrapped, gen = wrap_print_argument argument translated info gen in
      (PyCall (info, PyVar (info, "str"), [ wrapped ]), gen)
  | ECall (info, EVar (_, "range", _), args, _) when not (is_bound "range" scope)
    ->
      (* A range used as a value is materialised
         (docs/target_python.md, "range"); the for header keeps Python's
         lazy form. *)
      let py_args, gen = translate_each (arg_exprs args) scope gen in
      ( PyCall
          ( info,
            PyVar (info, "list"),
            [ PyCall (info, PyVar (info, "range"), py_args) ] ),
        gen )
  | ECall (info, f, args, _) ->
      let py_f, gen = translate_expr f scope gen in
      let py_args, gen = translate_each (arg_exprs args) scope gen in
      (PyCall (info, py_f, py_args), gen)
  | EList (info, elements, _) ->
      let py_elements, gen = translate_each elements scope gen in
      (PyList (info, py_elements), gen)
  | ETuple (info, elements, _) ->
      let py_elements, gen = translate_each elements scope gen in
      (PyTuple (info, py_elements), gen)
  | EIf (info, cond, then_expr, else_expr, _) ->
      (* Pyking's `if c then a else b` is exactly Python's conditional
         expression `a if c else b` -- same semantics (both branches
         lazy, `else` mandatory), only the operand order differs. *)
      let py_cond, gen = translate_expr cond scope gen in
      let py_then, gen = translate_expr then_expr scope gen in
      let py_else, gen = translate_expr else_expr scope gen in
      (PyIfExp (info, py_cond, py_then, py_else), gen)
  | EListComp (info, element, clauses, _) ->
      (* A Python comprehension has its own scope, exactly like a Pyking
         one, so its variables never need renaming -- but they must not
         leak into the enclosing scope either, hence the
         `function_scope`. *)
      let comp_scope =
        function_scope scope StringSet.empty StringSet.empty
      in
      let py_clauses, comp_scope, gen =
        List.fold_left
          (fun (out, comp_scope, gen) clause ->
            match clause with
            | CompFor _ ->
                let clause_py, comp_scope, gen =
                  translate_comp_for clause comp_scope gen
                in
                (out @ clause_py, comp_scope, gen)
            | CompIf (clause_info, condition, _) ->
                let py_condition, gen = translate_expr condition comp_scope gen in
                (out @ [ PyCompIf (clause_info, py_condition) ], comp_scope, gen))
          ([], comp_scope, gen) clauses
      in
      let py_element, gen = translate_expr element comp_scope gen in
      (PyListComp (info, py_element, py_clauses), gen)

(** Every expression of a list, left to right.
    [expr] -> scope -> gen -> ([pyexpr], gen) *)
and translate_each exprs scope gen =
  List.fold_left
    (fun (out, gen) e ->
      let py_e, gen = translate_expr e scope gen in
      (out @ [ py_e ], gen))
    ([], gen) exprs

(** One print argument, formatted for Pyking's true/false spelling and
    its own string quoting: inline where the checker's type settles it,
    a call through the generated helper otherwise
    (docs/target_python.md, "Booleans").
    expr -> pyexpr -> info -> gen -> (pyexpr, gen) *)
and wrap_print_argument pyking_expr translated info gen =
  let type_ = IntMap.find_opt (expr_sym pyking_expr) gen.types in
  let kind = bool_kind type_ in
  if kind = "bool" then
    (PyIfExp (info, translated, PyString (info, "true"), PyString (info, "false")), gen)
  else if is_float_type type_ then
    (* Python spells a float its own way -- `1e+300` where Pyking writes
       `1e300` -- so even a bare one goes through the formatter. *)
    (PyCall (info, PyVar (info, gen.float_name), [ translated ]), gen)
  else if kind = "not-bool" && not (nests_a_string type_ false) then
    (translated, gen)
  else
    let name, gen = format_helper_name info gen in
    (PyCall (info, PyVar (info, name), [ translated; PyBool (info, true) ]), gen)

(** One host-crossing call (print), as the bare Python call. A call's
    arguments are formatted, not merely translated -- see
    `wrap_print_argument`.
    info -> string -> [expr] -> scope -> gen -> (pyexpr, gen) *)
and runtime_call info name args scope gen =
  let py_args, gen =
    List.fold_left
      (fun (out, gen) a ->
        let translated, gen = translate_expr a scope gen in
        let wrapped, gen = wrap_print_argument a translated info gen in
        (out @ [ wrapped ], gen))
      ([], gen) args
  in
  (PyCall (info, PyVar (info, name), py_args), gen)

(** Expands one Pyking CompFor into one or two Python comprehension
    clauses -- one for an irrefutable pattern, two (raw items, then a
    match helper) for a refutable one -- with the scope its pattern
    extends. comp_clause -> scope -> gen -> ([pycompclause], scope, gen) *)
and translate_comp_for clause scope gen =
  match clause with
  | CompFor (info, pattern, sequence, _) ->
      let py_sequence, gen = translate_expr sequence scope gen in
      if is_irrefutable pattern then
        let target, scope = pattern_to_target pattern scope in
        ([ PyCompFor (info, target, py_sequence) ], scope, gen)
      else
        let item_var, helper_name, gen = fresh_comp_names gen in
        let names, gen = build_match_helper pattern helper_name gen in
        (* The unpacking target is always a tuple target, e.g. `()` if
           the pattern captures nothing, `(n,)` for one name --
           PyTargetTuple already prints the right shape (including the
           singleton comma) in every case. *)
        let elements, scope =
          List.fold_left
            (fun (out, scope) name ->
              let py_name, scope = bind name scope in
              (out @ [ PyTargetName (info, py_name) ], scope))
            ([], scope) names
        in
        ( [
            PyCompFor (info, PyTargetName (info, item_var), py_sequence);
            PyCompFor
              ( info,
                PyTargetTuple (info, elements),
                PyCall
                  ( info,
                    PyVar (info, helper_name),
                    [ PyVar (info, item_var) ] ) );
          ],
          scope,
          gen )
  | CompIf _ -> ([], scope, gen)

(** range(n) as Python's own lazy range, for a for header.
    expr -> scope -> gen -> (pyexpr, gen) *)
and lazy_range call scope gen =
  match call with
  | ECall (info, _, args, _) ->
      let py_args, gen = translate_each (arg_exprs args) scope gen in
      (PyCall (info, PyVar (info, "range"), py_args), gen)
  | e -> translate_expr e scope gen

(** A host-crossing call written as a statement: the bare call, with
    none of the unit `translate_expr` adds for value position.
    expr -> scope -> gen -> (pystmt, gen) *)
and runtime_call_stmt e scope gen =
  match e with
  | ECall (info, EVar (_, name, _), args, _) ->
      let call, gen = runtime_call info name (arg_exprs args) scope gen in
      (PyExprStmt (info, call), gen)
  | e -> (PyExprStmt (expr_info e, PyTuple (expr_info e, [])), gen)

(** Binds every def in this block, and everything an import brings into
    it, before any of it is translated (docs/target_python.md,
    "Functions used before they are written"). Both are visible
    throughout the block they are written in, so both are bound ahead of
    it. [stmt] -> scope -> scope *)
and declare_functions stmts scope =
  List.fold_left
    (fun scope s ->
      match s with
      | SFunctionDef (_, name, _, _, _, _, _) -> snd (bind name scope)
      | SImport (_, _, local, selected, fields, _) ->
          let names =
            if selected then List.map (fun (_, local) -> local) fields
            else [ local ]
          in
          List.fold_left (fun scope name -> snd (bind name scope)) scope names
      | _ -> scope)
    scope stmts

(** Translates a statement sequence, threading the scope through it. A
    caller entering a block passes a `block_scope` and discards the
    answered scope. [stmt] -> scope -> gen -> ([pystmt], scope, gen) *)
and translate_stmts stmts scope gen =
  let scope = declare_functions stmts scope in
  let groups = turn_groups stmts scope in
  (* Everything a group takes with it is emitted where the group starts,
     so those statements are passed over when the walk reaches them. *)
  let covered =
    List.concat_map
      (fun (start, (members, taken, _)) ->
        List.filter (fun i -> i <> start) (members @ taken))
      groups
  in
  let translated, scope, gen, _ =
    List.fold_left
      (fun (translated, scope, gen, index) statement ->
        if List.mem index covered then (translated, scope, gen, index + 1)
        else
          match List.assoc_opt index groups with
          | Some (members, taken, captures) ->
              let py_stmts, scope, gen =
                translate_turn_group members taken captures stmts scope gen
              in
              (translated @ py_stmts, scope, gen, index + 1)
          | None ->
              let py_stmts, scope, gen = translate_stmt statement scope gen in
              (translated @ py_stmts, scope, gen, index + 1))
      ([], scope, gen, 0) stmts
  in
  (translated, scope, gen)

(** One group of defs inside a loop, built by a factory taking the
    captured names as parameters (docs/target_python.md, "A def inside a
    loop"; docs/gap.md).
    [int] -> [int] -> StringSet.t -> [stmt] -> scope -> gen
    -> ([pystmt], scope, gen) *)
and translate_turn_group members taken captures stmts scope gen =
  let order = List.sort compare (members @ taken) in
  let py_captures =
    List.map (fun name -> lookup name scope) (StringSet.elements captures)
  in
  let inner, bound, inner_scope, gen =
    List.fold_left
      (fun (inner, bound, inner_scope, gen) i ->
        let py_stmts, inner_scope, gen =
          translate_stmt (List.nth stmts i) inner_scope gen
        in
        let bound =
          bound
          @ List.map
              (fun name -> lookup name inner_scope)
              (stmt_bound_names (List.nth stmts i))
        in
        (inner @ py_stmts, bound, inner_scope, gen))
      ([], [], scope, gen) order
  in
  let info = stmt_info (List.nth stmts (List.hd order)) in
  let factory, gen = fresh_turn_name gen in
  let returned =
    match bound with
    | [ single ] -> PyVar (info, single)
    | bound -> PyTuple (info, List.map (fun n -> PyVar (info, n)) bound)
  in
  let target =
    match bound with
    | [ single ] -> PyTargetName (info, single)
    | bound ->
        PyTargetTuple (info, List.map (fun n -> PyTargetName (info, n)) bound)
  in
  ( [
      PyFunctionDef
        (info, factory, py_captures, inner @ [ PyReturn (info, returned) ]);
      PyAssign
        ( info,
          target,
          PyCall
            ( info,
              PyVar (info, factory),
              List.map (fun p -> PyVar (info, p)) py_captures ) );
    ],
    inner_scope,
    gen )

(** Translates one statement, answering it with the scope it leaves
    behind. A loop answers with several statements.
    stmt -> scope -> gen -> ([pystmt], scope, gen) *)
and translate_stmt s scope gen =
  match s with
  | SLet (info, target, e, _, _, _) ->
      (* The right-hand side is translated *before* the target binds, so
         `x = x + 1` reads the outer `x` -- if that binding is a
         shadowing one, the read still resolves to the old name. *)
      let py_expr, gen = translate_expr e scope gen in
      let py_target, scope = translate_target ~rebinding:true target scope in
      ([ PyAssign (info, py_target, py_expr) ], scope, gen)
  | SLetStmt (info, target, (SLoop _ as loop), _, _, _) ->
      (* `x = loop ...` -- the loop's value is the accumulator it
         stopped with, so the binding is one assignment after it. *)
      let py_target, scope = translate_target ~rebinding:true target scope in
      let py_stmts, value, scope, gen = translate_loop loop scope gen in
      (py_stmts @ [ PyAssign (info, py_target, value) ], scope, gen)
  | SLetStmt (_, target, inner, _, _, _) ->
      (* The target binds in *this* scope (the branches are blocks of
         their own) and is bound first, so a branch that shadows a name
         cannot be handed the Python name the target is using. *)
      let py_target, scope = translate_target ~rebinding:true target scope in
      let py_stmt, gen = translate_value_stmt inner py_target scope gen in
      ([ py_stmt ], scope, gen)
  | SImport (info, module_name, local, selected, fields, _) ->
      (* Python's own import is Pyking's, name for name: a module is a
         file, and a public name is a name the module binds. There is no
         privacy to express -- Python has none -- so the `public` marks
         leave no trace in the output. The names were bound by
         `declare_functions`; where one had to be renamed, Python's own
         `as` says so. *)
      (* A module whose name Python has built into the interpreter cannot
         be reached by an ordinary `import`: the frozen one wins, however
         `sys.path` is ordered. Such a module is loaded by path instead,
         through a helper this puts in the prelude -- only here, so an
         ordinary program's output stays an ordinary program's. *)
      let gen =
        if shadowed module_name && not (List.mem module_name gen.externals) then
          match gen.import_def with
          | Some _ -> gen
          | None -> { gen with import_def = Some (build_import_helper info) }
        else gen
      in
      let loaded from_module target =
        PyAssign
          ( info,
            PyTargetName (info, target),
            PyCall
              ( info,
                PyVar (info, import_helper),
                [ PyString (info, from_module) ] ) )
      in
      (* One `import` per half of the module the name reaches: the file
         generated for it, the implementation the target's own source
         provides, or both. *)
      let external_here =
        Option.value
          (List.assoc_opt module_name gen.external_fields)
          ~default:[]
      in
      let half wanted =
        List.filter (fun (exported, _) -> List.mem exported external_here = wanted)
          fields
      in
      let one from_module alias_name chosen =
        if selected then
          let taken held =
            List.map
              (fun (exported, local_name) ->
                PyAssign
                  ( info,
                    PyTargetName (info, lookup local_name scope),
                    PyAttr (info, PyVar (info, held), exported) ))
              chosen
          in
          if shadowed from_module then
            (* The module is bound once and its fields taken off it: one
               load per `from` line, since loading per field would run
               the module's top level once per field. *)
            let held = shadowed_binding from_module in
            loaded from_module held :: taken held
          else
            [
              PyFromImport
                ( info,
                  from_module,
                  List.map
                    (fun (exported, local_name) ->
                      (exported, lookup local_name scope))
                    chosen );
            ]
        else if shadowed from_module then [ loaded from_module alias_name ]
        else
          let alias =
            if alias_name = from_module then None else Some alias_name
          in
          [ PyImport (info, from_module, alias) ]
      in
      let py_name = lookup local scope in
      let own =
        if List.mem module_name gen.externals then []
        else if selected && half false = [] && fields <> [] then []
        else one module_name py_name (half false)
      in
      let implementation =
        if external_here = [] then []
        else if selected && half true = [] then []
        else
          one (module_name ^ "_external") (py_name ^ "_external") (half true)
      in
      (own @ implementation, scope, gen)
  | SVar (info, name, e, _) ->
      let py_expr, gen = translate_expr e scope gen in
      (* A `var` is a mutable location: `:=` updates the one binding,
         and a function reading it is meant to see that (PYKING.md,
         "Names and scoping"). So it is *not* carried per turn of a loop
         -- a copy handed to a factory would freeze at the value it had
         when the turn's functions were built, which is the opposite of
         what `var` means. *)
      let py_name, scope =
        bind ~rebinding:true ~loop_carried:false ~mutable_:true name scope
      in
      ([ PyAssign (info, PyTargetName (info, py_name), py_expr) ], scope, gen)
  | SMutate (info, name, e, _) ->
      (* An update, not a binding: it reuses the variable's name,
         whatever renaming that variable got when it was declared. *)
      let py_expr, gen = translate_expr e scope gen in
      let py_name = lookup name scope in
      ([ PyAssign (info, PyTargetName (info, py_name), py_expr) ], scope, gen)
  | SReturn (info, e, _) ->
      let py_expr, gen = translate_expr e scope gen in
      ([ PyReturn (info, py_expr) ], scope, gen)
  | SExprStmt (_, e, _) when yields_unit e ->
      (* Nothing reads what a statement is worth, so `print(x)` is
         written as itself rather than as the value form. *)
      let py_stmt, gen = runtime_call_stmt e scope gen in
      ([ py_stmt ], scope, gen)
  | SExprStmt (info, e, _) ->
      let py_expr, gen = translate_expr e scope gen in
      ([ PyExprStmt (info, py_expr) ], scope, gen)
  | SLoop _ ->
      let py_stmts, _, scope, gen = translate_loop s scope gen in
      (py_stmts, scope, gen)
  | SBreak (info, _) ->
      (* Python's own: the accumulator variable is left holding what this
         turn started with, which is what the loop is worth. *)
      ([ PyBreak info ], scope, gen)
  | SContinue (info, _) -> ([ PyContinue info ], scope, gen)
  | SIf (info, cond, then_body, else_body, _) ->
      let py_cond, gen = translate_expr cond scope gen in
      let py_then, _, gen = translate_stmts then_body (block_scope scope) gen in
      let py_else, gen =
        match else_body with
        | None -> (None, gen)
        | Some else_body ->
            let py_else, _, gen =
              translate_stmts else_body (block_scope scope) gen
            in
            (Some py_else, gen)
      in
      ([ PyIf (info, py_cond, py_then, py_else) ], scope, gen)
  | SFunctionDef (info, name, params, body, _, _, _) ->
      let py_name, scope = bind name scope in
      let body_bound =
        StringSet.add name
          (set_of (List.map (fun (Param (_, n, _, _, _)) -> n) params))
      in
      let body_scope =
        function_scope scope (free_names body body_bound)
          (captured_names body body_bound)
      in
      let param_names, body_scope =
        List.fold_left
          (fun (out, body_scope) (Param (_, param_name, _, _, _)) ->
            let py_param, body_scope = bind param_name body_scope in
            (out @ [ py_param ], body_scope))
          ([], body_scope) params
      in
      (* Before anything in the body is translated, since the
         declarations name the variables as they are known *outside* it
         -- which is what `body_scope` still holds here. *)
      let declarations = scope_declarations (mutated_names body) body_scope info in
      let py_body, gen = translate_tail_block body body_scope gen in
      let py_body =
        if falls_through py_body then
          py_body @ [ PyReturn (info, PyTuple (info, [])) ]
        else py_body
      in
      ( [ PyFunctionDef (info, py_name, param_names, declarations @ py_body) ],
        scope,
        gen )
  | SReturnStmt (_, inner, _) ->
      (* `return if c: ...` -- the same push-down as a tail-position
         if/match, written explicitly. A loop answers with several
         statements (the accumulator, the loop, the return). *)
      let py_stmts, gen = translate_tail_stmt inner scope gen in
      (py_stmts, scope, gen)
  | SMatch (info, subject, cases, _) ->
      let py_subject, gen = translate_expr subject scope gen in
      let py_cases, gen =
        List.fold_left
          (fun (out, gen) c ->
            let py_case, gen = translate_case c scope gen in
            (out @ [ py_case ], gen))
          ([], gen) cases
      in
      ([ PyMatch (info, py_subject, py_cases) ], scope, gen)
  | SFunctionSig _ -> ([], scope, gen)

(** One case arm outside a binding.
    match_case -> scope -> gen -> (pymatchcase, gen) *)
and translate_case (MatchCase (info, pattern, body, _)) scope gen =
  let py_pattern, arm_scope = translate_pattern pattern (block_scope scope) in
  let py_body, _, gen = translate_stmts body arm_scope gen in
  (match_case info py_pattern py_body, gen)

(** Translates a statement list whose last statement is in tail position
    (PYKING.md, "Tail position"; docs/target_python.md, "Tail
    position"). [stmt] -> scope -> gen -> ([pystmt], gen) *)
and translate_tail_block stmts scope gen =
  match stmts with
  | [] -> ([], gen)
  | stmts ->
      (* Over the whole block, including the last statement: a `def` in
         tail position is still visible to everything above it. *)
      let scope = declare_functions stmts scope in
      let count = List.length stmts in
      let front = List.filteri (fun i _ -> i < count - 1) stmts in
      let last = List.nth stmts (count - 1) in
      let body, tail_scope, gen = translate_stmts front scope gen in
      let tail, gen = translate_tail_stmt last tail_scope gen in
      (body @ tail, gen)

(** The last statement of a body in tail position, as a list of Python
    statements. stmt -> scope -> gen -> ([pystmt], gen) *)
and translate_tail_stmt s scope gen =
  match s with
  | SExprStmt (_, e, _) when yields_unit e ->
      let py_stmts, _, gen = translate_stmt s scope gen in
      (py_stmts, gen)
  | SExprStmt (info, e, _) ->
      let py_expr, gen = translate_expr e scope gen in
      ([ PyReturn (info, py_expr) ], gen)
  | SIf (_, _, _, None, _) ->
      (* An `if` with no `else` supplies unit whatever its one branch
         ends in (PYKING.md, "Type checking"): a path runs no branch at
         all, so there is no value the statement can be counted on for.
         Translated as an ordinary statement, so the function falls out
         of its end -- Python's own implicit None, i.e. unit. *)
      let py_stmts, _, gen = translate_stmt s scope gen in
      (py_stmts, gen)
  | SIf (info, cond, then_body, Some else_body, _) ->
      let py_cond, gen = translate_expr cond scope gen in
      let py_then, gen = translate_tail_block then_body (block_scope scope) gen in
      let py_else, gen = translate_tail_block else_body (block_scope scope) gen in
      ([ PyIf (info, py_cond, py_then, Some py_else) ], gen)
  | SMatch (info, subject, cases, _) ->
      let py_subject, gen = translate_expr subject scope gen in
      let py_cases, gen =
        List.fold_left
          (fun (out, gen) c ->
            let py_case, gen = translate_tail_case c scope gen in
            (out @ [ py_case ], gen))
          ([], gen) cases
      in
      ([ PyMatch (info, py_subject, py_cases) ], gen)
  | SLoop (info, _, _, _, _, _, _) ->
      (* A function ending in a loop returns what the loop produced: the
         accumulator it stopped with. *)
      let py_stmts, value, _, gen = translate_loop s scope gen in
      (py_stmts @ [ PyReturn (info, value) ], gen)
  | s ->
      let py_stmts, _, gen = translate_stmt s scope gen in
      (py_stmts, gen)

(** One case arm of a match in tail position.
    match_case -> scope -> gen -> (pymatchcase, gen) *)
and translate_tail_case (MatchCase (info, pattern, body, _)) scope gen =
  let py_pattern, arm_scope = translate_pattern pattern (block_scope scope) in
  let py_body, gen = translate_tail_block body arm_scope gen in
  (match_case info py_pattern py_body, gen)

(** Translates a value-form if/match (docs/target_python.md,
    "Value-form if/match"): the same PyIf/PyMatch the statement form
    produces, with each branch's tail assigned to py_target.
    stmt -> pytarget -> scope -> gen -> (pystmt, gen) *)
and translate_value_stmt s py_target scope gen =
  match s with
  | SIf (info, cond, then_body, else_body, _) ->
      (* The parser guarantees `else_body` is not None here. *)
      let py_cond, gen = translate_expr cond scope gen in
      let py_then, gen = translate_value_block then_body py_target scope gen in
      let py_else, gen =
        translate_value_block
          (Option.value else_body ~default:[])
          py_target scope gen
      in
      (PyIf (info, py_cond, py_then, Some py_else), gen)
  | SMatch (info, subject, cases, _) ->
      let py_subject, gen = translate_expr subject scope gen in
      let py_cases, gen =
        List.fold_left
          (fun (out, gen) c ->
            let py_case, gen = translate_value_case c py_target scope gen in
            (out @ [ py_case ], gen))
          ([], gen) cases
      in
      (PyMatch (info, py_subject, py_cases), gen)
  | s -> (PyExprStmt (stmt_info s, PyTuple (stmt_info s, [])), gen)

(** Translates one branch of a value-form if/match.
    [stmt] -> pytarget -> scope -> gen -> ([pystmt], gen) *)
and translate_value_block stmts py_target scope gen =
  let branch_scope = declare_functions stmts (block_scope scope) in
  let count = List.length stmts in
  let front = List.filteri (fun i _ -> i < count - 1) stmts in
  let body, branch_scope, gen = translate_stmts front branch_scope gen in
  match List.nth stmts (count - 1) with
  | SExprStmt (info, e, _) ->
      let py_expr, gen = translate_expr e branch_scope gen in
      (body @ [ PyAssign (info, py_target, py_expr) ], gen)
  | (SIf _ | SMatch _) as nested ->
      let py_stmt, gen = translate_value_stmt nested py_target branch_scope gen in
      (body @ [ py_stmt ], gen)
  | last ->
      let py_stmts, _, gen = translate_stmt last branch_scope gen in
      (body @ py_stmts, gen)

(** One case arm of a value-form match.
    match_case -> pytarget -> scope -> gen -> (pymatchcase, gen) *)
and translate_value_case (MatchCase (info, pattern, body, _)) py_target scope gen
    =
  let py_pattern, arm_scope = translate_pattern pattern (block_scope scope) in
  let py_body, gen = translate_value_block body py_target arm_scope gen in
  (match_case info py_pattern py_body, gen)

(** Translates a loop into Python's own `while True`/`for` over a
    mutable accumulator variable (docs/target_python.md, "loop"): the
    initializer becomes the variable's first value and every tail of the
    body assigns the next one, so the variable holds what the loop is
    worth however it stops -- a `break` is Python's own, and leaves this
    turn's value where it is. Answers the statements, the expression
    holding the loop's value afterwards, and the scope -- which is the
    caller's, since the accumulator belongs to the body.
    stmt -> scope -> gen -> ([pystmt], pyexpr, scope, gen) *)
and translate_loop s scope gen =
  match s with
  | SLoop (info, target, init, _, iterate, body, _) ->
      let body_scope = loop_scope scope in
      let setup, py_target, value, body_scope, gen =
        match (target, init) with
        | Some target, Some init ->
            (* The initializer is translated before the accumulator
               binds, so `loop x = x + 1:` reads the enclosing `x`,
               exactly as an `=` binding does. *)
            let py_init, gen = translate_expr init scope gen in
            let py_target, body_scope =
              translate_target ~rebinding:true target body_scope
            in
            ( [ PyAssign (info, py_target, py_init) ],
              Some py_target,
              target_as_expr py_target,
              body_scope,
              gen )
        | _ -> ([], None, PyTuple (info, []), body_scope, gen)
      in
      (* The iteration clause decides which Python loop this is. A `for`
         binds its element in the body's scope, where Python's own `for`
         target lives too, so it renames like anything else when it
         shadows. *)
      let py_name, py_sequence, body_scope, gen =
        match iterate with
        | Some (ForIn (_, name, sequence, _)) ->
            (* `for i in range(n)` iterates lazily, as Python's own
               does: only a range used as a *value* is materialised into
               the list its type says it is. *)
            let py_sequence, gen =
              if is_builtin_range sequence scope then lazy_range sequence scope gen
              else translate_expr sequence scope gen
            in
            let py_name, body_scope = bind name body_scope in
            (Some py_name, Some py_sequence, body_scope, gen)
        | _ -> (None, None, body_scope, gen)
      in
      let py_body, gen = translate_loop_block body py_target body_scope gen in
      let loop, gen =
        match iterate with
        | Some (ForIn _) ->
            ( PyFor
                (info, Option.get py_name, Option.get py_sequence, py_body, None),
              gen )
        | Some (WhileTest (_, condition, _)) ->
            let py_condition, gen = translate_expr condition body_scope gen in
            (PyWhile (info, py_condition, py_body, None), gen)
        | None -> (PyWhile (info, PyBool (info, true), py_body, None), gen)
      in
      (setup @ [ loop ], value, scope, gen)
  | s -> ([], PyTuple (stmt_info s, []), scope, gen)

(** Translates a loop body: whatever a path ends in is the next turn's
    accumulator, so every tail becomes an assignment to py_target --
    except a `break`/`continue`, which has already said what happens
    next. py_target is None for a loop carrying nothing, where the
    body's value is simply discarded.
    [stmt] -> pytarget option -> scope -> gen -> ([pystmt], gen) *)
and translate_loop_block stmts py_target scope gen =
  let scope = declare_functions stmts scope in
  match stmts with
  | [] -> ([], gen)
  | stmts ->
      let count = List.length stmts in
      let front = List.filteri (fun i _ -> i < count - 1) stmts in
      let body, scope, gen = translate_stmts front scope gen in
      let tail, gen =
        translate_loop_tail (List.nth stmts (count - 1)) py_target scope gen
      in
      (body @ tail, gen)

(** The last statement of a loop body, or of one branch of one.
    stmt -> pytarget option -> scope -> gen -> ([pystmt], gen) *)
and translate_loop_tail s py_target scope gen =
  match py_target with
  | None ->
      let py_stmts, _, gen = translate_stmt s scope gen in
      (py_stmts, gen)
  | Some target -> (
      match s with
      | SExprStmt (info, e, _) ->
          let py_expr, gen = translate_expr e scope gen in
          ([ PyAssign (info, target, py_expr) ], gen)
      | SIf (info, cond, then_body, else_body, _) ->
          let py_cond, gen = translate_expr cond scope gen in
          let py_then, gen =
            translate_loop_block then_body py_target (block_scope scope) gen
          in
          let py_else, gen =
            match else_body with
            | None ->
                (* A path that runs no branch produces nothing, and
                   nothing is unit -- what PYKING.md's tail-position
                   table says of every statement that yields no value,
                   and what interpreter.ml does with one. *)
                ([ PyAssign (info, target, PyTuple (info, [])) ], gen)
            | Some else_body ->
                translate_loop_block else_body py_target (block_scope scope) gen
          in
          ([ PyIf (info, py_cond, py_then, Some py_else) ], gen)
      | SMatch (info, subject, cases, _) ->
          let py_subject, gen = translate_expr subject scope gen in
          let py_cases, gen =
            List.fold_left
              (fun (out, gen) c ->
                let py_case, gen = translate_loop_case c py_target scope gen in
                (out @ [ py_case ], gen))
              ([], gen) cases
          in
          ([ PyMatch (info, py_subject, py_cases) ], gen)
      (* Each of these says by itself what happens next: two leave the
         loop, one leaves the whole function. *)
      | SBreak _ | SContinue _ | SReturn _ | SReturnStmt _ ->
          let py_stmts, _, gen = translate_stmt s scope gen in
          (py_stmts, gen)
      | s ->
          (* Anything else supplies unit, so that is the accumulator the
             next turn gets. *)
          let py_stmts, _, gen = translate_stmt s scope gen in
          ( py_stmts
            @ [ PyAssign (stmt_info s, target, PyTuple (stmt_info s, [])) ],
            gen ))

(** One case arm of a match at the tail of a loop body.
    match_case -> pytarget option -> scope -> gen -> (pymatchcase, gen) *)
and translate_loop_case (MatchCase (info, pattern, body, _)) py_target scope gen
    =
  let py_pattern, arm_scope = translate_pattern pattern (block_scope scope) in
  let py_body, gen = translate_loop_block body py_target arm_scope gen in
  (match_case info py_pattern py_body, gen)

(** Translates a full program: every helper synthesized along the way is
    prepended. `tmap` is the checker's symbol -> type table, which is
    what decides how a print argument is formatted.
    [stmt] -> typ IntMap.t -> pyprogram *)
let translate_program ?(external_fields = []) ?(externals = []) ?(own = "")
    stmts tmap =
  let used =
    StringSet.union (collect_identifiers stmts) (import_identifiers stmts)
  in
  (* Whether this module has a Float at all decides whether any of the
     Float formatting is emitted, so a program without one is compiled
     to exactly what it was compiled to before. *)
  let module_floats =
    IntMap.exists (fun _ type_ -> holds_float type_) tmap
  in
  (* Both halves are found together, so the two names always agree about
     which suffix they took. *)
  let float_name =
    let rec go n =
      let suffix = if n = 0 then "" else string_of_int n in
      if
        StringSet.mem ("__pyk_float" ^ suffix) used
        || StringSet.mem ("__pyk_fdiv" ^ suffix) used
      then go (n + 1)
      else "__pyk_float" ^ suffix
    in
    go 0
  in
  let gen =
    {
      used;
      types = tmap;
      comp_counter = 0;
      turn_counter = 0;
      pending = [];
      format_helper = None;
      format_def = None;
      floats = module_floats;
      float_name = float_name;
      divide_def = None;
      import_def = None;
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
  let translated, _, gen =
    translate_stmts stmts
      {
        empty_scope with
        captured = captured_names stmts StringSet.empty;
      }
      gen
  in
  let prelude =
    List.filter_map (fun d -> d)
      [ gen.import_def; gen.divide_def; gen.format_def ]
  in
  (* The implementation of this module's own declaration half, imported
     so that a name declared here can be called here. *)
  let own_import =
    if gen.own_external = [] then []
    else [ PyImport (Lexer.{ file = ""; row1 = 1; col1 = 0; row2 = 1; col2 = 0 },
                     gen.own_module ^ "_external", None) ]
  in
  {
    prelude;
    formats = gen.format_def <> None;
    floats = gen.floats;
    float_helper = gen.float_name;
    stmts = own_import @ gen.pending @ translated;
  }
