// The Pyking notebook: a Markdown document whose Pyking code blocks are
// cells a reader can edit and run with the interpreter, in the browser.
// The document itself is read-only -- edits live in the page until it is
// reloaded, and each edited cell can be reset to what the file says.
//
// Embedding it in another page is one call:
//
//   import { mountNotebook } from "./notebook/notebook.js";
//   mountNotebook(document.getElementById("host"), { url: "tutorial.md" });
//
// It needs webrun/, vendor/ and pyking/ served beside notebook/ -- the
// layout `pyk notebook` serves (src/web_tools.ml) -- or their URLs given as
// options. See tools/notebook/README.md.
//
// Cells can also be embedded one at a time in a page that is not a
// notebook, as the website does (tools/site/): each is a `.pkn-cell`
// placeholder inside a `.pkn-notebook` element, and one call makes all of
// them runnable:
//
//   import { mountCells } from "./notebook/notebook.js";
//   mountCells(document.querySelectorAll(".pkn-cell"), { theme: "dark" });
//
// A document's tasks, quizzes and rules are activities.js's, made
// from what tasks.js reads out of it; `mode` says whether a student
// or a teacher is reading, and `results()` what has been solved.
//
// Data structures:
//   Cells -- what the cells of one page share: the compiler worker, the
//     run queue, and the theme.
//   Notebook -- one mounted document: Cells, plus the page around them.
//   Cell -- one runnable code block: its editor, its output, its state.
//
// Functions:
//   mountNotebook(host, options) -- renders a document into host.
//   mountCells(placeholders, options) -- makes cell placeholders, and
//     fragments of a notebook, runnable.
//   cellSpec(placeholder, index) -- what a placeholder's data attributes say.

import { renderMarkdown, escapeHTML } from "./markdown.js";
import { Activities } from "./activities.js";
import { checkNotebook } from "./checks.js";
import { pictures } from "./tasks.js";

const HERE = new URL(".", import.meta.url);

const DEFAULTS = {
  url: null,              // the Markdown file to fetch, or
  markdown: null,         // its text, given directly
  webrunURL: new URL("../webrun/", HERE).href,
  vendorURL: new URL("../vendor/", HERE).href,
  pykingURL: new URL("../pyking/", HERE).href,
  baseURL: null,          // relative links resolve here; default: beside url
  documentLink: null,     // (href) -> href, for links to other .md files
  header: true,           // the title bar with status and theme toggle
  contents: true,         // the contents sidebar
  theme: null,            // "auto" | "light" | "dark"; default: remembered
  fontSize: 14,           // the editors' and outputs' font size, in px
  mode: "student",        // "student" or "teacher": who is reading
  storageKey: null,       // where progress is kept; default: from url
  onChange: null,         // (results) -> (), whenever an answer is checked
  cellActions: [],        // [{label, title, run(source)}]: a button on each cell
  save: null,             // {url, root}: where a picture a solution makes is saved
  runtime: null,          // a PykingRuntime to share; default: one of its own
  watch: false,           // reload the page when the document at url changes
  warnings: [],           // the -W flags a cell's run is checked with, as pyk takes them
};

// How often a watched document is fetched again, in milliseconds.
const WATCH_INTERVAL = 1000;

const SCROLL_KEY = "pyking-notebook.scroll:";

const THEME_KEY = "pyking-notebook.theme";
const THEMES = ["auto", "light", "dark"];
const ACE_THEME = { light: "ace/theme/tomorrow", dark: "ace/theme/tomorrow_night" };

// The Ace mode each fence language is highlighted with; a language not
// here is shown as plain text.
const MODES = {
  pyking: "pyking", pyk: "pyking",
  python: "python", py: "python",
  javascript: "javascript", js: "javascript", node: "javascript",
  c: "c_cpp", h: "c_cpp", cpp: "c_cpp", "c++": "c_cpp",
  java: "java", ocaml: "ocaml", ml: "ocaml", html: "html",
  sh: "sh", bash: "sh", shell: "sh", console: "sh", json: "json",
};

// How much of one run's output the page keeps. A program printing in an
// endless loop would otherwise grow the page until the tab dies.
const OUTPUT_LIMIT = 200000;

// How long an edited cell sits still before the page asks the compiler
// whether it reads standard input or its arguments.
const ANALYZE_DELAY = 400;

/** Renders a document into host and makes its cells runnable. Resolves
 *  to the mounted Notebook. Element -> {...} -> Promise<Notebook> */
export async function mountNotebook(host, options = {}) {
  const cfg = { ...DEFAULTS, ...options };
  const webrun = new URL(cfg.webrunURL, document.baseURI).href;
  const web = await import(new URL("web.js", webrun.endsWith("/") ? webrun : webrun + "/").href);
  web.loadStyle(new URL("notebook.css", HERE).href);

  const source = cfg.markdown ?? await web.fetchText(cfg.url);
  const baseURL = cfg.baseURL
    ?? (cfg.url ? new URL(".", new URL(cfg.url, document.baseURI)).href : "");
  const doc = renderMarkdown(source, { baseURL, documentLink: cfg.documentLink });

  const notebook = new Notebook(host, doc, cfg, web, source);
  notebook.baseURL = baseURL;
  await notebook.init();
  if (cfg.watch && cfg.url) watch(new URL(cfg.url, document.baseURI).href, source);
  return notebook;
}

/** Fetches the document every WATCH_INTERVAL and reloads the page when
 *  its text has changed, at the place it was scrolled to.
 *  String -> String -> () */
function watch(url, source) {
  const key = SCROLL_KEY + url;
  const scroller = document.scrollingElement ?? document.documentElement;
  let kept = null;
  try {
    kept = sessionStorage.getItem(key);
    sessionStorage.removeItem(key);
  } catch {
    /* not kept; the page opens at its top */
  }
  if (kept !== null) requestAnimationFrame(() => { scroller.scrollTop = Number(kept); });
  const poll = async () => {
    let text = null;
    try {
      const response = await fetch(url, { cache: "no-store" });
      if (response.ok) text = await response.text();
    } catch {
      /* the server is gone or busy: ask again later */
    }
    if (text !== null && text !== source) {
      try {
        sessionStorage.setItem(key, String(scroller.scrollTop));
      } catch {
        /* reloaded at the top */
      }
      location.reload();
      return;
    }
    setTimeout(poll, WATCH_INTERVAL);
  };
  setTimeout(poll, WATCH_INTERVAL);
}

