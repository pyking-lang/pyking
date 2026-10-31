// Drives the playground in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// its editor, Monaco, as a client of the language server in the
// compiler's worker: an error is underlined, a hover shows a type,
// completion offers a name, go to definition moves the cursor, the
// outline answers; and that compiling and running still work. Then the
// right-hand tabs, the REPL (entries, Tab completion, the environment, Copy from editor,
// Stop), the Debug tab (breakpoints, stepping, the panes, a tinyweb
// callback), the light and dark themes, a link holding a program (Copy
// code as link, then the link opened in the same tab), the settings'
// tabs, every setting saved and restored and an earlier version's
// migrated, Copy for slides (the right-click menu, its key, the editor's
// button, each option, read back off the clipboard), and every command's
// keys changed and pressed for real. It serves nothing:
// tests/test_lsp.py starts `pyk playground` and runs this against it.
//
// Usage: node playground.mjs <chromium> <url>
// Writes {checks, failures} as JSON.

import path from "node:path";

import { progress, start } from "../chromium.mjs";

const [browser, url] = process.argv.slice(2);
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
  await enter('print("hi " + string(double(x)))');
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
  // Stopped there, and done showing it: the buttons are enabled only
  // then, and a click on a disabled one does nothing.
  const stoppedAt = (row, depth) => until(() => dbg.state === "stopped" && dbg.frames.length > 0
    && dbg.frames[0].span.row1 === row && (depth === undefined || dbg.frames.length === depth)
    && !d("continue").disabled, 20000);
  const consoleText = () => d("console").textContent;
  await source("use mutation\\ndef fact(n: Int) -> Int:\\n    if n <= 1:\\n        return 1\\n    return n * fact(n - 1)\\n\\nvar total = 0\\nxs = [1, 2, 3]\\nfor x in xs:\\n    total := total + fact(x)\\nprint(\\"total\\", total)\\n");
  $("[data-tab=debug]").click();
  check("the Debug tab shows its controls", d("start") && !d("start").classList.contains("pyk-hidden")
    && d("environment") && d("watch") && d("stack") && d("breakpointList") && d("console"));
  check("a control's tooltip names its keys", /\\(F10 or (Alt|Option)\\+O\\)/.test(d("next").title), d("next").title);
  check("Debug's tooltip names Continue's keys too",
    /\\((Alt|Option)\\+D or F8 or (Alt|Option)\\+C\\)/.test(d("start").title), d("start").title);
  check("the names pane is called Environment",
    d("environment").closest("details").querySelector("summary").textContent.trim() === "Environment");
  dbg.toggleBreakpoint(4);
  check("a breakpoint shows in the margin",
    await until(() => $$("[data-r=leftEditor] .pyk-bp-glyph.pyk-bp").length === 1));
  check("and in the Breakpoints pane", d("breakpointList").textContent.includes("line 4"),
    d("breakpointList").textContent);
  dbg.watches = ["n * 100"];
  d("start").click();
  check("Debug stops at the breakpoint", await stoppedAt(4, 2), JSON.stringify(dbg.frames));
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
  check("Continue stops at the breakpoint again, one call deeper", await stoppedAt(4, 3), stack());
  $$(".pyk-debug-frame")[2].click();
  check("choosing a frame shows its names",
    await until(() => /total\\s*1\\s*Int/.test(d("environment").textContent)
      && d("environment").textContent.includes("xs")), d("environment").textContent);
  check("and marks its line as a caller's",
    await until(() => $$("[data-r=leftEditor] .pyk-debug-line-caller").length > 0));
  check("a var is offered to be set", $$(".pyk-debug-node .value[title]").length > 0);
  dbg.toggleBreakpoint(4);
  d("out").click();
  check("Step out stops in the caller, at the call", await stoppedAt(5, 2), stack());
  const press = (target, key, code, more = {}) => {
    const event = new KeyboardEvent("keydown", { key, code, bubbles: true, cancelable: true, ...more });
    target.dispatchEvent(event);
    return event.defaultPrevented;
  };
  press($("[data-r=leftEditor] textarea"), "F10", "F10");
  check("the step-over key steps over the rest of the call, to its caller", await stoppedAt(10, 1), stack());
  d("next").click();
  check("Step over goes to the next turn of the loop", await stoppedAt(10, 1), stack());
  $("[data-tab=repl]").click();
  press($("[data-r=replInput]"), "i", "KeyI", { altKey: true });
  check("Alt+I in another tab steps into the call", await stoppedAt(3, 2), stack());
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

  await source("use mutation\\nimport tinyweb as tw\\ntw.web_init(0)\\nvar count = 0\\ndef pressed():\\n    count := count + 1\\n    print(\\"pressed\\", count)\\ntw.button(\\"Count\\", on_click = pressed)\\n");
  dbg.toggleBreakpoint(7);
  d("start").click();
  check("a tinyweb program's top level ends, and the page's events are awaited",
    await until(() => dbg.state === "idle", 20000), dbg.state + " " + d("status").textContent);
  const button = await until(() => $$("[data-r=page] button").find((b) => b.textContent === "Count"));
  $("[data-tab=web]").click();
  button?.click();
  check("a breakpoint in a callback stops when its button is pressed", await stoppedAt(7, 1), stack());
  check("and the Debug tab is shown again", app.tab === "debug", app.tab);
  check("in the callback", stack() === "pressed", stack());
  d("continue").click();
  check("the callback runs on", await until(() => consoleText().includes("pressed 1")), consoleText());
  check("and the page's events are awaited again", await until(() => dbg.state === "idle"), dbg.state);
  d("stop").click();
  check("Stop ends debugging a page", await until(() => dbg.state === "off"), dbg.state);
  dbg.toggleBreakpoint(7);

  const row = (id) => '.pyk-key-row[data-command="' + id + '"]';
  const chips = (id) => $$(row(id) + " .pyk-key-chip").map((c) => c.firstChild.textContent);
  check("the settings show each of an action's keys", chips("debug.next").length === 2
    && chips("debug.next")[0] === "F10", JSON.stringify(chips("debug.next")));
  $(row("debug.next") + " .pyk-key-chip button").click();
  check("✕ removes one key", JSON.stringify(app.settings.keys?.["debug.next"]) === '["Alt+O"]'
    && !/F10/.test(d("next").title), d("next").title);
  $(row("debug.next") + " .pyk-key-add").click();
  press($(row("debug.next") + " .pyk-key-field"), "F9", "F9", { shiftKey: true });
  check("+ records a key pressed", chips("debug.next").join(",") === "Alt+O,Shift+F9"
    || chips("debug.next").join(",") === "Option+O,Shift+F9", JSON.stringify(chips("debug.next")));
  $(row("debug.next") + " .pyk-key-reset").click();
  check("reset gives an action its defaults back", app.settings.keys?.["debug.next"] === undefined
    && chips("debug.next").length === 2, JSON.stringify(app.settings.keys));

  dbg.toggleBreakpoint(1);
  await app.loadExample(app.meta.examples[0].file);
  check("choosing an example removes the breakpoints", await until(() => dbg.breakpoints.length === 0
    && $$("[data-r=leftEditor] .pyk-bp-glyph.pyk-bp").length === 0), JSON.stringify(dbg.breakpoints));
  return checks;
})()`;

// Warnings: underlined as warnings by the language server, shown in the
// output before what the program prints, and set on the settings'
// Warnings tab, which names each flag, says what it means, and turns
// each on, off or into an error -- an error underlined as one, and
// refusing the program.
const WARNINGS = `(async () => { ${HELPERS}
  const command = () => $("[data-r=warningCommand]").textContent;
  const change = (el, value) => {
    el.checked = value;
    el.dispatchEvent(new Event("change"));
  };
  await source("x = 5\\nif true:\\n    x = 10\\nprint(41 + 1)\\n");
  check("an unused binding is underlined as a warning",
    await until(() => markers().length === 2)
      && markers().every((m) => m.severity === monaco.MarkerSeverity.Warning)
      && markers().some((m) => m.message.includes("Did you try to update x as a variable?")),
    JSON.stringify(markers()));
  $("[data-r=runLeft]").click();
  check("Run shows the warnings first, then runs the program",
    await until(() => /42\\n[\\s\\S]*finished/.test(output()), 30000)
      && $$("[data-r=output] .warn").length === 2
      && output().indexOf("Unused binding 'x'") < output().indexOf("42"), output());
  $("[data-r=settingsButton]").click();
  $("[data-settings-tab=warnings]").click();
  const rows = $$(".pyk-warning");
  check("the Warnings tab names every warning's flag, its default and what it means",
    rows.length === 7 && rows[0].textContent.includes("-Wunused-binding")
      && rows[0].textContent.includes("on by default") && rows[0].textContent.includes("-Werror=unused-binding")
      && rows[4].textContent.includes("-Wunused-pattern-var") && rows[4].textContent.includes("off by default")
      && rows.every((r) => r.querySelector(".pyk-hint").textContent.length > 20),
    rows.map((r) => r.textContent).join(" / "));
  check("and the command line its settings stand for", command() === "pyk playground.pyk", command());
  change($("#pyk-warning-unused-binding"), false);
  check("turning one off is a -Wno- flag", command() === "pyk -Wno-unused-binding playground.pyk", command());
  check("and the underlines follow", await until(() => markers().length === 1
    && markers()[0].startLineNumber === 3), JSON.stringify(markers()));
  change($("[data-r=warningsError]"), true);
  check("-Werror makes every warning an error", command() === "pyk -Wno-unused-binding -Werror playground.pyk"
    && $$(".pyk-warning-error input").every((b) => b.checked && b.disabled), command());
  check("underlined as one", await until(() => markers().length === 1
    && markers()[0].severity === monaco.MarkerSeverity.Error), JSON.stringify(markers()));
  $("[data-r=modalClose]").click();
  $("[data-r=runLeft]").click();
  check("and Run refuses the program", await until(() => output().includes("[-Werror=shadowed-update]"), 30000)
    && !output().includes("42"), output());
  $("[data-r=settingsButton]").click();
  $("[data-r=warningsDefaults]").click();
  check("Back to the defaults", command() === "pyk playground.pyk" && !$("[data-r=warningsError]").checked
    && $("#pyk-warning-unused-binding").checked, command());
  $("[data-r=warningsAll]").click();
  check("Turn them all on is -Wall's",
    command() === "pyk -Wunused-pattern-var -Wunused-parameter -Wunused-loop-var playground.pyk", command());
  $("[data-r=warningsNone]").click();
  check("and Turn them all off -w's", command().startsWith("pyk -Wno-unused-binding -Wno-unused-function")
    && $$(".pyk-warning > input").every((b) => !b.checked), command());
  check("with nothing underlined", await until(() => markers().length === 0), JSON.stringify(markers()));
  $("[data-r=warningsDefaults]").click();
  $("[data-r=modalClose]").click();
  await source("print(41 + 1)\\n");
  return checks;
})()`;

// The settings dialog: its six tabs, what each holds, moving between
// them by the keyboard, and that it opens on Appearance again.
const SETTINGS = `(async () => { ${HELPERS}
  const modal = $("[data-r=modal]");
  const tabs = () => $$("[data-r=settingsTabs] [role=tab]");
  const selected = () => tabs().find((t) => t.getAttribute("aria-selected") === "true")?.dataset.settingsTab;
  const panel = (name) => $("[data-settings-panel=" + name + "]");
  const visible = () => $$("[data-settings-panel]").filter((p) => !p.classList.contains("pyk-hidden"))
    .map((p) => p.dataset.settingsPanel);
  $("[data-r=settingsButton]").click();
  check("Settings opens the dialog", !modal.classList.contains("pyk-hidden"));
  check("in six tabs", tabs().map((t) => t.textContent.trim()).join("|")
    === "Appearance|Running|Warnings|Debugger|Copy for slides|Keys", tabs().map((t) => t.textContent));
  check("a tab list of tabs, each controlling its panel",
    $("[data-r=settingsTabs]").getAttribute("role") === "tablist"
    && tabs().every((t) => panel(t.dataset.settingsTab).getAttribute("role") === "tabpanel"
      && t.getAttribute("aria-controls") === panel(t.dataset.settingsTab).id
      && panel(t.dataset.settingsTab).getAttribute("aria-labelledby") === t.id));
  check("it opens on Appearance, with the focus on its tab", selected() === "appearance"
    && visible().join() === "appearance" && document.activeElement === tabs()[0],
    selected() + " " + visible());
  check("only the chosen tab is in the tab order",
    tabs().map((t) => t.tabIndex).join() === "0,-1,-1,-1,-1,-1", tabs().map((t) => t.tabIndex));
  const holds = (name, refs) => refs.every((r) => panel(name).contains($("[data-r=" + r + "]")));
  check("Appearance holds the theme, the font size and the layout",
    holds("appearance", ["themeChoice", "fontSize", "resetLayoutButton"]));
  check("Running holds run while you type, clearing, scrolling and the tinyweb log",
    holds("running", ["autoRun", "clearOnRun", "scrollOutput", "tinywebLogSetting"]));
  check("Warnings holds every warning, -Werror, its buttons and the command line",
    holds("warnings", ["warningList", "warningsError", "warningsAll", "warningsNone",
                       "warningsDefaults", "warningCommand"]));
  check("Debugger holds stopping at the first statement and just my code",
    holds("debugger", ["debugStopOnEntry", "debugJustMyCode"]));
  check("Copy for slides holds every option, the button's switch and a preview",
    holds("slides", ["slidesTheme", "slidesFont", "slidesSize", "slidesBackgroundKind",
                     "slidesColor", "slidesSpaces", "slidesButton", "slidesPreview"]));
  check("Keys holds every command's keys", holds("keys", ["keyList", "keysReset"]));
  const areas = $$(".pyk-key-group").map((g) => g.querySelector(".pyk-key-area").textContent);
  check("grouped by area: Editor, Debugger, REPL", areas.join() === "Editor,Debugger,REPL", areas);
  const commands = $$(".pyk-key-row").map((r) => r.dataset.command);
  check("every command is there", commands.join() === ["run", "copySlides", "debug.start",
    "debug.continue", "debug.next", "debug.in", "debug.out", "debug.stop", "debug.breakpoint",
    "repl.submit", "repl.newline", "repl.previous", "repl.next", "repl.complete"].join(), commands);
  const chipsOf = (id) => $$('.pyk-key-row[data-command="' + id + '"] .pyk-key-chip')
    .map((c) => c.firstChild.textContent).join(",");
  check("with its default keys", chipsOf("run").startsWith("Shift+Enter,Ctrl+Enter")
    && /^(Alt|Option)\\+Shift\\+C$/.test(chipsOf("copySlides")) && chipsOf("repl.submit") === "Enter"
    && chipsOf("repl.previous") === "Up" && chipsOf("repl.complete") === "Tab",
    [chipsOf("run"), chipsOf("copySlides"), chipsOf("repl.submit")]);
  check("and nothing to reset", $$(".pyk-key-reset").every((b) => b.disabled) && $("[data-r=keysReset]").disabled);

  const key = (target, k) => {
    const event = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true });
    target.dispatchEvent(event);
  };
  key(tabs()[0], "ArrowRight");
  check("ArrowRight shows the next tab, and moves the focus there", selected() === "running"
    && visible().join() === "running" && document.activeElement === tabs()[1], selected());
  key(tabs()[1], "End");
  check("End shows the last", selected() === "keys" && document.activeElement === tabs()[5], selected());
  key(tabs()[5], "ArrowRight");
  check("ArrowRight on the last goes round to the first", selected() === "appearance", selected());
  key(tabs()[0], "ArrowLeft");
  check("ArrowLeft on the first goes round to the last", selected() === "keys", selected());
  key(tabs()[5], "Home");
  check("Home shows the first", selected() === "appearance", selected());
  tabs()[4].click();
  check("a click shows a tab", selected() === "slides" && visible().join() === "slides", selected());
  check("Copy for slides previews the snippet", await until(() => $("[data-r=slidesPreview] pre")
    && $("[data-r=slidesPreview]").textContent.includes("def greet"), 20000),
    $("[data-r=slidesPreview]").innerHTML.slice(0, 200));
  $("[data-r=modalClose]").click();
  check("✕ closes it", modal.classList.contains("pyk-hidden"));
  $("[data-r=settingsButton]").click();
  check("and it opens on Appearance again", selected() === "appearance", selected());
  $("[data-r=settingsTabs]").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  check("Escape closes it", modal.classList.contains("pyk-hidden"));
  return checks;
})()`;

// The settings at a phone's width: the dialog inside the screen, and no
// tab's panel wider than the dialog.
const PHONE = `(async () => { ${HELPERS}
  $("[data-r=settingsButton]").click();
  await sleep(200);
  const dialog = $(".pyk-settings-dialog").getBoundingClientRect();
  check("at a phone's width the settings fit the screen", dialog.left >= 0
    && dialog.right <= innerWidth + 1, dialog.left + ".." + dialog.right + " of " + innerWidth);
  for (const tab of $$("[data-r=settingsTabs] [role=tab]")) {
    tab.scrollIntoView({ inline: "nearest" });
    tab.click();
    await sleep(100);
    const body = $(".pyk-settings-body");
    check("and " + tab.textContent + " needs no sideways scrolling",
      body.scrollWidth <= body.clientWidth + 1, body.scrollWidth + " > " + body.clientWidth);
  }
  $("[data-r=modalClose]").click();
  return checks;
})()`;

// Every setting changed through its control, and saved.
const SETTINGS_SET = `(async () => { ${HELPERS}
  localStorage.removeItem("pyking-playground.settings");
  $("[data-r=settingsButton]").click();
  const set = (r, value) => {
    const el = $("[data-r=" + r + "]");
    if (el.type === "checkbox") el.checked = value; else el.value = value;
    el.dispatchEvent(new Event(el.type === "checkbox" || el.tagName === "SELECT" ? "change" : "input"));
  };
  set("themeChoice", "light");
  set("fontSize", "17");
  set("autoRun", true);
  set("clearOnRun", false);
  set("scrollOutput", false);
  set("tinywebLogSetting", true);
  check("the tinyweb log's two switches follow each other", $("[data-r=tinywebLog]").checked);
  set("debugStopOnEntry", true);
  set("debugJustMyCode", false);
  set("slidesTheme", "dark");
  set("slidesFont", "Courier New");
  set("slidesSize", "28");
  set("slidesBackgroundKind", "custom");
  check("a colour of one's choice shows the colour", !$("[data-r=slidesColor]").classList.contains("pyk-hidden"));
  set("slidesColor", "#123456");
  set("slidesSpaces", "all");
  set("slidesButton", true);
  check("the editor's Copy for slides button shows when switched on",
    !$("[data-r=copySlides]").classList.contains("pyk-hidden"));
  set("warningsError", true);
  $('.pyk-key-row[data-command="debug.stop"] .pyk-key-chip button').click();
  const box = $("#pyk-warning-unused-pattern-var");
  box.checked = true;
  box.dispatchEvent(new Event("change"));
  const saved = JSON.parse(localStorage.getItem("pyking-playground.settings"));
  const want = { theme: "light", fontSize: 17, autoRun: true, clearOnRun: false, scrollOutput: false,
    tinywebLog: true, debugStopOnEntry: true, debugJustMyCode: false, slidesTheme: "dark",
    slidesFont: "Courier New", slidesSize: 28, slidesBackground: "#123456", slidesSpaces: "all",
    slidesButton: true, warningsError: true };
  for (const [name, value] of Object.entries(want)) {
    check("saved: " + name, saved?.[name] === value, JSON.stringify(saved?.[name]));
  }
  check("saved: a command's keys", JSON.stringify(saved?.keys) === '{"debug.stop":[]}', JSON.stringify(saved?.keys));
  check("saved: a warning turned on", JSON.stringify(saved?.warnings) === '{"unused-pattern-var":{"on":true}}',
    JSON.stringify(saved?.warnings));
  check("and no debugKeys", saved && !("debugKeys" in saved), JSON.stringify(saved));
  $("[data-r=modalClose]").click();
  return checks;
})()`;

// The same, after the page was loaded again.
const SETTINGS_RESTORED = `(async () => { ${HELPERS}
  const is = (r, value) => {
    const el = $("[data-r=" + r + "]");
    const got = el.type === "checkbox" ? el.checked : el.value;
    check("restored: " + r, got === value, JSON.stringify(got));
  };
  is("themeChoice", "light");
  check("restored: the theme shows", $(".pyk-playground").dataset.theme === "light");
  is("fontSize", "17");
  check("restored: the editor's font size", app.left.getOption(monaco.editor.EditorOption.fontSize) === 17);
  is("autoRun", true);
  is("clearOnRun", false);
  is("scrollOutput", false);
  is("tinywebLogSetting", true);
  is("tinywebLog", true);
  is("debugStopOnEntry", true);
  is("debugJustMyCode", false);
  is("slidesTheme", "dark");
  is("slidesFont", "Courier New");
  is("slidesSize", "28");
  is("slidesBackgroundKind", "custom");
  is("slidesColor", "#123456");
  is("slidesSpaces", "all");
  is("slidesButton", true);
  is("warningsError", true);
  check("restored: a warning turned on", $("#pyk-warning-unused-pattern-var").checked
    && $("[data-r=warningCommand]").textContent === "pyk -Wunused-pattern-var -Werror playground.pyk",
    $("[data-r=warningCommand]").textContent);
  check("restored: the editor's button", !$("[data-r=copySlides]").classList.contains("pyk-hidden"));
  check("restored: a command's keys",
    $$('.pyk-key-row[data-command="debug.stop"] .pyk-key-chip').length === 0
    && !$('.pyk-key-row[data-command="debug.stop"] .pyk-key-reset').disabled
    && /no key/.test(app.debugger.ui.stop.title), app.debugger.ui.stop.title);
  return checks;
})()`;

// Settings an earlier version saved: the debugger's keys as debugKeys.
const SETTINGS_MIGRATED = `(async () => { ${HELPERS}
  const chips = (id) => $$('.pyk-key-row[data-command="' + id + '"] .pyk-key-chip')
    .map((c) => c.dataset.spec).join(",");
  check("an earlier version's debugKeys are the debugger's keys",
    chips("debug.next") === "F7" && chips("debug.start") === "Alt+G" && chips("debug.stop") === "Alt+S",
    [chips("debug.next"), chips("debug.start"), chips("debug.stop")]);
  check("shown on its buttons", /\\(F7\\)/.test(app.debugger.ui.next.title), app.debugger.ui.next.title);
  check("with what else was saved", app.settings.fontSize === 15, app.settings.fontSize);
  const saved = JSON.parse(localStorage.getItem("pyking-playground.settings"));
  check("and saved again as keys", JSON.stringify(saved.keys) === '{"debug.next":["F7"],"debug.start":["Alt+G"]}'
    && !("debugKeys" in saved), JSON.stringify(saved));
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

/** What a Mac's Option types with a letter, which the page sees as the
 *  key's text: Option+Shift with a letter is the letter's entry with a
 *  `+` after it. */
const MAC_OPTION = {
  D: "∂", C: "ç", O: "ø", I: "ˆ", T: "†", S: "ß", B: "∫", R: "®", K: "˚", G: "©", J: "∆",
  X: "≈", Y: "¥", Q: "œ", W: "∑", P: "π", "C+": "Ç",
};

/** A key pressed for real, through the browser's input, as a reader on
 *  a Mac (`mac`) or elsewhere presses it: `spec` as keys.js writes it,
 *  Mod being Cmd on a Mac and Ctrl elsewhere.
 *  (send, String, String, Bool) -> Promise<()> */
async function pressKey(send, sessionId, spec, mac) {
  const parts = spec.split("+");
  const name = parts.pop();
  const has = (m) => parts.includes(m);
  const alt = has("Alt");
  const shift = has("Shift");
  const ctrl = has("Ctrl") || (has("Mod") && !mac);
  const meta = has("Mod") && mac;
  const special = {
    Enter: { key: "Enter", code: "Enter", vk: 13, text: "\r" },
    Up: { key: "ArrowUp", code: "ArrowUp", vk: 38 },
    Down: { key: "ArrowDown", code: "ArrowDown", vk: 40 },
    Tab: { key: "Tab", code: "Tab", vk: 9 },
  };
  let key;
  let code;
  let vk;
  let text;
  if (special[name]) ({ key, code, vk, text } = special[name]);
  else if (/^F[0-9]+$/.test(name)) [key, code, vk] = [name, name, 111 + Number(name.slice(1))];
  else {
    code = "Key" + name;
    vk = name.charCodeAt(0);
    text = alt ? MAC_OPTION[name + (shift ? "+" : "")] : shift ? name : name.toLowerCase();
    key = text;
  }
  if (ctrl || meta) {
    text = undefined;
    if (!special[name] && !/^F/.test(name)) key = name.toLowerCase();
  }
  const common = { key, code, windowsVirtualKeyCode: vk,
                   modifiers: (alt ? 1 : 0) | (ctrl ? 2 : 0) | (meta ? 4 : 0) | (shift ? 8 : 0) };
  await send("Input.dispatchKeyEvent",
    { type: text ? "keyDown" : "rawKeyDown", text, unmodifiedText: text, ...common }, sessionId);
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...common }, sessionId);
  await sleep(150);
}

