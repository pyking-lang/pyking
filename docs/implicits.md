# Implicit parameters

A parameter written `implicit` may be left out at a call, and the type
checker fills it from the calling context: it looks for a binding of
that **name** whose **type** fits. Both halves matter, and both are
part of the function's type.

```pyking
def foo(x: a, implicit bar: (a) -> b) -> (b, b):
    (bar(x), bar(x))

def my1() -> ():
    implicit def bar(z: Int) -> String: str(z) ++ "!"
    print(foo(78))                      # ('78!', '78!')
```

The design follows "Syntactic Implicit Parameters with Static
Overloading" (OOPSLA 2025). [overloading.md](overloading.md) is the
other half of the same pass; PYKING.md, "Implicits", is what the
language says.

## The rules, and why each one is there

**Only an `implicit` definition is ever resolved to.** An ordinary
binding of the right name and the right type is invisible to the
search. The keyword at the *definition* is what makes a value findable,
so nothing is captured by accident — which is the mistake this design
is most careful to avoid, and the one place it departs from Koka.

**The name is half of the question.** `implicit bar: (a) -> b` asks for
something called `bar`. That is why the same `foo` means two different
things in two scopes without being written twice, and why an implicit
parameter's name is part of the function's type: `(implicit bar: T) -> U`
and `(implicit baz: T) -> U` are different types.

**Implicit parameters are trailing.** It makes filling them "append",
keeps an arity error counting explicit parameters only, and lets them
live in a field of their own — so nothing that reads a function's
parameters had to change.

**A definition with implicit parameters, or one that is itself
implicit, writes its whole type down.** Resolving is a question about
types, and there has to be a type to ask it of.

**There is no specificity ordering.** Two candidates that both fit is
an error for the programmer to settle, by writing the argument out.
Ordering them would mean a coherence argument, and there is none to
make.

## The search

`Typesystem.resolve_implicit`, for one parameter `bar : T` at one call:

1. Every **implicit** binding in scope whose base name is `bar` — its
   own, or `q::bar` for any qualifier, or one a module brought in.
2. Each is instantiated and **stripped of its own implicit
   parameters**, and what is left is unified with `T` in a store of its
   own. The stripped parameters become *obligations*.
3. Exactly one fit resolves it; none and several are both errors, and
   the "none" message names a non-implicit binding of that name where
   there is one, since that is the mistake worth pointing at.
4. The obligations are discharged **in the scope of the call**, not
   inside the callee, to a depth of 32.

## The dictionary

An implicit that is filled by a definition taking implicit arguments of
its own cannot simply be named: it is wanted at a type that has no
implicit parameters. What is passed is a **lambda that supplies them**:

```pyking
less_index([2], [[1], [2, 3]])
```

resolves `implicit leq: ([Int], [Int]) -> Bool` to `list::leq`, whose
own `implicit leq: (Int, Int) -> Bool` is then discharged to
`int::leq`, and the argument built for it is

```pyking
(__implicit__1: [Int], __implicit__2: [Int]) =>
    list__leq(__implicit__1, __implicit__2, int__leq)
```

This is a dictionary in the type-class sense, constructed at the call
site rather than looked up at run time. It is why lambdas are part of
this change, and it is the one place the pass generates a name
(`Elaborate.generated_name` says which).

*Not optimal:* a lambda is what C and Java have no closures for, so a
program whose resolution needs a wrapper compiles on Python,
JavaScript, OCaml and the interpreter and is refused on those two. A
generated `def` would have compiled everywhere — a wrapper captures no
value, only function names — and switching is a change to one function
in `elaborate.ml` if that turns out to matter.

## A function carrying implicits, passed on

The same adaptation applies to an **explicit** argument. A function
whose type says `implicit my` is called with `my` resolved where the
call is written; handing it somewhere that wants an ordinary function
is that demand one step earlier, so the implicit is resolved *there*
and what is passed is the lambda that supplies it.

```pyking
implicit my = 10

def bar(a, f):                  # f is (Int) -> a: a body cannot
    f(a + 1)                    # discover an implicit parameter

def foo(x: Int, implicit my: Int) -> Int: x + my

print(bar(7, foo))              # 18 -- foo's `my` resolved here
```

`bar` writes no types, so inference reads `f` off its body, and the
body can only say that `f` takes one argument. `foo` does not have that
type -- but it can be *made* to, by supplying what it asks for, and the
scope that has to answer is the one passing it. `elaborate.ml` writes

```pyking
bar(7, (__implicit__1: Int) => foo(__implicit__1, my))
```

Writing the implicit into `f`'s type says the other thing, and the two
are meant to differ:

```pyking
def bar(a, f: (Int, implicit my: Int) -> Int):
    implicit my = 7
    f(a + 1)                    # 15 -- resolved in bar's own body
```

It goes the other way too. A function that asks for **nothing** stands
wherever one that asks for an implicit is wanted: the lambda takes the
implicit argument and hands on only what the value wants. So a
parameter written `f: (Int, implicit my: Int) -> Int` accepts both

```pyking
def bar(a, f: (Int, implicit my: Int) -> Int):
    implicit my = 10
    f(a + 1)

print(bar(7, adds))         # adds asks for `my`: passed as it is
print(bar(2, x => x + 1))   # the lambda does not: it is widened
```

and that is usually the annotation to write, because it is the one that
resolves the implicit **inside** `bar`, where `bar`'s own `my` is.

