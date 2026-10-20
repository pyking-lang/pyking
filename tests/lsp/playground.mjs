// Drives the playground in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// its editor, Monaco, as a client of the language server in the
// compiler's worker: an error is underlined, a hover shows a type,
// completion offers a name, go to definition moves the cursor, the
// outline answers; and that compiling and running still work. Then the
// right-hand tabs, the REPL (entries, Tab completion, the environment, Copy from editor,
// Stop), the Debug tab (breakpoints, stepping, the panes, a tinyweb
// callback), the light and dark themes, and a link holding a program (Copy
// code as link, then the link opened in the same tab). It serves nothing:
// tests/test_lsp.py starts `pyk playground` and runs this against it.
//
// Usage: node playground.mjs <chromium> <url>
// Writes {checks, failures} as JSON.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { connect, launch, progress } from "../chromium.mjs";

const [browser, url] = process.argv.slice(2);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "pyk-playground-"));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// What runs in the page: helpers, then one script per phase, each
// answering [[label, ok, detail]].
const HELPERS = `
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const app = window.pykingPlayground;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const until = async (test, ms = 15000) => {
    for (let waited = 0; waited < ms; waited += 100) {
      const value = await test();
      if (value) return value;
      await sleep(100);
    }
    return await test();
  };
  const output = () => $("[data-r=output]").textContent;
  const markers = () => monaco.editor.getModelMarkers(
    { owner: "pyking-lsp", resource: app.left.getModel().uri });
  const source = async (text) => {
    app.setSource(text);
    app.left.focus();
    await sleep(800);
  };
  const at = (lineNumber, column) => {
    app.left.setPosition({ lineNumber, column });
    app.left.focus();
  };
  const checks = [];
  const check = (label, ok, detail = "") => checks.push([label, !!ok, String(detail).slice(0, 300)]);
`;

const PAGE = `(async () => { ${HELPERS}
  check("the editor is Monaco", window.monaco?.editor
    && $("[data-r=leftEditor] .monaco-editor") && $("[data-r=rightEditor] .monaco-editor")
    && app.left.getModel().getLanguageId() === "pyking",
    app.left?.getModel?.().getLanguageId?.());
  check("the source is highlighted",
    await until(() => new Set($$("[data-r=leftEditor] .view-lines span span")
      .map((s) => s.className)).size >= 3), "fewer than three token classes");

  await source("total = 1 + 2\\nprint(total)\\n");
  const target = $("[data-r=target]");
  target.value = "python12";
  target.dispatchEvent(new Event("change"));
  $("[data-r=compile]").click();
  const compiled = await until(() => app.right.getValue().includes("print"));
  check("Compile to python shows the generated code", compiled, app.right.getValue());
  check("in Python", app.right.getModel().getLanguageId() === "python",
    app.right.getModel().getLanguageId());
  check("highlighted", await until(() => new Set($$("[data-r=rightEditor] .view-lines span span")
      .map((s) => s.className)).size >= 2), "one token class");

  const offered = [];
  const made = URL.createObjectURL;
  URL.createObjectURL = (blob) => { offered.push(blob); return made.call(URL, blob); };
  $("[data-r=download]").click();
  check("Download offers a zip", await until(() => offered.length > 0, 20000), "nothing offered");
  URL.createObjectURL = made;
  const zipped = offered[0] ? new Uint8Array(await offered[0].arrayBuffer()) : new Uint8Array();
  const listing = new TextDecoder().decode(zipped);
  check("holding the program and a Makefile", zipped[0] === 0x50 && zipped[1] === 0x4b
    && listing.includes("playground-python12/playground.py")
    && listing.includes("playground-python12/Makefile"), listing.slice(0, 200));

  $("[data-r=runLeft]").click();
  const ran = await until(() => /finished/.test(output()), 30000);
  check("Run prints what the program prints", ran && output().includes("3\\n"), output());
  return checks;
})()`;

