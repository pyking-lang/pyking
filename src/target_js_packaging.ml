(** Packaging for the JavaScript backends: wraps target_js_core.ml's
    target-independent output into the files each of nodejs/html/esm
    delivers, and supplies the JavaScript side of the runtime interface
    (where print goes). See
    docs/target_js.md, "The three targets".

    Functions:
      package_program target units output_path stdout -- every file a
        whole program emits, and the text --stdout prints.
      reserved_names modules -- the JavaScript names a packaging writes
        around a program, which a Pyking binding may not take.
      package_nodejs / package_html / package_esm_module -- one
        target's file(s).
      esm_paths output_path -- the four paths the esm target writes. *)

open Target_js_core

(* The module holding `print` for a nodejs program of several files, so
   that the host code is written once rather than copied into every one.
   The hyphen is deliberate: a Pyking module is imported by name, so its
   file's stem is an identifier, and no Pyking module can ever be called
   this -- which is what makes the name safe to take. *)
let runtime_module = "pyk-runtime.js"

(** Every JavaScript name a packaging writes around a program, which a
    Pyking binding must therefore not take. A module reached under its
    own name is bound by the `import` line, so each module's name is one
    of them. [string] -> [string] *)
let reserved_names modules = modules

(* The formatter every host needs, implementing builtin.ml's
   print rules. Four values need converting: JavaScript's undefined (a
   unit-returning function's actual result), which Pyking spells `()`; a
   tuple, which is an array here and prints in Pyking's own notation;
   a string inside one, which is quoted where a string on its own is
   not; and a datatype's value, built by the compiled program's
   `pykData`. Everything else -- numbers, booleans -- already prints the way
   Pyking wants. *)
let format_js =
  String.concat "\n"
    [
      "function pykFormat(value, inner) {";
      "  if (value === undefined) return '()';";
      "  if (typeof value === 'string') return inner ? pykQuote(value) : value;";
      "  // A Pyking list and a Pyking tuple are both JavaScript arrays and";
      "  // print differently, so a list carries a marker (see `pykList` in the";
      "  // compiled program). A property rather than a class, because for the";
      "  // `esm` target the two live in different modules.";
      "  if (Array.isArray(value) && value.pykList === true) {";
      "    return '[' + value.map((element) => pykFormat(element, true)).join(', ') + ']';";
      "  }";
      "  if (Array.isArray(value)) {";
      "    const parts = value.map((element) => pykFormat(element, true));";
      "    return parts.length === 1 ? '(' + parts[0] + ',)' : '(' + parts.join(', ') + ')';";
      "  }";
      "  // A datatype's value: its constructor and its fields by position,";
      "  // each Float one written as a Float where the compiler said so.";
      "  if (value !== null && typeof value === 'object' && value.pykTag !== undefined) {";
      "    if (value.pykValues.length === 0) return value.pykTag;";
      "    const shapes = value.pykShape === null ? null : pykShapeParts(value.pykShape.slice(1, -1));";
      "    const parts = value.pykValues.map((element, i) =>";
      "      shapes === null ? pykFormat(element, true) : pykShaped(element, shapes[i], true));";
      "    return value.pykTag + '(' + parts.join(', ') + ')';";
      "  }";
      "  return String(value);";
      "}";
      "";
      "function pykQuote(text) {";
      "  return \"'\" + text";
      "    .replace(/\\\\/g, '\\\\\\\\')";
      "    .replace(/'/g, \"\\\\'\")";
      "    .replace(/\\n/g, '\\\\n')";
      "    .replace(/\\t/g, '\\\\t')";
      "    .replace(/\\r/g, '\\\\r') + \"'\";";
      "}";
    ]

(* builtin.ml's rule, in JavaScript, and the walk that goes with it. A
   JavaScript number is one type, so a value's own form never says
   whether Pyking called it an Int or a Float: the compiler reads that
   off the checker's types and hands `pykShaped` a descriptor saying
   which positions are Floats (see target_js.md, "Floats"). *)