/** Makes every placeholder runnable, sharing one compiler worker and one
 *  run queue. A placeholder is a `.pkn-cell` element inside a
 *  `.pkn-notebook` one, holding the code as a `<pre>`, with what
 *  `cellSpec` reads in its data attributes -- or a `.pkn-fragment`
 *  holding a piece of a notebook in `data-markdown`, whose tasks
 *  and quizzes work as they do in one. Resolves to the mounted Cells.
 *  [Element] -> {...} -> Promise<Cells> */
export async function mountCells(placeholders, options = {}) {
  const cfg = { ...DEFAULTS, header: false, contents: false, ...options };
  const webrun = new URL(cfg.webrunURL, document.baseURI).href;
  const web = await import(new URL("web.js", webrun.endsWith("/") ? webrun : webrun + "/").href);
  web.loadStyle(new URL("notebook.css", HERE).href);

  const cells = new Cells(cfg, web);
  let fragments = 0;
  const made = [];
  for (const placeholder of placeholders) {
    if (!placeholder.classList.contains("pkn-fragment")) {
      cells.cells.push(new Cell(cells, cellSpec(placeholder, cells.cells.length), placeholder));
      continue;
    }
    const doc = renderMarkdown(placeholder.dataset.markdown ?? "", { baseURL: cfg.baseURL ?? "" });
    const offset = cells.cells.length;
    placeholder.innerHTML = `<div class="pkn-prose">${doc.html}</div>`;
    for (const element of placeholder.querySelectorAll(".pkn-cell[data-cell]")) {
      const spec = doc.cells[Number(element.dataset.cell)];
      const index = offset + spec.index;
      cells.cells.push(new Cell(cells, { ...spec, index, id: `cell-${index + 1}` }, element));
    }
    fragments += 1;
    cells.fragments.push(placeholder);
    made.push([doc, placeholder]);
    cells.activities.push(new Activities(cells, doc, placeholder, {
      mode: cfg.mode,
      storageKey: `${cfg.storageKey ?? location.pathname}#${fragments}`,
      summary: false,
      onChange: () => cells.changed(),
      cellOffset: offset,
    }));
  }
  // First in the run queue, as in a notebook: the text may show them.
  const drawn = made.reduce((before, [doc, placeholder]) =>
    before.then(() => cells.makePictures(doc, placeholder, cfg.baseURL ?? "")), Promise.resolve());
  await cells.init();
  cells.picturesMade = drawn;
  return cells;
}

/** What a placeholder's data attributes say about its cell: the code is
 *  the `<pre>`'s text, `data-readonly` and `data-error` are its
 *  attributes, and `data-stdin` and `data-args` fill in its input.
 *  Element -> Int -> {index, id, source, attrs, stdin, args} */
export function cellSpec(placeholder, index) {
  const data = placeholder.dataset;
  return {
    index,
    id: placeholder.id || `cell-${index + 1}`,
    source: placeholder.querySelector("pre")?.textContent ?? "",
    attrs: { norun: false, readonly: "readonly" in data, error: "error" in data },
    stdin: data.stdin ?? null,
    args: data.args ?? null,
  };
}

// ------------------------------------------------------------------- cells

class Cells {
  constructor(cfg, web) {
    this.cfg = cfg;
    this.web = web;
    this.ui = {};
    this.runtime = cfg.runtime
      ?? web.createRuntime({ webrun: cfg.webrunURL, pyking: cfg.pykingURL });
    this.runtime.setWarnings?.(cfg.warnings ?? []);
    this.cells = [];
    this.queue = Promise.resolve();
    this.generation = 0;       // bumped by Stop, which cancels what is queued
    this.running = null;       // the Cell executing now
    this.editorsReady = false; // Ace and the compiler loaded: a cell may make its editor
    this.executions = 0;       // the [n] counter, as in Jupyter
    this.themeChoice = cfg.theme ?? loadTheme();
    this.media = globalThis.matchMedia?.("(prefers-color-scheme: dark)");
    this.activities = [];      // the tasks and quizzes, per document
    this.fragments = [];       // mountCells' fragments, cells or none
  }

  /** Every task's and quiz's state, and the totals.
   *  () -> {items, solved, total, points, max, pass, passed, done} */
  results() {
    const all = this.activities.map((a) => a.results());
    const items = all.flatMap((r) => r.items);
    const counted = items.filter((item) => item.graded);
    const add = (key) => all.reduce((sum, r) => sum + (r[key] ?? 0), 0);
    const max = all.some((r) => r.max !== null) ? add("max") : null;
    const pass = all.some((r) => r.pass !== null) ? add("pass") : null;
    const points = add("points");
    const solved = counted.filter((item) => item.state === "solved").length;
    return {
      items, solved, total: counted.length, points, max, pass,
      passed: pass === null ? null : points >= pass,
      done: counted.length > 0 && solved === counted.length,
    };
  }

  /** Tells the embedding page that an answer was checked. */
  changed() {
    this.cfg.onChange?.(this.results());
  }

  async init() {
    this.applyTheme();
    this.media?.addEventListener?.("change", () => this.applyTheme());
    this.status("busy", "loading the compiler");
    try {
      await this.web.ensureEditor(
        this.runtime, { webrun: this.cfg.webrunURL, vendor: this.cfg.vendorURL },
        (message) => this.status("busy", message));
    } catch (err) {
      this.status("error", "the compiler did not load");
      for (const cell of this.cells) cell.fail("Could not start the compiler: " + err.message);
      throw err;
    }
    this.attachWhenSeen();
    this.status("ready", "ready");
  }

