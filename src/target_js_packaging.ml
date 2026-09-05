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

open Syntax
open Target_js_core

let targets = [ "nodejs"; "html"; "esm" ]

(* The module holding `print` for a nodejs program of several files, so
   that the host code is written once rather than copied into every one.
   The hyphen is deliberate: a Pyking module is imported by name, so its
   file's stem is an identifier, and no Pyking module can ever be called
   this -- which is what makes the name safe to take. *)
let runtime_module = "pyk-runtime.js"

(* What the esm packaging calls the function that runs one module's top
   level, and the prefix of the name the module importing it reads it
   under. Both are handed to Target_js_core.translate_program as names
   already spoken for. *)
let esm_init = "init"
let esm_init_prefix = "pykInit_"

(** What the module importing `module_` calls its init function.
    string -> string *)
let esm_init_name module_ = esm_init_prefix ^ module_

(** Every JavaScript name a packaging writes around a program of these
    modules, which a Pyking binding must therefore not take.
    [string] -> [string] *)
let reserved_names modules = esm_init :: List.map esm_init_name modules

(* The formatter every host needs, implementing runtime_interface's
   print rules. Three values need converting: JavaScript's undefined (a
   unit-returning function's actual result), which Pyking spells `()`; a
   tuple, which is an array here and prints in Pyking's own notation;
   and a string inside one, which is quoted where a string on its own is
   not. Everything else -- numbers, booleans -- already prints the way
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

let header source =
  Printf.sprintf "// Generated from %s by the Pyking compiler. Do not edit."
    source

(** A print implementing the runtime interface, emitting one line
    through sink. string -> string *)
let print_via sink =
  String.concat "\n"
    [
      "function print(...values) {";
      Printf.sprintf "  %s(values.map((value) => pykFormat(value)).join(' '));"
        sink;
      "}";
    ]

(* Markers around the host code a self-contained file carries ahead of
   the compiled program, so a reader can see at a glance which lines
   came from the `.pyk` source and which are the harness around it. *)
let prelude_begin =
  String.concat "\n"
    [
      "// --- prelude begins ---";
      "// A Pyking program cannot do I/O by itself; its host must define \
       `print`.";
    ]

let prelude_end = "// --- prelude ends; the compiled program follows ---"

(** The host definitions, delimited (esm has none: its module is handed a
    runtime instead of building one). [string] -> string *)
let prelude parts =
  String.concat "\n" ((prelude_begin :: "" :: parts) @ [ ""; prelude_end ])

(* --- modules: how each packaging spells what crosses a boundary ---

   One Pyking module is one JavaScript module, except on the page, which
   is one file and so holds them all (docs/target_js.md, "Modules").
   What differs between the three is only how a module is brought in and
   how its public names are handed out; the compiled body is the same
   text in all of them, which is what `jshost` is for. *)

(** The names a `from` line takes, as a JavaScript destructuring
    pattern's body. [(string, string)] -> string *)
let selected fields =
  String.concat ", "
    (List.map
       (fun (name, local) ->
         if name = local then name else Printf.sprintf "%s: %s" name local)
       fields)

(** A module's public names, as an object literal's body. Each is a
    binding of that very name in the module, so the shorthand says it.
    [string] -> string *)
let exported names =
  if names = [] then "{}" else "{ " ^ String.concat ", " names ^ " }"

(** One import as an ES module's own `import`: what a program reaching
    an external module has to use, since the implementation is an ES
    module and CommonJS cannot require one. jsstmt -> string *)
let module_import statement =
  match statement with
  | JsImport (_, module_, name, is_selected, fields) ->
      if is_selected then
        Printf.sprintf "import { %s } from './%s.js';" (selected fields) module_
      else Printf.sprintf "import * as %s from './%s.js';" name module_
  | _ -> ""

(** One import as CommonJS: what a plain `.js` file run by node means.
    An external module is an ES module, so a program that imports one is
    emitted as an ES module throughout and this is not used for it.
    jsstmt -> string *)
let nodejs_import statement =
  match statement with
  | JsImport (_, module_, name, is_selected, fields) ->
      let required = Printf.sprintf "require('./%s.js')" module_ in
      if is_selected then
        Printf.sprintf "const { %s } = %s;" (selected fields) required
      else Printf.sprintf "const %s = %s;" name required
  | _ -> ""

(** One import as a call to the module's own `init`, which runs its top
    level the first time and answers with what it exports. The ES
    `import` bringing that `init` in is a line of the file's own, above
    `run`. jsstmt -> string *)
let esm_import externals statement =
  match statement with
  | JsImport (_, module_, name, is_selected, fields) ->
      if List.mem module_ externals then
        (* Implemented in JavaScript, so there is no `init` to run and
           nothing to hand a runtime to: the names are already bound by
           the file's own `import`. *)
        if is_selected then ""
        else Printf.sprintf "const %s = %s;" name (esm_init_name module_)
      else
        let started = Printf.sprintf "%s(runtime)" (esm_init_name module_) in
        if is_selected then
          Printf.sprintf "const { %s } = %s;" (selected fields) started
        else Printf.sprintf "const %s = %s;" name started
  | _ -> ""

(** One import on the page, where the module it names has already been
    built above it: nothing at all where it is reached by its own name,
    and a binding otherwise. jsstmt -> string *)
let page_import statement =
  match statement with
  | JsImport (_, module_, name, is_selected, fields) ->
      if is_selected then
        Printf.sprintf "const { %s } = %s;" (selected fields) module_
      else Printf.sprintf "const %s = %s;" name module_
  | _ -> ""

(** Whether an import needs a line of its own on the page: a module
    imported under its own name is already there under it.
    jsstmt -> bool *)
let needed statement =
  match statement with
  | JsImport (_, module_, name, is_selected, _) -> is_selected || name <> module_
  | _ -> false

(** The jshost for one packaging: where its print goes, and how it
    writes an import. string -> (jsstmt -> string) -> jshost *)
let host operation importing =
  { operations = [ ("print", operation) ]; importing = Some importing }

(* --- nodejs: one self-contained script --- *)

(** A single file runnable as `node prog.js`; print goes straight to
    console.log. [jsstmt] -> string -> string *)
let package_nodejs js_program source =
  let body = pprint_js_program js_program (host "print" nodejs_import) in
  String.concat "\n"
    [
      header source;
      "// Target: nodejs. Run with:  node <this file>";
      "";
      prelude [ format_js; ""; print_via "console.log" ];
      "";
      body;
      "";
    ]

(* --- html: one self-contained page --- *)

let page title script =
  Printf.sprintf
    "<!doctype html>\n\
     <html lang=\"en\">\n\
     <head>\n\
     <meta charset=\"utf-8\">\n\
     <title>%s</title>\n\
     <style>\n\
    \  body { font-family: system-ui, sans-serif; margin: 2rem; }\n\
    \  h1 { font-size: 1rem; font-weight: 600; color: #444; }\n\
    \  #pyk-output {\n\
    \    font-family: ui-monospace, monospace;\n\
    \    white-space: pre-wrap;\n\
    \    padding: 1rem;\n\
    \    border: 1px solid #ccc;\n\
    \    border-radius: 6px;\n\
    \    background: #f7f7f7;\n\
    \    min-height: 3rem;\n\
    \  }\n\
     </style>\n\
     </head>\n\
     <body>\n\
     <h1>%s</h1>\n\
     <pre id=\"pyk-output\"></pre>\n\
     <script type=\"module\">\n\
     %s\n\
     </script>\n\
     </body>\n\
     </html>\n"
    title title script

(** print for a browser: appends a line to the page's visible output
    box. () -> string *)
let page_print_js () =
  prelude
    [
      "const pykOutput = document.getElementById('pyk-output');";
      "";
      format_js;
      "";
      print_via "pykWrite";
      "";
      "function pykWrite(line) {";
      "  pykOutput.textContent += line + '\\n';";
      "}";
    ]

(** A single, self-contained page that runs the program on load and
    prints into it. [jsstmt] -> string -> string *)
let package_html js_program source =
  let body = pprint_js_program js_program (host "print" page_import) in
  let script =
    String.concat "\n" [ header source; ""; page_print_js (); ""; body ]
  in
  page source script

(* --- esm: a module plus a wrapper for each host --- *)

(** The ES `import` lines one module's file opens with: the `init` of
    each module it imports, under a name of the packaging's own.
    [jsstmt] -> [string] *)
let esm_imports externals js_program =
  let modules =
    List.fold_left
      (fun found statement ->
        match statement with
        | JsImport (_, module_, _, _, _) when not (List.mem module_ found) ->
            found @ [ module_ ]
        | _ -> found)
      [] js_program
  in
  List.map
    (fun name ->
      if List.mem name externals then
        (* The implementation is an ordinary ES module: what it exports
           is what the declaration said, with no `init` around it. *)
        Printf.sprintf "import * as %s from './%s.js';" (esm_init_name name) name
      else
        Printf.sprintf "import { %s as %s } from './%s.js';" esm_init
          (esm_init_name name) name)
    modules
  @ if modules = [] then [] else [ "" ]

(** The esm module: run(runtime), printing through runtime.print.
    Reaches nothing by itself. [jsstmt] -> string -> string *)
let package_esm_module ?(externals = []) js_program source =
  let body =
    pprint_js_program ~level:1 js_program
      (host "runtime.print" (esm_import externals))
  in
  String.concat "\n"
    ([
       header source;
       "// Target: esm (the module). The program is pure: `runtime` supplies";
       "// everything it can observe -- for now `print(...values)`, which must";
       "// write one line, values formatted as in src/runtime_interface.ml.";
       "// Loaded as an ES module: the generated package.json beside this file";
       "// sets \"type\": \"module\", which is what makes plain .js mean that.";
       "";
     ]
    @ esm_imports externals js_program
    @ [ "export function run(runtime) {"; body; "}"; "" ])

(** Runs the esm module under node, printing with console.log (the
    nodejs target's behavior). string -> string -> string *)
let package_esm_node_driver module_name source =
  String.concat "\n"
    [
      header source;
      "// Target: esm (node driver). Run with:  node <this file>";
      "// Needs the generated package.json beside it, whose \"type\": \
       \"module\"";
      "// tells node to read these .js files as ES modules.";
      "";
      Printf.sprintf "import { run } from './%s';" module_name;
      "";
      format_js;
      "";
      "run({";
      "  print: (...values) => console.log(values.map((value) => \
       pykFormat(value)).join(' ')),";
      "});";
      "";
    ]

(** Runs the esm module in a browser, printing onto the page (the html
    target's behavior); must be served, not opened from disk (see
    docs/target_js.md). string -> string -> string *)
let package_esm_html module_name source =
  let script =
    String.concat "\n"
      [
        header source;
        "// Served, not opened from disk: browsers block module imports";
        "// over file:// -- e.g. `python3 -m http.server` in this directory.";
        "";
        Printf.sprintf "import { run } from './%s';" module_name;
        "";
        "const pykOutput = document.getElementById('pyk-output');";
        "";
        format_js;
        "";
        "run({";
        "  print: (...values) => {";
        "    pykOutput.textContent += values.map((value) => \
         pykFormat(value)).join(' ') + '\\n';";
        "  },";
        "});";
      ]
  in
  page source script

(* The extension each target's primary file gets when the compiler names
   it itself, and the ones it strips back off to find the stem
   underneath. *)
let primary_extensions =
  [ ("nodejs", ".js"); ("html", ".html"); ("esm", ".js") ]

let known_extensions = [ ".node.js"; ".node.mjs"; ".mjs"; ".js"; ".html"; ".py" ]

(* esm emits plain .js files, so the target writes package.json
   alongside them to put node into ES module mode
   (docs/target_js.md). *)
let module_manifest = "package.json"
let module_manifest_json = "{\n  \"type\": \"module\"\n}\n"

(** Whether an existing package.json already puts its directory in ES
    module mode. Looks for the one key rather than parsing JSON: nothing
    here has a JSON reader, and the answer only decides whether the
    driver prints a note. string -> bool *)
let manifest_declares_module text =
  let length = String.length text in
  let rec skip i =
    if i < length && (text.[i] = ' ' || text.[i] = '\n' || text.[i] = '\t' || text.[i] = '\r')
    then skip (i + 1)
    else i
  in
  let starts_at i needle =
    i + String.length needle <= length
    && String.sub text i (String.length needle) = needle
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

(** path with a known output extension removed. string -> string *)
let output_stem path =
  let ends_with suffix =
    String.length path >= String.length suffix
    && String.sub path
         (String.length path - String.length suffix)
         (String.length suffix)
       = suffix
  in
  match List.find_opt ends_with known_extensions with
  | Some extension ->
      String.sub path 0 (String.length path - String.length extension)
  | None -> path

(** The directory part of a path, with its trailing slash, or "".
    string -> string *)
let directory_of path =
  match String.rindex_opt path '/' with
  | None -> ""
  | Some i -> String.sub path 0 (i + 1)

(** The four paths the esm target writes: module, node driver, HTML
    wrapper, manifest. output_path is read as a stem, not one of the
    files. string -> (string, string, string, string) *)
let esm_paths output_path =
  let stem = output_stem output_path in
  let directory = directory_of stem in
  ( stem ^ ".js",
    stem ^ ".node.js",
    stem ^ ".html",
    directory ^ module_manifest )

(** The path a module of the program is written to: beside the program's
    own output, under its own name. string -> string -> string *)
let beside output_path name = directory_of output_path ^ name

(** The file name a generated header names a module by.
    Module.t -> string *)
let source_of (unit : Module.t) = Filename.basename unit.path

(** Whether a module reaches the world at all, and so needs the host
    code that lets it. [jsstmt] -> bool *)
let prints js_program =
  uses (function JsRuntimeCall _ -> true | _ -> false) js_program

(** A module's statements as the page writes them: an import of a module
    already built above under its own name is dropped, there being
    nothing left for it to say. [jsstmt] -> [jsstmt] *)
let page_body js_program =
  List.filter
    (fun statement ->
      match statement with JsImport _ -> needed statement | _ -> true)
    js_program

(** The public names of one module, in source order.
    Module.t -> [string] *)
let publics_of (unit : Module.t) = List.map fst unit.publics

(* --- nodejs: one CommonJS file per module --- *)

(** The host code a nodejs program of several files shares: `print`, and
    the formatting runtime_interface.ml lays down for it. () -> string *)
let nodejs_runtime ?(externals = []) () =
  String.concat "\n"
    [
      "// Generated by the Pyking compiler. Do not edit.";
      "// The host half of a Pyking program: what it can observe of the";
      (if externals = [] then
         "// world. Every module of the program requires this one."
       else "// world. Every module of the program imports this one.");
      "";
      format_js;
      "";
      print_via "console.log";
      "";
      (if externals = [] then "module.exports = { print };"
       else "export { print };");
      "";
    ]

(** One module of a nodejs program: its compiled body, the host code it
    needs brought in from the shared runtime module, and -- unless it is
    the program's own module, which nothing imports -- its public names
    handed out. Module.t -> [jsstmt] -> bool -> string *)
let nodejs_module ?(externals = []) unit js_program main =
  (* An external module is an ES module, and CommonJS cannot require
     one, so a program that reaches one is written as ES modules
     throughout -- imports, the shared runtime, and what each module
     hands out (docs/target_js.md, "External modules"). *)
  let as_modules = externals <> [] in
  let lines =
    [
      header (source_of unit);
      "// Target: nodejs. "
      ^ (if main then "Run with:  node <this file>"
         else
           Printf.sprintf "A module of the program, imported as '%s'."
             unit.Module.name);
      "";
    ]
  in
  let lines =
    if prints js_program then
      lines
      @ [
          (if as_modules then
             Printf.sprintf "import { print } from './%s';" runtime_module
           else Printf.sprintf "const { print } = require('./%s');" runtime_module);
          "";
        ]
    else lines
  in
  let lines =
    lines
    @ [
        pprint_js_program js_program
          (host "print" (if as_modules then module_import else nodejs_import));
      ]
  in
  let lines =
    if main then lines
    else
      lines
      @ [
          "";
          (if as_modules then
             Printf.sprintf "export %s;" (exported (publics_of unit))
           else Printf.sprintf "module.exports = %s;" (exported (publics_of unit)));
        ]
  in
  String.concat "\n" (lines @ [ "" ])

(** A one-module program is the single self-contained script it has
    always been. Several modules are several files, each `require`ing
    the ones it imports, with the host code they share in one module of
    its own beside them.
    [(Module.t, [jsstmt])] -> string option -> bool
    -> ([(string, string)], string) *)
let package_nodejs_program ?(externals = []) units output_path stdout =
  match units with
  | [ (unit, js_program) ] ->
      let text = package_nodejs js_program (source_of unit) in
      ( (if stdout then []
         else match output_path with None -> [] | Some path -> [ (path, text) ]),
        text )
  | units ->
      let main_name = (fst (List.nth units (List.length units - 1))).Module.name in
      let files, primary =
        List.fold_left
          (fun (files, primary) ((unit : Module.t), js_program) ->
            let main = unit.name = main_name in
            let text = nodejs_module ~externals unit js_program main in
            let primary = if main then text else primary in
            let files =
              (* An external module's file is its own implementation,
                 copied by the driver; nothing is generated for it. *)
              if stdout || unit.is_external then files
              else
                match output_path with
                | None -> files
                | Some path ->
                    files
                    @ [
                        ( (if main then path else beside path (unit.name ^ ".js")),
                          text );
                      ]
            in
            (files, primary))
          ([], "") units
      in
      let files =
        if stdout then files
        else
          match output_path with
          | None -> files
          | Some path ->
              files
              @ [ (beside path runtime_module, nodejs_runtime ~externals ()) ]
              (* Plain `.js` means CommonJS to node unless a package.json
                 beside it says otherwise, which is what makes the
                 generated `import` lines legal. *)
              @
              if externals = [] then []
              else [ (beside path module_manifest, module_manifest_json) ]
      in
      (files, primary)

(* --- html: every module on one page --- *)

(** One page, whatever a program is made of: a page is a file, so a
    module becomes a block of it rather than a file of its own, built in
    the order the modules must run and reached afterwards by its own
    name.
    [(Module.t, [jsstmt])] -> string option
    -> ([(string, string)], string) *)
let package_html_program units output_path =
  let runtime = host "print" page_import in
  let count = List.length units in
  let front = List.filteri (fun i _ -> i < count - 1) units in
  let blocks =
    List.concat_map
      (fun ((unit : Module.t), js_program) ->
        let body =
          pprint_js_program ~level:1 ~helpers:false (page_body js_program)
            runtime
        in
        [
          Printf.sprintf "// The module '%s', from %s." unit.name
            (source_of unit);
          Printf.sprintf "const %s = (() => {" unit.name;
          body;
          Printf.sprintf "  return %s;" (exported (publics_of unit));
          "})();";
          "";
        ])
      front
  in
  let main_unit, main_program = List.nth units (count - 1) in
  let helpers = js_helpers (List.concat_map (fun (_, js) -> js) units) in
  let script =
    String.concat "\n"
      ([ header (source_of main_unit); ""; page_print_js (); "" ]
      @ (if helpers <> "" then [ helpers; "" ] else [])
      @ blocks
      @ [ pprint_js_program ~helpers:false (page_body main_program) runtime ])
  in
  let text = page (source_of main_unit) script in
  ((match output_path with None -> [] | Some path -> [ (path, text) ]), text)

(* --- esm: one ES module per Pyking module --- *)

(** One module the program imports: `init(runtime)` runs its top level
    and answers with its public names, and does so once however many
    modules import it. Module.t -> [jsstmt] -> string *)
let esm_module ?(externals = []) (unit : Module.t) js_program =
  String.concat "\n"
    ([
       header (source_of unit);
       Printf.sprintf
         "// Target: esm. A module of the program, imported as '%s'." unit.name;
       "// `init` runs its top level the first time it is called and answers";
       "// with what the module exports; every module of a program shares the";
       "// `runtime` the program was started with.";
       "";
     ]
    @ esm_imports externals js_program
    @ [
        "let pykExports;";
        "";
        Printf.sprintf "export function %s(runtime) {" esm_init;
        "  if (pykExports !== undefined) return pykExports;";
        pprint_js_program ~level:1 js_program
          (host "runtime.print" (esm_import externals));
        Printf.sprintf "  pykExports = %s;" (exported (publics_of unit));
        "  return pykExports;";
        "}";
        "";
      ])

(** A one-module program is the module and its wrappers it has always
    been. Several modules are several ES modules: each one the program
    imports exports an `init(runtime)` that runs its top level once and
    answers with what it exports, and the program's own `run(runtime)`
    starts them by importing them.
    [(Module.t, [jsstmt])] -> string option -> bool
    -> ([(string, string)], string) *)
let package_esm_program ?(externals = []) units output_path stdout =
  let count = List.length units in
  let main_unit, main_program = List.nth units (count - 1) in
  let primary =
    package_esm_module ~externals main_program (source_of main_unit)
  in
  match output_path with
  | None -> ([], primary)
  | Some output_path ->
      if stdout then ([], primary)
      else
        let module_path, node_path, html_path, manifest_path =
          esm_paths output_path
        in
        let module_name = Filename.basename module_path in
        let files =
          [
            (module_path, primary);
            (node_path, package_esm_node_driver module_name (source_of main_unit));
            (html_path, package_esm_html module_name (source_of main_unit));
            (manifest_path, module_manifest_json);
          ]
          @ List.filter_map
              (fun ((unit : Module.t), js_program) ->
                (* An external module's file is its own implementation,
                   copied by the driver; nothing is generated for it. *)
                if unit.is_external then None
                else
                  Some
                    ( beside module_path (unit.name ^ ".js"),
                      esm_module ~externals unit js_program ))
              (List.filteri (fun i _ -> i < count - 1) units)
        in
        (files, primary)

(** Every file a whole program compiles to, as (path, contents), and the
    text `--stdout` prints -- the program's own module, since the
    modules it imports are files and `--stdout` writes none. `units`
    pairs each module with its translated body, dependencies first.
    string -> [(Module.t, [jsstmt])] -> string option -> bool
    -> ([(string, string)], string) *)
let package_program target units output_path stdout =
  let externals =
    List.filter_map
      (fun ((unit : Module.t), _) ->
        if unit.is_external then Some unit.name else None)
      units
  in
  (* A page is one file and has nothing to fetch a module with, so an
     external module cannot be reached from it (docs/target_js.md). *)
  if target = "html" && externals <> [] then
    List.iter
      (fun ((unit : Module.t), _) ->
        List.iter
          (fun statement ->
            match statement with
            | SImport (info, name, _, _, _, _) when List.mem name externals ->
                raise
                  (Unsupported
                     ( info,
                       Printf.sprintf
                         "the external module '%s' -- a page is one file, so \
                          there is nothing for it to load an implementation \
                          from"
                         name ))
            | _ -> ())
          unit.stmts)
      units;
  match target with
  | "nodejs" -> package_nodejs_program ~externals units output_path stdout
  | "html" -> package_html_program units output_path
  | "esm" -> package_esm_program ~externals units output_path stdout
  | target -> invalid_arg ("no packaging for target " ^ target)
