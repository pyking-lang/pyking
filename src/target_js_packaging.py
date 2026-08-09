"""Packaging for the JavaScript backends: wraps target_js_core.py's
target-independent output into the files each of nodejs/html/esm
delivers, and supplies the JavaScript side of the runtime interface
(where print goes). See docs/target_js.md, "The three targets".

Functions:
    package(target, js_program, source, output_path) -- every file a
        target emits, as {path: contents}.
    primary_source(target, js_program, source) -- the one artifact
        --stdout prints.
    package_nodejs / package_html / package_esm_module(js_program,
        source) -- one target's file(s).
    esm_paths(output_path) -- the four paths the esm target writes.
"""

from target_js_core import pprint_js_program

TARGETS = ("nodejs", "html", "esm")

# The formatter every host needs, implementing runtime_interface's
# print rules. JavaScript's undefined (a unit-returning function's
# actual result) is the one value that needs converting; everything
# else already prints the way Pyking wants.
_FORMAT_JS = """function pykFormat(value) {
  if (value === undefined) return '()';
  return String(value);
}"""

_HEADER = "// Generated from {source} by the Pyking compiler. Do not edit."


def _print_via(sink):
    """A print implementing the runtime interface, emitting one line
    through sink. String -> String"""
    return f"""function print(...values) {{
  {sink}(values.map(pykFormat).join(' '));
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
    body = pprint_js_program(js_program, {"print": "print"})
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
    body = pprint_js_program(js_program, {"print": "print"})
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
    body = pprint_js_program(js_program, {"print": "runtime.print"}, level=1)
    return "\n".join([
        _HEADER.format(source=source),
        "// Target: esm (the module). The program is pure: `runtime` supplies",
        "// everything it can observe -- for now `print(...values)`, which must",
        "// write one line, values formatted as in src/runtime_interface.py.",
        "// Loaded as an ES module: the generated package.json beside this file",
        "// sets \"type\": \"module\", which is what makes plain .js mean that.",
        "",
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
        "  print: (...values) => console.log(values.map(pykFormat).join(' ')),",
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
        "    pykOutput.textContent += values.map(pykFormat).join(' ') + '\\n';",
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


def package(target, js_program, source, output_path):
    """Every file target emits, as {path: contents} in write order.
    String -> [JsStmt] -> String -> String -> {String: String}"""
    match target:
        case "nodejs":
            return {output_path: package_nodejs(js_program, source)}
        case "html":
            return {output_path: package_html(js_program, source)}
        case "esm":
            module_path, node_path, html_path, manifest_path = esm_paths(output_path)
            module_name = module_path.rsplit("/", 1)[-1]
            return {
                module_path: package_esm_module(js_program, source),
                node_path: package_esm_node_driver(module_name, source),
                html_path: package_esm_html(module_name, source),
                manifest_path: MODULE_MANIFEST_JSON,
            }
        case _:
            raise NotImplementedError(f"no packaging for target {target!r}")


def primary_source(target, js_program, source):
    """The one artifact --stdout prints (for esm, the module). String ->
    [JsStmt] -> String -> String"""
    match target:
        case "nodejs":
            return package_nodejs(js_program, source)
        case "html":
            return package_html(js_program, source)
        case "esm":
            return package_esm_module(js_program, source)
        case _:
            raise NotImplementedError(f"no packaging for target {target!r}")