  /** Gives each cell its editor when it comes near the screen: a page of
   *  a hundred editors made at once holds the browser for seconds.
   *  () -> () */
  attachWhenSeen() {
    this.editorsReady = true;
    if (!globalThis.IntersectionObserver) {
      for (const cell of this.cells) cell.ensureEditor();
      return;
    }
    const byElement = new Map(this.cells.map((cell) => [cell.element, cell]));
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        observer.unobserve(entry.target);
        byElement.get(entry.target)?.ensureEditor();
      }
    }, { rootMargin: "800px 0px" });
    for (const cell of this.cells) observer.observe(cell.element);
  }

  /** The elements the theme is set on: the `.pkn-notebook` around each
   *  cell and each fragment. () -> [Element] */
  themed() {
    const elements = [...this.cells.map((cell) => cell.element), ...this.fragments];
    return [...new Set(elements.map((element) => element.closest(".pkn-notebook")))]
      .filter(Boolean);
  }

  editorOptions() {
    return {
      theme: ACE_THEME[this.effectiveTheme()],
      minLines: 1,
      maxLines: Infinity,
      fontSize: this.cfg.fontSize,
      tabSize: 4,
      useSoftTabs: true,
      showPrintMargin: false,
      useWorker: false,
      fontFamily: "var(--pkn-mono)",
    };
  }

  // -- theme -------------------------------------------------------------

  effectiveTheme() {
    if (this.themeChoice === "light" || this.themeChoice === "dark") return this.themeChoice;
    return this.media?.matches ? "dark" : "light";
  }

  applyTheme() {
    const theme = this.effectiveTheme();
    for (const element of this.themed()) element.dataset.theme = theme;
    if (this.ui.theme) {
      this.ui.theme.innerHTML = ICON[this.themeChoice];
      this.ui.theme.title = `Theme: ${this.themeChoice} (click to change)`;
      this.ui.theme.setAttribute("aria-label", this.ui.theme.title);
    }
    for (const cell of this.cells) cell.editor?.setTheme(ACE_THEME[theme]);
    for (const editor of this.statics ?? []) editor.setTheme(ACE_THEME[theme]);
  }

  cycleTheme() {
    this.setTheme(THEMES[(THEMES.indexOf(this.themeChoice) + 1) % THEMES.length]);
  }

  /** Sets the theme, and remembers it in this browser unless `remember`
   *  is false. String -> Bool -> () */
  setTheme(choice, remember = true) {
    this.themeChoice = THEMES.includes(choice) ? choice : "auto";
    if (remember) saveTheme(this.themeChoice);
    this.applyTheme();
  }

  // -- running -----------------------------------------------------------

  /** Queues a cell to run; cells run one at a time, in the order asked.
   *  `until` is a task's compare-until limit (tasks.js `untilLimit`), which
   *  Submit's run of the answer stops at. Cell -> {events, patterns}? -> Promise */
  enqueue(cell, until = null) {
    const generation = this.generation;
    cell.setState("queued");
    this.queue = this.queue.then(async () => {
      if (generation !== this.generation) return cell.setState("idle");
      await this.execute(cell, until);
    });
    return this.queue;
  }

  async execute(cell, until = null) {
    let stopped = false;           // whether `until` has ended the program
    this.running = cell;
    cell.begin();
    this.status("busy", `running cell ${cell.spec.index + 1}`);
    const started = performance.now();
    try {
      await this.runtime.ready();
      const input = await cell.currentInput();
      const result = await this.runtime.runProgram(cell.source(), {
        name: cell.name(),
        onOutput: (text) => cell.write(text),
        // What the cell's check found -- a name never used -- above what
        // it printed. An answer being checked (`capture`) shows none.
        onWarning: (text) => cell.write(text, "pkn-warning"),
        onDebug: (text) => {
          cell.write(text, "pkn-debug");
          console.log(text.replace(/\n$/, ""));
        },
        // A program using a library that needs a page shows it under the
        // cell, and goes on running there after this run has answered.
        onPage: (module, data) => cell.page(module, data),
        onFailure: (text) => cell.write(text.trimEnd() + "\n", "pkn-failure"),
        onExit: (code) => cell.write(`exited with status ${code}\n`, "pkn-failure"),
        onEnd: () => cell.host?.freeze(),
        // A callback the page made reached the limit: the program is over.
        onUntil: () => {
          if (!stopped) cell.write(`stopped after ${until.events} events, as far as the task compares\n`, "pkn-debug");
          stopped = true;
          cell.host?.freeze();
        },
        tinywebUntil: until,
        ...input,
      });
      if (result.until) {
        result.until = until.events;
        stopped = true;
        cell.host?.freeze();
      }
      cell.finish(result, ++this.executions, performance.now() - started);
      this.status("ready", "ready");
    } catch (err) {
      if (cell.stopped) {
        cell.finishStopped();
      } else {
        cell.fail("The compiler failed: " + err.message);
        this.status("error", "the compiler failed");
      }
    } finally {
      this.running = null;
    }
  }

  /** Runs a program quietly -- an answer being checked, or the solution
   *  it is checked against -- in the same queue as the cells, and answers
   *  what it printed. A run longer than `timeout` is stopped. With
   *  `tinyweb`, also tinyweb's log and what the program sent its page,
   *  each batch as [module, data]. `until`, a task's compare-until limit,
   *  ends the run once tinyweb's log has had that many matching lines;
   *  it then answers `until` true and ended with status 0.
   *  String -> {name, stdin, args, timeout, tinyweb, events, until} ->
   *  Promise<{ok, text?, stdout, stderr, exit, timedOut?, tinyweb?, page?, until?}> */
  capture(source, { name = "check.pyk", stdin = "", args = [], timeout = 10000, tinyweb = false, events = "",
    until = null } = {}) {
    const generation = this.generation;
    const job = this.queue.then(async () => {
      if (generation !== this.generation) return { ok: false, text: "stopped", stdout: "", stderr: "" };
      this.status("busy", "checking an answer");
      let stdout = "";
      let stderr = "";
      let log = "";
      const page = [];
      let failure = "";
      let exit = null;
      let timer = null;
      let timedOut = false;
      try {
        await this.runtime.ready();
        const drawing = tinyweb ? {
          tinywebLog: "separate",
          tinywebEvents: events,
          tinywebUntil: until,
          onTinyweb: (text) => { log += text; },
          onPage: (module, data) => { page.push([module, data]); },
        } : {};
        const running = this.runtime.runProgram(source, {
          name, stdin, args, ...drawing,
          onOutput: (text) => { stdout += text; },
          onDebug: (text) => { stderr += text; },
          onFailure: (text) => { failure += text; },
          onExit: (code) => { exit = code; },
        });
        const late = new Promise((resolve) => {
          timer = setTimeout(() => {
            timedOut = true;
            this.stop();
            resolve(null);
          }, timeout);
        });
        const result = await Promise.race([running, late]);
        const drawn = tinyweb ? { tinyweb: log, page } : {};
        if (timedOut || result === null) {
          return { ok: false, timedOut: true, stdout, stderr, ...drawn, text: "did not finish in time" };
        }
        this.runtime.endLive();
        this.status("ready", "ready");
        if (failure) return { ok: false, stdout, stderr, ...drawn, text: failure };
        return { ...result, stdout, stderr, ...drawn, exit: result.exit ?? exit ?? 0 };
      } catch (err) {
        return { ok: false, stdout, stderr, timedOut, text: err.message };
      } finally {
        clearTimeout(timer);
      }
    });
    this.queue = job.then(() => {}, () => {});
    return job;
  }

  /** Shows what a program sent its page in `element`, as a page of its
   *  own that sends no events back and plays no sound: the pictures a
   *  submission and its solution drew. Resolves once it has been drawn,
   *  to the PageHost.
   *  Element -> [[String, [Object]]] -> Promise<PageHost> */
  async drawPage(element, page) {
    const host = new this.web.PageHost(element,
      { libURL: this.runtime.libURL, send: () => {}, silent: true });
    for (const [module, data] of page) host.receive(module, data);
    await Promise.all([...host.pages.values()]);
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    host.freeze();
    return host;
  }

  /** What a solution's save_canvas saves: its solution run on its own
   *  input, the canvas named drawn on white at its own size, as a PNG.
   *  Resolves to the PNG, or to why there is none.
   *  {task, canvas, file} -> Doc -> Promise<{blob?, problem?}> */
  async picture({ task, canvas }, doc) {
    const spec = doc.cells[task.solution.cell];
    const result = await this.capture(spec.source, {
      name: `${task.id}-solution.pyk`,
      stdin: spec.stdin ?? task.stdin,
      args: this.web.splitArguments(spec.args ?? task.args),
      tinyweb: true,
    });
    if (!result.ok) return { problem: `the solution did not run: ${(result.text ?? "").trim()}` };
    const holder = document.createElement("div");
    holder.style.cssText = "position: fixed; left: -100000px; top: 0;";
    document.body.append(holder);
    try {
      const host = await this.drawPage(holder, result.page);
      const drawn = holder.querySelector(`canvas[data-tinyweb-id="${CSS.escape(canvas)}"]`);
      if (!drawn) {
        host.close();
        return { problem: `the solution drew no canvas named "${canvas}"` };
      }
      const width = parseFloat(drawn.style.width) || drawn.width;
      const height = parseFloat(drawn.style.height) || drawn.height;
      const out = document.createElement("canvas");
      out.width = Math.round(width);
      out.height = Math.round(height);
      const g = out.getContext("2d");
      g.fillStyle = "#ffffff";
      g.fillRect(0, 0, out.width, out.height);
      g.drawImage(drawn, 0, 0, out.width, out.height);
      host.close();
      const blob = await new Promise((resolve) => out.toBlob(resolve, "image/png"));
      return blob ? { blob } : { problem: "the canvas could not be made a picture" };
    } finally {
      holder.remove();
    }
  }

  /** Makes every picture the solutions in `doc` save, before anything
   *  else runs: each image in `root` naming its file shows it, and where
   *  the page was told where (`save`), it is saved beside the document.
   *  A teacher is told why one could not be made.
   *  Doc -> Element -> String -> Promise */
  async makePictures(doc, root, baseURL) {
    const wanted = pictures(doc.notebook);
    if (!wanted.length || typeof document === "undefined") return;
    const base = new URL(baseURL || ".", document.baseURI);
    const jobs = wanted.map((want) => {
      const target = new URL(want.file, base).href;
      const images = [...root.querySelectorAll("img")]
        .filter((img) => new URL(img.getAttribute("src") ?? "", base).href === target);
      for (const img of images) img.style.visibility = "hidden";
      return { want, target, images };
    });
    for (const { want, target, images } of jobs) {
      let made;
      try {
        made = await this.picture(want, doc);
      } catch (err) {
        made = { problem: err.message };
      }
      for (const img of images) img.style.visibility = "";
      if (made.blob) {
        const url = URL.createObjectURL(made.blob);
        for (const img of images) img.src = url;
        this.save(target, made.blob);
      } else {
        console.warn(`${want.file}: ${made.problem}`);
        if (this.cfg.mode === "teacher") {
          for (const img of images.length ? images : []) {
            img.after(Object.assign(document.createElement("div"), {
              className: "pkn-picture-problem",
              textContent: `${want.file} was not made: ${made.problem}`,
            }));
          }
        }
      }
    }
  }

  /** Saves a picture beside the document, where the page was told how:
   *  posted to `save.url` under its path below `save.root`. Nothing is
   *  said where it cannot be. String -> Blob -> () */
  save(target, blob) {
    const save = this.cfg.save;
    if (!save?.url || !save.root || !target.startsWith(save.root)) return;
    const path = target.slice(save.root.length).split("/").map(encodeURIComponent).join("/");
    fetch(new URL(path, save.url), { method: "POST", body: blob })
      .then((response) => {
        if (!response.ok) console.warn(`could not save ${path}: ${response.status}`);
      })
      .catch(() => { /* no server to save to */ });
  }

  /** Ends the running cell and cancels every queued one. The compiler's
   *  worker is terminated -- the only stop that works on a loop that
   *  never checks for one -- and a fresh one boots behind it. */
  stop() {
    this.generation += 1;
    const cell = this.running;
    if (cell) cell.stopped = true;
    this.runtime.stop();
    this.status("busy", "restarting the compiler");
    this.runtime.ready()
      .then(() => this.status("ready", "ready"))
      .catch(() => this.status("error", "the compiler did not restart"));
  }

  /** Runs the cell at index. Int -> Promise */
  run(index) {
    return this.enqueue(this.cells[index]);
  }

  /** Puts the cell at index back to what the document says. Int -> () */
  reset(index) {
    this.cells[index].reset();
  }

  /** Moves the keyboard to the cell after this one, if there is one.
   *  Cell -> () */
  focusAfter(cell) {
    const next = this.cells[this.cells.indexOf(cell) + 1];
    next?.ensureEditor();
    if (!next?.editor) {
      cell.editor?.blur();
      return;
    }
    // After the key that asked for it is finished with: Ace is still
    // inside the keystroke's handling, and a read-only editor's input
    // would otherwise lose the focus straight back to this one.
    setTimeout(() => {
      next.editor.focus();
      next.element.scrollIntoView({ block: "nearest", behavior: "smooth" });
    });
  }

  status(kind, text) {
    if (!this.ui.status) return;
    this.ui.status.className = "pkn-status pkn-" + kind;
    this.ui.statusText.textContent = text;
  }
}

