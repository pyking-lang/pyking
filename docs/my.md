

# Pyking System Design

*By David Broman*

This document contains informal notes about the archiecture of the
pyking compiler. This is a document that no AI system is allowed to
modify, i.e., it is must be completely written by humans.

## Type checker

The type checker is implemented in file `src/typesystem.py`. It is
written in a functional style in Python, with the aim of making it
easy to translate it into pure Pyking functions when bootstrapping the
compiler.

### Functions type_check and check_stmts

Function `type_check(stmts:[Stmt]) -> TMap` is the main type checking
function that takes a list of statements as input.
If type checking fails, it raises an error, therwise it returns
a type map, `TMap = {Int: Type}`, i.e., a mapping from symbols
(represented as integers) to types.


Function `type_check` creates a mutable variable `tmap` and calls
function `check_stmts`, with the following named signature:

`def check_ stmts(stmts, env, tmap, return_type, loop, store)`
`([Stmt], Env, {Int: Type}, Type?, Type?, Store) -> (Type, Store)"`

Key data structures, and paramerers used in the
during type checking


* `env : {String: Type?}`, mapping a name in the environment to a option
type. *WHY OPTION?*

* `return_type : Type?`, this is the optional type that is expected to be 
returned. This is provided if type checking is within a function (the type
is fiven by the signature. If the outer most loop, None is assigned to the
return type

* `loop : Loop?`. It contains information if the checker is inside a `loop` construct. If not is not inside a loop, it has value None. If within a loop, `loop.accumulator : Type` contains the type of the accumulator. This is found directly by type checking the initializatio of the accumulator. But, loops do not have to contain a declared accumulator. If it contains a accumulator, written is true, else it is false. The main reason is to give reasonable error message if `continue` is given with a value, but there is not accumulator declared. 





* `Store`  *WHAT IS THE STORE?*
