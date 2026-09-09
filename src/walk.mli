(** One generic traversal of the AST, for the passes that ask a question
    of a whole subtree rather than of one node kind: which functions can
    print, whether an expression holds a call, whether a name is used as
    a string. The descent is written out once -- in this module --
    instead of once per pass.

    `children` is the whole of it: one node's immediate children, in the
    order src/syntax.ml declares the fields they came from, so a
    pre-order walk reaches a node before anything inside it. Everything
    else here is a fold over that.

    A node kind added to syntax.ml needs a case in `children`, and
    nothing but a pass that would have looked inside it will notice if
    it is missed. See docs/architecture.md.

    Data structures:
      node -- any AST node, whatever its type.

    Functions:
      children n -- one node's immediate children, in field order.
      fold f acc n -- f over every node in a subtree, pre-order.
      exists p n -- whether any node in a subtree satisfies p.
      fold_stmts f acc stmts -- fold over a statement sequence.
      exists_stmts p stmts -- exists over a statement sequence.
      exprs n -- every expression in a subtree, pre-order.
      stmts_in n -- every statement in a subtree, pre-order.
      name_field n -- the value of a node's `name` field, if it has one. *)

open Syntax

(** Any AST node, whatever its type: what a traversal that does not care
    which kind of node it is looking at carries. *)
type node =
  | NExpr of expr
  | NType of typ
  | NPattern of pattern
  | NListRest of list_rest
  | NCompClause of comp_clause
  | NTarget of assign_target
  | NParam of param
  | NLoopIter of loop_iter
  | NMatchCase of match_case
  | NStmt of stmt

(** One node's immediate children, in the order src/syntax.ml declares
    the fields they came from. node -> [node] *)
val children : node -> node list

(** f over every node in a subtree, the subtree's own root first.
    ('a -> node -> 'a) -> 'a -> node -> 'a *)
val fold : ('a -> node -> 'a) -> 'a -> node -> 'a

(** Whether any node in a subtree satisfies p. Stops at the first one.
    (node -> bool) -> node -> bool *)
val exists : (node -> bool) -> node -> bool

(** f over every node in a statement sequence. The sequence itself is
    not a node. ('a -> node -> 'a) -> 'a -> [stmt] -> 'a *)
val fold_stmts : ('a -> node -> 'a) -> 'a -> stmt list -> 'a

(** Whether any node in a statement sequence satisfies p.
    (node -> bool) -> [stmt] -> bool *)
val exists_stmts : (node -> bool) -> stmt list -> bool

(** Every expression in a subtree, pre-order. node -> [expr] *)
val exprs : node -> expr list

(** Every statement in a subtree, pre-order. node -> [stmt] *)
val stmts_in : node -> stmt list

(** The value of a node's `name` field, where it has one. Note what is
    not one: a PText's captured middle is called `rest`, and the
    variables a TForall binds are called `vars`, so neither is an
    identifier by this test. node -> string option *)
val name_field : node -> string option