// ---------------------------------------------------------------- notebook

class Notebook extends Cells {
  constructor(host, doc, cfg, web, source) {
    super(cfg, web);
    this.host = host;
    this.doc = doc;
    this.title = doc.title;
    this.source = source;
  }

  async init() {
    this.buildDom();
    if (this.doc.math) this.renderMath();
    // First in the run queue: the text may show what they make.
    this.picturesMade = this.makePictures(this.doc, this.host, this.baseURL);
    await super.init();
    for (const pre of this.host.querySelectorAll("pre.pkn-code")) this.highlight(pre);
    if (this.activities[0]?.checks) this.check();
  }

  /** Runs what test mode checks, in this page's worker, and shows each
   *  problem under the element it is about. () -> Promise */
  async check() {
    const run = (source, name, stdin, args, events = "", until = null) =>
      this.capture(source, { name, stdin, args: this.web.splitArguments(args ?? ""),
        tinyweb: events !== "" || until !== null, events, until });
    const { problems } = await checkNotebook(this.doc, run);
    this.activities[0].showChecks(problems);
    this.checked = problems;
  }

  themed() {
    return [this.host];
  }

  // -- the page ----------------------------------------------------------

  buildDom() {
    const { host, doc, cfg } = this;
    host.classList.add("pkn-notebook");
    const contents = cfg.contents ? this.contentsList() : "";
    host.innerHTML = `
      ${cfg.header ? `
      <header class="pkn-header">
        ${contents ? `<button class="pkn-icon pkn-menu" data-r="menu"
            aria-label="Contents" title="Contents">${ICON.menu}</button>` : ""}
        <div class="pkn-title">${escapeHTML(doc.title || "Notebook")}</div>
        <div class="pkn-status" data-r="status"><span class="pkn-dot"></span>
          <span data-r="statusText"></span></div>
        <button class="pkn-icon pkn-theme" data-r="theme"></button>
      </header>` : ""}
      <div class="pkn-layout${contents ? "" : " pkn-no-contents"}">
        ${contents}
        <main class="pkn-main"><article class="pkn-prose">${doc.html}</article></main>
      </div>`;
    this.ui = {};
    for (const el of host.querySelectorAll("[data-r]")) this.ui[el.dataset.r] = el;

    this.ui.theme?.addEventListener("click", () => this.cycleTheme());
    this.ui.menu?.addEventListener("click", () =>
      host.classList.toggle("pkn-contents-open"));
    host.querySelector(".pkn-contents")?.addEventListener("click", (event) => {
      if (event.target.closest("a")) host.classList.remove("pkn-contents-open");
    });

    for (const placeholder of host.querySelectorAll(".pkn-cell[data-cell]")) {
      const spec = doc.cells[Number(placeholder.dataset.cell)];
      this.cells.push(new Cell(this, spec, placeholder));
    }
    // Cells in document order, so the [n] of a cell and Shift+Enter's
    // next cell follow the page even when a task moves one.
    this.cells.sort((a, b) => a.spec.index - b.spec.index);
    this.activities.push(new Activities(this, doc, host, {
      mode: cfg.mode,
      storageKey: cfg.storageKey ?? (cfg.url ? new URL(cfg.url, document.baseURI).href
        : "text:" + textHash(this.source)),
      onChange: () => this.changed(),
      checks: true,
    }));
    if (contents) this.followScrolling();
  }