const TABS = `(async () => { ${HELPERS}
  const shown = (r) => !$("[data-r=" + r + "]").closest(".pyk-hidden");
  const active = () => $(".pyk-tab.active")?.dataset.tab;
  check("there are six tabs", $$(".pyk-tab").map((t) => t.textContent).join("|")
    === "Run output|Compiled code|Web output|REPL|Debug|Help", $$(".pyk-tab").map((t) => t.textContent));
  check("Compile and the targets are on the Compiled code tab only",
    $("[data-r=panelCompiled]").contains($("[data-r=compile]"))
    && $("[data-r=panelCompiled]").contains($("[data-r=target]")));

  await source("print(6 * 7)\\n");
  $("[data-r=tabCompiled]").click();
  $("[data-r=runLeft]").click();
  check("Run shows the Run output tab", await until(() => active() === "run"
    && /42\\n[\\s\\S]*finished/.test(output()), 30000), active() + ": " + output());
  check("which the whole tab is given to", shown("output")
    && $("[data-r=panelRun]").contains($("[data-r=output]")));
  check("with no tinyweb log switch there", !shown("tinywebLogBox"));

  await app.loadExample("tinyweb1.pyk", { silent: true });
  $("[data-r=runLeft]").click();
  check("a program with a page shows the Web output tab",
    await until(() => active() === "web" && $("[data-r=page] canvas"), 30000), active());
  check("with its output below the page", $("[data-r=panelWeb]").contains($("[data-r=output]"))
    && await until(() => output().includes("built the page")), output());
  check("in a frame named after the program",
    $("[data-r=pageTitle]").textContent === "tinyweb1.pyk", $("[data-r=pageTitle]").textContent);
  $("[data-r=output]").textContent = "";
  $("[data-r=refresh]").click();
  check("Refresh runs the program again", await until(() => output().includes("built the page")
    && $("[data-r=page] canvas"), 30000), output());
  check("the Web output tab has a tinyweb log switch", shown("tinywebLogBox"));
  $("[data-r=tinywebLog]").click();
  $("[data-r=output]").textContent = "";
  $("[data-r=refresh]").click();
  check("which shows the tinyweb log as stderr", await until(() =>
    $$("[data-r=output] .debug").some((e) => e.textContent.startsWith('canvas "canvas"')), 30000),
    output());
  $("[data-r=tinywebLog]").click();
  app.stopRun();
  await until(() => !app.running);
  check("a stopped program leaves no page, only the line saying what the frame is for",
    !$("[data-r=page] canvas") && $("[data-r=page] .pyk-page-empty") !== null,
    $("[data-r=page]").innerHTML.slice(0, 200));

  $("[data-r=tabHelp]").click();
  check("the Help tab shows the help, with its menu above the page",
    await until(() => $(".pyk-help-menu a") && $(".pyk-help-page h1")?.textContent, 30000),
    $("[data-r=helpHost]").textContent.slice(0, 120));
  const menu = $(".pyk-help-menu").getBoundingClientRect().height;
  const panel = $("[data-r=panelHelp]").getBoundingClientRect().height;
  check("the menu takes at most 30% of the tab", menu <= panel * .3 + 1, menu + " of " + panel);
  const tab = $("[data-r=panelHelp]").getBoundingClientRect();
  const page = $(".pyk-help-page").getBoundingClientRect();
  check("the page ends inside the tab, so its last line can be read",
    page.bottom <= tab.bottom + 1, page.bottom + " > " + tab.bottom);
  [...$$(".pyk-help-menu a")].find((a) => a.textContent === "io").click();
  check("a library's page opens, its functions boxed",
    await until(() => $$(".pyk-help-page .pyk-api").length >= 4, 20000),
    $(".pyk-help-page h1")?.textContent);
  const run = $(".pyk-help-page .pkn-run").getBoundingClientRect();
  check("a cell's run button is inside the page, not cut off",
    run.width > 0 && run.left >= page.left, run.left + " < " + page.left);
  const copy = await until(() => $$(".pyk-help-page .pkn-action")[0], 20000);
  copy?.click();
  check("Copy to editor puts an example in the editor",
    app.left.getValue().startsWith("import io"), app.left.getValue().slice(0, 60));
  return checks;
})()`;

