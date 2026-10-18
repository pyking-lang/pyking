// The JavaScript side of the compiler's browser boundary: the primitives
// pyking_web.ml declares as `external`. js_of_ocaml compiles an OCaml
// closure of known arity to a JavaScript function of the same arity, so
// each of these is `globalThis[name] = f` and nothing more; the 0-ary
// one is called with OCaml's unit, which is the integer 0 here.
//
// Written by hand rather than generated, and small on purpose: it is the
// only JavaScript the compiler itself needs, and it needs no OCaml
// library to declare it.

// Text crossing into OCaml is UTF-8 bytes, one character each, as the
// native pyk reads a file; text crossing out is read back from them.
// A string Pyking made that is not UTF-8 crosses out as its bytes.
//Provides: pyk_utf8_of_text
function pyk_utf8_of_text(text) {
  try {
    return unescape(encodeURIComponent(text));
  } catch (error) {
    return text;
  }
}

//Provides: pyk_text_of_utf8
function pyk_text_of_utf8(bytes) {
  try {
    return decodeURIComponent(escape(bytes));
  } catch (error) {
    return bytes;
  }
}

//Provides: pyk_register0
//Requires: pyk_text_of_utf8
function pyk_register0(name, f) {
  globalThis[name] = function () { return pyk_text_of_utf8(f(0)); };
  return 0;
}

//Provides: pyk_register1
//Requires: pyk_utf8_of_text, pyk_text_of_utf8
function pyk_register1(name, f) {
  globalThis[name] = function (a) { return pyk_text_of_utf8(f(pyk_utf8_of_text(a))); };
  return 0;
}

//Provides: pyk_register_utf8
// Like pyk_register1, for text that may hold any character: the argument
// is handed to OCaml as UTF-8 bytes and the answer read back from them,
// so a column counted in bytes means what it does in the native pyk.
function pyk_register_utf8(name, f) {
  globalThis[name] = function (a) {
    return decodeURIComponent(escape(f(unescape(encodeURIComponent(a)))));
  };
  return 0;
}

//Provides: pyk_register_utf8_0
function pyk_register_utf8_0(name, f) {
  globalThis[name] = function () { return decodeURIComponent(escape(f(0))); };
  return 0;
}

//Provides: pyk_register3
//Requires: pyk_utf8_of_text, pyk_text_of_utf8
function pyk_register3(name, f) {
  globalThis[name] = function (a, b, c) {
    return pyk_text_of_utf8(f(pyk_utf8_of_text(a), pyk_utf8_of_text(b), pyk_utf8_of_text(c)));
  };
  return 0;
}

// Where a running program's output goes. The page replaces this before it
// runs anything; until then, printed lines are dropped rather than lost
// in a thrown exception.
//Provides: pyk_emit
//Requires: pyk_text_of_utf8
function pyk_emit(line) {
  (globalThis.pykOnPrint || function () {})(pyk_text_of_utf8(line));
  return 0;
}

// Where a running program's `debug` lines go: `pykOnDebug` where the page
// supplied one, and the console otherwise -- debug output is for whoever
// is debugging, and the console is where they look.
//Provides: pyk_debug
//Requires: pyk_text_of_utf8
function pyk_debug(line) {
  var sink = globalThis.pykOnDebug || function (text) {
    console.error(text.replace(/\n$/, ""));
  };
  sink(pyk_text_of_utf8(line));
  return 0;
}

// Where the playground's REPL sends what it shows of an entry -- a
// value and its type, a command's answer -- kept apart from what the
// program printed: `pykOnShow` where the page supplied one, and
// `pykOnPrint` otherwise.
//Provides: pyk_show
//Requires: pyk_text_of_utf8
function pyk_show(line) {
  (globalThis.pykOnShow || globalThis.pykOnPrint || function () {})(pyk_text_of_utf8(line));
  return 0;
}