`Typesystem.adapted` is the rule, tried where an argument does not fit
its parameter and before the mismatch is reported. It applies only when
the two types differ by nothing but their implicit parameters, so a
genuine mismatch still reads as one, and it wraps whatever expression
was written rather than only a name.
`tests/typecheck_implicit_adapt.pyk` and
`tests/typecheck_implicit_deferred.pyk` pin all four combinations.

When the supply direction cannot find what it needs, the message says
*why the search happened there*, since that is the part that surprises:

```
no implicit 'my' of type Int is in scope here. 'foo' takes it
  implicitly and the parameter it is passed to does not, so it is
  resolved here rather than where that parameter is called; write the
  implicit into that parameter's own type to have it resolved there
  instead
```

## An obligation never crosses a `def`

This is the decision that defines the system. If a body calls something
whose type carries an implicit `bar`, and that body's own scope has no
implicit `bar`, it is an error **there**:

```pyking
def run(f: (Int, implicit bar: (Int) -> String) -> String) -> String:
    f(2)                                # error: no implicit 'bar' here
```

The fix is to write `implicit bar` in `run`'s own parameters.
Propagating the obligation outward into `run`'s inferred type is
inferred contexts — type classes — and every guarantee the inference
makes (docs/type_inference.md, §5) rests on not doing that.

What *is* supported, and is the reason implicits are part of the type
rather than of the definition, is passing an implicit-taking function
as a value and calling it somewhere else. The resolution happens where
the **call** is written, whatever that call's callee is:

```pyking
def apply_twice(f: (Int, implicit bar: (Int) -> String) -> (String, String),
                n: Int) -> (String, String):
    implicit def bar(z: Int) -> String: str(z * 2)
    f(n)                                # `bar` resolved here
```

`tests/implicit_function.pyk` pins both halves.

## Across a module boundary

A **public implicit** is found by an unqualified call in the file that
imports the module, automatically; a public name that is not implicit
is reached through the module name as usual. It is bound under one
spelling either way, so a resolution always names the module it came
from and `elaborate.ml` writes `mod.int__leq` rather than a name
nothing declared.

Auto-import is **not transitive**: what is in scope is what this file
imports. The cost — a library cannot re-export another's orderings — is
stated in PYKING.md rather than fixed.

## Why one check is enough

The checker changes nothing. What it produces beside `tmap` is `qmap`,
a call's symbol → what that call denotes, and `src/elaborate.ml`
rewrites the program by it: names renamed, resolved calls naming their
definition, implicit parameters made ordinary. Everything downstream —
the mutability analysis, the tail-call pass, nine backends, the
interpreter — sees ordinary Pyking.

**The checker does not run again.** That is the same bargain
`opt_tailcall.ml` makes (docs/optimization.md, "Why one check is
enough"), and it is paid for the same way — with an argument that the
rewrite preserves typing by construction:

- Every node the pass builds gets its type from `qmap`, and every type
  in `qmap` is one the checker worked out by unification at the point
  the demand was made. Nothing is guessed.
- The rewrite is type-preserving case by case. Renaming `q::b` to `q__b`
  changes no type. Naming the resolved definition at a call replaces a
  callee whose type the checker never recorded with one whose type is
  exactly the candidate it chose. Appending resolved arguments turns
  `(P...) -> R` with implicits `I...` into `(P..., I...) -> R`, which is
  `Typesystem.without_implicits` of the same type — applied to the
  definition, to the sigmap a backend sees, and to the call, so the
  three agree by construction.
- A generated lambda's type is the parameter type it fills, its
  parameters are that type's parameters, and its body is a call to a
  definition whose type is that parameter list extended by the types of
  the arguments it supplies — each of which is in `qmap` in turn.

Three mechanics keep `qmap` honest and are easy to break.
`record_resolution` **overwrites**, as `record` does, because a
generalisable body is checked twice and `verified`'s pass is the one
that counts. `type_check` reads every resolution back through `zonk` at
the end, since one recorded while a metavariable was open may have been
decided by something written further down. And **`learned` carries
`qmap` back**, as it carries `tmap`: a definition that wrote no types
is worked out in a store of its own, and a call resolved in there is
resolved once — dropping it leaves `elaborate.ml` with nothing to
rewrite that call by, so the program type-checks and then calls a
function with the wrong number of arguments.
`tests/typecheck_implicit_deferred.pyk` pins all three.

## Where each piece lives

| | |
|---|---|
| `src/lexer.ml` | the `implicit` keyword |
| `src/parser.ml` | `implicit` on a `def` and an `=`; `parse_implicit_params`; `parse_implicit_type_params` |
| `src/syntax.ml` | `IParam`, `TFunction`'s seventh field, `SFunctionDef`'s last two |
| `src/typesystem.ml` | `binding.bimplicit`, `resolve_implicit`, `discharge`, `qmap` |
| `src/elaborate.ml` | the rewrite, and the generated lambda |
| `src/desugar_args.ml` | an implicit parameter a call leaves out |
| `src/repl.ml` | an entry checked under the source's names, run under the rewritten ones |

## What is not done

- **An implicit parameter on a signature line.** A `def name : type`
  line says a type and binds nothing, so an implicit parameter there
  would name something the body cannot use; it is written on the `def`
  itself. The same goes for `implicit` in front of one, and for either
  in an external module's declaration half, which no pass rewrites.
- **Partial explicit supply.** A call writes out every implicit
  argument or none of them.
- **`implicit var`.** A binding resolved at compile time whose value is
  written at run time is a trap.
- **An implicit parameter on a lambda.** It is part of a function's
  type, and only a `def` writes one down.