const REPL = `(async () => { ${HELPERS}
  const shown = (r) => !$("[data-r=" + r + "]").closest(".pyk-hidden");
  $("[data-r=tabRepl]").click();
  const log = () => $("[data-r=replLog]").textContent;
  const input = $("[data-r=replInput]");
  const enter = async (text, wait = /> /) => {
    input.value = (input.value ?? "") + text;
    input.setSelectionRange(input.value.length, input.value.length);
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await sleep(300);
    await until(() => !app.replBusy, 20000);
  };
  const rows = () => $$("[data-r=env] tbody tr").map((r) => [...r.cells].map((c) => c.textContent).join(" "));
  check("the REPL starts", await until(() => log().includes("Pyking REPL"), 30000), log());
  check("with nothing bound", rows().join() === "no bindings yet", rows());
  await enter("x = 21");
  await enter("x * 2");
  check("an entry's value is shown with its type", log().includes("> x * 2\\n42 : Int\\n"), log());
  check("the environment lists what was bound", rows().join("|") === "x 21 Int", rows());
  await enter("def double(n):");
  check("Enter after a ':' opens an indented line", input.value === "def double(n):\\n    ",
    JSON.stringify(input.value));
  await enter("n * 2");
  await enter("");
  check("a blank line ends the block", log().includes("> def double(n):\\n.     n * 2\\n"), log());
  check("and the environment is up to date after each entry",
    rows().includes("double <function> (Int) -> Int") || rows().includes("double <function> (?) -> ?"),
    rows());
  await enter('print("hi " ++ string(double(x)))');
  check("what an entry prints appears", log().includes("hi 42\\n"), log());
  await enter("y = nope");
  check("a refusal is shown in red", $$("[data-r=replLog] .err").some((e) =>
    e.textContent.includes("unbound name 'nope'")), log());
  await enter(":ls");
  check(":ls answers", /x\\s+= 21 : Int/.test(log()), log());

  const tab = async (text) => {
    input.value = text;
    input.setSelectionRange(text.length, text.length);
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true }));
    await sleep(500);
  };
  await tab("dou");
  check("Tab completes the one name that fits", input.value === "double", JSON.stringify(input.value));
  input.value = "";
  await enter("delta = 1");
  await tab("d");
  check("Tab with several that fit lists them, each with its type",
    shown("replComplete") && $("[data-r=replComplete]").textContent.includes("delta")
    && $("[data-r=replComplete]").textContent.includes("(Int) -> Int"),
    $("[data-r=replComplete]").textContent);
  $$("[data-r=replComplete] .item").find((row) => row.textContent.startsWith("delta"))
    ?.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  check("and clicking one puts it in", input.value === "delta" && !shown("replComplete"),
    JSON.stringify(input.value));
  await tab("    ");
  check("Tab at the start of a line indents", input.value === "        ", JSON.stringify(input.value));
  input.value = "";

  app.left.setSelection(new monaco.Range(1, 1, 1, 1));
  $("[data-r=replCopy]").click();
  check("Copy from editor with nothing marked says to mark something",
    $$("[data-r=replLog] .err").some((e) => e.textContent.includes("mark the text")), log());
  await source("def triple(n: Int) -> Int:\\n    return n * 3\\n");
  app.left.setSelection(new monaco.Range(1, 1, 3, 1));
  $("[data-r=replCopy]").click();
  check("Copy from editor puts the marked text in the prompt",
    input.value === "def triple(n: Int) -> Int:\\n    return n * 3", JSON.stringify(input.value));
  input.value = "";

  await enter("def spin(n: Int) -> Int:");
  await enter("spin(n + 1)");
  await enter("");
  input.value = "spin(0)";
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  check("an entry that does not end can be stopped",
    await until(() => app.replBusy && shown("replStop"), 10000));
  $("[data-r=replStop]").click();
  check("which starts the session again", await until(() => !app.replBusy
    && log().includes("session starts again") && rows().join() === "no bindings yet", 30000),
    rows());
  await enter("z = 5");
  // An entry made while the session is still starting again waits for
  // it, so its bindings arrive once the new worker has loaded.
  check("and the new session works", await until(() => rows().join("|") === "z 5 Int", 30000),
    JSON.stringify([rows(), input.value]));
  return checks;
})()`;

const THEME = `(async () => { ${HELPERS}
  const root = $(".pyk-playground");
  const before = root.dataset.theme;
  $("[data-r=themeButton]").click();
  const after = root.dataset.theme;
  check("the header's switch changes the theme", before !== after
    && ["light", "dark"].includes(after), before + " -> " + after);
  check("Monaco follows it", $(".monaco-editor").classList.contains(after === "dark" ? "vs-dark" : "vs"),
    $(".monaco-editor").className);
  check("and the setting says so", $("[data-r=themeChoice]").value === after,
    $("[data-r=themeChoice]").value);
  const choice = $("[data-r=themeChoice]");
  choice.value = before;
  choice.dispatchEvent(new Event("change"));
  check("the setting changes it back", root.dataset.theme === before, root.dataset.theme);
  check("the page's colours follow the theme",
    getComputedStyle(root).backgroundColor !== "" && (() => {
      const [r, g, b] = getComputedStyle(root).backgroundColor.match(/\\d+/g).map(Number);
      return (r + g + b > 384) === (before === "light");
    })(), getComputedStyle(root).backgroundColor);
  return checks;
})()`;