  /** The contents sidebar: every heading down to level 3. A lone
   *  level-1 heading is the title, already in the header, and is left
   *  out. () -> String */
  contentsList() {
    const headings = this.doc.headings.filter((h) => h.level <= 3);
    const ones = headings.filter((h) => h.level === 1);
    const shown = ones.length === 1 ? headings.filter((h) => h.level > 1) : headings;
    if (shown.length < 2) return "";
    const top = Math.min(...shown.map((h) => h.level));
    const items = shown.map((h) => `<li class="pkn-toc-${h.level - top}">`
      + `<a href="#${h.id}" data-id="${h.id}">${escapeHTML(h.text)}</a></li>`).join("");
    return `<nav class="pkn-contents" aria-label="Contents">
      <div class="pkn-contents-title">Contents</div><ul>${items}</ul></nav>`;
  }

  /** Highlights the contents entry of the section being read. */
  followScrolling() {
    const links = [...this.host.querySelectorAll(".pkn-contents a")];
    const targets = links.map((a) => this.host.querySelector(`#${CSS.escape(a.dataset.id)}`));
    let pending = false;
    const update = () => {
      pending = false;
      const edge = (this.ui.status?.closest(".pkn-header")?.offsetHeight ?? 0) + 24;
      let current = 0;
      targets.forEach((el, k) => {
        if (el && el.getBoundingClientRect().top <= edge) current = k;
      });
      links.forEach((a, k) => a.classList.toggle("pkn-current", k === current));
    };
    // Captured, so it hears whichever element scrolls: the window when the
    // notebook is the page, or a container when it is embedded in one.
    document.addEventListener("scroll", () => {
      if (!pending) { pending = true; requestAnimationFrame(update); }
    }, { capture: true, passive: true });
    update();
  }