let float_js =
  String.concat "\n"
    [
      "function pykFloatStr(x) {";
      "  if (Number.isNaN(x)) return 'nan';";
      "  if (x === Infinity) return 'inf';";
      "  if (x === -Infinity) return '-inf';";
      "  const sign = x < 0 || Object.is(x, -0) ? '-' : '';";
      "  const a = Math.abs(x);";
      "  if (a === 0) return sign + '0.0';";
      "  if (a >= 1e-4 && a < 1e16) {";
      "    const fixed = String(a);";
      "    return sign + (fixed.indexOf('.') < 0 ? fixed + '.0' : fixed);";
      "  }";
      "  const s = String(a);";
      "  const at = s.indexOf('e');";
      "  const mant = at < 0 ? s : s.slice(0, at);";
      "  const exp = at < 0 ? 0 : Number(s.slice(at + 1));";
      "  const dot = mant.indexOf('.');";
      "  const whole = dot < 0 ? mant : mant.slice(0, dot);";
      "  const frac = dot < 0 ? '' : mant.slice(dot + 1);";
      "  let digits = (whole + frac).replace(/^0+/, '');";
      "  const decpt = whole === '0' ? exp - (frac.length - digits.length) : whole.length + exp;";
      "  digits = digits.replace(/0+$/, '');";
      "  if (digits === '') digits = '0';";
      "  const n = digits.length;";
      "  if (decpt <= -4 || decpt > 16) {";
      "    const mantissa = n === 1 ? digits : digits[0] + '.' + digits.slice(1);";
      "    return sign + mantissa + 'e' + (decpt - 1);";
      "  }";
      "  if (decpt <= 0) return sign + '0.' + '0'.repeat(-decpt) + digits;";
      "  if (decpt >= n) return sign + digits + '0'.repeat(decpt - n) + '.0';";
      "  return sign + digits.slice(0, decpt) + '.' + digits.slice(decpt);";
      "}";
      "";
      "// The comma-separated parts of a tuple descriptor, split at the";
      "// top level so a nested list or tuple stays whole.";
      "function pykShapeParts(body) {";
      "  const parts = [];";
      "  let depth = 0;";
      "  let start = 0;";
      "  for (let i = 0; i < body.length; i++) {";
      "    const c = body[i];";
      "    if (c === '[' || c === '(') depth++;";
      "    else if (c === ']' || c === ')') depth--;";
      "    else if (c === ',' && depth === 0) {";
      "      parts.push(body.slice(start, i));";
      "      start = i + 1;";
      "    }";
      "  }";
      "  if (body.length > 0) parts.push(body.slice(start));";
      "  return parts;";
      "}";
      "";
      "// `f` is a Float, `.` anything pykFormat already prints right,";
      "// `[s]` a list of s and `(s,s)` a tuple.";
      "function pykShaped(value, shape, inner) {";
      "  if (shape === 'f') return pykFloatStr(value);";
      "  if (shape === '.') return pykFormat(value, inner);";
      "  const body = shape.slice(1, -1);";
      "  if (shape[0] === '[') {";
      "    return '[' + value.map((e) => pykShaped(e, body, true)).join(', ') + ']';";
      "  }";
      "  const parts = pykShapeParts(body).map((s, i) => pykShaped(value[i], s, true));";
      "  return parts.length === 1 ? '(' + parts[0] + ',)' : '(' + parts.join(', ') + ')';";
      "}";
    ]