const LSP = `(async () => { ${HELPERS}
  const running = await app.lspStarted;
  check("the language server is running", running === true, running);
  if (running !== true) return checks;

  await source("def f(a: Int) -> Int:\\n    return a\\n\\nprint(f(\\"no\\"))\\n");
  const found = await until(() => markers().length > 0);
  check("a type error is underlined, at its line", found
    && markers()[0].startLineNumber === 4
    && markers()[0].severity === monaco.MarkerSeverity.Error,
    JSON.stringify(markers()));

  await source("def f(a: Int) -> Int:\\n    return a\\n\\nprint(f(1))\\n");
  check("and the underline goes once it is fixed",
    await until(() => markers().length === 0), JSON.stringify(markers()));

  at(4, 7);
  app.left.trigger("test", "editor.action.revealDefinition", null);
  check("go to definition moves the cursor to the def",
    await until(() => app.left.getPosition().lineNumber === 1),
    JSON.stringify(app.left.getPosition()));

  // The right-click menu: white text on a dark menu. Monaco draws it in
  // a shadow root of its own.
  app.left.focus();
  app.left.trigger("test", "editor.action.showContextMenu", null);
  const label = await until(() => [document, ...$$(".shadow-root-host").map((h) => h.shadowRoot)]
    .filter(Boolean).map((root) => root.querySelector(".monaco-menu .action-label"))
    .find(Boolean));
  const colour = (el, property) => el ? getComputedStyle(el)[property] : "";
  // The menu's background is painted by whichever element round the
  // label first has one.
  let menuBox = label;
  while (menuBox && ["rgba(0, 0, 0, 0)", "transparent"].includes(getComputedStyle(menuBox).backgroundColor)) {
    menuBox = menuBox.parentElement;
  }
  const channels = colour(menuBox, "backgroundColor").replace(/[^0-9,]/g, "").split(",").map(Number);
  check("the context menu's text is white", colour(label, "color") === "rgb(255, 255, 255)",
    colour(label, "color"));
  check("on a dark menu", channels.length >= 3 && channels.slice(0, 3).every((v) => v < 100),
    colour(menuBox, "backgroundColor"));
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  app.left.focus();

  const symbols = await app.lsp.symbols();
  check("the outline lists the def", Array.isArray(symbols)
    && symbols.some((s) => s.name === "f"), JSON.stringify(symbols));

  await source("total = 1 + 2\\nprint(total)\\n");
  at(2, 8);
  app.left.trigger("test", "editor.action.showHover", null);
  const hover = await until(() => $$(".monaco-hover")
    .map((h) => h.textContent).find((t) => t.includes("Int")));
  check("a hover over a bound name shows its type", hover,
    $$(".monaco-hover").map((h) => h.textContent).join(" | "));
  app.left.trigger("test", "editor.action.hideHover", null);

  await source("total = 1 + 2\\n");
  at(2, 1);
  app.left.trigger("keyboard", "type", { text: "print(to" });
  await sleep(500);
  app.left.trigger("test", "editor.action.triggerSuggest", null);
  const offered = await until(() => $$(".suggest-widget .monaco-list-row")
    .map((r) => r.textContent).find((t) => t.includes("total")));
  check("completion offers a name in scope", offered,
    $$(".suggest-widget .monaco-list-row").map((r) => r.textContent).join(" | "));
  app.left.trigger("test", "hideSuggestWidget", null);
  return checks;
})()`;

const LINK = `(async () => { ${HELPERS}
  const program = "# å ä ö 👑\\nprint(\\"from the link\\")\\n";
  let copied = null;
  Object.defineProperty(navigator, "clipboard",
    { configurable: true, value: { writeText: async (text) => { copied = text; } } });
  await source(program);
  $("[data-r=copyLink]").click();
  await until(() => copied !== null, 5000);
  check("Copy code as link copies a link to the playground holding the program",
    copied && copied.startsWith(location.href.replace(/#.*$/, "") + "#code="), copied);
  await source("print(1)\\n");
  location.hash = copied.slice(copied.indexOf("#"));
  check("opening the link puts its program in the editor",
    await until(() => app.left.getValue() === program, 5000), app.left.getValue());
  check("in place of an example", $("[data-r=example]").value === "", $("[data-r=example]").value);
  await sleep(500);
  check("and does not run it", !output().includes("from the link"), output());
  return checks;
})()`;

