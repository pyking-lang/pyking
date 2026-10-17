(** Submodules: a definition whose name has a dot in it, `def
    mymod.foo(...)`, is `foo` in the submodule `mymod` of its file. This
    pass gives every dotted name the plain name it compiles to
    (`mymod__foo`), and turns an import naming a submodule into the
    `from` line taking its members, so nothing after it sees a
    submodule. See docs/modules.md, "Submodules".

    Data structures:
      Error -- a refusal, with the source position.
      table -- a module's dotted names and the plain names they become.

    Functions:
      root name -- the module an import's dotted name reaches.
      module_ tokens stmts declarations imported -- one module
        rewritten, with its table. *)

(** A refusal: a submodule that is not there, or a name that clashes
    with one. *)
exception Error of Lexer.info * string

(** A module's dotted names, each with the plain name it compiles to. *)
type table = (string * string) list

(** The module an import's dotted name reaches: its first part.
    String -> String *)
val root : string -> string

(** One module with its submodules gone: every dotted name it defines or
    reaches given the plain name it compiles to, every import naming a
    submodule turned into the `from` line taking its members, and its own
    table. `tokens` and `stmts` are its Pyking half as lexed and as first
    parsed, `declarations` its declaration half, and `imported` each
    module it may import, with its table and public names. `context` is
    what was written before these statements in the same module -- the
    REPL's earlier entries -- whose submodules and imports count here
    too. A module with no dotted name to settle comes back as it was.
    Raises Error.
    [stmt]? -> [token] -> [stmt] -> [stmt] -> [(String, (table, [String]))] ->
    ([stmt], [stmt], table) *)
val module_ :
  ?context:Syntax.stmt list ->
  Lexer.token list ->
  Syntax.stmt list ->
  Syntax.stmt list ->
  (string * (table * string list)) list ->
  Syntax.stmt list * Syntax.stmt list * table
