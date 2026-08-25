

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

### Function type_check

Function `type_check(stmts:[Stmt]) -> TMap` is the main type checking
function that takes a list of statements as input.
If type checking fails, it raises an error, therwise it returns
a type map, `TMap = {Int: Type}`, i.e., a mapping from symbols
(represented as integers) to types.


Function `type_check` creates a mutable variable `tmap` and calls
function `check_stmts`. Key data structures that are used in the
during type checking

* `env : {String: Type?}`, mapping a name in the environment to a option
type. *WHY OPTION?*

* `Store`  *WHAT IS THE STORE?*