// The Debug tab: a breakpoint, where it stops, the call stack, the
// variables, a watch and the console; stepping by button and by key;
// the end of the program; a runtime error; and a tinyweb callback,
// stopped in when its button is pressed.
const DEBUG = `(async () => { ${HELPERS}
  const dbg = app.debugger;
  const d = (name) => $("[data-d=" + name + "]");
  const stoppedAt = (row, depth) => until(() => dbg.state === "stopped" && dbg.frames.length > 0
    && dbg.frames[0].span.row1 === row && (depth === undefined || dbg.frames.length === depth), 20000);
  const consoleText = () => d("console").textContent;
  await source("def fact(n: Int) -> Int:\\n    if n <= 1:\\n        return 1\\n    return n * fact(n - 1)\\n\\nvar total = 0\\nxs = [1, 2, 3]\\nfor x in xs:\\n    total := total + fact(x)\\nprint(\\"total\\", total)\\n");
  $("[data-tab=debug]").click();
  check("the Debug tab shows its controls", d("start") && !d("start").classList.contains("pyk-hidden")
    && d("environment") && d("watch") && d("stack") && d("breakpointList") && d("console"));
  check("a control's tooltip names its keys", /\\(F10 or (Alt|Option)\\+O\\)/.test(d("next").title), d("next").title);
  check("Debug's tooltip names Continue's keys too",
    /\\((Alt|Option)\\+D or F8 or (Alt|Option)\\+C\\)/.test(d("start").title), d("start").title);
  check("the names pane is called Environment",
    d("environment").closest("details").querySelector("summary").textContent.trim() === "Environment");
  dbg.toggleBreakpoint(3);
  check("a breakpoint shows in the margin",
    await until(() => $$("[data-r=leftEditor] .pyk-bp-glyph.pyk-bp").length === 1));
  check("and in the Breakpoints pane", d("breakpointList").textContent.includes("line 3"),
    d("breakpointList").textContent);
  dbg.watches = ["n * 100"];
  d("start").click();
  check("Debug stops at the breakpoint", await stoppedAt(3, 2), JSON.stringify(dbg.frames));
  check("the status says why", /breakpoint/.test(d("status").textContent), d("status").textContent);
  check("the line is marked in the editor",
    await until(() => $$("[data-r=leftEditor] .pyk-debug-line").length > 0));
  const stack = () => $$(".pyk-debug-frame .name").map((e) => e.textContent).join(" | ");
  check("the call stack shows the calls in progress", stack() === "fact | <module playground>", stack());
  check("the variables show n, an Int, in the call",
    await until(() => /n\\s*1\\s*Int/.test(d("environment").textContent)), d("environment").textContent);
  check("a watch is evaluated where it stopped",
    await until(() => d("watch").textContent.includes("100")), d("watch").textContent);
  d("input").value = "fact(5)";
  d("input").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  check("the console evaluates an expression where it stopped",
    await until(() => consoleText().includes("120 : Int")), consoleText());
  d("continue").click();
  check("Continue stops at the breakpoint again, one call deeper", await stoppedAt(3, 3), stack());
  $$(".pyk-debug-frame")[2].click();
  check("choosing a frame shows its names",
    await until(() => /total\\s*1\\s*Int/.test(d("environment").textContent)
      && d("environment").textContent.includes("xs")), d("environment").textContent);
  check("and marks its line as a caller's",
    await until(() => $$("[data-r=leftEditor] .pyk-debug-line-caller").length > 0));
  check("a var is offered to be set", $$(".pyk-debug-node .value[title]").length > 0);
  dbg.toggleBreakpoint(3);
  d("out").click();
  check("Step out stops in the caller, at the call", await stoppedAt(4, 2), stack());
  const press = (target, key, code, more = {}) => {
    const event = new KeyboardEvent("keydown", { key, code, bubbles: true, cancelable: true, ...more });
    target.dispatchEvent(event);
    return event.defaultPrevented;
  };
  press($("[data-r=leftEditor] textarea"), "F10", "F10");
  check("the step-over key steps over the rest of the call, to its caller", await stoppedAt(9, 1), stack());
  d("next").click();
  check("Step over goes to the next turn of the loop", await stoppedAt(9, 1), stack());
  $("[data-tab=repl]").click();
  press($("[data-r=replInput]"), "i", "KeyI", { altKey: true });
  check("Alt+I in another tab steps into the call", await stoppedAt(2, 2), stack());
  check("and leaves the tab being looked at", app.tab === "repl", app.tab);
  d("continue").click();
  check("the program runs to its end",
    await until(() => dbg.state === "off" && consoleText().includes("total 9")), consoleText());
  check("and says it finished", consoleText().includes("finished"), consoleText());
  check("nothing is marked once it has ended",
    $$("[data-r=leftEditor] .pyk-debug-line").length === 0);
  check("with nothing debugged a step key does nothing",
    press($("[data-r=leftEditor] textarea"), "o", "KeyO", { altKey: true }) && dbg.state === "off");

  await source("xs = [1]\\nprint(10 / (len(xs) - 1))\\n");
  dbg.watches = [];
  d("start").click();
  check("Debug with no breakpoint stops at the first statement", await stoppedAt(1, 1),
    JSON.stringify(dbg.frames));
  d("stop").click();
  await until(() => dbg.state === "off");
  $("[data-tab=repl]").click();
  press($("[data-r=replInput]"), "d", "KeyD", { altKey: true });
  check("Alt+D starts debugging from another tab, at the first statement",
    await stoppedAt(1, 1) && app.tab === "debug", app.tab);
  d("continue").click();
  check("a runtime error stops the program where it happens",
    await until(() => dbg.state === "stopped" && /runtime error/.test(d("status").textContent), 20000),
    d("status").textContent);
  check("the console says what the error is", consoleText().includes("division by zero"), consoleText());
  d("stop").click();
  check("Stop ends debugging", await until(() => dbg.state === "off"), dbg.state);

  await source("import tinyweb as tw\\ntw.web_init(0)\\nvar count = 0\\ndef pressed():\\n    count := count + 1\\n    print(\\"pressed\\", count)\\ntw.button(\\"Count\\", on_click = pressed)\\n");
  dbg.toggleBreakpoint(6);
  d("start").click();
  check("a tinyweb program's top level ends, and the page's events are awaited",
    await until(() => dbg.state === "idle", 20000), dbg.state + " " + d("status").textContent);
  const button = await until(() => $$("[data-r=page] button").find((b) => b.textContent === "Count"));
  $("[data-tab=web]").click();
  button?.click();
  check("a breakpoint in a callback stops when its button is pressed", await stoppedAt(6, 1), stack());
  check("and the Debug tab is shown again", app.tab === "debug", app.tab);
  check("in the callback", stack() === "pressed", stack());
  d("continue").click();
  check("the callback runs on", await until(() => consoleText().includes("pressed 1")), consoleText());
  check("and the page's events are awaited again", await until(() => dbg.state === "idle"), dbg.state);
  d("stop").click();
  check("Stop ends debugging a page", await until(() => dbg.state === "off"), dbg.state);
  dbg.toggleBreakpoint(6);

  const chips = (action) => $$(".pyk-key-row[data-action=" + action + "] .pyk-key-chip")
    .map((c) => c.firstChild.textContent);
  check("the settings show each of an action's keys", chips("next").length === 2
    && chips("next")[0] === "F10", JSON.stringify(chips("next")));
  $(".pyk-key-row[data-action=next] .pyk-key-chip button").click();
  check("✕ removes one key", JSON.stringify(app.settings.debugKeys?.next) === '["Alt+O"]'
    && !/F10/.test(d("next").title), d("next").title);
  $(".pyk-key-row[data-action=next] .pyk-key-add").click();
  press($(".pyk-key-row[data-action=next] .pyk-key-field"), "F9", "F9", { shiftKey: true });
  check("+ records a key pressed", chips("next").join(",") === "Alt+O,Shift+F9"
    || chips("next").join(",") === "Option+O,Shift+F9", JSON.stringify(chips("next")));
  $(".pyk-key-row[data-action=next] .pyk-key-reset").click();
  check("reset gives an action its defaults back", app.settings.debugKeys?.next === undefined
    && chips("next").length === 2, JSON.stringify(app.settings.debugKeys));

  dbg.toggleBreakpoint(1);
  await app.loadExample(app.meta.examples[0].file);
  check("choosing an example removes the breakpoints", await until(() => dbg.breakpoints.length === 0
    && $$("[data-r=leftEditor] .pyk-bp-glyph.pyk-bp").length === 0), JSON.stringify(dbg.breakpoints));
  return checks;
})()`;

