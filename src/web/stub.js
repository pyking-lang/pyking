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

// Where a running program's `debug` lines go: `pykOnDebug` where the page
// supplied one, and the console otherwise -- debug output is for whoever
// is debugging, and the console is where they look.
//Provides: pyk_debug
function pyk_debug(line) {
  var sink = globalThis.pykOnDebug || function (text) {
    console.error(text.replace(/\n$/, ""));
  };
  sink(line);
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
    return pyk_encode(value);
  }
  var result;
  try {
    result = value.apply(null, JSON.parse(argsJson));
  } catch (error) {
    // `sys.exit` stops the program by throwing an error carrying
    // `pykExit`. It crosses back as data, which pyking_web.ml turns into
    // the end of the run, rather than as a JavaScript exception unwinding
    // through the interpreter.
    if (error && error.pykExit !== undefined) {
      return '{"pyk_exit":' + JSON.stringify(error.pykExit) + "}";
    }
    throw error;
  }
  return pyk_encode(result);
}

// A Pyking list and a Pyking tuple are both arrays here, told apart by
// the `pykList` marker a list carries (docs/modules.md, "What may cross
// the boundary"). `JSON.stringify` drops that marker, so a tuple would
// reach the interpreter as a list -- this keeps the two apart by
// writing a tuple as an object the reader knows.
function pyk_encode(value) {
  if (Array.isArray(value)) {
    var parts = [];
    for (var i = 0; i < value.length; i += 1) {
      parts.push(pyk_encode(value[i]));
    }
    return value.pykList
      ? "[" + parts.join(",") + "]"
      : '{"pyk_tuple":[' + parts.join(",") + "]}";
  }
  return JSON.stringify(value === undefined ? null : value);
}

// The program's own files, for the `iweb` target and for a playground
// running a program of several modules: the page puts them in
// `pykSources` as {name: text}, and the module system reads them
// through these two exactly as it reads a directory.
//
// A name the page did not supply is asked of `pykFetchSource`, where the
// page has one: that is how a program run in the playground or a notebook
// imports the standard library, fetched the first time it is named.
//Provides: pyk_file_exists
//Requires: pyk_source
function pyk_file_exists(name) {
  return pyk_source(name) === null ? "" : "1";
}

//Provides: pyk_file_read
//Requires: pyk_source
function pyk_file_read(name) {
  var text = pyk_source(name);
  if (text === null) {
    throw new Error("no source '" + name + "' was supplied");
  }
  return text;
}

//Provides: pyk_source
function pyk_source(name) {
  var files = globalThis.pykSources || (globalThis.pykSources = {});
  if (Object.prototype.hasOwnProperty.call(files, name)) return files[name];
  var fetched = globalThis.pykFetchSource ? globalThis.pykFetchSource(name) : null;
  if (typeof fetched !== "string") return null;
  files[name] = fetched;
  return fetched;
}

// A file of the standard library, by its path under lib/ -- what a page
// compiling for `web` ships beside the program -- or the empty string
// where the page cannot supply one.
//Provides: pyk_library_file
function pyk_library_file(path) {
  var text = globalThis.pykLibraryFile ? globalThis.pykLibraryFile(path) : null;
  return typeof text === "string" ? text : "";
}