  /** A static code block as a read-only editor in its language's mode.
   *  Element -> () */
  highlight(pre) {
    const mode = MODES[pre.dataset.lang];
    if (!mode) return;
    const text = pre.textContent;
    const holder = document.createElement("div");
    holder.className = "pkn-static";
    pre.replaceWith(holder);
    const editor = ace.edit(holder, {
      ...this.editorOptions(),
      mode: "ace/mode/" + mode,
      readOnly: true,
      showGutter: false,
      highlightActiveLine: false,
      highlightGutterLine: false,
    });
    editor.setValue(text, -1);
    editor.renderer.setPadding(16);
    editor.renderer.setScrollMargin(10, 10, 0, 0);
    editor.renderer.$cursorLayer.element.style.display = "none";
    this.statics = [...(this.statics ?? []), editor];
  }

  /** Typesets every math span with KaTeX, loaded only for a document
   *  that has some. A formula KaTeX cannot read is shown as written. */
  async renderMath() {
    let katex;
    try {
      katex = await this.web.ensureKatex(this.cfg.vendorURL);
    } catch {
      return;          // the TeX stays visible, which is still readable
    }
    for (const el of this.host.querySelectorAll(".pkn-math")) {
      const tex = el.textContent;
      try {
        katex.render(tex, el, {
          displayMode: el.classList.contains("pkn-math-display"),
          throwOnError: false,
        });
        el.title = tex;
      } catch {
        el.textContent = tex;
      }
    }
  }
}

// -------------------------------------------------------------------- cell

