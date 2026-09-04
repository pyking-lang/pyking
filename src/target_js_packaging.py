"""Packaging for the JavaScript backends: wraps target_js_core.py's
target-independent output into the files each of nodejs/html/esm
delivers, and supplies the JavaScript side of the runtime interface
(where print goes). See docs/target_js.md, "The three targets".

Functions:
    package_program(target, units, output_path, stdout) -- every file a
        whole program emits, as {path: contents}, and the text --stdout
        prints.
    reserved_names(modules) -- the JavaScript names a packaging writes
        around a program, which a Pyking binding may not take.
    package_nodejs / package_html / package_esm_module(js_program,
        source) -- one target's file(s).
    esm_paths(output_path) -- the four paths the esm target writes.
"""

from target_js_core import (
    JsHost, JsImport, JsRuntimeCall, js_helpers, pprint_js_program, _uses,
)

TARGETS = ("nodejs", "html", "esm")

# The module holding `print` for a nodejs program of several files, so
# that the host code is written once rather than copied into every one.
# The hyphen is deliberate: a Pyking module is imported by name, so its
# file's stem is an identifier, and no Pyking module can ever be called
# this -- which is what makes the name safe to take.
RUNTIME_MODULE = "pyk-runtime.js"

# What the esm packaging calls the function that runs one module's top
# level, and the prefix of the name the module importing it reads it
# under. Both are handed to target_js_core.translate_program as names
# already spoken for.
ESM_INIT = "init"
ESM_INIT_PREFIX = "pykInit_"


def esm_init_name(module):
    """What the module importing `module` calls its init function.
    String -> String"""
    return ESM_INIT_PREFIX + module


def reserved_names(modules):
    """Every JavaScript name a packaging writes around a program of
    these modules, which a Pyking binding must therefore not take.
    [String] -> {String}"""
    return frozenset(
        [ESM_INIT] + [esm_init_name(name) for name in modules]
    )

# The formatter every host needs, implementing runtime_interface's
# print rules. Three values need converting: JavaScript's undefined (a
# unit-returning function's actual result), which Pyking spells `()`; a
# tuple, which is an array here and prints in Pyking's own notation; and
# a string inside one, which is quoted where a string on its own is not.
# Everything else -- numbers, booleans -- already prints the way Pyking
# wants.
_FORMAT_JS = r"""function pykFormat(value, inner) {
  if (value === undefined) return '()';
  if (typeof value === 'string') return inner ? pykQuote(value) : value;
  // A Pyking list and a Pyking tuple are both JavaScript arrays and
  // print differently, so a list carries a marker (see `pykList` in the
  // compiled program). A property rather than a class, because for the
  // `esm` target the two live in different modules.
  if (Array.isArray(value) && value.pykList === true) {
    return '[' + value.map((element) => pykFormat(element, true)).join(', ') + ']';
  }
  if (Array.isArray(value)) {
    const parts = value.map((element) => pykFormat(element, true));
    return parts.length === 1 ? '(' + parts[0] + ',)' : '(' + parts.join(', ') + ')';
  }
  return String(value);
}

function pykQuote(text) {
  return "'" + text
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\n/g, '\\n')
    .replace(/\t/g, '\\t')
    .replace(/\r/g, '\\r') + "'";
}"""

_HEADER = "// Generated from {source} by the Pyking compiler. Do not edit."


def _print_via(sink):
    """A print implementing the runtime interface, emitting one line
    through sink. String -> String"""
    return f"""function print(...values) {{
  {sink}(values.map((value) => pykFormat(value)).join(' '));
}}"""


# Markers around the host code a self-contained file carries ahead of the
# compiled program, so a reader can see at a glance which lines came from
# the `.pyk` source and which are the harness around it.
_PRELUDE_BEGIN = "\n".join([
    "// --- prelude begins ---",
    "// A Pyking program cannot do I/O by itself; its host must define `print`.",
])
_PRELUDE_END = "// --- prelude ends; the compiled program follows ---"