/** A real click at a point of the page. (send, String, Number, Number) -> Promise<()> */
async function clickAt(send, sessionId, x, y) {
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y }, sessionId);
  await send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 }, sessionId);
  await send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 }, sessionId);
  await sleep(150);
}

/** Polls `test` until it answers true, for up to `ms`. */
async function waitFor(test, ms = 20000) {
  for (let waited = 0; waited < ms; waited += 100) {
    if (await test()) return true;
    await sleep(100);
  }
  return false;
}

/** In the page: what is on the clipboard, each kind's text, and the
 *  HTML's <pre> read back -- its style and its text. */
const READ_CLIPBOARD = `(async () => {
  const items = await navigator.clipboard.read();
  const out = { types: [] };
  for (const item of items) {
    for (const type of item.types) {
      out.types.push(type);
      out[type] = await (await item.getType(type)).text();
    }
  }
  if (out["text/html"]) {
    const pre = new DOMParser().parseFromString(out["text/html"], "text/html").querySelector("pre");
    out.preStyle = pre?.getAttribute("style") ?? "";
    out.preText = pre?.textContent ?? "";
    out.coloured = pre ? pre.querySelectorAll("span[style*=color]").length : 0;
  }
  return out;
})()`;

/** Copy for slides: from the right-click menu, by its key, by the
 *  editor's button and without ClipboardItem, for the selection and for
 *  the whole program, read back off the clipboard as HTML and as plain
 *  text; then each of its options. `full` adds the menu, the button and
 *  the options, which are the same on every platform.
 *  (send, String, evaluate, String, Bool, Bool) -> Promise<[[label, ok, detail]]> */