class Cell {
  constructor(notebook, spec, placeholder) {
    this.notebook = notebook;
    this.spec = spec;
    this.editor = null;
    this.expected = null;      // the stdout block the document shows under it
    this.stopped = false;
    this.marker = null;
    this.outputSize = 0;

    const { error, readonly } = spec.attrs;
    const element = document.createElement("div");
    element.className = "pkn-cell";
    element.id = spec.id;
    element.innerHTML = `
      <div class="pkn-cell-side">
        <button class="pkn-run" data-r="run" title="Run (Shift+Enter)"
                aria-label="Run cell ${spec.index + 1}">${ICON.run}</button>
        <button class="pkn-stop pkn-hidden" data-r="stop" title="Stop"
                aria-label="Stop">${ICON.stop}</button>
        <span class="pkn-count" data-r="count"></span>
      </div>
      <div class="pkn-cell-main">
        <div class="pkn-cell-inputs pkn-hidden" data-r="inputs">
          <label class="pkn-input pkn-hidden" data-r="stdinField">
            <span class="pkn-input-label">stdin</span>
            <textarea class="pkn-stdin" rows="2" spellcheck="false"
                      data-r="stdin" aria-label="Standard input for cell ${spec.index + 1}"></textarea>
          </label>
          <label class="pkn-input pkn-hidden" data-r="argsField">
            <span class="pkn-input-label">args</span>
            <input class="pkn-args" type="text" spellcheck="false"
                   data-r="args" aria-label="Arguments for cell ${spec.index + 1}">
          </label>
        </div>
        <div class="pkn-cell-frame">
          <div class="pkn-cell-editor" data-r="editorHost"></div>
          <div class="pkn-cell-tags">
            ${error ? '<span class="pkn-tag pkn-tag-error" title="This example is meant to be refused">expects an error</span>' : ""}
            ${readonly ? '<span class="pkn-tag" title="This cell cannot be edited">read-only</span>' : ""}
            <button class="pkn-tag pkn-reset pkn-hidden" data-r="reset"
                    title="Put back the code the document has">${ICON.reset} reset</button>
          </div>
        </div>
        <div class="pkn-output pkn-hidden" data-r="output">
          <div class="pkn-page pkn-hidden" data-r="page"></div>
          <div class="pkn-stdout-box" data-r="stdoutBox">
            <span class="pkn-input-label">stdout</span>
            <pre class="pkn-stdout" data-r="stdout"></pre>
          </div>
          <div class="pkn-result pkn-hidden" data-r="result"></div>
        </div>
      </div>`;
    this.ui = {};
    for (const el of element.querySelectorAll("[data-r]")) this.ui[el.dataset.r] = el;
    // The plain-text copy the renderer wrote stays until Ace replaces it,
    // so the code is readable while the compiler loads.
    this.ui.editorHost.appendChild(placeholder.querySelector("pre"));
    placeholder.replaceWith(element);
    this.element = element;

    this.ui.stdin.value = spec.stdin ?? "";
    this.ui.args.value = spec.args ?? "";
    // The code editor's own keys, in the two input fields too, so a cell
    // can be run from wherever its input is being typed.
    for (const field of [this.ui.stdin, this.ui.args]) {
      field.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
          field.blur();
        } else if (event.key === "Enter" && event.shiftKey
                   && !event.ctrlKey && !event.metaKey) {
          event.preventDefault();
          this.run();
          this.notebook.focusAfter(this);
        } else if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
          event.preventDefault();
          this.run();
        }
      });
    }
    this.ui.run.addEventListener("click", () => this.run());
    this.ui.stop.addEventListener("click", () => this.notebook.stop());
    this.ui.reset.addEventListener("click", () => this.reset());
    // What the embedding page offers to do with a cell's code -- the
    // playground's Help tab copies it into the editor.
    for (const action of notebook.cfg.cellActions ?? []) {
      const button = document.createElement("button");
      button.className = "pkn-tag pkn-action";
      button.textContent = action.label;
      button.title = action.title ?? action.label;
      button.addEventListener("click", () => action.run(this.source()));
      element.querySelector(".pkn-cell-tags").appendChild(button);
    }
    this.analyzeTimer = null;
    this.uses = { stdin: false, args: false };
    this.analyzed = null;          // the source `uses` was found for
    this.editListeners = [];
    this.pendingSource = null;
  }

  /** Calls `listener` with the code each time it is edited.
   *  (String -> ()) -> () */
  onEdit(listener) {
    this.editListeners.push(listener);
  }

  /** Puts `text` in the editor, as if it had been typed there.
   *  String -> () */
  setSource(text) {
    if (this.editor) {
      this.editor.setValue(text, -1);
      return;
    }
    this.pendingSource = text;
    for (const listener of this.editListeners) listener(this.source());
  }

  /** The file name a cell's program runs as. () -> String */
  name() {
    return `cell-${this.spec.index + 1}.pyk`;
  }

  /** What the cell's program reads and is passed, where it uses them.
   *  () -> {stdin, args} */
  input() {
    return {
      stdin: this.uses.stdin ? this.ui.stdin.value : "",
      args: this.uses.args ? this.notebook.web.splitArguments(this.ui.args.value) : [],
    };
  }

  /** What the cell's program reads and is passed, once the compiler has
   *  said whether its code as it is now uses them: a run right after
   *  the page opened or the code changed does not wait on the analysis
   *  the timer would start, and so gets no input.
   *  () -> Promise<{stdin, args}> */
  async currentInput() {
    if (this.analyzed !== this.source()) {
      clearTimeout(this.analyzeTimer);
      await this.analyze();
    }
    return this.input();
  }

  /** Asks the compiler whether the program reads standard input or its
   *  arguments, and shows the fields for whichever it does. A program
   *  that does not check keeps the fields it had. () -> Promise */
  async analyze() {
    const source = this.source();
    let analysis;
    try {
      analysis = await this.notebook.runtime.analyze(source, this.name());
    } catch {
      return;
    }
    if (!analysis.ok) return;
    this.uses = { stdin: analysis.stdin, args: analysis.args };
    this.analyzed = source;
    this.ui.stdinField.classList.toggle("pkn-hidden", !analysis.stdin);
    this.ui.argsField.classList.toggle("pkn-hidden", !analysis.args);
    this.ui.inputs.classList.toggle("pkn-hidden", !(analysis.stdin || analysis.args));
  }

  scheduleAnalyze() {
    clearTimeout(this.analyzeTimer);
    this.analyzeTimer = setTimeout(() => this.analyze(), ANALYZE_DELAY);
  }

  attachEditor() {
    const host = this.ui.editorHost;
    host.textContent = "";
    const editor = ace.edit(host, {
      ...this.notebook.editorOptions(),
      mode: "ace/mode/pyking",
      readOnly: this.spec.attrs.readonly,
      highlightActiveLine: false,
      highlightGutterLine: false,
    });
    editor.setValue(this.pendingSource ?? this.spec.source, -1);
    this.ui.reset.classList.toggle("pkn-hidden", editor.getValue() === this.spec.source);
    this.pendingSource = null;
    editor.session.setUndoManager(new (ace.require("ace/undomanager").UndoManager)());
    editor.renderer.setScrollMargin(10, 10, 0, 0);
    editor.on("focus", () => {
      editor.setHighlightActiveLine(true);
      this.element.classList.add("pkn-focused");
    });
    editor.on("blur", () => {
      editor.setHighlightActiveLine(false);
      this.element.classList.remove("pkn-focused");
    });
    editor.session.on("change", () => {
      this.clearMarker();
      this.ui.reset.classList.toggle("pkn-hidden", this.source() === this.spec.source);
      this.scheduleAnalyze();
      for (const listener of this.editListeners) listener(this.source());
    });
    // Registered as Ace commands, since Ace handles keys on its own
    // textarea before any listener outside it would hear them.
    const bind = (name, bindKey, exec) =>
      editor.commands.addCommand({ name, bindKey, exec, readOnly: true });
    bind("pknRunAdvance", { win: "Shift-Enter", mac: "Shift-Enter" }, () => {
      this.run();
      this.notebook.focusAfter(this);
    });
    // On a Mac, Control as well as Command, as in the playground.
    bind("pknRun", { win: "Ctrl-Enter", mac: "Command-Enter|Ctrl-Enter" }, () => this.run());
    bind("pknLeave", { win: "Esc", mac: "Esc" }, () => editor.blur());
    this.editor = editor;
    if (this.notebook.running === this) editor.setReadOnly(true);
    this.analyze();
  }

  source() {
    return this.editor ? this.editor.getValue() : (this.pendingSource ?? this.spec.source);
  }

  /** Makes the cell's editor, once the compiler has loaded, if it has
   *  none yet. () -> () */
  ensureEditor() {
    if (!this.editor && this.notebook.editorsReady) this.attachEditor();
  }

  /** Runs the cell; `until` is a task's compare-until limit, which
   *  Submit's run of an answer stops at. {events, patterns}? -> Promise */
  run(until = null) {
    this.ensureEditor();
    if (!this.editor) return Promise.resolve();
    if (this.state === "queued" || this.state === "running") return Promise.resolve();
    return this.notebook.enqueue(this, until);
  }

  reset() {
    this.editor?.setValue(this.spec.source, -1);
    this.pendingSource = null;
    this.clearMarker();
  }

  setState(state) {
    this.state = state;
    this.element.dataset.state = state;
    if (state === "queued") this.ui.count.textContent = "[*]";
    if (state === "idle") this.ui.count.textContent = this.lastCount ? `[${this.lastCount}]` : "";
  }

  begin() {
    this.setState("running");
    this.expected?.classList.add("pkn-hidden");
    this.stopped = false;
    this.clearMarker();
    this.ui.run.classList.add("pkn-hidden");
    this.ui.stop.classList.remove("pkn-hidden");
    this.ui.count.textContent = "[*]";
    this.ui.stdout.textContent = "";
    this.outputSize = 0;
    this.ui.result.className = "pkn-result pkn-hidden";
    this.ui.result.textContent = "";
    this.ui.output.classList.add("pkn-hidden");
    this.host?.close();
    this.host = null;
    this.ui.page.classList.add("pkn-hidden");
  }

  /** Shows what the program sent its page, mounting the page the first
   *  time. String -> [Object] -> () */
  page(module, data) {
    if (!this.host) {
      const runtime = this.notebook.runtime;
      this.host = new this.notebook.web.PageHost(this.ui.page, {
        libURL: runtime.libURL,
        send: (name, event) => runtime.sendEvent(name, event),
      });
    }
    this.ui.output.classList.remove("pkn-hidden");
    this.ui.page.classList.remove("pkn-hidden");
    this.host.receive(module, data);
  }

  end() {
    this.ui.stop.classList.add("pkn-hidden");
    this.ui.run.classList.remove("pkn-hidden");
    this.setState("idle");
  }

  /** Appends what the program wrote -- marked with `kind` where it is a
   *  `debug` line or a failure. What it reads is not shown.
   *  String -> String? -> () */
  write(text, kind = null) {
    if (this.outputSize >= OUTPUT_LIMIT) return;
    this.ui.output.classList.remove("pkn-hidden");
    this.ui.stdoutBox.classList.remove("pkn-hidden");
    this.outputSize += text.length;
    const shown = this.outputSize < OUTPUT_LIMIT ? text : text + "… (output truncated)\n";
    if (kind === null) {
      this.ui.stdout.append(shown);
    } else {
      const span = document.createElement("span");
      span.className = kind;
      span.textContent = shown;
      this.ui.stdout.append(span);
    }
  }

  /** Shows how a run ended. A cell marked `error` is expected to be
   *  refused, so a refusal is what it should show and a clean run is the
   *  surprise. {ok, text?, info?} -> Int -> Float -> () */
  finish(result, count, elapsed) {
    this.lastCount = count;
    this.end();
    const expectError = this.spec.attrs.error;
    if (result.ok && result.exit && !expectError) {
      this.result("pkn-error", `exited with status ${result.exit} after ${formatTime(elapsed)}`);
    } else if (result.ok && result.until && !expectError) {
      this.result("pkn-ok", `${ICON.ok} stopped after ${result.until} events, as far as the task `
        + `compares, in ${formatTime(elapsed)}`);
    } else if (result.ok && !expectError) {
      this.result("pkn-ok", `${ICON.ok} ran in ${formatTime(elapsed)}`);
    } else if (result.ok) {
      this.result("pkn-surprise",
        `${ICON.warn} This example is meant to be refused, but it ran.`);
    } else {
      const label = expectError ? "Refused, as this example intends" : "";
      this.result(expectError ? "pkn-expected" : "pkn-error",
        (label ? `<div class="pkn-result-label">${label}</div>` : "")
        + `<pre>${escapeHTML(result.text.trimEnd())}</pre>`);
      if (result.info) this.mark(result.info, expectError);
    }
  }

  finishStopped() {
    this.end();
    this.result("pkn-stopped", `${ICON.stop} stopped`);
  }

  fail(message) {
    this.end();
    this.result("pkn-error", `<pre>${escapeHTML(message)}</pre>`);
  }

  result(kind, html) {
    this.ui.output.classList.remove("pkn-hidden");
    this.ui.stdoutBox.classList.toggle("pkn-hidden", this.ui.stdout.textContent === "");
    this.ui.result.className = "pkn-result " + kind;
    this.ui.result.innerHTML = html;
  }

  /** Underlines the span an error names, in the editor. {row1, col1,
   *  row2, col2} -> Bool -> () */
  mark(info, expected) {
    if (!this.editor) return;
    const Range = ace.require("ace/range").Range;
    const range = new Range(info.row1 - 1, info.col1, info.row2 - 1, info.col2);
    this.marker = this.editor.session.addMarker(
      range, expected ? "pkn-expected-marker" : "pkn-error-marker", "text");
    this.editor.session.setAnnotations([{
      row: info.row1 - 1, column: info.col1,
      type: expected ? "warning" : "error", text: "the error is here",
    }]);
  }

  clearMarker() {
    if (this.marker === null || !this.editor) return;
    this.editor.session.removeMarker(this.marker);
    this.editor.session.clearAnnotations();
    this.marker = null;
  }
}

