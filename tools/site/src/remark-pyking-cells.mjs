// A remark plugin: turns every ```pyking block of a page into a cell
// placeholder that public/site/cells.js makes runnable with the
// notebook's own cells (tools/notebook/assets/notebook.js, mountCells).
// The fences mean what they mean in a notebook (tools/notebook/README.md):
// `readonly` and `error` are kept as data attributes, `norun` leaves the
// block as highlighted code, and a ```stdin or ```args block just before
// a cell fills in that cell's input and is not shown on its own.
//
// Functions:
//   remarkPykingCells() -- the plugin.
//   cellHTML(source, words, input) -- one cell's placeholder, as HTML.

const CELL_LANGUAGES = ["pyking", "pyk"];
const INPUT_LANGUAGES = ["stdin", "args"];

/** The plugin: rewrites every block-holding node's children in place.
 *  () -> (Tree -> ()) */
export default function remarkPykingCells() {
  return (tree) => visit(tree);
}

/** Rewrites one node's children, then its children's. Node -> () */
function visit(node) {
  if (!Array.isArray(node.children)) return;
  const out = [];
  let input = {};
  for (const child of node.children) {
    const lang = child.type === "code" ? (child.lang ?? "").toLowerCase() : null;
    if (INPUT_LANGUAGES.includes(lang)) {
      input = { ...input, [lang]: child.value };
      continue;
    }
    if (CELL_LANGUAGES.includes(lang)) {
      const words = (child.meta ?? "").toLowerCase().split(/\s+/).filter(Boolean);
      if (words.includes("norun")) {
        out.push({ ...child, lang: "pyking", meta: null });
      } else {
        out.push({ type: "html", value: cellHTML(child.value, words, input) });
      }
      input = {};
      continue;
    }
    // Anything between an input block and a cell lets the input go.
    input = {};
    visit(child);
    out.push(child);
  }
  node.children = out;
}

/** One cell's placeholder: the code as a <pre>, readable before the
 *  compiler loads, and what notebook.js's cellSpec reads.
 *  String -> [String] -> {stdin?, args?} -> String */
export function cellHTML(source, words, input) {
  const data = [];
  if (words.includes("readonly")) data.push("data-readonly");
  if (words.includes("error")) data.push("data-error");
  if (input.stdin !== undefined) {
    // Standard input is lines, each ending in a newline, as a file's are.
    const stdin = input.stdin.replace(/\n*$/, input.stdin === "" ? "" : "\n");
    data.push(`data-stdin="${escape(stdin)}"`);
  }
  if (input.args !== undefined) data.push(`data-args="${escape(input.args.replace(/\n+$/, ""))}"`);
  return `<div class="pkn-notebook pkn-embedded not-content">`
    + `<div class="pkn-cell" ${data.join(" ")}>`
    + `<pre class="pkn-cell-fallback"><code>${escape(source.replace(/\n+$/, ""))}</code></pre>`
    + `</div></div>`;
}

function escape(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