(* The conversions JavaScript's own `Number` and `parseInt` would get
   wrong: both read strings Pyking does not ("0x1F", " 3", "1_000"), and
   a truncated Float has to answer 0 where it is no Int (builtin.ml, "what
   a conversion reads"). *)
let conversion_js =
  String.concat "\n"
    [
      "function pykParseInt(text) {";
      "  if (!/^[+-]?[0-9]+$/.test(text)) return 0;";
      "  const n = Number(text);";
      "  return n >= -2147483648 && n <= 2147483647 && n !== 0 ? n : 0;";
      "}";
      "";
      "function pykTrunc(x) {";
      "  const t = Math.trunc(x);";
      "  return t >= -2147483648 && t <= 2147483647 && t !== 0 ? t : 0;";
      "}";
      "";
      "function pykParseFloat(text) {";
      "  if (text === 'inf' || text === '+inf') return Infinity;";
      "  if (text === '-inf') return -Infinity;";
      "  if (text === 'nan') return NaN;";
      "  return /^[+-]?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$/.test(text) ? Number(text) : NaN;";
      "}";
    ]

let header source =
  Printf.sprintf "// Generated from %s by the Pyking compiler. Do not edit."
    source

(** One host-crossing builtin implementing the runtime interface --
    `print` or `debug` -- emitting one line through sink.
    string -> string -> string *)
let line_via name sink =
  String.concat "\n"
    [
      Printf.sprintf "function %s(...values) {" name;
      Printf.sprintf "  %s(values.map((value) => pykFormat(value)).join(' '));"
        sink;
      "}";
    ]

(* The browser's standard output: the `io` library's own browser
   implementation, which a page embedding the program may replace. `print`
   writes through it, so a program and an `io.write_line` share one
   stream. *)
let browser_io = "io_external.js"

(* --- modules ---

   One Pyking module is one JavaScript module. ES modules give Pyking's
   own rule for free: a module's top level runs once, the first time
   something imports it, and imports are resolved before the importing
   file runs -- which is exactly "every module runs after everything it
   imports". So there is no `init` to call and no order for the program
   to arrange (docs/target_js.md, "Modules"). *)


(** The names a `from` line takes, as an ES import clause's body. A
    name taken under another is `as`, which is the import list's own
    spelling -- not the `:` an object pattern would use.
    [(string, string)] -> string *)
let selected fields =
  String.concat ", "
    (List.map
       (fun (name, local) ->
         if name = local then name else Printf.sprintf "%s as %s" name local)
       fields)

(** A module's public names, as an export clause's body. Each is
    usually a binding of that very name, so the shorthand says it; a
    name the translation had to rename is exported *as* the name a
    program imports it by, which is what `as` is for. An export name may
    be a word JavaScript reserves even where a binding may not, so
    `export { arguments2 as arguments }` is legal where
    `const arguments` is not.
    [(string, string)] -> [string] -> string *)
let exported renames names =
  if names = [] then "{}"
  else
    "{ "
    ^ String.concat ", "
        (List.map
           (fun name ->
             match List.assoc_opt name renames with
             | Some local -> Printf.sprintf "%s as %s" local name
             | None -> name)
           names)
    ^ " }"

(** One import, as the ES module it is. A module reached under its own
    name is a namespace import; a `from` line names what it takes.
    jsstmt -> string *)
let module_import statement =
  match statement with
  | JsImport (_, module_, name, is_selected, fields) ->
      if is_selected then
        Printf.sprintf "import { %s } from './%s.js';" (selected fields) module_
      else Printf.sprintf "import * as %s from './%s.js';" name module_
  | _ -> ""

(** The jshost every JavaScript file uses: `print` imported from the
    runtime module, and imports written as ES imports. jshost *)
let runtime_host =
  {
    operations = [ ("print", "print"); ("debug", "debug") ];
    importing = Some module_import;
  }

(* --- the files a program becomes --- *)

let beside output_path name =
  let directory = Filename.dirname output_path in
  if directory = "." && not (String.contains output_path '/') then name
  else Filename.concat directory name

(** The file name a generated header names a module by.
    Module.t -> string *)
let source_of (unit : Module.t) = Filename.basename unit.path

(** Whether a module calls one host-crossing builtin, and so needs it
    brought in. [jsstmt] -> string -> bool *)
let calls js_program name =
  uses
    (function JsRuntimeCall (_, used, _) -> used = name | _ -> false)
    js_program

(** Whether a module calls one of the runtime's formatters, which is how
    it says it needs that one imported. [jsstmt] -> string -> bool *)
let uses_name js_program name =
  uses (function JsVar (_, used) -> used = name | _ -> false) js_program

(** The public names the *generated* file holds. A module is up to two
    files, and the names its declaration half offers are the
    implementation's -- an importer reaches those directly, so exporting
    them here would name something this file never declared.
    Module.t -> [string] *)
let publics_of (unit : Module.t) =
  let declared = List.map fst (Module.external_signatures unit.declarations) in
  List.filter (fun name -> not (List.mem name declared)) (List.map fst unit.publics)

let module_manifest = "package.json"
let module_manifest_json = "{\n  \"type\": \"module\"\n}\n"

(** Whether an existing package.json already puts its directory in ES
    module mode. Looks for the one key rather than parsing JSON: nothing
    here has a JSON reader, and the answer only decides whether the
    driver prints a note. string -> bool *)
let manifest_declares_module text =
  let length = String.length text in
  let rec skip i = if i < length && (text.[i] = ' ' || text.[i] = '\n' || text.[i] = '\r' || text.[i] = '\t') then skip (i + 1) else i in
  let starts_at i needle =
    let n = String.length needle in
    i + n <= length && String.sub text i n = needle
  in
  let rec go i =
    if i >= length then false
    else if starts_at i "\"type\"" then
      let j = skip (i + 6) in
      if j < length && text.[j] = ':' then starts_at (skip (j + 1)) "\"module\""
      else go (i + 1)
    else go (i + 1)
  in
  go 0

(** The host code every file of a program shares: `print` and `debug`,
    and the formatting builtin.ml lays down for them. On node `print`
    writes with console.log; in a browser it writes through the `io`
    library's `write_line`, which a page embedding the program may
    replace. `debug` writes with console.error on both.
    string -> string *)
let shared_runtime target =
  let browser = Targets.family_of target = Targets.Web in
  String.concat "\n"
    ([
       "// The host half of a compiled Pyking program: what it needs from the";
       "// world. Every module of the program imports this one.";
     ]
    @ (if browser then
         [ Printf.sprintf "import { write_line } from './%s';" browser_io ]
       else [])
    @ [
        "";
        format_js;
        "";
        float_js;
        "";
        conversion_js;
        "";
        line_via "print" (if browser then "write_line" else "console.log");
        "";
        line_via "debug" "console.error";
        "";
        "export { print, debug, pykFormat, pykFloatStr, pykShaped, pykParseInt, pykTrunc,";
        "  pykParseFloat };";
        "";
      ])

(** One module of a program: its compiled body, `print` brought in where
    it needs it, its imports, and -- unless it is the program's own
    module, which nothing imports -- its public names handed out.
    Module.t -> [jsstmt] -> bool -> string -> string *)
let js_module (unit : Module.t) js_program renames main target =
  let lines =
    [
      header (source_of unit);
      Printf.sprintf "// Target: %s. %s" target
        (if main then
           if Targets.family_of target = Targets.Web then
             "The program, loaded by the .html beside it. Serve this directory."
           else "Run with:  node <this file>"
         else Printf.sprintf "A module of the program, imported as '%s'." unit.name);
      "";
    ]
  in
  let wanted =
    List.filter (calls js_program) [ "print"; "debug" ]
    @ List.filter (uses_name js_program)
        [ "pykFormat"; "pykFloatStr"; "pykShaped"; "pykParseInt"; "pykTrunc";
          "pykParseFloat" ]
  in
  let lines =
    if wanted = [] then lines
    else
      lines
      @ [
          Printf.sprintf "import { %s } from './%s';"
            (String.concat ", " wanted) runtime_module;
          "";
        ]
  in
  let lines = lines @ [ pprint_js_program js_program runtime_host ] in
  let lines =
    if main then lines
    else
      lines
      @ [ ""; Printf.sprintf "export %s;" (exported renames (publics_of unit)) ]
  in
  String.concat "\n" (lines @ [ "" ])

(** The page a `web` program is opened with: a loader and nothing else.
    The program prints to the browser console, so there is nothing for
    the page itself to show. The loader writes out a line `io.write` left
    unfinished once the program stops, and reports a `sys.exit` with a
    status other than 0. string -> string -> string *)
let web_page module_name source =
  String.concat "\n"
    [
      "<!doctype html>";
      "<html lang=\"en\">";
      "<meta charset=\"utf-8\">";
      Printf.sprintf "<title>%s</title>" source;
      "<script type=\"module\">";
      Printf.sprintf "import { flush } from './%s';" browser_io;
      "try {";
      Printf.sprintf "  await import('./%s');" module_name;
      "} catch (error) {";
      "  if (error === null || error.pykExit === undefined) throw error;";
      "  if (error.pykExit !== 0) console.log(`exited with status ${error.pykExit}`);";
      "} finally {";
      "  flush();";
      "}";
      "</script>";
      "";
    ]

(** Every file a whole program compiles to, as (path, contents), and the
    text `--stdout` prints -- the program's own module, since the
    modules it imports are files and `--stdout` writes none.
    string -> [(Module.t, [jsstmt])] -> string option -> bool
    -> ([(string, string)], string) *)
let package_program target units output_path stdout =
  let externals =
    List.filter_map
      (fun ((unit : Module.t), _, _) ->
        if unit.is_external then Some unit.name else None)
      units
  in
  ignore externals;
  let count = List.length units in
  let main_unit, main_program, main_renames = List.nth units (count - 1) in
  let main_text = js_module main_unit main_program main_renames true target in
  match output_path with
  | None -> ([], main_text)
  | Some output_path ->
      if stdout then ([], main_text)
      else
        let stem = Filename.remove_extension (Filename.basename output_path) in
        let main_js = beside output_path (stem ^ ".js") in
        let files =
          [ (main_js, main_text) ]
          @ List.filter_map
              (fun ((unit : Module.t), js_program, renames) ->
                (* An external module's file is its own implementation,
                   copied by the driver; nothing is generated for it. *)
                if unit.is_external then None
                else
                  Some
                    ( beside output_path (unit.name ^ ".js"),
                      js_module unit js_program renames false target ))
              (List.filteri (fun i _ -> i < count - 1) units)
          @ [ (beside output_path runtime_module, shared_runtime target) ]
          (* The manifest is node's alone: it is what makes node read a
             plain `.js` as an ES module. A browser decides that from the
             script tag and never looks at a package.json, so the `web`
             target writes none -- and one written into a directory it
             was not meant for governs every `.js` below it. *)
          @
          if Targets.family_of target = Targets.Node then
            [ (beside output_path module_manifest, module_manifest_json) ]
          else []
        in
        let files =
          if Targets.family_of target = Targets.Web then
            files
            @ [ (output_path, web_page (stem ^ ".js") (source_of main_unit)) ]
          else files
        in
        (files, main_text)

(* --- the interpreted target ---

   `iweb` compiles nothing. It ships the Pyking sources and the compiler
   itself built to JavaScript, and the page interprets the program --
   which is how it supports the whole language in a browser rather than
   the subset a backend covers. See docs/target_js.md, "The interpreted
   target". *)

(** What the compiler-as-JavaScript is called beside an `iweb` page.
    string *)
let interpreter_module = "pyking.js"

(** The page an `iweb` program is opened with: the interpreter, the
    program's own sources, and the call that runs them. The sources are
    inlined rather than fetched so the page needs no second round trip
    and no fetch permissions -- it is still served, because a module
    script is. `release` has the page run the program with every call to
    `debug` removed, which is what --release means for a program that is
    interpreted rather than compiled.
    bool -> string -> [string] -> [(string, string)] -> string *)
let interpreted_page ?(release = false) main sources externals =
  let quoted text =
    (* Inlined into a <script>, so the one sequence that must not appear
       literally is a closing tag. *)
    let buffer = Buffer.create (String.length text + 16) in
    String.iter
      (fun c ->
        match c with
        | '\\' -> Buffer.add_string buffer "\\\\"
        | '"' -> Buffer.add_string buffer "\\\""
        | '\n' -> Buffer.add_string buffer "\\n"
        | '\r' -> Buffer.add_string buffer "\\r"
        | '<' -> Buffer.add_string buffer "\\u003c"
        | c -> Buffer.add_char buffer c)
      text;
    "\"" ^ Buffer.contents buffer ^ "\""
  in
  ignore quoted;
  String.concat "\n"
    ([
       "<!doctype html>";
       "<html lang=\"en\">";
       "<meta charset=\"utf-8\">";
       Printf.sprintf "<title>%s</title>" main;
       "";
       "<!-- Generated by the Pyking compiler. Do not edit.";
       "     The program below is not compiled: it is Pyking source, run by";
       "     the Pyking interpreter built to JavaScript. Serve this";
       "     directory -- a module script cannot be fetched over file://. -->";
       "";
       "<script type=\"module\">";
       "import './" ^ interpreter_module ^ "';";
     ]
    @ List.map
        (fun (name, file) ->
          Printf.sprintf "import * as pykExt_%s from './%s';" name file)
        externals
    @ [
        "";
        "// Every module of the program, by the name its imports use.";
        "const sources = {};";
      ]
    @ List.map
        (fun name ->
          Printf.sprintf "sources[%s] = await (await fetch('./%s')).text();"
            (Printf.sprintf "'%s'" name) name)
        sources
    @ [
        "";
        "// What the interpreter reads instead of a directory, and where a";
        "// module implemented in JavaScript is found.";
        "globalThis.pykSources = sources;";
        "globalThis.pykExternals = {"
        ^ String.concat ", "
            (List.map
               (fun (name, _) -> Printf.sprintf "%s: pykExt_%s" name name)
               externals)
        ^ "};";
        "// `print` writes through the `io` library, as a compiled page's does,";
        "// and `debug` to the console.";
        "globalThis.pykOnPrint = (line) => pykExt_io.write(line);";
        "globalThis.pykOnDebug = (line) => console.error(line.replace(/\\n$/, ''));";
        "";
        Printf.sprintf "const result = JSON.parse(pykRunProgram('%s%s'));" main
          (if release then "\\nrelease" else "");
        "pykExt_io.flush();";
        "if (!result.ok) console.error(result.text);";
        "else if (result.exit) console.log(`exited with status ${result.exit}`);";
        "</script>";
        "";
      ])
