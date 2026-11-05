// Drives the website's shell, tools/site/public/site/shell.js, in a real,
// headless Chromium: that each section of the site is kept open as the
// reader left it while another is shown. It serves pages of its own, one
// per section of tools/site/src/sections.mjs, each with the header's tabs
// and some links, under a base
// path as a site on GitHub Pages has -- so it needs no Astro and no
// built website -- and checks: the window the reader opened becomes the
// shell, with the page in a frame; a section's tab shows that section as
// it was left (the same document, scrolled where it was, a script's
// state kept); a link to another section shows that page of it; a link
// within a section is followed in its frame; the address bar, the title
// and Back follow; a hidden section is told so; a theme picked in one
// section is every section's; and a page opened with ?noshell, a page
// that is no section's and a page in another page's frame are plain
// pages. Then a new build: when version.json names another build than the
// page's, the window is reloaded onto it only when nothing is busy and
// the reader has left it alone, or when it is hidden; each page keeps
// what it can first, the sections open again where they were, a reload
// that came back as the old build is not repeated, and a plain page is
// reloaded too. Last, a link to another site replaces the whole window.
//
// Usage: node shell.mjs <chromium>
// Writes {checks, failures} as JSON. tests/test_site.py runs it.

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { progress, start } from "../chromium.mjs";
import { SECTIONS as SITE_SECTIONS } from "../../tools/site/src/sections.mjs";

const [browser] = process.argv.slice(2);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const SHELL = path.join(HERE, "..", "..", "tools", "site", "public", "site", "shell.js");
const BASE = "/pk";
// The site's own sections, keyed as astro.config.mjs keys them.
const SECTIONS = SITE_SECTIONS.map((s) => ({ ...s, key: s.prefix.replace(/\//g, "") }));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// The build the pages say they are, and the one version.json names: the
// same until a check of a new build changes them.
const builds = { page: "b1", named: "b1" };
// How long a reader must leave a page alone before it is reloaded under
// them, and how often a busy page is asked again: short, for the test.
const IDLE = 1500;
const RETRY = 100;

// A page of the site: the header -- the logo and the tabs -- and `body`.
// Every page in a frame counts the times it was loaded in sessionStorage,
// and every page records each `pyking:visibility` event it hears.
function page(title, body) {
  const sections = JSON.stringify(SECTIONS.map(({ key, label, prefix }) => ({ key, label, prefix })));
  const tabs = SECTIONS.map(({ label, path: to }) => `<a href="${BASE}${to}">${label}</a>`).join("\n");
  return `<!doctype html>
<html><head><meta charset="utf-8"><title>${title} | Pyking</title>
<script src="${BASE}/site/shell.js" data-base="${BASE}" data-sections='${sections}'
  data-build="BUILD" data-update="3600000 ${IDLE} ${RETRY}"></script>
</head><body>
<header><a class="site-title" href="${BASE}/">Pyking</a><nav class="pyking-nav">${tabs}</nav></header>
<main>${body}</main>
<script>
  if (!document.documentElement.classList.contains("pyking-shell")) {
    window.loads = Number(sessionStorage.getItem(location.pathname) || 0) + 1;
    sessionStorage.setItem(location.pathname, String(window.loads));
  }
  window.heard = [];
  addEventListener("pyking:visibility", (event) => heard.push(event.detail.hidden));
  window.shellStartedHere = document.documentElement.classList.contains("pyking-shell");
  // Busy when a test says so; counts the times it was asked to keep
  // what it could before a reload.
  window.pykingUpdate = {
    busy: () => window.busyNow === true,
    save: () => sessionStorage.setItem("saved:" + location.pathname,
      String(Number(sessionStorage.getItem("saved:" + location.pathname) || 0) + 1)),
  };
</script>
</body></html>`;
}

const tall = '<div style="height: 4000px">tall</div>';
const PAGES = {
  "/": page("Home", "<h1>Pyking</h1>"),
  "/install/": page("Install", "<h1>Install</h1>"),
  "/getstarted/overview/": page("Overview", `<h1>Overview</h1>
    <a id="toMath" href="${BASE}/libraries/math/">math</a>
    <a id="toSecond" href="${BASE}/getstarted/second/">second</a>
    <a id="toLinked" href="${BASE}/playground/#code=abc">a program</a>
    <a id="toRuntime" href="${BASE}/runtime/plain.html">a runtime page</a>
    <a id="newTab" href="${BASE}/libraries/" target="_blank">new tab</a>
    <a id="away" href="http://localhost.invalid/elsewhere/">another site</a>`),
  "/getstarted/second/": page("Second", "<h1>Second</h1>"),
  "/documentation/language/": page("Language", "<h1>Language</h1>"),
  "/libraries/": page("Libraries", `<h1>Libraries</h1>${tall}`),
  "/libraries/math/": page("math", `<h1>math</h1>${tall}`),
  "/playground/": page("Playground", `<h1>Playground</h1><textarea id="code"></textarea>`),
  "/other/": page("Other", `<iframe id="inner" src="${BASE}/install/"></iframe>`),
};

function serve() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://localhost");
    let file = url.pathname.startsWith(BASE) ? url.pathname.slice(BASE.length) : null;
    if (file === "/index.html") file = "/";
    if (file === "/site/shell.js") {
      response.writeHead(200, { "content-type": "text/javascript" });
      response.end(fs.readFileSync(SHELL));
    } else if (file === "/runtime/plain.html") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end("<!doctype html><title>plain</title><p>plain</p>");
    } else if (file === "/version.json") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ build: builds.named }));
    } else if (file !== null && PAGES[file] !== undefined) {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(PAGES[file].replace('data-build="BUILD"', `data-build="${builds.page}"`));
    } else {
      response.writeHead(404, { "content-type": "text/html" });
      response.end(page("Not found", "<h1>404</h1>")
        .replace('data-build="BUILD"', `data-build="${builds.page}"`));
    }
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