async function copyChecks(send, sessionId, evaluate, platform, mac, full) {
  const checks = [];
  const check = (label, ok, detail = "") =>
    checks.push([`${label} (${platform})`, Boolean(ok), String(detail).slice(0, 300)]);
  const app = "window.pykingPlayground";
  const program = "def f(n: Int) -> Int:\n    return n * 2\n\nprint(f(21))\n";
  const nb = " ".repeat(4);
  const whole = program.replace("    return", nb + "return");
  const selected = "def f(n: Int) -> Int:\n" + nb + "return n * 2\n";
  const clear = () => evaluate(`navigator.clipboard.writeText("-")`);
  const clipboard = () => evaluate(READ_CLIPBOARD);
  const copied = async () => {
    let got = null;
    await waitFor(async () => {
      got = await clipboard();
      return got["text/plain"] !== "-";
    }, 15000);
    return got;
  };
  const status = () => evaluate(`document.querySelector("[data-r=statusText]").textContent`);
  const editor = () => evaluate(`${app}.left.getValue()`);
  await evaluate(`${app}.showTab("run"); ${app}.setSource(${JSON.stringify(program)}); `
    + `${app}.left.focus(); ${app}.left.setPosition({ lineNumber: 1, column: 1 })`);
  await sleep(300);

  if (full) {
    await clear();
    await evaluate(`${app}.left.trigger("test", "editor.action.showContextMenu", null)`);
    // Once the menu has settled where it shows.
    const item = await waitFor(async () => (await evaluate(MENU_ITEM)) !== null, 5000)
      ? (await sleep(400), await evaluate(MENU_ITEM)) : null;
    check("the editor's right-click menu has Copy for Slides", item, "no item");
    const labels = item?.labels ?? [];
    const at = labels.indexOf("Copy for Slides");
    check("beside Copy, before Paste", at > 0 && labels[at - 1] === "Copy" && labels[at + 1] === "Paste",
      JSON.stringify(labels));
    check("naming its key", /Alt|⌥/.test(item?.keys ?? "") && /C/.test(item?.keys ?? ""), item?.keys);
    if (item) await clickAt(send, sessionId, item.x, item.y);
    const menu = await copied();
    check("choosing it copies the whole program, as plain text with the indentation non-breaking",
      menu["text/plain"] === whole, JSON.stringify(menu["text/plain"]));
    check("and as HTML: a <pre> with its colours inline", menu.types.includes("text/html")
      && menu.coloured >= 3 && /color/.test(menu.preStyle) && menu.preText === whole.replace(/\n$/, ""),
      JSON.stringify([menu.preStyle, menu.preText, menu.coloured]));
    check("in Menlo, the default font", /Menlo/.test(menu.preStyle), menu.preStyle);
    check("with no size and no background by default",
      !/font-size/.test(menu.preStyle) && !/background/.test(menu.preStyle), menu.preStyle);
    check("the status line says what was copied",
      /copied the program \(4 lines\) for slides/.test(await status()), await status());
  }

  await clear();
  await evaluate(`${app}.left.focus(); ${app}.left.setSelection(new monaco.Range(1, 1, 3, 1))`);
  await pressKey(send, sessionId, "Alt+Shift+C", mac);
  const key = await copied();
  check("Alt+Shift+C copies the selection", key["text/plain"] === selected,
    JSON.stringify(key["text/plain"]));
  check("as HTML too", key.preText === selected.replace(/\n$/, "") && key.coloured >= 2,
    JSON.stringify(key.preText));
  check("and types nothing", (await editor()) === program, JSON.stringify(await editor()));
  check("the status line says the selection was copied",
    /copied the selection \(2 lines\) for slides/.test(await status()), await status());
  if (mac) {
    const title = await evaluate(`document.querySelector("[data-r=copySlides]").title`);
    check("its key is named as a Mac's keyboard names it", /Option\+Shift\+C/.test(title), title);
  }
  if (mac) {
    // Run's keys on a Mac: Cmd+Enter and Ctrl+Enter, two keys there.
    for (const spec of ["Mod+Enter", "Ctrl+Enter"]) {
      await evaluate(`${app}.clearOutput(); ${app}.left.focus(); ${app}.left.setPosition({ lineNumber: 1, column: 1 })`);
      await pressKey(send, sessionId, spec, mac);
      const ran = await waitFor(async () => /42\n[\s\S]*finished/.test(
        await evaluate(`document.querySelector("[data-r=output]").textContent`)), 30000);
      check(`${spec.replace("Mod", "Cmd")} runs the program`, ran && (await editor()) === program,
        JSON.stringify(await editor()));
    }
  }

  // Without ClipboardItem, the copy a key press makes carries both.
  await clear();
  await evaluate(`window.savedClipboardItem = window.ClipboardItem; window.ClipboardItem = undefined; `
    + `${app}.left.focus(); ${app}.left.setPosition({ lineNumber: 1, column: 1 })`);
  await pressKey(send, sessionId, "Alt+Shift+C", mac);
  const fallback = await copied();
  await evaluate(`window.ClipboardItem = window.savedClipboardItem`);
  check("without ClipboardItem it copies the whole program by a copy event",
    fallback["text/plain"] === whole && fallback.preText === whole.replace(/\n$/, ""),
    JSON.stringify([fallback["text/plain"], fallback.types]));
  if (!full) return checks;

  check("the editor has no Copy for slides button by default",
    await evaluate(`document.querySelector("[data-r=copySlides]").classList.contains("pyk-hidden")`));
  await evaluate(`(() => { const box = document.querySelector("[data-r=slidesButton]"); `
    + `box.checked = true; box.dispatchEvent(new Event("change")); })()`);
  const button = await evaluate(`(() => { const b = document.querySelector("[data-r=copySlides]"); `
    + `if (b.closest(".pyk-hidden")) return null; const r = b.getBoundingClientRect(); `
    + `return { x: r.x + r.width / 2, y: r.y + r.height / 2, title: b.title }; })()`);
  check("switched on in the settings, it shows", button, "hidden");
  check("its tooltip names the key", /\((Alt|Option)\+Shift\+C\)/.test(button?.title ?? ""), button?.title);
  await clear();
  await evaluate(`${app}.left.setSelection(new monaco.Range(4, 1, 4, 13))`);
  if (button) await clickAt(send, sessionId, button.x, button.y);
  const pressed = await copied();
  check("pressing it copies the selection", pressed["text/plain"] === "print(f(21))",
    JSON.stringify(pressed["text/plain"]));
  await evaluate(`(() => { const box = document.querySelector("[data-r=slidesButton]"); `
    + `box.checked = false; box.dispatchEvent(new Event("change")); })()`);
  check("switched off, it goes",
    await evaluate(`document.querySelector("[data-r=copySlides]").classList.contains("pyk-hidden")`));

  // Each option, set in the settings, and what it does to what is copied.
  const set = (r, value) => evaluate(`(() => { const el = document.querySelector("[data-r=${r}]"); `
    + `el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input")); })()`);
  const copy = async () => {
    await clear();
    await evaluate(`${app}.left.setPosition({ lineNumber: 1, column: 1 }); ${app}.copyForSlides()`);
    return copied();
  };
  const light = await copy();
  await set("slidesTheme", "dark");
  const dark = await copy();
  const luminance = (style) => {
    const m = /(?:^|;)\s*color:\s*(?:#([0-9a-f]{6})|rgb\((\d+), (\d+), (\d+)\))/i.exec(style);
    if (!m) return null;
    const [r, g, b] = m[1] ? [0, 2, 4].map((k) => parseInt(m[1].slice(k, k + 2), 16)) : m.slice(2).map(Number);
    return r + g + b;
  };
  check("light colours: dark text", luminance(light.preStyle) !== null && luminance(light.preStyle) < 384,
    light.preStyle);
  check("dark colours: light text", luminance(dark.preStyle) > 384, dark.preStyle);
  check("and other colours for the words", light["text/html"] !== dark["text/html"]);
  await set("slidesTheme", "light");
  await set("slidesFont", "Courier New");
  const font = await copy();
  check("the font", /Courier New/.test(font.preStyle), font.preStyle);
  await set("slidesFont", "");
  await set("slidesSize", "28");
  const size = await copy();
  check("the size, in points", /font-size:\s*28pt/.test(size.preStyle), size.preStyle);
  await set("slidesSize", "");
  check("blank size: none", !/font-size/.test((await copy()).preStyle));
  await set("slidesBackgroundKind", "theme");
  const themed = await copy();
  check("the colours' background", /background/.test(themed.preStyle), themed.preStyle);
  await set("slidesBackgroundKind", "custom");
  await set("slidesColor", "#123456");
  const custom = await copy();
  check("a background of one's choice", /background(-color)?:\s*(#123456|rgb\(18, 52, 86\))/i.test(custom.preStyle),
    custom.preStyle);
  await set("slidesBackgroundKind", "none");
  check("no background", !/background/.test((await copy()).preStyle));
  await set("slidesSpaces", "all");
  const all = await copy();
  check("every space non-breaking", all["text/plain"] === program.replace(/ /g, " ")
    && all.preText === program.replace(/ /g, " ").replace(/\n$/, ""), JSON.stringify(all["text/plain"]));
  await set("slidesSpaces", "none");
  const plain = await copy();
  check("plain spaces", plain["text/plain"] === program && plain.preText === program.replace(/\n$/, ""),
    JSON.stringify(plain["text/plain"]));
  await set("slidesSpaces", "indent");
  const indent = await copy();
  check("non-breaking indentation again", indent["text/plain"] === whole, JSON.stringify(indent["text/plain"]));
  const preview = await evaluate(`(async () => { document.querySelector("[data-r=settingsButton]").click(); `
    + `document.querySelector("[data-settings-tab=slides]").click(); `
    + `const box = document.querySelector("[data-r=slidesPreview]"); `
    + `const el = document.querySelector("[data-r=slidesSize]"); el.value = "31"; el.dispatchEvent(new Event("input")); `
    + `for (let k = 0; k < 100 && !/31pt/.test(box.innerHTML); k++) await new Promise((r) => setTimeout(r, 100)); `
    + `const html = box.innerHTML; el.value = ""; el.dispatchEvent(new Event("input")); `
    + `document.querySelector("[data-r=modalClose]").click(); return html; })()`);
  check("the preview follows the options as they change", /font-size:\s*31pt/.test(preview), preview.slice(0, 200));
  return checks;
}

/** In the page: the right-click menu's Copy for Slides, where it is and
 *  its key, and every label of the menu in order -- or null. */
const MENU_ITEM = `(() => {
  const roots = [document, ...[...document.querySelectorAll(".shadow-root-host")].map((h) => h.shadowRoot)]
    .filter(Boolean);
  for (const root of roots) {
    for (const item of root.querySelectorAll(".monaco-menu .action-item")) {
      if (item.querySelector(".action-label")?.textContent.trim() !== "Copy for Slides") continue;
      const box = item.getBoundingClientRect();
      return { x: box.x + box.width / 2, y: box.y + box.height / 2,
               keys: item.querySelector(".keybinding")?.textContent ?? "",
               labels: [...root.querySelectorAll(".monaco-menu .action-item .action-label")]
                 .map((l) => l.textContent.trim()).filter(Boolean) };
    }
  }
  return null;
})()`;

/** Every command's keys changed in the settings -- recorded by pressing
 *  the new key for real -- and the new keys working where the old ones
 *  no longer do; then reset, per command and all at once.
 *  (send, String, evaluate, Bool) -> Promise<[[label, ok, detail]]> */
async function keyChecks(send, sessionId, evaluate, mac) {
  const checks = [];
  const check = (label, ok, detail = "") => checks.push([label, Boolean(ok), String(detail).slice(0, 300)]);
  const app = "window.pykingPlayground";
  const press = (spec) => pressKey(send, sessionId, spec, mac);
  const row = (id) => `document.querySelector('.pyk-key-row[data-command="${id}"]')`;
  const specs = (id) => evaluate(`[...${row(id)}.querySelectorAll(".pyk-key-chip")].map((c) => c.dataset.spec).join(",")`);
  // A command's keys made `keys`, through the Keys tab: each chip removed
  // by its ✕, each new key pressed after +.
  const setKeys = async (id, keys) => {
    await evaluate(`document.querySelector("[data-r=settingsButton]").click(); `
      + `document.querySelector("[data-settings-tab=keys]").click()`);
    while ((await specs(id)) !== "") await evaluate(`${row(id)}.querySelector(".pyk-key-chip button").click()`);
    for (const key of keys) {
      await evaluate(`${row(id)}.querySelector(".pyk-key-add").click()`);
      await press(key);
    }
    await evaluate(`document.querySelector("[data-r=modalClose]").click()`);
  };
  const assigned = {
    run: ["Alt+R"], copySlides: ["Alt+K"], "debug.start": ["Alt+G"], "debug.continue": ["Alt+J"],
    "debug.next": ["Alt+X"], "debug.in": ["Alt+Y"], "debug.out": ["Alt+Q"], "debug.stop": ["Alt+W"],
    "debug.breakpoint": ["Alt+P"], "repl.submit": ["Mod+Enter"], "repl.newline": ["Enter"],
    "repl.previous": ["Alt+Up"], "repl.next": ["Alt+Down"], "repl.complete": ["F2"],
  };
  for (const [id, keys] of Object.entries(assigned)) {
    await setKeys(id, keys);
    check(`the Keys tab records ${id}'s new key`, (await specs(id)) === keys.join(","), await specs(id));
  }
  const saved = await evaluate(`localStorage.getItem("pyking-playground.settings")`);
  check("and the settings keep them", JSON.stringify(JSON.parse(saved).keys) === JSON.stringify(assigned), saved);

  // Run.
  const program = "a = 1\nb = a + 1\ndef f(n: Int) -> Int:\n    return n * 2\nc = f(b)\nprint(c)\n";
  const editor = () => evaluate(`${app}.left.getValue()`);
  const output = () => evaluate(`document.querySelector("[data-r=output]").textContent`);
  const fresh = async (line = 1) => {
    await evaluate(`${app}.debugger.stop({ quiet: true }); ${app}.setSource(${JSON.stringify(program)}); `
      + `${app}.showTab("run"); ${app}.clearOutput(); ${app}.left.focus(); `
      + `${app}.left.setPosition({ lineNumber: ${line}, column: 1 })`);
    await sleep(200);
  };
  await fresh();
  await press("Alt+R");
  check("Run's new key runs the program", await waitFor(async () => /4\n[\s\S]*finished/.test(await output())),
    await output());
  check("and types nothing", (await editor()) === program, JSON.stringify(await editor()));
  check("Run's tooltip names it", /\((Alt|Option)\+R\)/.test(await evaluate(`document.querySelector("[data-r=runLeft]").title`)),
    await evaluate(`document.querySelector("[data-r=runLeft]").title`));
  await fresh();
  await press("Shift+Enter");
  await sleep(500);
  check("its old key no longer runs: Shift+Enter types a newline", (await editor()) === "\n" + program
    && !/finished/.test(await output()), JSON.stringify([await editor(), await output()]));
  await fresh();
  await evaluate(`document.querySelector("[data-r=example]").focus()`);
  await press("Alt+R");
  check("the new key runs from outside the editors too",
    await waitFor(async () => /finished/.test(await output())), await output());

  // Copy for slides.
  await fresh();
  await evaluate(`navigator.clipboard.writeText("-")`);
  await press("Alt+K");
  check("Copy for slides' new key copies", await waitFor(async () =>
    (await evaluate(`navigator.clipboard.readText()`)).startsWith("a = 1\nb")), await evaluate(`navigator.clipboard.readText()`));
  check("and types nothing", (await editor()) === program, JSON.stringify(await editor()));

  // The debugger's seven.
  const state = () => evaluate(`${app}.debugger.state`);
  const where = () => evaluate(`JSON.stringify(${app}.debugger.frames.map((f) => f.span.row1))`);
  const stoppedAt = (rows) => waitFor(async () => (await state()) === "stopped" && (await where()) === JSON.stringify(rows));
  await fresh(5);
  await evaluate(`${app}.debugger.clearBreakpoints()`);
  await press("Alt+P");
  check("the breakpoint's new key sets one", await waitFor(async () =>
    (await evaluate(`JSON.stringify(${app}.debugger.breakpoints.map((b) => b.line))`)) === "[5]"));
  await press("Alt+G");
  check("Start's new key starts debugging, to the breakpoint", await stoppedAt([5]), await where());
  await press("Alt+Y");
  check("Step into's new key steps into the call", await stoppedAt([4, 5]), await where());
  await press("Alt+Q");
  check("Step out's new key steps out", await waitFor(async () => (await state()) === "stopped"
    && JSON.parse(await where()).length === 1), await where());
  await press("Alt+X");
  check("Step over's new key steps over", await waitFor(async () => (await state()) === "stopped"
    && JSON.parse(await where())[0] === 6), await where());
  await press("Alt+W");
  check("Stop's new key stops", await waitFor(async () => (await state()) === "off"), await state());
  await press("Alt+J");
  check("Continue's new key starts debugging when nothing is", await stoppedAt([5]), await where());
  await press("Alt+J");
  check("and runs it to its end", await waitFor(async () => (await state()) === "off"), await state());
  check("none of them typed anything", (await editor()) === program, JSON.stringify(await editor()));
  check("the debugger's buttons name the new keys",
    /\((Alt|Option)\+X\)/.test(await evaluate(`${app}.debugger.ui.next.title`)),
    await evaluate(`${app}.debugger.ui.next.title`));
  await evaluate(`${app}.debugger.clearBreakpoints()`);

  // The REPL's five.
  const input = `document.querySelector("[data-r=replInput]")`;
  const value = () => evaluate(`${input}.value`);
  const log = () => evaluate(`document.querySelector("[data-r=replLog]").textContent`);
  await evaluate(`${app}.showTab("repl")`);
  await waitFor(async () => (await log()).includes("Pyking REPL"), 30000);
  await evaluate(`${input}.focus()`);
  await send("Input.insertText", { text: "kilo = 4" }, sessionId);
  await press("Enter");
  check("the REPL's new line key opens a line", await waitFor(async () => (await value()) === "kilo = 4\n"),
    JSON.stringify(await value()));
  await press("Mod+Enter");
  check("its new submit key submits the entry", await waitFor(async () => (await log()).includes("> kilo = 4")),
    await log());
  await waitFor(async () => !(await evaluate(`${app}.replBusy`)));
  await evaluate(`${input}.focus()`);
  await send("Input.insertText", { text: "kilo * 10" }, sessionId);
  await press("Mod+Enter");
  check("a whole line too", await waitFor(async () => (await log()).includes("40 : Int")), await log());
  await waitFor(async () => !(await evaluate(`${app}.replBusy`)));
  await evaluate(`${input}.focus()`);
  await press("Up");
  check("Up no longer goes back", (await value()) === "", JSON.stringify(await value()));
  await press("Alt+Up");
  check("the previous entry's new key does", (await value()) === "kilo * 10", JSON.stringify(await value()));
  await press("Alt+Up");
  check("again", (await value()) === "kilo = 4", JSON.stringify(await value()));
  await press("Alt+Down");
  check("the next entry's new key comes forward", (await value()) === "kilo * 10", JSON.stringify(await value()));
  await press("Alt+Down");
  await evaluate(`${input}.value = ""`);
  await send("Input.insertText", { text: "kil" }, sessionId);
  await press("F2");
  check("the complete key's new key completes", await waitFor(async () => (await value()) === "kilo"),
    JSON.stringify(await value()));

  // Reset: one command, then all of them.
  await evaluate(`document.querySelector("[data-r=settingsButton]").click(); `
    + `document.querySelector("[data-settings-tab=keys]").click(); `
    + `${row("repl.submit")}.querySelector(".pyk-key-reset").click()`);
  check("reset gives one command its keys back", (await specs("repl.submit")) === "Enter"
    && (await specs("repl.newline")) === "Enter", await specs("repl.submit"));
  await evaluate(`document.querySelector("[data-r=keysReset]").click(); `
    + `document.querySelector("[data-r=modalClose]").click()`);
  const after = JSON.parse(await evaluate(`localStorage.getItem("pyking-playground.settings")`));
  check("Reset all the keys gives every command its defaults", JSON.stringify(after.keys) === "{}"
    && (await specs("run")).startsWith("Shift+Enter"), JSON.stringify(after.keys));
  await evaluate(`${input}.value = ""; ${input}.focus()`);
  await send("Input.insertText", { text: "kilo + 1" }, sessionId);
  await press("Enter");
  check("and Enter submits again", await waitFor(async () => (await log()).includes("5 : Int")), await log());
  await fresh();
  await press("Shift+Enter");
  check("and Shift+Enter runs again", await waitFor(async () => /finished/.test(await output())), await output());
  return checks;
}

let output = { checks: 0, failures: [] };
let chrome = null;
try {
  const problems = [];
  chrome = await start(browser, "pyk-playground-", (data) => {
    if (data.method === "Runtime.exceptionThrown") {
      problems.push(data.params.exceptionDetails.exception?.description
                    || data.params.exceptionDetails.text);
    }
  });
  const { send } = chrome;
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  // The clipboard, written by Copy for slides and read back here.
  await send("Browser.grantPermissions", { origin: new URL(url).origin,
    permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"] });
  await send("Emulation.setFocusEmulationEnabled", { enabled: true }, sessionId);
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
  const record = (label, ok, detail) => {
    output.checks += 1;
    if (!ok) output.failures.push(`${label}${detail ? ": " + detail : ""}`);
  };
  const phase = async (name, script) => {
    progress(`checking ${name}`);
    for (const [label, ok, detail] of await evaluate(script)) record(label, ok, detail);
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
  for (const [name, script] of [["the page", PAGE], ["the language server", LSP], ["the warnings", WARNINGS],
                                ["the tabs", TABS], ["the REPL", REPL], ["the debugger", DEBUG],
                                ["the themes", THEME], ["a link", LINK],
                                ["the settings' tabs", SETTINGS], ["every setting saved", SETTINGS_SET]]) {
    await phase(name, script);
  }
  const KEY = '"pyking-playground.settings"';
  await reload();
  await phase("every setting restored", SETTINGS_RESTORED);
  await evaluate(`localStorage.setItem(${KEY}, JSON.stringify({ fontSize: 15, `
    + `debugKeys: { next: "F7", start: ["Alt+G"] } }))`);
  await reload();
  await phase("an earlier version's settings", SETTINGS_MIGRATED);
  await evaluate(`localStorage.removeItem(${KEY})`);
  await send("Emulation.setDeviceMetricsOverride",
             { width: 390, height: 800, deviceScaleFactor: 1, mobile: false }, sessionId);
  await reload();
  await phase("the settings on a phone", PHONE);
  await send("Emulation.setDeviceMetricsOverride",
             { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false }, sessionId);
  await reload();
  // Copy for slides and every command's keys, pressed for real through
  // the browser's input, so a key the playground does not swallow types
  // into the editor; what is copied is read back off the clipboard.
  progress("checking Copy for slides");
  for (const [label, ok, detail] of await copyChecks(send, sessionId, evaluate, "this platform", false, true)) {
    record(label, ok, detail);
  }
  progress("checking every command's keys changed");
  for (const [label, ok, detail] of await keyChecks(send, sessionId, evaluate, false)) {
    record(label, ok, detail);
  }
  await evaluate(`localStorage.removeItem(${KEY})`);
  await reload();
  // The debugger's keys pressed for real: once as this platform, once as
  // a Mac, and Copy for slides' key as a Mac.
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
  progress("checking Copy for slides on a Mac");
  for (const [label, ok, detail] of await copyChecks(send, sessionId, evaluate, "a Mac", true, false)) {
    record(label, ok, detail);
  }
  output.checks += 1;
  if (problems.length) output.failures.push("no uncaught errors: " + problems.slice(0, 5).join(" | "));
} catch (error) {
  output = { checks: output.checks + 1, failures: [...output.failures, error.message] };
} finally {
  if (chrome) await chrome.stop();
}
process.stdout.write(JSON.stringify(output));
