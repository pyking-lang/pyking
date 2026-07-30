"""Packaging for the JavaScript backends: wraps the target-independent
output of `src/target_js_core.py` into the files each target delivers,
and supplies the JavaScript side of the runtime interface.

The core emits a `JsRuntimeCall` wherever a program reaches the outside
world (see `src/runtime_interface.py`) without deciding what that call
looks like. Deciding is this module's job, and it is the only real
difference between the three targets:

  target    files                                          print goes to
  ------    -----                                          -------------
  nodejs    prog.js                                        console.log, directly
  html      prog.html                                      an element on the page
  esm       prog.js, prog.node.js, prog.html, package.json a supplied function

`esm` is the interesting one: the module itself cannot reach anything: it
exports `run(runtime)` and calls `runtime.print(...)`, so the same module
prints to a terminal under the node driver and onto the page under the
HTML wrapper, with no recompilation. The two wrappers exist so that
running either one behaves exactly like the `nodejs` and `html` targets,
and the `package.json` exists so that the plain `.js` files are read as
ES modules -- node decides that from the extension first and the nearest
manifest second, so `.js` without one means CommonJS and the driver's
`import` fails.

Value formatting is duplicated (a few lines) into each host rather than
shared from the module, deliberately: formatting is what a *host* does
with the values it is handed, and a module that formatted its own output
would already have decided what output looks like.
"""

from target_js_core import pprint_js_program

TARGETS = ("nodejs", "html", "esm")

# The formatter every host needs, implementing the rules in
# `runtime_interface.PRINT`. Only booleans actually need converting --
# JavaScript spells them lowercase -- but going through one function
# keeps every host's output identical and gives later value types
# (lists, tuples) one place to land.
_FORMAT_JS = """function pykFormat(value) {
  if (value === true) return 'True';
  if (value === false) return 'False';
  return String(value);
}"""

_HEADER = "// Generated from {source} by the Pyking compiler. Do not edit."


def _print_via(sink):
    """A `print` implementing the runtime interface: format each argument,
    join with single spaces, emit one line through `sink`."""
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
    """The host definitions, delimited. `esm` has no prelude at all -- its
    module is handed a `runtime` instead of building one -- which is the
    same boundary drawn a different way."""
    return "\n".join([_PRELUDE_BEGIN, "", *parts, "", _PRELUDE_END])


# --- nodejs: one self-contained script ---

def package_nodejs(js_program, source):
    """A single file runnable as `node prog.js`. `print` goes straight to
    `console.log` -- no module boundary, nothing injected."""
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
    """`print` for a browser: append a line to the visible output box,
    which is the whole point of the html target -- output the reader can
    see without opening a developer console."""
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
    """A single page that runs the program on load and prints into it.
    Self-contained on purpose: nothing is imported, so the file works
    when opened straight from disk."""
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
    """The module: `run(runtime)`, printing through `runtime.print`. It
    reaches nothing by itself -- every effect arrives as an argument."""
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
    """Runs the module under node, printing with `console.log` -- the same
    behaviour as the `nodejs` target."""
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
    """Runs the module in a browser, printing onto the page -- the same
    behaviour as the `html` target. Unlike that target this page *imports*
    the module, and browsers refuse module imports over `file://`, so it
    needs to be served (`python3 -m http.server`, then open the page)."""
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

# `esm` emits plain `.js` files, which node reads as CommonJS unless the
# nearest package.json says otherwise -- so the target writes that
# manifest alongside them. This is what `.mjs` buys you for free, traded
# for the extension every JavaScript project already uses.
MODULE_MANIFEST = "package.json"
MODULE_MANIFEST_JSON = '{\n  "type": "module"\n}\n'


def manifest_declares_module(text):
    """Whether an existing `package.json` already puts its directory in ES
    module mode. Parsed, not pattern-matched, so a `"type"` mentioned in
    some unrelated field doesn't read as a yes."""
    import json

    try:
        return json.loads(text).get("type") == "module"
    except (ValueError, AttributeError):
        return False


def output_stem(path):
    """`path` with a known output extension removed, so a name can be
    rebuilt with the right one. `out/prog.mjs`, `out/prog.js` and
    `out/prog` all yield `out/prog`."""
    for extension in _KNOWN_EXTENSIONS:
        if path.endswith(extension):
            return path[: -len(extension)]
    return path


def esm_paths(output_path):
    """The paths the `esm` target writes. `output_path` is read as a
    *stem*, not as one of the files: the target produces a module, a node
    driver, an HTML wrapper and the manifest that puts the first two in
    module mode, so their endings are the compiler's to choose --
    `out/prog`, `out/prog.js` and `out/prog.html` all yield the same four.
    Naming one file with `--output` and deriving the rest from whatever
    ending it happened to have is where the confusion lives."""
    stem = output_stem(output_path)
    directory = stem.rsplit("/", 1)[0] + "/" if "/" in stem else ""
    return (
        f"{stem}.js",
        f"{stem}.node.js",
        f"{stem}.html",
        f"{directory}{MODULE_MANIFEST}",
    )


def package(target, js_program, source, output_path):
    """Every file `target` emits, as `{path: contents}` in write order.
    A single-file target writes exactly `output_path`, which the caller
    chose; `esm` reads it as a stem and names all three files itself (see
    `esm_paths`)."""
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
    """The one artifact `--stdout` prints: the script, the page, or -- for
    `esm`, whose wrappers only exist as files -- the module."""
    match target:
        case "nodejs":
            return package_nodejs(js_program, source)
        case "html":
            return package_html(js_program, source)
        case "esm":
            return package_esm_module(js_program, source)
        case _:
            raise NotImplementedError(f"no packaging for target {target!r}")
