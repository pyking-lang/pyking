(** The JavaScript code-generation core: a JS AST, a translation from
    syntax.ml, and a printer. Knows nothing about packaging (node
    script, ES module, or HTML page): that is target_js_packaging.ml's
    job. See docs/target_js.md for how each construct compiles and
    where the output is not optimal.

    The AST is public because the packager works on it: it decides how
    a call across the runtime interface and an import are spelled, and
    both arrive here as nodes naming the operation rather than as text.
    The translation itself -- the scope, the renaming JavaScript's const
    rules force, pattern tests, comprehensions -- is private, and so are
    the generated program's own runtime helpers, which the printer
    emits.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      jsexpr / jsstmt -- the JavaScript AST; see the comment on each
        variant for its shape.
      jstarget -- what a binding binds; the printer's own.
      jshost -- everything the packager decides and the core only names.

    Functions:
      translate_program stmts taken -- translates a whole module, and
        says which top-level names it had to rename.
      pprint_js_program stmts runtime -- the AST as JavaScript source
        text; runtime is the jshost the packager supplies.
      uses p stmts -- whether any expression in a module satisfies p,
        which is how the packager asks whether a module prints. *)

open Lexer

(** Raised for a Pyking construct this backend cannot compile yet;
    carries the source position, like the front end's errors do for
    their stages. *)
exception Unsupported of info * string

(* --- JavaScript AST --- *)

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

(** What a binding binds: a name, or an array pattern for a tuple.
    Built and printed here; nothing outside looks inside one. *)
and jstarget

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

(** Translates one module to JavaScript statements. `taken` is the
    names the packaging writes around the program, which a Pyking
    binding may therefore not keep.

    Answers the statements and every top-level name this module had to
    rename: a Pyking name that is a word JavaScript reserves is bound
    under another one, and a packaging that exports it has to say which
    (`export { arguments2 as arguments }`) rather than write a name
    nothing declared.
    [string] -> [stmt] -> ([jsstmt], [(string, string)]) *)
val translate_program :
  ?taken:Syntax.StringSet.elt list ->
  Syntax.stmt list ->
  jsstmt list * (string * string) list

(** The AST as JavaScript source text, with the generated program's own
    runtime helpers where it needs them. `runtime` is the jshost the
    packager supplies, which is what decides how a runtime call and an
    import are spelled. int -> bool -> [jsstmt] -> jshost -> string *)
val pprint_js_program :
  ?level:int -> ?helpers:bool -> jsstmt list -> jshost -> string

(** Whether any expression anywhere in a module satisfies p.
    (jsexpr -> bool) -> [jsstmt] -> bool *)
val uses : (jsexpr -> bool) -> jsstmt list -> bool