// ----------------------------------------------------------------- helpers

/** A short fingerprint of a document given as text, naming where its
 *  progress is kept. String -> String */
function textHash(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h * 33) ^ text.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

function formatTime(ms) {
  return ms < 1000 ? `${Math.max(1, Math.round(ms))} ms` : `${(ms / 1000).toFixed(2)} s`;
}

/* The theme choice lives in localStorage, which a private window or a
   sandboxed frame may refuse; neither is worth failing over, so both
   directions degrade to "auto". */
function loadTheme() {
  try {
    const saved = localStorage.getItem(THEME_KEY);
    return THEMES.includes(saved) ? saved : "auto";
  } catch {
    return "auto";
  }
}

function saveTheme(choice) {
  try {
    localStorage.setItem(THEME_KEY, choice);
  } catch {
    /* not remembered; the choice still applies to this page */
  }
}

const svg = (body, extra = "") =>
  `<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" ${extra}>${body}</svg>`;

const ICON = {
  run: svg('<path d="M4.9 3.3v9.4a.7.7 0 0 0 1.05.6l7.3-4.7a.7.7 0 0 0 0-1.2L5.95 2.7a.7.7 0 0 0-1.05.6z" fill="currentColor"/>'),
  stop: svg('<rect x="4" y="4" width="8" height="8" rx="1.2" fill="currentColor"/>'),
  reset: svg('<path d="M3.5 8a4.5 4.5 0 1 0 1.4-3.3M3.5 2.5v2.8h2.8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>', 'width="12" height="12"'),
  ok: svg('<path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>', 'width="12" height="12"'),
  warn: svg('<path d="M8 2l6.5 11.5h-13z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/><path d="M8 6.5v3.2M8 11.6v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>', 'width="13" height="13"'),
  menu: svg('<path d="M2.5 4h11M2.5 8h11M2.5 12h11" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'),
  auto: svg('<circle cx="8" cy="8" r="5.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 2.5a5.5 5.5 0 0 1 0 11z" fill="currentColor"/>'),
  light: svg('<circle cx="8" cy="8" r="3" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.4 1.4M11.6 11.6L13 13M3 13l1.4-1.4M11.6 4.4L13 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'),
  dark: svg('<path d="M13.5 9.5A5.8 5.8 0 0 1 6.5 2.5a5.8 5.8 0 1 0 7 7z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>'),
};
