// A remark plugin: turns every ```pyking block of a page into a cell
// placeholder that public/site/cells.js makes runnable with the
// notebook's own cells (tools/notebook/assets/notebook.js, mountCells).
// The fences mean what they mean in a notebook (tools/notebook/README.md):
// `readonly` and `error` are kept as data attributes, `norun` leaves the
// block as highlighted code, and a ```stdin or ```args block just before
// a cell fills in that cell's input and is not shown on its own.
//
// A run of adjacent blocks that holds more than that -- an exercise and
// its solution and tests, a quiz and its answer, the rules, a cell's
// stdout, or input written on a cell's header -- is a piece of a
// notebook instead: its Markdown goes into one `.pkn-fragment`
// placeholder, which mountCells renders and makes work as the notebook
// does (tools/notebook/README.md, "Exercises and quizzes").
//
// Functions:
//   remarkPykingCells() -- the plugin.
//   cellHTML(source, words, input) -- one cell's placeholder, as HTML.
//   fragmentHTML(blocks) -- a piece of a notebook's placeholder, as HTML.

const CELL_LANGUAGES = ["pyking", "pyk"];
const INPUT_LANGUAGES = ["stdin", "args"];
const PART_LANGUAGES = ["stdout", "stderr", "quiz", "answer", "rules"];
const CELL_WORDS = ["norun", "readonly", "error"];

/** The plugin: rewrites every block-holding node's children in place.
 *  () -> (Tree -> ()) */
export default function remarkPykingCells() {
  return (tree) => visit(tree);
}

/** Rewrites one node's children, then its children's. Node -> () */
function visit(node) {
  if (!Array.isArray(node.children)) return;
  node.children = fragments(node.children);
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

/** The language of a node that is a notebook block, or null. Node -> String? */
function notebookLanguage(node) {
  if (node.type !== "code") return null;
  const lang = (node.lang ?? "").toLowerCase();
  return CELL_LANGUAGES.includes(lang) || INPUT_LANGUAGES.includes(lang)
    || PART_LANGUAGES.includes(lang) ? lang : null;
}

/** Whether a run of notebook blocks needs the notebook rather than
 *  plain cells: anything but input blocks and cells with flags only.
 *  [Node] -> Bool */
function needsNotebook(run) {
  return run.some((node) => {
    const lang = notebookLanguage(node);
    if (PART_LANGUAGES.includes(lang)) return true;
    if (!CELL_LANGUAGES.includes(lang)) return false;
    const words = (node.meta ?? "").toLowerCase().split(/\s+/).filter(Boolean);
    return words.some((word) => !CELL_WORDS.includes(word));
  });
}

/** The children, with each run of adjacent notebook blocks that needs
 *  the notebook made into one fragment. [Node] -> [Node] */
function fragments(children) {
  const out = [];
  let run = [];
  const flush = () => {
    if (run.length && needsNotebook(run)) out.push({ type: "html", value: fragmentHTML(run) });
    else out.push(...run);
    run = [];
  };
  for (const child of children) {
    if (notebookLanguage(child) !== null) {
      run.push(child);
    } else {
      flush();
      out.push(child);
    }
  }
  flush();
  return out;
}

/** A piece of a notebook's placeholder: its blocks written back as
 *  Markdown, which notebook.js renders. [Node] -> String */
export function fragmentHTML(blocks) {
  const markdown = blocks.map((node) => {
    const longest = Math.max(2, ...(node.value.match(/`+/g) ?? []).map((m) => m.length));
    const fence = "`".repeat(longest + 1);
    return `${fence}${node.lang ?? ""}${node.meta ? " " + node.meta : ""}\n${node.value}\n${fence}`;
  }).join("\n\n");
  return `<div class="pkn-notebook pkn-embedded not-content">`
    + `<div class="pkn-fragment" data-markdown="${escape(markdown)}"></div></div>`;
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
