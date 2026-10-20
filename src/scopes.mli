(** What the names in a module mean: every use of a name with the
    binding it reaches, and which names are in scope where. The language
    server and the debugger both read it. See design/lsp.md.

    Data structures:
      place -- a file and the span of a name in it.
      binding_kind -- a def, an `=`, a `var` or a parameter.
      meaning -- what a name refers to.
      use -- one name used, where, and what it means.
      scope -- the names in scope from one position to another.
      found -- every use and every scope of a module.
      SMap -- the map from a name that a scope is made of.

    Functions:
      name_span tokens name from -- the span of a name at or after a span.
      export_place unit name -- where a module binds a top-level name.
      target_bindings target -- the names an assignment target binds.
      resolve units unit -- every use and scope of a module.
      use_at found row col -- the use at a position.
      names_at found row col -- the names in scope at a position.
      bindings found -- every binding the module's scopes hold. *)

module SMap : Map.S with type key = string

(** Where a name is bound: a file and the name's span in it. *)
type place = { file : string; span : Lexer.info }

(** What kind of binding a name is: a def, an `=`, a `var`, a
    parameter. *)
type binding_kind = KFunction | KValue | KVariable | KParameter

(** What a name refers to: a binding (its place, symbol and kind), an
    imported module, a builtin, or nothing found. *)
type meaning =
  | Bound of place * int * binding_kind
  | Module_of of string
  | Builtin
  | Unknown

(** One name found in a module: where, what it is called and what it
    means. *)
type use = { use_at : Lexer.info; use_name : string; use_meaning : meaning }

(** The names in scope from a row and column to another. *)
type scope = { scope_from : int * int; scope_to : int * int; names : meaning SMap.t }

(** What resolution found: every use, and every scope. *)
type found = { uses : use list; scopes : scope list }

(** The span of the first identifier `name` at or after where a span
    starts, from a module's tokens. [token] -> string -> Lexer.info ->
    Lexer.info *)
val name_span : Lexer.token list -> string -> Lexer.info -> Lexer.info

(** Where a module binds one of its top-level names, and the binding's
    symbol and kind. Module.t -> string -> (place, int, binding_kind)? *)
val export_place : Module.t -> string -> (place * int * binding_kind) option

(** The names an assignment target binds, with their spans and symbols.
    assign_target -> [(string, Lexer.info, int)] *)
val target_bindings : Syntax.assign_target -> (string * Lexer.info * int) list

(** What every name in a module means, and what is in scope where.
    [Module.t] -> Module.t -> found *)
val resolve : Module.t list -> Module.t -> found

(** The smallest use of a name holding a position, or None.
    found -> int -> int -> use? *)
val use_at : found -> int -> int -> use option

(** The names in scope at a position. found -> int -> int -> meaning
    SMap.t *)
val names_at : found -> int -> int -> meaning SMap.t

(** Every binding the module's scopes hold, each once: its name, place,
    symbol and kind. found -> [(string, place, int, binding_kind)] *)
val bindings : found -> (string * place * int * binding_kind) list
