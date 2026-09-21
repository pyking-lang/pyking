# Static overloading

Two definitions may share a name if they are told apart by a
**qualifier**: `int::leq` and `float::leq` are two names, and a call
written `leq(1, 2)` is resolved to one of them by its arguments. The
qualifier is part of the name and nothing else — `int` and `float` mean
nothing here, they only make the names unique.

Resolution happens in the type checker, which changes nothing; what it
writes down is `qmap`, and `src/elaborate.ml` rewrites the program by
it. See [implicits.md](implicits.md) for the other half of that pass,
and PYKING.md, "Static overloading", for what the language says.

## What a qualifier may be written on

A `def` with **at least one parameter**, and nothing else. A call's
arguments are what say which definition it means, so a name with
nothing to resolve it by is refused where it is written rather than
where it is used:

```
$ pyk compile -t pyking tests/fail_typecheck_overload_value.pyk
'...' 11:4-11:13 Parsing error: 'int::zero' takes no argument, so
  nothing could say which definition of 'zero' a call means; a '::'
  name belongs to a 'def' that takes at least one
```

The same refusal covers an `=` binding, a `var`, a parameter, a loop
variable, a pattern capture, a module name and an import alias. All of
them are `src/parser.ml`'s `check_plain_name`, which is the one place
the rule is written.

A qualified name *is* one identifier: the lexer reads `int::leq` as a
single `TokIdent`, with no whitespace permitted on either side of the
`::`, which is what keeps it clear of the block `:` and the annotation
`:`. `src/names.ml` is the only place one is taken apart.

## A plain definition is not a member of any set

If a file binds `leq` plainly, `leq(1, 2)` means *that* one and
type-errors if it does not fit. There is no fallback to the `::`
definitions. The alternative — try the plain one, then the set — would
give one name two meanings depending on what else the file happens to
contain.

## How a call is resolved

`Typesystem.resolve_overload`, and it is four steps:

1. **The arguments are checked once**, left to right, exactly as any
   call's are. What they turn out to be is what the candidates are
   tried against; nothing is checked twice.
2. **Candidates** are every binding in scope whose base name is the one
   written. An unqualified call sees this file's own `q::name`
   definitions and, through an import, a module's *public implicit*
   ones — those are the only names that arrive unqualified (PYKING.md,
   "Modules"). A `mod.name(...)` call sees that module's.
3. **Each candidate is tried in a store of its own**: instantiated,
   checked for arity, and unified argument by argument. The store is a
   value, so a trial that does not fit is discarded by not being kept —
   there is no backtracking to undo.
4. **Exactly one survivor resolves the call**, and its store is the one
   that is kept.

The test is **unification, not matching**. That is what lets
`leq([171, 10], [188])` pick `list::leq` when the argument type is
still `[?1]`: choosing the candidate is what decides `?1 = Int`. A rule
that demanded a ground argument type first would resolve almost
nothing, since an argument is usually a call whose own type is still
being worked out.

Two candidates fitting is an error, and so is none:

```
no definition of 'twice' takes (Bool); the ones in scope are
  'int::twice' of type (Int) -> Int, 'string::twice' of type
  (String) -> String
```

An argument type nothing has decided fits *every* candidate, and saying
so is worth more than listing them:

```
nothing here decides which 'twice' is meant: 'int::twice' and
  'string::twice' all take these arguments, and the type of at least
  one of them is still open. Annotate it, or take the definition as an
  implicit parameter
```

That last sentence is the whole design in one line. Deferring the
choice until something decides the type is inferred contexts, which is
type classes; the feature that solves the problem properly is an
implicit parameter, and it is next door.

## Defaults, and the count that settles first

A default parameter lets a definition take fewer arguments, so it is
part of what says whether a call *could* mean it. But defaults are
erased before the type checker runs -- `src/desugar_args.ml` turns each
one into a generated `def` and fills omitted arguments in at the call
-- and it fills them only where it can tell which definition a call
reaches. On an overloaded name it cannot, since that is settled by the
types it does not have.

So the **count** is settled there and the **types** here:

- Exactly one definition takes the call once defaults are counted →
  that one's defaults are filled in, and the checker resolves what is
  left in the ordinary way. It may still refuse the call on types; the
  filling commits to nothing.
- Two or more take it, and one of them only by using a default →
  refused, because nothing says which:

  ```
  this call to 'my2' is ambiguous: 'b::my2' takes them as written and
    'c::my2' takes them with its default for 'z' -- write the
    qualified name to say which is meant
  ```

- Two or more take it and none needs a default → left alone, which is
  ordinary overloading and the checker's question.

A **named argument** on an overloaded call is refused for the same
reason: putting one in its parameter's place needs to know whose
parameter list to use.

*Not optimal:* the first rule is the count only. Two definitions that
take a call at the same arity, one of them by default, are refused even
where their types would have told them apart. Making that work means
the checker seeing which parameters had defaults, which is a table
`desugar_args` would have to hand it; the message names the way out
(write the qualifier), so the refusal costs one word.

## What the output holds

`src/elaborate.ml` renames `q::b` to `q__b` — at the definition, at
every reference, and in the `fields` of an import — so no backend and
not the interpreter ever sees a `::`. A program that also binds the
plain name is refused by name:

```
'int::twice' and 'int__twice' cannot both be bound in this program: a
  qualified name compiles to the plain one, and the two would be one
  name
```

The renaming is deterministic, which is what lets two modules agree on
it with no shared state. A module's *sigmap* keeps the source's own
spelling, since that is what the file importing it writes; the sigmap
a **backend** is handed is renamed, since that is what the generated
file declares (`Module.context`).

`-t pyking` prints the renamed program, so `tests/typecheck_overload.ast.out`
pins every resolution this feature makes.

## Where each piece lives

| | |
|---|---|
| `src/names.ml` | the spelling: `is_qualified`, `qualifier`, `base`, `renamed`, `field` |
| `src/lexer.ml` | one `TokIdent` for `q::b`; a keyword half is refused |
| `src/parser.ml` | `check_plain_name`, and the arity rule on a `def` |
| `src/typesystem.ml` | `candidates_for`, `resolve_overload`, `qmap` |
| `src/elaborate.ml` | the renaming, and the clash check |
| `src/module.ml` | the renamed sigmap a backend is given |

## What is not done

- **No return-type-directed resolution.** The arguments decide, and the
  result is a consequence of the choice. Giving the checker an expected
  type at a call means threading one through `check_expr`, which is a
  change to the checker's shape rather than an addition to it.
- **No overloaded values and no nullary overloads**, for the same
  reason: there would be nothing to resolve them by.
- **A builtin's name is never part of a set.** `str`, `len`, `print`,
  `range`, `float` and `int` are `TBuiltin` and are checked by
  `check_builtin_call` rather than by unification; joining the two
  rules would mean one call site using both.
- **A declaration half may not carry a qualified name.** An external
  module's `.external.pyk` writes signatures, which no pass renames.