/** The debugger's keys pressed for real, as a reader on `platform`
 *  presses them -- Alt with the character a Mac's Option types -- and
 *  what each did: nothing typed, and the debugger moved.
 *  (send, String, evaluate, String) -> Promise<[[label, ok, detail]]> */
async function realKeys(send, sessionId, evaluate, platform) {
  const checks = [];
  const check = (label, ok, detail = "") => checks.push([`${label} (${platform})`, Boolean(ok), detail]);
  const MAC_TEXT = { D: "∂", C: "ç", O: "ø", I: "ˆ", T: "†", S: "ß", B: "∫" };
  const press = async (spec) => {
    const parts = spec.split("+");
    const name = parts.pop();
    const alt = parts.includes("Alt");
    const shift = parts.includes("Shift");
    const fkey = /^F[0-9]+$/.test(name);
    const code = fkey ? name : "Key" + name;
    const text = fkey ? undefined : alt ? MAC_TEXT[name] : name.toLowerCase();
    const key = fkey ? name : text;
    const common = { key, code, modifiers: (alt ? 1 : 0) | (shift ? 8 : 0),
                     windowsVirtualKeyCode: fkey ? 111 + Number(name.slice(1)) : name.charCodeAt(0) };
    await send("Input.dispatchKeyEvent",
      { type: text ? "keyDown" : "rawKeyDown", text, unmodifiedText: text, ...common }, sessionId);
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...common }, sessionId);
    await sleep(150);
  };
  const app = "window.pykingPlayground";
  const state = () => evaluate(`${app}.debugger.state`);
  const where = () => evaluate(`JSON.stringify(${app}.debugger.frames.map((f) => f.span.row1))`);
  const until = async (test, ms = 20000) => {
    for (let waited = 0; waited < ms; waited += 100) {
      if (await test()) return true;
      await sleep(100);
    }
    return false;
  };
  const stoppedAt = (rows) => until(async () => (await state()) === "stopped" && (await where()) === JSON.stringify(rows));
  const program = "a = 1\nb = a + 1\ndef f(n: Int) -> Int:\n    return n * 2\nc = f(b)\nprint(c)\n";
  const editor = () => evaluate(`${app}.left.getValue()`);
  const focusEditor = (line) => evaluate(`${app}.showTab("run"); ${app}.left.focus(); `
    + `${app}.left.setPosition({ lineNumber: ${line}, column: 1 })`);
  const untouched = async () => (await editor()) === program;

  await evaluate(`${app}.debugger.stop({ quiet: true }); ${app}.setSource(${JSON.stringify(program)}); `
    + `${app}.debugger.clearBreakpoints()`);
  await sleep(500);
  if (platform === "a Mac") {
    const title = await evaluate(`${app}.debugger.ui.start.title`);
    check("the keys are named as a Mac's keyboard names them", /Option\+D/.test(title), title);
  }
  await focusEditor(1);
  await press("Alt+D");
  check("Alt+D in the editor starts debugging, at the first statement", await stoppedAt([1]), await where());
  check("and types nothing", await untouched(), await editor());
  await focusEditor(1);
  await press("Alt+O");
  check("Alt+O steps over", await stoppedAt([2]), await where());
  await press("F10");
  check("F10 steps over", await until(async () => (await state()) === "stopped"
    && JSON.parse(await where())[0] > 2), await where());
  check("and the steps type nothing", await untouched(), await editor());
  await press("Alt+S");
  check("Alt+S stops", await until(async () => (await state()) === "off"), await state());

  await focusEditor(5);
  await press("Alt+B");
  check("Alt+B sets a breakpoint on the cursor's line",
    await until(async () => (await evaluate(`JSON.stringify(${app}.debugger.breakpoints.map((b) => b.line))`)) === "[5]"),
    await evaluate(`JSON.stringify(${app}.debugger.breakpoints.map((b) => b.line))`));
  check("and types nothing", await untouched(), await editor());
  for (const spec of ["Alt+O", "Alt+I", "Alt+T", "Alt+S", "F10", "F11", "Shift+F11"]) {
    await press(spec);
  }
  await sleep(300);
  check("with nothing debugged the step keys and Alt+S do nothing", (await state()) === "off"
    && await untouched(), (await state()) + " " + JSON.stringify(await editor()));
  await press("Alt+C");
  check("Alt+C starts debugging, to the breakpoint", await stoppedAt([5]), await where());
  await press("Alt+I");
  check("Alt+I steps into the call", await stoppedAt([4, 5]), await where());
  await press("Alt+T");
  check("Alt+T steps out to the caller", await until(async () => (await state()) === "stopped"
    && JSON.parse(await where()).length === 1), await where());
  await press("Alt+C");
  check("Alt+C runs it to its end", await until(async () => (await state()) === "off"), await state());
  check("and none of it typed anything", await untouched(), await editor());

  await evaluate(`${app}.showTab("repl"); document.querySelector("[data-r=replInput]").focus()`);
  await press("Alt+D");
  check("Alt+D in another tab starts debugging", await stoppedAt([5]), await where());
  check("shows the Debug tab", (await evaluate(`${app}.tab`)) === "debug", await evaluate(`${app}.tab`));
  check("and types nothing there",
    (await evaluate(`document.querySelector("[data-r=replInput]").value`)) === "",
    await evaluate(`document.querySelector("[data-r=replInput]").value`));
  await press("F11");
  check("F11 steps into the call", await stoppedAt([4, 5]), await where());
  await press("Shift+F11");
  check("Shift+F11 steps out", await until(async () => (await state()) === "stopped"
    && JSON.parse(await where()).length === 1), await where());
  await press("F8");
  check("F8 runs it to its end", await until(async () => (await state()) === "off"), await state());
  // A dead key, Option+I on a Mac: the keyboard starts an accent before
  // the page sees the key (a composition holding ˆ, U+02C6), and each
  // further one ends the open accent and starts another.
  const deadKey = async (name) => {
    const common = { key: "Dead", code: "Key" + name, modifiers: 1,
                     windowsVirtualKeyCode: name.charCodeAt(0) };
    await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...common }, sessionId);
    await send("Input.imeSetComposition", { text: "\u02c6", selectionStart: 1, selectionEnd: 1 }, sessionId);
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...common }, sessionId);
    await sleep(300);
  };
  await focusEditor(1);
  await press("Alt+C");
  check("(a dead key) Alt+C stops at the breakpoint", await stoppedAt([5]), await where());
  await evaluate(`${app}.left.focus(); ${app}.left.setPosition({ lineNumber: 2, column: 1 })`);
  await deadKey("I");
  check("a dead Alt+I steps into the call", await stoppedAt([4, 5]), await where());
  await deadKey("I");
  await deadKey("I");
  await sleep(300);
  check("and Alt+I pressed again and again leaves no accent in the editor", await untouched(),
    JSON.stringify(await editor()));
  await press("Alt+S");
  await until(async () => (await state()) === "off");
  await focusEditor(1);
  await deadKey("I");
  await press("E");
  check("a letter typed after a dead Alt+I comes out without the accent",
    (await editor()) === "e" + program, JSON.stringify(await editor()));
  await evaluate(`${app}.setSource(${JSON.stringify(program)})`);

  await sleep(1500);
  const shown = await evaluate(`document.querySelector("[data-r=leftEditor] .view-lines").textContent`);
  check("the editor shows no inferred types in the text", !/: *Int/.test(shown), shown);
  await focusEditor(1);
  check("the editor takes its input through a textarea",
    (await evaluate("document.activeElement.tagName")) === "TEXTAREA",
    await evaluate("document.activeElement.tagName + '.' + document.activeElement.className"));
  await evaluate(`${app}.debugger.clearBreakpoints()`);
  return checks;
}

