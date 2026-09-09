(** The browser-side entry point to the Pyking compiler: the same stages
    pyk.ml runs, exposed as functions the page can call and answering
    JSON strings rather than reading argv or touching a filesystem.
    Compiled to JavaScript by js_of_ocaml (see docs/build.md and
    tools/playground/README.md).

    This module exports nothing to OCaml, and that is the interface: its
    boundary is the other way round -- the entry points the
    `let () = ...` at the bottom of the file registers on the global
    object, through the primitives in stub.js.

      pykCompile(source, target, name)  compile, as JSON
      pykRun(source, name)              run with the interpreter, as JSON
      pykTargets()                      the targets, as JSON
      pykFormatHelper()                 the JS value formatter's source
      pykKeywords() / pykBuiltins()     the language's own word lists

    Nothing here is compiler logic: every entry goes through the same
    library functions pyk.ml calls, and reports a refusal with the same
    error wording. *)
