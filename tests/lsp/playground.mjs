// Drives the playground in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// its editor, Monaco, as a client of the language server in the
// compiler's worker: an error is underlined, a hover shows a type,
// completion offers a name, go to definition moves the cursor, the
// outline answers; and that compiling and running still work. Then the
// right-hand tabs, the REPL (entries, the environment, Copy from editor,
// Stop) and the light and dark themes. It serves nothing:
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
  target.value = "python14";
  target.dispatchEvent(new Event("change"));
  $("[data-r=compile]").click();
  const compiled = await until(() => app.right.getValue().includes("print"));
  check("Compile to python shows the generated code", compiled, app.right.getValue());
  check("in Python", app.right.getModel().getLanguageId() === "python",
    app.right.getModel().getLanguageId());
  check("highlighted", await until(() => new Set($$("[data-r=rightEditor] .view-lines span span")
      .map((s) => s.className)).size >= 2), "one token class");

  $("[data-r=runLeft]").click();
  const ran = await until(() => /finished/.test(output()), 30000);
  check("Run prints what the program prints", ran && output().includes("3\\n"), output());
  return checks;
})()`;

const TABS = `(async () => { ${HELPERS}
  const shown = (r) => !$("[data-r=" + r + "]").closest(".pyk-hidden");
  const active = () => $(".pyk-tab.active")?.dataset.tab;
  check("there are five tabs", $$(".pyk-tab").map((t) => t.textContent).join("|")
    === "Run output|Compiled code|Web output|REPL|Help", $$(".pyk-tab").map((t) => t.textContent));
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
  app.stopRun();
  await until(() => !app.running);

  $("[data-r=tabHelp]").click();
  check("the Help tab shows the help, with its menu above the page",
    await until(() => $(".pyk-help-menu a") && $(".pyk-help-page h1")?.textContent, 30000),
    $("[data-r=helpHost]").textContent.slice(0, 120));
  const menu = $(".pyk-help-menu").getBoundingClientRect().height;
  const panel = $("[data-r=panelHelp]").getBoundingClientRect().height;
  check("the menu takes at most a quarter of the tab", menu <= panel / 4 + 1, menu + " of " + panel);
  [...$$(".pyk-help-menu a")].find((a) => a.textContent === "io").click();
  check("a library's page opens, its functions boxed",
    await until(() => $$(".pyk-help-page .pyk-api").length >= 4, 20000),
    $(".pyk-help-page h1")?.textContent);
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
  check("and the new session works", rows().join("|") === "z 5 Int", rows());
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
  if (!ready) throw new Error("the playground did not become ready");
  for (const [name, phase] of [["the page", PAGE], ["the language server", LSP],
                               ["the tabs", TABS], ["the REPL", REPL],
                               ["the themes", THEME]]) {
    progress(`checking ${name}`);
    for (const [label, ok, detail] of await evaluate(phase)) {
      output.checks += 1;
      if (!ok) output.failures.push(`${label}${detail ? ": " + detail : ""}`);
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