// Calling into a module implemented in JavaScript, for the `iweb`
// target: the page registers `pykExternal`, which answers what one of an
// external module's exports is, or calls one of its functions. Values
// cross as JSON, which is the one encoding both sides already have --
// see docs/modules.md, "What may cross the boundary". The JSON is UTF-8
// bytes on the OCaml side, so text with any character crosses whole.
//Provides: pyk_external
//Requires: pyk_external_text, pyk_utf8_of_text, pyk_text_of_utf8
function pyk_external(module_, field, argsJson) {
  return pyk_utf8_of_text(pyk_external_text(module_, field, pyk_text_of_utf8(argsJson)));
}

// pyk_external, with the JSON as JavaScript text both ways.
//Provides: pyk_external_text
function pyk_external_text(module_, field, argsJson) {
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
    result = value.apply(null, pyk_revive(JSON.parse(argsJson)));
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

// An argument as the JavaScript value it stands for: a Float written as
// {"pyk_float":text} becomes a number, and a Pyking function written as
// {"pyk_callback":id} becomes a JavaScript function calling it back
// through `pykCallback`. A failure in that call goes to `pykOnError`
// where the page supplied one, and `sys.exit` to `pykOnExit`.
function pyk_revive(value) {
  if (Array.isArray(value)) {
    return value.map(pyk_revive);
  }
  if (value !== null && typeof value === "object") {
    if (typeof value.pyk_float === "string") {
      var text = value.pyk_float;
      return text === "nan" ? NaN : text === "inf" ? Infinity
        : text === "-inf" ? -Infinity : Number(text);
    }
    if (typeof value.pyk_callback === "number") {
      var id = value.pyk_callback;
      return function () {
        var args = Array.prototype.slice.call(arguments);
        var answer = JSON.parse(
          globalThis.pykCallback(id + "\n" + pyk_encode(args.map(pyk_list))));
        if (!answer.ok) {
          (globalThis.pykOnError || function (text) { console.error(text); })(answer.text);
        } else if (answer.exit !== undefined && globalThis.pykOnExit) {
          globalThis.pykOnExit(answer.exit);
        }
      };
    }
  }
  return value;
}

// An argument handed to a Pyking function: an array becomes a list, as
// JavaScript code calling back means one, unless it is marked otherwise.
function pyk_list(value) {
  if (Array.isArray(value) && !value.pykList) {
    var copy = value.map(pyk_list);
    copy.pykList = true;
    return copy;
  }
  return value;
}

// A Pyking list and a Pyking tuple are both arrays here, told apart by
// the `pykList` marker a list carries (docs/modules.md, "What may cross
// the boundary"). `JSON.stringify` drops that marker, so a tuple would
// reach the interpreter as a list -- this keeps the two apart by
// writing a tuple as an object the reader knows. JSON has no NaN, no
// infinity and no -0, so those cross under the Float marker.
function pyk_encode(value) {
  if (typeof value === "number" && (!isFinite(value) || Object.is(value, -0))) {
    var text = value !== value ? "nan" : value === Infinity ? "inf"
      : value === -Infinity ? "-inf" : "-0.0";
    return '{"pyk_float":"' + text + '"}';
  }
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
//Requires: pyk_source, pyk_text_of_utf8
function pyk_file_exists(name) {
  return pyk_source(pyk_text_of_utf8(name)) === null ? "" : "1";
}

//Provides: pyk_file_read
//Requires: pyk_source, pyk_utf8_of_text, pyk_text_of_utf8
function pyk_file_read(name) {
  var text = pyk_source(pyk_text_of_utf8(name));
  if (text === null) {
    throw new Error("no source '" + name + "' was supplied");
  }
  return pyk_utf8_of_text(text);
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
//Requires: pyk_utf8_of_text
function pyk_library_file(path) {
  var text = globalThis.pykLibraryFile ? globalThis.pykLibraryFile(path) : null;
  return typeof text === "string" ? pyk_utf8_of_text(text) : "";
}