const output = { checks: 0, failures: [] };
let chrome = null;
let server = null;
try {
  server = await serve();
  const site = `http://127.0.0.1:${server.address().port}${BASE}`;
  const problems = [];
  chrome = await start(browser, "pyk-shell-", (data) => {
    if (data.method === "Runtime.exceptionThrown") {
      problems.push(data.params.exceptionDetails.exception?.description
                    || data.params.exceptionDetails.text);
    }
  });
  const { send } = chrome;
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    }
    return result.result.value;
  };
  const check = (label, ok, detail = "") => {
    output.checks += 1;
    if (!ok) output.failures.push(`${label}${detail === "" ? "" : ": " + String(detail).slice(0, 300)}`);
  };
  const until = async (expression, ms = 10000) => {
    let value;
    for (let waited = 0; waited < ms; waited += 100) {
      try {
        value = await evaluate(expression);
      } catch {
        value = undefined;   // the page is still loading
      }
      if (value) return value;
      await sleep(100);
    }
    return value;
  };
  const open = async (url) => {
    await send("Page.navigate", { url }, sessionId);
    await until("document.readyState === 'complete'");
  };
  // A section's frame, and its window and document, from the shell.
  const frame = (key) => `pykingShell.frame(${JSON.stringify(key)})`;
  const win = (key) => `${frame(key)}.contentWindow`;
  const doc = (key) => `${frame(key)}.contentDocument`;
  // Waits until a section's frame has its page.
  const ready = (key, page) => until(`${frame(key)}?.contentDocument?.readyState === "complete"
    && ${win(key)}.location.pathname === ${JSON.stringify(BASE + page)}
    && ${win(key)}.loads !== undefined`);
  // Clicks an element of a section's page once the page has it: a frame
  // just navigated may still be parsing, with no header yet.
  const click = async (key, selector) => {
    const element = `${doc(key)}?.querySelector(${JSON.stringify(selector)})`;
    if (!await until(`!!${element}`)) throw new Error(`no ${selector} in the ${key} section's page`);
    await evaluate(`${element}.click()`);
  };
  const tab = (key, label) => evaluate(`[...${doc(key)}.querySelectorAll(".pyking-nav a")]
    .find((a) => a.textContent === ${JSON.stringify(label)}).click()`);
  const where = () => evaluate("location.pathname + location.hash");
  const shown = () => evaluate(`[...document.querySelectorAll("#pyking-shell > iframe")]
    .filter((f) => f.dataset.hidden === undefined).map((f) => f.dataset.section).join(",")`);

  progress("the shell");
  await open(`${site}/libraries/math/`);
  check("the window opened is the shell", await evaluate(
    "document.documentElement.classList.contains('pyking-shell') && !!window.pykingShell"));
  check("with the page in a frame of its section", await ready("libraries", "/libraries/math/"));
  check("which is a section, not a shell", await evaluate(
    `${doc("libraries")}.documentElement.classList.contains("pyking-framed")
     && !${doc("libraries")}.documentElement.classList.contains("pyking-shell")`));
  check("the shell's own page is not shown", await evaluate(
    "getComputedStyle(document.querySelector('main')).display === 'none'"));
  check("and the frame fills the window", await evaluate(`(() => {
    const r = ${frame("libraries")}.getBoundingClientRect();
    return r.width === innerWidth && r.height === innerHeight; })()`));
  check("the address is the page's", await where() === `${BASE}/libraries/math/`, await where());
  check("the title is the page's", await until("document.title === 'math | Pyking'"),
    await evaluate("document.title"));

  progress("a section's tab");
  await evaluate(`${win("libraries")}.scrollTo(0, 700)`);
  await tab("libraries", "Playground");
  check("a section's tab opens that section", await ready("playground", "/playground/"));
  check("and shows it alone", await shown() === "playground", await shown());
  check("with its address and title", await where() === `${BASE}/playground/`
    && await until("document.title === 'Playground | Pyking'"), await where());
  check("the section left is told it is hidden",
    await evaluate(`JSON.stringify(${win("libraries")}.heard)`) === "[true]",
    await evaluate(`JSON.stringify(${win("libraries")}.heard)`));
  check("and cannot be reached", await evaluate(`${frame("libraries")}.inert`));
  await evaluate(`${win("playground")}.state = 7;
    ${doc("playground")}.getElementById("code").value = "print(1)"`);
  await tab("playground", "Libraries");
  check("the tab of a section left shows it again", await shown() === "libraries", await shown());
  check("as it was: the same page, not loaded again",
    await evaluate(`${win("libraries")}.loads`) === 1
    && await where() === `${BASE}/libraries/math/`, await where());
  check("scrolled where it was", await evaluate(`${win("libraries")}.scrollY`) === 700,
    await evaluate(`${win("libraries")}.scrollY`));
  check("and told it is shown again",
    await evaluate(`JSON.stringify(${win("libraries")}.heard)`) === "[true,false]",
    await evaluate(`JSON.stringify(${win("libraries")}.heard)`));
  await tab("libraries", "Playground");
  check("a script's state and what was typed are kept", await evaluate(
    `${win("playground")}.state === 7 && ${doc("playground")}.getElementById("code").value === "print(1)"
     && ${win("playground")}.loads === 1`));
  check("only the page opened first was ever the shell", await evaluate(
    `${win("playground")}.shellStartedHere === false && window.shellStartedHere === true`));

  progress("links");
  await tab("playground", "Getting started");
  check("a section opened for the first time starts at its first page",
    await ready("getstarted", "/getstarted/overview/"));
  await click("getstarted", "#toMath");
  check("a link to another section shows that page of it",
    await until(`${win("libraries")}.location.pathname === "${BASE}/libraries/math/"`)
    && await shown() === "libraries", await shown());
  check("in the frame that section had", await evaluate(`${frame("libraries")}.isConnected`)
    && await evaluate(`document.querySelectorAll("#pyking-shell > iframe").length`) === 3);
  await evaluate("history.back()");
  check("Back goes to the section the link was on",
    await until(`pykingShell.current === "getstarted"`)
    && await where() === `${BASE}/getstarted/overview/`, await where());
  await evaluate("history.forward()");
  check("and Forward to the section it went to",
    await until(`pykingShell.current === "libraries"`)
    && await where() === `${BASE}/libraries/math/`, await where());
  await evaluate("history.back()");
  await until(`pykingShell.current === "getstarted"`);
  await click("getstarted", "#toSecond");
  check("a link within a section is followed in its frame",
    await ready("getstarted", "/getstarted/second/") && await shown() === "getstarted");
  check("with the address and the title following it",
    await until(`location.pathname === "${BASE}/getstarted/second/"`)
    && await until("document.title === 'Second | Pyking'"), await where());
  await evaluate("history.back()");
  check("and Back within the section",
    await ready("getstarted", "/getstarted/overview/")
    && await until(`location.pathname === "${BASE}/getstarted/overview/"`), await where());
  await click("getstarted", "#toLinked");
  check("a link to a program shows it in the playground already open",
    await until(`${win("playground")}.location.hash === "#code=abc"`)
    && await shown() === "playground"
    && await evaluate(`${win("playground")}.state === 7`));
  check("with the link's address", await until(`location.hash === "#code=abc"`), await where());
  await tab("playground", "Getting started");
  // Already at its first page, so the page it is reloading looks ready
  // too: marked, so the check waits until the new one has replaced it.
  await evaluate(`${win("getstarted")}.left = true`);
  await tab("getstarted", "Getting started");
  check("a section's own tab goes to its first page, as without the shell",
    await until(`${win("getstarted")}.left === undefined`)
    && await ready("getstarted", "/getstarted/overview/"));
  await click("getstarted", ".site-title");
  check("the logo shows the start page", await ready("home", "/")
    && await shown() === "home" && await where() === `${BASE}/`, await where());
  await tab("home", "Getting started");
  await until(`pykingShell.current === "getstarted"`);
  await click("getstarted", "#newTab");
  await sleep(500);
  check("a link opening a new window is left to do that",
    await evaluate("pykingShell.current") === "getstarted"
    && (await send("Target.getTargets")).targetInfos.some((t) => t.url === `${site}/libraries/`));
  await click("getstarted", "#toRuntime");
  check("a link to a page that is no section's is followed in the frame",
    await until(`${win("getstarted")}.location.pathname === "${BASE}/runtime/plain.html"`)
    && await shown() === "getstarted");
  await evaluate("history.back()");
  await ready("getstarted", "/getstarted/overview/");

  progress("the theme");
  await evaluate(`${win("getstarted")}.localStorage.setItem("starlight-theme", "light")`);
  check("a theme picked in one section is every section's", await until(
    `${doc("libraries")}.documentElement.dataset.theme === "light"
     && ${doc("playground")}.documentElement.dataset.theme === "light"`));
  await evaluate(`${win("getstarted")}.localStorage.setItem("starlight-theme", "dark")`);
  check("both ways", await until(`${doc("libraries")}.documentElement.dataset.theme === "dark"`));

  progress("plain pages");
  await open(`${site}/install/?noshell`);
  check("a page opened with ?noshell is a page on its own", await evaluate(
    "!window.pykingShell && !document.querySelector('#pyking-shell') && "
    + "getComputedStyle(document.querySelector('main')).display !== 'none'"));
  await open(`${site}/nowhere/`);
  check("so is a page that is no section's", await evaluate(
    "!window.pykingShell && document.documentElement.className === ''"));
  await open(`${site}/other/`);
  check("and a page in another page's frame", await until(
    `document.getElementById("inner").contentDocument?.querySelector("main")
     && document.getElementById("inner").contentDocument.documentElement.className === ""`));

  progress("a new build");
  // A window that has been reloaded has lost `stayed`.
  const stayed = () => evaluate("window.stayed === true");
  await open(`${site}/libraries/math/`);
  await ready("libraries", "/libraries/math/");
  await evaluate(`${win("libraries")}.scrollTo(0, 700)`);
  await tab("libraries", "Playground");
  await ready("playground", "/playground/");
  await evaluate(`window.stayed = true; ${win("playground")}.busyNow = true`);
  check("a page is told which build it is", await evaluate("pykingShell.build") === "b1",
    await evaluate("pykingShell.build"));
  builds.page = builds.named = "b2";
  await evaluate("pykingShell.checkBuild()");
  await sleep(4 * RETRY);
  check("a newer build is noticed", await evaluate("pykingShell.newerBuild") === "b2",
    await evaluate("pykingShell.newerBuild"));
  check("but a busy section is not reloaded", await stayed());
  await evaluate(`${doc("playground")}.dispatchEvent(new KeyboardEvent("keydown"));
    ${win("playground")}.busyNow = false`);
  await sleep(IDLE / 3);
  check("nor one the reader has just typed in", await stayed());
  check("once it is left alone and nothing is busy, the window is reloaded onto the new build",
    await until("window.stayed === undefined && window.pykingShell?.build === 'b2'"),
    await evaluate("window.pykingShell?.build"));
  check("each section kept what it could first", await evaluate(
    `sessionStorage.getItem("saved:${BASE}/playground/") === "1"
     && sessionStorage.getItem("saved:${BASE}/libraries/math/") === "1"`));
  check("the section shown is shown again", await ready("playground", "/playground/")
    && await shown() === "playground" && await where() === `${BASE}/playground/`, await where());
  await tab("playground", "Libraries");
  check("another section's tab opens it at the page it was at",
    await ready("libraries", "/libraries/math/"), await where());
  check("scrolled where it was", await until(`${win("libraries")}.scrollY === 700`),
    await evaluate(`${win("libraries")}.scrollY`));

  await evaluate(`window.stayed = true; ${win("libraries")}.busyNow = true`);
  builds.page = builds.named = "b3";
  await evaluate("pykingShell.checkBuild()");
  await sleep(4 * RETRY);
  check("a busy section waits", await stayed() && await evaluate("pykingShell.newerBuild") === "b3");
  await evaluate(`Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"))`);
  check("but a hidden window is reloaded, busy or not",
    await until("window.stayed === undefined && window.pykingShell?.build === 'b3'"),
    await evaluate("window.pykingShell?.build"));

  // version.json names a build the page does not come back as: a cache
  // that is not past it yet.
  await ready("libraries", "/libraries/math/");
  await evaluate("window.stayed = true");
  builds.named = "b4";
  await evaluate("pykingShell.checkBuild()");
  await until("window.stayed === undefined && window.pykingShell?.build === 'b3'");
  await ready("libraries", "/libraries/math/");
  await evaluate("window.stayed = true");
  await evaluate("pykingShell.checkBuild()");
  await sleep(IDLE + 4 * RETRY);
  check("a reload that came back as the old build is not repeated", await stayed()
    && await evaluate("pykingShell.newerBuild") === null);

  builds.page = builds.named = "b5";
  await open(`${site}/install/?noshell`);
  builds.page = builds.named = "b6";
  await evaluate("window.stayed = true; document.dispatchEvent(new Event('visibilitychange'))");
  check("a plain page is reloaded onto a new build too", await until(
    "window.stayed === undefined "
    + "&& document.querySelector('script[data-build]')?.dataset.build === 'b6'"));

  progress("another site");
  await open(`${site}/getstarted/overview/`);
  await ready("getstarted", "/getstarted/overview/");
  await click("getstarted", "#away");
  await sleep(1500);
  const history = await send("Page.getNavigationHistory", {}, sessionId);
  const now = history.entries[history.currentIndex].url;
  check("a link to another site replaces the whole window", now.startsWith("http://localhost.invalid/"),
    now);

  check("no page threw", problems.length === 0, problems.join(" | "));
} catch (error) {
  output.checks += 1;
  output.failures.push(`the driver failed: ${error.message}`);
} finally {
  await chrome?.stop();
  server?.close();
}
process.stdout.write(JSON.stringify(output));
process.exit(0);
