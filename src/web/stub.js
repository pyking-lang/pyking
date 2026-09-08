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

// Calling into a module implemented in JavaScript, for the `iweb`
// target: the page registers `pykExternal`, which answers what one of an
// external module's exports is, or calls one of its functions. Values
// cross as JSON, which is the one encoding both sides already have --
// see docs/modules.md, "What may cross the boundary".
//Provides: pyk_external
function pyk_external(module_, field, argsJson) {
  var table = globalThis.pykExternals || {};
  var target = table[module_];
  if (!target) {
    throw new Error("no external module '" + module_ + "' was supplied");
  }
  if (!(field in target)) {
    throw new Error("'" + module_ + "' has no '" + field + "'");
  }
  var value = target[field];
  // An empty argument list means "this is a value, not a call": OCaml
  // passes a string, so the empty one is the sentinel.
  if (argsJson === "") {
    return JSON.stringify(value === undefined ? null : value);
  }
  var result = value.apply(null, JSON.parse(argsJson));
  return JSON.stringify(result === undefined ? null : result);
}

// The program's own files, for the `iweb` target and for a playground
// running a program of several modules: the page puts them in
// `pykSources` as {name: text}, and the module system reads them
// through these two exactly as it reads a directory.
//Provides: pyk_file_exists
function pyk_file_exists(name) {
  return Object.prototype.hasOwnProperty.call(globalThis.pykSources || {}, name)
    ? "1"
    : "";
}

//Provides: pyk_file_read
function pyk_file_read(name) {
  var files = globalThis.pykSources || {};
  if (!Object.prototype.hasOwnProperty.call(files, name)) {
    throw new Error("no source '" + name + "' was supplied");
  }
  return files[name];
}