def _prelude(*parts):
    """The host definitions, delimited (esm has none: its module is
    handed a runtime instead of building one). (String,) -> String"""
    return "\n".join([_PRELUDE_BEGIN, "", *parts, "", _PRELUDE_END])


# --- nodejs: one self-contained script ---

def package_nodejs(js_program, source):
    """A single file runnable as `node prog.js`; print goes straight to
    console.log. [JsStmt] -> String -> String"""
    body = pprint_js_program(js_program, _host("print", _nodejs_import))
    return "\n".join([
        _HEADER.format(source=source),
        "// Target: nodejs. Run with:  node <this file>",
        "",
        _prelude(_FORMAT_JS, "", _print_via("console.log")),
        "",
        body,
        "",
    ])


# --- html: one self-contained page ---

_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 2rem; }}
  h1 {{ font-size: 1rem; font-weight: 600; color: #444; }}
  #pyk-output {{
    font-family: ui-monospace, monospace;
    white-space: pre-wrap;
    padding: 1rem;
    border: 1px solid #ccc;
    border-radius: 6px;
    background: #f7f7f7;
    min-height: 3rem;
  }}
</style>
</head>
<body>
<h1>{title}</h1>
<pre id="pyk-output"></pre>
<script type="module">
{script}
</script>
</body>
</html>
"""


def _page_print_js():
    """print for a browser: appends a line to the page's visible output
    box. () -> String"""
    return _prelude(
        "const pykOutput = document.getElementById('pyk-output');",
        "",
        _FORMAT_JS,
        "",
        _print_via("pykWrite"),
        "",
        "function pykWrite(line) {",
        "  pykOutput.textContent += line + '\\n';",
        "}",
    )


def package_html(js_program, source):
    """A single, self-contained page that runs the program on load and
    prints into it. [JsStmt] -> String -> String"""
    body = pprint_js_program(js_program, _host("print", _page_import))
    script = "\n".join([
        _HEADER.format(source=source),
        "",
        _page_print_js(),
        "",
        body,
    ])
    return _PAGE.format(title=source, script=script)


# --- esm: a module plus a wrapper for each host ---

def package_esm_module(js_program, source):
    """The esm module: run(runtime), printing through runtime.print.
    Reaches nothing by itself. [JsStmt] -> String -> String"""
    body = pprint_js_program(
        js_program, _host("runtime.print", _esm_import), level=1
    )
    return "\n".join([
        _HEADER.format(source=source),
        "// Target: esm (the module). The program is pure: `runtime` supplies",
        "// everything it can observe -- for now `print(...values)`, which must",
        "// write one line, values formatted as in src/runtime_interface.py.",
        "// Loaded as an ES module: the generated package.json beside this file",
        "// sets \"type\": \"module\", which is what makes plain .js mean that.",
        "",
        *_esm_imports(js_program),
        "export function run(runtime) {",
        body,
        "}",
        "",
    ])


def package_esm_node_driver(module_name, source):
    """Runs the esm module under node, printing with console.log (the
    nodejs target's behavior). String -> String -> String"""
    return "\n".join([
        _HEADER.format(source=source),
        "// Target: esm (node driver). Run with:  node <this file>",
        "// Needs the generated package.json beside it, whose \"type\": \"module\"",
        "// tells node to read these .js files as ES modules.",
        "",
        f"import {{ run }} from './{module_name}';",
        "",
        _FORMAT_JS,
        "",
        "run({",
        "  print: (...values) => console.log(values.map((value) => pykFormat(value)).join(' ')),",
        "});",
        "",
    ])


def package_esm_html(module_name, source):
    """Runs the esm module in a browser, printing onto the page (the
    html target's behavior); must be served, not opened from disk (see
    docs/target_js.md). String -> String -> String"""
    script = "\n".join([
        _HEADER.format(source=source),
        "// Served, not opened from disk: browsers block module imports",
        "// over file:// -- e.g. `python3 -m http.server` in this directory.",
        "",
        f"import {{ run }} from './{module_name}';",
        "",
        "const pykOutput = document.getElementById('pyk-output');",
        "",
        _FORMAT_JS,
        "",
        "run({",
        "  print: (...values) => {",
        "    pykOutput.textContent += values.map((value) => pykFormat(value)).join(' ') + '\\n';",
        "  },",
        "});",
    ])
    return _PAGE.format(title=source, script=script)


# The extension each target's primary file gets when the compiler names it
# itself, and the ones it strips back off to find the stem underneath.
PRIMARY_EXTENSIONS = {"nodejs": ".js", "html": ".html", "esm": ".js"}
_KNOWN_EXTENSIONS = (".node.js", ".node.mjs", ".mjs", ".js", ".html", ".py")

# esm emits plain .js files, so the target writes package.json alongside
# them to put node into ES module mode (docs/target_js.md).
MODULE_MANIFEST = "package.json"
MODULE_MANIFEST_JSON = '{\n  "type": "module"\n}\n'


def manifest_declares_module(text):
    """Whether an existing package.json already puts its directory in ES
    module mode. String -> Bool"""
    import json

    try:
        return json.loads(text).get("type") == "module"
    except (ValueError, AttributeError):
        return False


def output_stem(path):
    """path with a known output extension removed. String -> String"""
    for extension in _KNOWN_EXTENSIONS:
        if path.endswith(extension):
            return path[: -len(extension)]
    return path


def esm_paths(output_path):
    """The four paths the esm target writes: module, node driver, HTML
    wrapper, manifest. output_path is read as a stem, not one of the
    files. String -> (String, String, String, String)"""
    stem = output_stem(output_path)
    directory = stem.rsplit("/", 1)[0] + "/" if "/" in stem else ""
    return (
        f"{stem}.js",
        f"{stem}.node.js",
        f"{stem}.html",
        f"{directory}{MODULE_MANIFEST}",
    )


# --- modules: how each packaging spells what crosses a boundary ------
#
# One Pyking module is one JavaScript module, except on the page, which
# is one file and so holds them all (docs/target_js.md, "Modules"). What
# differs between the three is only how a module is brought in and how
# its public names are handed out; the compiled body is the same text in
# all of them, which is what `JsHost` is for.


def _selected(fields):
    """The names a `from` line takes, as a JavaScript destructuring
    pattern's body. [(String, String)] -> String"""
    return ", ".join(
        name if name == local else f"{name}: {local}"
        for name, local in fields
    )


def _exported(names):
    """A module's public names, as an object literal's body. Each is a
    binding of that very name in the module, so the shorthand says it.
    [String] -> String"""
    return "{ " + ", ".join(names) + " }" if names else "{}"


def _nodejs_import(statement):
    """One import as CommonJS: what a plain `.js` file run by node
    means. JsImport -> String"""
    required = f"require('./{statement.module}.js')"
    if statement.selected:
        return f"const {{ {_selected(statement.fields)} }} = {required};"
    return f"const {statement.name} = {required};"


def _esm_import(statement):
    """One import as a call to the module's own `init`, which runs its
    top level the first time and answers with what it exports. The ES
    `import` bringing that `init` in is a line of the file's own, above
    `run`. JsImport -> String"""
    started = f"{esm_init_name(statement.module)}(runtime)"
    if statement.selected:
        return f"const {{ {_selected(statement.fields)} }} = {started};"
    return f"const {statement.name} = {started};"


def _page_import(statement):
    """One import on the page, where the module it names has already
    been built above it: nothing at all where it is reached by its own
    name, and a binding otherwise. JsImport -> String"""
    if statement.selected:
        return f"const {{ {_selected(statement.fields)} }} = {statement.module};"
    return f"const {statement.name} = {statement.module};"


def _needed(statement):
    """Whether an import needs a line of its own on the page: a module
    imported under its own name is already there under it.
    JsImport -> Bool"""
    return statement.selected or statement.name != statement.module


def _host(operation, importing):
    """The JsHost for one packaging: where its print goes, and how it
    writes an import. String -> (JsImport -> String)? -> JsHost"""
    return JsHost({"print": operation}, importing)


def package_program(target, units, output_path, stdout):
    """Every file a whole program compiles to, as {path: contents}, and
    the text `--stdout` prints -- the program's own module, since the
    modules it imports are files and `--stdout` writes none. `units`
    pairs each module with its translated body, dependencies first.
    String -> [(Module, [JsStmt])] -> String? -> Bool
    -> ({String: String}, String)"""
    match target:
        case "nodejs":
            return _package_nodejs_program(units, output_path, stdout)
        case "html":
            return _package_html_program(units, output_path)
        case "esm":
            return _package_esm_program(units, output_path, stdout)
        case _:
            raise NotImplementedError(f"no packaging for target {target!r}")


def _beside(output_path, name):
    """The path a module of the program is written to: beside the
    program's own output, under its own name. String -> String -> String"""
    directory = output_path.rsplit("/", 1)[0] + "/" if "/" in output_path else ""
    return f"{directory}{name}"


# --- nodejs: one CommonJS file per module ---


def _package_nodejs_program(units, output_path, stdout):
    """A one-module program is the single self-contained script it has
    always been. Several modules are several files, each `require`ing
    the ones it imports, with the host code they share in one module of
    its own beside them.
    [(Module, [JsStmt])] -> String? -> Bool
    -> ({String: String}, String)"""
    if len(units) == 1:
        unit, js_program = units[0]
        text = package_nodejs(js_program, _source(unit))
        return ({} if stdout else {output_path: text}), text

    files, primary = {}, None
    for unit, js_program in units:
        main = unit is units[-1][0]
        text = _nodejs_module(unit, js_program, main)
        if main:
            primary = text
        if not stdout:
            files[
                output_path if main else _beside(output_path, unit.name + ".js")
            ] = text
    if not stdout:
        files[_beside(output_path, RUNTIME_MODULE)] = _nodejs_runtime()
    return files, primary


def _nodejs_module(unit, js_program, main):
    """One module of a nodejs program: its compiled body, the host code
    it needs brought in from the shared runtime module, and -- unless it
    is the program's own module, which nothing imports -- its public
    names handed out. Module -> [JsStmt] -> Bool -> String"""
    lines = [
        _HEADER.format(source=_source(unit)),
        "// Target: nodejs. " + (
            "Run with:  node <this file>" if main
            else f"A module of the program, imported as '{unit.name}'."
        ),
        "",
    ]
    if _prints(js_program):
        lines += [f"const {{ print }} = require('./{RUNTIME_MODULE}');", ""]
    lines.append(pprint_js_program(js_program, _host("print", _nodejs_import)))
    if not main:
        lines += ["", f"module.exports = {_exported(list(unit.publics))};"]
    lines.append("")
    return "\n".join(lines)


def _nodejs_runtime():
    """The host code a nodejs program of several files shares: `print`,
    and the formatting src/runtime_interface.py lays down for it.
    () -> String"""
    return "\n".join([
        "// Generated by the Pyking compiler. Do not edit.",
        "// The host half of a Pyking program: what it can observe of the",
        "// world. Every module of the program requires this one.",
        "",
        _FORMAT_JS,
        "",
        _print_via("console.log"),
        "",
        "module.exports = { print };",
        "",
    ])


# --- html: every module on one page ---


def _package_html_program(units, output_path):
    """One page, whatever a program is made of: a page is a file, so a
    module becomes a block of it rather than a file of its own, built in
    the order the modules must run and reached afterwards by its own
    name. [(Module, [JsStmt])] -> String? -> ({String: String}, String)"""
    host = _host("print", _page_import)
    blocks = []
    for unit, js_program in units[:-1]:
        body = pprint_js_program(
            _page_body(js_program), host, level=1, helpers=False
        )
        blocks += [
            f"// The module '{unit.name}', from {_source(unit)}.",
            f"const {unit.name} = (() => {{",
            body,
            f"  return {_exported(list(unit.publics))};",
            "})();",
            "",
        ]
    main_unit, main_program = units[-1]
    everything = [js for _, js in units]
    helpers = js_helpers(everything)
    script = "\n".join([
        _HEADER.format(source=_source(main_unit)),
        "",
        _page_print_js(),
        "",
        *([helpers, ""] if helpers else []),
        *blocks,
        pprint_js_program(_page_body(main_program), host, helpers=False),
    ])
    page = _PAGE.format(title=_source(main_unit), script=script)
    return ({} if output_path is None else {output_path: page}), page


def _page_body(js_program):
    """A module's statements as the page writes them: an import of a
    module already built above under its own name is dropped, there
    being nothing left for it to say. [JsStmt] -> [JsStmt]"""
    return [
        statement for statement in js_program
        if not isinstance(statement, JsImport) or _needed(statement)
    ]


# --- esm: one ES module per Pyking module ---


def _package_esm_program(units, output_path, stdout):
    """A one-module program is the module and its wrappers it has always
    been. Several modules are several ES modules: each one the program
    imports exports an `init(runtime)` that runs its top level once and
    answers with what it exports, and the program's own `run(runtime)`
    starts them by importing them.
    [(Module, [JsStmt])] -> String? -> Bool
    -> ({String: String}, String)"""
    main_unit, main_program = units[-1]
    module_path, node_path, html_path, manifest_path = (
        esm_paths(output_path) if output_path is not None
        else (None, None, None, None)
    )
    primary = package_esm_module(main_program, _source(main_unit))
    if stdout or output_path is None:
        return {}, primary
    module_name = module_path.rsplit("/", 1)[-1]
    files = {
        module_path: primary,
        node_path: package_esm_node_driver(module_name, _source(main_unit)),
        html_path: package_esm_html(module_name, _source(main_unit)),
        manifest_path: MODULE_MANIFEST_JSON,
    }
    for unit, js_program in units[:-1]:
        files[_beside(module_path, unit.name + ".js")] = _esm_module(
            unit, js_program
        )
    return files, primary


def _esm_module(unit, js_program):
    """One module the program imports: `init(runtime)` runs its top
    level and answers with its public names, and does so once however
    many modules import it. Module -> [JsStmt] -> String"""
    return "\n".join([
        _HEADER.format(source=_source(unit)),
        f"// Target: esm. A module of the program, imported as '{unit.name}'.",
        "// `init` runs its top level the first time it is called and answers",
        "// with what the module exports; every module of a program shares the",
        "// `runtime` the program was started with.",
        "",
        *_esm_imports(js_program),
        "let pykExports;",
        "",
        f"export function {ESM_INIT}(runtime) {{",
        "  if (pykExports !== undefined) return pykExports;",
        pprint_js_program(js_program, _host("runtime.print", _esm_import),
                          level=1),
        f"  pykExports = {_exported(list(unit.publics))};",
        "  return pykExports;",
        "}",
        "",
    ])


def _esm_imports(js_program):
    """The ES `import` lines one module's file opens with: the `init` of
    each module it imports, under a name of the packaging's own.
    [JsStmt] -> [String]"""
    lines = []
    for statement in js_program:
        if isinstance(statement, JsImport) and statement.module not in lines:
            lines.append(statement.module)
    return [
        f"import {{ {ESM_INIT} as {esm_init_name(name)} }} from './{name}.js';"
        for name in lines
    ] + ([""] if lines else [])


def _source(unit):
    """The file name a generated header names a module by.
    Module -> String"""
    return unit.path.rsplit("/", 1)[-1]


def _prints(js_program):
    """Whether a module reaches the world at all, and so needs the host
    code that lets it. [JsStmt] -> Bool"""
    return _uses(js_program, JsRuntimeCall)