const chrome = launch(browser, profile);

let output = { checks: 0, failures: [] };
try {
  const problems = [];
  const { send, close } = await connect(profile, (data) => {
    if (data.method === "Runtime.exceptionThrown") {
      problems.push(data.params.exceptionDetails.exception?.description
                    || data.params.exceptionDetails.text);
    }
  });
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  await send("Emulation.setDeviceMetricsOverride",
             { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false }, sessionId);
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    }
    return result.result.value;
  };
  progress("loading the playground");
  await send("Page.navigate", { url }, sessionId);
  let ready = false;
  for (let i = 0; i < 600 && !ready; i++) {
    await sleep(100);
    try {
      ready = await evaluate("!!window.pykingPlayground && "
        + "document.querySelector('[data-r=statusText]')?.textContent.includes('ready')");
    } catch {
      /* still loading */
    }
  }
  if (!ready) {
    throw new Error("the playground did not become ready"
      + (problems.length ? ": " + problems.join(" | ") : ""));
  }
  for (const [name, phase] of [["the page", PAGE], ["the language server", LSP],
                               ["the tabs", TABS], ["the REPL", REPL], ["the debugger", DEBUG],
                               ["the themes", THEME], ["a link", LINK]]) {
    progress(`checking ${name}`);
    for (const [label, ok, detail] of await evaluate(phase)) {
      output.checks += 1;
      if (!ok) output.failures.push(`${label}${detail ? ": " + detail : ""}`);
    }
  }
  // The debugger's keys pressed for real, through the browser's input,
  // so a key the playground does not swallow types into the editor:
  // once as this platform, once as a Mac.
  const record = (label, ok, detail) => {
    output.checks += 1;
    if (!ok) output.failures.push(`${label}${detail ? ": " + detail : ""}`);
  };
  const reload = async () => {
    await send("Page.reload", { ignoreCache: true }, sessionId);
    for (let i = 0; i < 600; i++) {
      await sleep(100);
      try {
        if (await evaluate("!!window.pykingPlayground && "
          + "document.querySelector('[data-r=statusText]')?.textContent.includes('ready')")) return;
      } catch { /* still loading */ }
    }
    throw new Error("the playground did not become ready again");
  };
  for (const platform of ["this platform", "a Mac"]) {
    if (platform === "a Mac") {
      await send("Emulation.setUserAgentOverride", {
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        platform: "MacIntel",
        userAgentMetadata: { platform: "macOS", platformVersion: "15.0", architecture: "arm",
                             model: "", mobile: false },
      }, sessionId);
      await reload();
    }
    progress(`checking the debugger's keys on ${platform}`);
    for (const [label, ok, detail] of await realKeys(send, sessionId, evaluate, platform)) {
      record(label, ok, detail);
    }
  }
  output.checks += 1;
  if (problems.length) output.failures.push("no uncaught errors: " + problems.slice(0, 5).join(" | "));
  close();
} catch (error) {
  output = { checks: output.checks + 1, failures: [...output.failures, error.message] };
} finally {
  chrome.kill();
  await sleep(200);
  fs.rmSync(profile, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(output));
