// Drives the playground in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// its editor, Monaco, as a client of the language server in the
// compiler's worker: an error is underlined, a hover shows a type,
// completion offers a name, go to definition moves the cursor, the
// outline answers; and that compiling and running still work. It serves
// nothing: tests/test_lsp.py starts `pyk playground` and runs this
// against it.
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
  for (const [name, phase] of [["the page", PAGE], ["the language server", LSP]]) {
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
