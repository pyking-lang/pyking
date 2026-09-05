// The JavaScript side of the compiler's browser boundary: the primitives
// pyking_web.ml declares as `external`. js_of_ocaml compiles an OCaml
// closure of known arity to a JavaScript function of the same arity, so
// each of these is `globalThis[name] = f` and nothing more; the 0-ary
// one is called with OCaml's unit, which is the integer 0 here.
//
// Written by hand rather than generated, and small on purpose: it is the
// only JavaScript the compiler itself needs, and it needs no OCaml
// library to declare it.

//Provides: pyk_register0
function pyk_register0(name, f) {
  globalThis[name] = function () { return f(0); };
  return 0;
}

//Provides: pyk_register1
function pyk_register1(name, f) {
  globalThis[name] = function (a) { return f(a); };
  return 0;
}

//Provides: pyk_register3
function pyk_register3(name, f) {
  globalThis[name] = function (a, b, c) { return f(a, b, c); };
  return 0;
}

// Where a running program's output goes. The page replaces this before it
// runs anything; until then, printed lines are dropped rather than lost
// in a thrown exception.
//Provides: pyk_emit
function pyk_emit(line) {
  (globalThis.pykOnPrint || function () {})(line);
  return 0;
}
