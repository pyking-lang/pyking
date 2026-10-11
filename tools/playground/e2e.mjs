// Browser tests for the playground: what `make e2e` runs.
//
// `make check` checks every example through the same compiler bundle
// the page loads, under node, which says nothing about the page. This drives the built page in a real browser
// instead: it mounts, loads the compiler, compiles, and runs -- the whole
// path a user takes, including the worker boundary and the sandboxed
// iframe that `check` cannot reach.
//
// Playwright is the one dependency in this repository, and it is
// optional: without it this says so and exits 0, so `make e2e` on a
// machine that has not installed it is not a failure.
//
// It starts `pyk playground` itself; `make vendor` must have run.

import { spawn } from "node:child_process";
import { createServer } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));

/** Playwright, or null when it is not installed. The global install is
 *  tried as well as the local one, since `npx playwright` puts it
 *  there. () -> Promise<module?> */
async function playwright() {
  for (const name of ["playwright", "/usr/lib/node_modules/playwright/index.mjs"]) {
    try {
      return await import(name);
    } catch { /* try the next */ }
  }
  return null;
}

/** A port nothing is listening on. () -> Promise<Int> */
function freePort() {
  return new Promise((resolve) => {
    const probe = createServer();
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** Starts `pyk playground`, as `make serve` would, and waits for it to
 *  print its URL. () -> Promise<{url, close}> */
async function serve() {
  const port = await freePort();
  const child = spawn(process.env.PYK || path.join(HERE, "..", "..", "pyk"),
                      ["playground", "--port", String(port)],
                      { cwd: HERE, stdio: ["ignore", "pipe", "inherit"] });
  await new Promise((resolve, reject) => {
    let seen = "";
    child.stdout.on("data", (chunk) => {
      seen += chunk;
      if (seen.includes("http://")) resolve();
    });
    child.on("exit", (code) => reject(new Error(`the server exited (${code})`)));
  });
  return {
    url: `http://127.0.0.1:${port}/index.html`,
    close: async () => { child.kill(); },
  };
}

let failures = 0;

/** One check. String -> Bool -> String? -> () */
function expect(label, ok, detail = "") {
  if (ok) {
    console.log(`  ok   ${label}`);
    return;
  }
  failures += 1;
  console.log(`  FAIL ${label}${detail ? ": " + detail : ""}`);
}

/** Waits for the status line to leave whatever it is doing, and answers
 *  with what it settled on. Page -> Int -> Promise<String> */
async function settled(page, seconds = 120) {
  for (let i = 0; i < seconds * 2; i += 1) {
    const status = await page.evaluate(
      () => document.querySelector('[data-r="statusText"]')?.textContent ?? "");
    if (/ready|idle|error|failed/.test(status)) return status;
    await page.waitForTimeout(500);
  }
  return "TIMEOUT";
}

/** The last line the output pane shows. Page -> Promise<String> */
function lastLine(page) {
  return page.evaluate(() => {
    const text = document.querySelector('[data-r="output"]')?.textContent ?? "";
    const lines = text.trimEnd().split("\n");
    return lines[lines.length - 1] ?? "";
  });
}

async function main() {
  const driver = await playwright();
  if (driver === null) {
    console.log("e2e: Playwright is not installed, so the browser tests are "
                + "skipped.\n     npx playwright install chromium  (then "
                + "`make e2e` again)");
    return;
  }

  const site = await serve();
  let browser;
  try {
    browser = await driver.chromium.launch();
  } catch (err) {
    console.log("e2e: no browser to drive, so the browser tests are skipped.\n"
                + "     npx playwright install chromium  (" + err.message.split("\n")[0] + ")");
    await site.close();
    return;
  }
  const page = await browser.newPage();

  // A page error is a failure wherever it happens, so they are collected
  // throughout and asserted at the end rather than at each step. The
  // preview iframe is sandboxed and reads no storage of its own, so its
  // own complaint about that is not the page's.
  const problems = [];
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("console", (m) => {
    if (m.type() === "error") problems.push("console: " + m.text());
  });

  console.log("The page");
  await page.goto(site.url, { waitUntil: "networkidle" });
  const meta = await page.evaluate(async () => {
    const manifest = await (await fetch("assets/playground.json")).json();
    const select = document.querySelector('[data-r="target"]');
    return {
      targets: [...select.options].map((o) => o.value),
      declared: manifest.targets.map((t) => t.name),
      examples: manifest.examples.map((e) => e.file).join(),
      offered: [...document.querySelectorAll('[data-r="example"] option')]
        .map((o) => o.value).join(),
    };
  });
  expect("mounts, with every target in the dropdown",
         meta.targets.length > 0 && meta.targets.join() === meta.declared.join(),
         `${meta.targets.join()} vs ${meta.declared.join()}`);
  expect("offers the example list", meta.examples !== ""
         && meta.offered === meta.examples, `${meta.offered} vs ${meta.examples}`);
  expect("both editors are Monaco", await page.evaluate(() =>
    !!window.monaco?.editor
    && document.querySelectorAll('[data-r$="Editor"] .monaco-editor').length === 2
    && window.pykingPlayground.left.getModel().getLanguageId() === "pyking"));

  // The examples import libraries, which Compile refuses, so what follows
  // starts from a plain program.
  await page.evaluate(() => window.pykingPlayground.setSource(
    "def twice(n: Int) -> Int:\n    return n * 2\n\n\nprint(twice(21))\n"));

  console.log("Compiling");
  await page.click('[data-r="compile"]');
  expect("loads the compiler", /ready/.test(await settled(page)));
  await page.waitForTimeout(500);
  expect("compiles for the default target",
         /^Compiled to /.test(await lastLine(page)), await lastLine(page));

  await page.selectOption('[data-r="target"]', "pyking");
  await page.click('[data-r="compile"]');
  await settled(page);
  await page.waitForTimeout(500);
  expect("compiles for the pyking target",
         /front end/.test(await lastLine(page)), await lastLine(page));

  console.log("Running");
  // The left Run button runs the program itself, with the interpreter,
  // whatever target is selected; the right one runs what is displayed,
  // which needs a target a browser can execute.
  await page.selectOption('[data-r="target"]', "node24");
  await page.click('[data-r="compile"]');
  await settled(page);
  await page.waitForTimeout(500);
  await page.click('[data-r="runLeft"]');
  await settled(page);
  await page.waitForTimeout(2000);
  const fromSource = await lastLine(page);
  expect("runs the source", /finished/.test(fromSource), fromSource);

  await page.click('[data-r="runRight"]');
  await settled(page);
  await page.waitForTimeout(2000);
  const generated = await lastLine(page);
  expect("runs the generated code", /finished/.test(generated), generated);

  // The keys are the editor's own actions: Shift+Enter in the source runs
  // it rather than typing a newline, and Ctrl+Enter compiles.
  console.log("Keys");
  const before = await page.evaluate(() => {
    window.pykingPlayground.clearOutput();
    window.pykingPlayground.left.focus();
    return window.pykingPlayground.left.getValue();
  });
  await page.keyboard.press("Shift+Enter");
  await settled(page);
  await page.waitForTimeout(2000);
  expect("Shift+Enter in the source runs it", /finished/.test(await lastLine(page))
         && await page.evaluate(() => window.pykingPlayground.left.getValue()) === before,
         await lastLine(page));
  await page.evaluate(() => window.pykingPlayground.left.focus());
  await page.keyboard.press("Control+Enter");
  await settled(page);
  await page.waitForTimeout(500);
  expect("Ctrl+Enter compiles", /^Compiled to /.test(await lastLine(page)),
         await lastLine(page));

  // Every example checks through the page's own runtime, with the
  // standard library it imports -- what Run does before it runs one.
  console.log("Every example, in the browser");
  const sweep = await page.evaluate(async () => {
    const manifest = await (await fetch("assets/playground.json")).json();
    const runtime = window.pykingPlayground.runtime;
    const wrong = [];
    for (const example of manifest.examples) {
      const source = await (await fetch("examples/" + example.file)).text();
      const result = await runtime.analyze(source, example.file);
      if (!result.ok) wrong.push(`${example.file}: ${result.text}`);
    }
    return { count: manifest.examples.length, wrong };
  });
  expect(`${sweep.count} examples check`, sweep.wrong.length === 0,
         "\n         " + sweep.wrong.join("\n         "));

  // A program may import the standard library, and one that reads its
  // input is asked for it before it runs: a dialog, only for a program
  // that reads. `io` and `sys` are the worker's own, so what it writes is
  // this pane, a `debug` line is marked apart, and `sys.exit` ends it.
  console.log("The standard library");
  await page.evaluate(() => {
    window.pykingPlayground.setSource([
      "import io", "import sys",
      "debug(\"starting\")",
      "name = io.read_line(\"Name? \")",
      "print(\"hello\", name, sys.args())",
      "sys.exit(3)", "print(\"never\")", "",
    ].join("\n"));
  });
  await page.click('[data-r="runLeft"]');
  await page.waitForSelector('[data-r="inputModal"]:not(.pyk-hidden)', { timeout: 60000 });
  expect("a program reading its input is asked for it first",
         await page.evaluate(() =>
           !document.querySelector('[data-r="inputStdinField"]').classList.contains("pyk-hidden")
           && !document.querySelector('[data-r="inputArgsField"]').classList.contains("pyk-hidden")));
  await page.fill('[data-r="inputStdin"]', "Ada\nnot read\n");
  await page.fill('[data-r="inputArgs"]', "a 'b c'");
  await page.click('[data-r="inputRun"]');
  await settled(page);
  await page.waitForTimeout(2000);
  const ran = await page.evaluate(() => {
    const output = document.querySelector('[data-r="output"]');
    return {
      text: output.textContent,
      debug: [...output.querySelectorAll(".debug")].map((e) => e.textContent).join(""),
    };
  });
  expect("it reads what it was given, and is passed its arguments",
         ran.text.includes("Name? Ada\nhello Ada ['a', 'b c']"), JSON.stringify(ran.text));
  expect("its debug line is marked apart", ran.debug === "starting\n",
         JSON.stringify(ran.debug));
  expect("sys.exit ends it, with the status shown",
         ran.text.includes("exited with status 3") && !ran.text.includes("never"),
         JSON.stringify(ran.text));
  await page.evaluate(() => {
    window.pykingPlayground.setSource("import io\nio.write_line(\"quiet\")\n");
  });
  await page.click('[data-r="runLeft"]');
  await settled(page);
  await page.waitForTimeout(2000);
  expect("a program that only writes is not asked for anything",
         await page.evaluate(() =>
           document.querySelector('[data-r="inputModal"]').classList.contains("pyk-hidden"))
         && /finished/.test(await lastLine(page)), await lastLine(page));
  // `print` on a `web` target writes through the shipped io_external.js.
  await page.evaluate(() => {
    window.pykingPlayground.setSource("print(\"from the page\", 1)\n");
  });
  await page.selectOption('[data-r="target"]', "web24");
  await page.click('[data-r="compile"]');
  await settled(page);
  await page.waitForTimeout(500);
  await page.click('[data-r="runRight"]');
  await settled(page);
  await page.waitForTimeout(2000);
  const web = await page.evaluate(
    () => document.querySelector('[data-r="output"]').textContent);
  expect("a web program prints through its io_external.js",
         web.includes("from the page 1") && /finished/.test(await lastLine(page)),
         JSON.stringify(web));

  // A program using tinyweb shows its page on the Page tab, and goes on
  // running there after its top level has ended: a click calls back the
  // function it handed over, and a frame callback keeps being called
  // until Stop. The canvas is read back pixel by pixel.
  console.log("A page");
  await page.evaluate(() => {
    window.pykingPlayground.setSource([
      "import tinyweb as tw",
      "c = tw.canvas(200, 100)",
      "tw.circle(c, 50, 50, 30, \"#ff0000\")",
      "status = tw.label(\"waiting\")",
      "var frames = 0",
      "def pressed():",
      "    print(\"pressed\")",
      "    tw.circle(c, 150, 50, 30, \"#0000ff\")",
      "def draw(t: Float):",
      "    frames := frames + 1",
      "    if frames == 3:",
      "        tw.set_label(status, \"three frames\")",
      "tw.button(\"Press\", on_click = pressed)",
      "tw.on_frame(draw)",
      "",
    ].join("\n"));
  });
  await page.click('[data-r="runLeft"]');
  const canvas = '[data-r="page"] canvas';
  await page.waitForSelector(canvas, { timeout: 60000 });
  const pixel = (x, y) => page.evaluate(([selector, x, y]) => {
    const element = document.querySelector(selector);
    const ratio = element.width / 200;
    const data = element.getContext("2d")
      .getImageData(Math.round(x * ratio), Math.round(y * ratio), 1, 1).data;
    return [...data.slice(0, 3)].join(",");
  }, [canvas, x, y]);
  expect("the page is shown on the Page tab", await page.evaluate(() =>
    !document.querySelector('[data-r="page"]').classList.contains("pyk-hidden")
    && document.querySelector('[data-r="viewPage"]').classList.contains("active")));
  expect("the canvas has the circle drawn", (await pixel(50, 50)) === "255,0,0",
         await pixel(50, 50));
  await page.waitForFunction(() =>
    document.querySelector('[data-r="page"]').textContent.includes("three frames"),
    null, { timeout: 30000 }).catch(() => {});
  expect("frames are delivered to the program", await page.evaluate(() =>
    document.querySelector('[data-r="page"]').textContent.includes("three frames")));
  await page.click('[data-r="page"] button');
  await page.waitForTimeout(1500);
  expect("a click calls the program back",
         (await pixel(150, 50)) === "0,0,255"
         && (await page.evaluate(() =>
           document.querySelector('[data-r="output"]').textContent)).includes("pressed\n"),
         await pixel(150, 50));
  expect("Stop stays armed while the page is live", await page.evaluate(() =>
    !document.querySelector('[data-r="stopLeft"]').classList.contains("pyk-hidden")));
  await page.click('[data-r="stopLeft"]');
  await page.waitForTimeout(500);
  expect("Stop lets it go", await page.evaluate(() =>
    document.querySelector('[data-r="stopLeft"]').classList.contains("pyk-hidden")));
  await page.click('[data-r="viewCode"]');

  // A Pyking loop need never end (PYKING.md, "Leaving a loop"), so the
  // page has to stay answerable while one is running -- which is the
  // whole point of running it in a worker. Nothing headless can show
  // this: it needs a real worker, really executing.
  console.log("Stopping");
  await page.evaluate(() => {
    window.pykingPlayground.setSource("loop:\n    continue\n");
  });
  await page.click('[data-r="runLeft"]');
  await page.waitForSelector('[data-r="stopLeft"]:not(.pyk-hidden)', { timeout: 30000 });
  expect("stays answerable while a program runs",
         await page.evaluate(
           () => document.querySelector('[data-r="stopLeft"]') !== null));
  await page.click('[data-r="stopLeft"]');
  await page.waitForTimeout(2000);
  expect("Stop ends a program that never would",
         await page.evaluate(() => document
           .querySelector('[data-r="stopLeft"]').classList.contains("pyk-hidden")));

  const real = problems.filter((p) => !p.includes("allow-same-origin"));
  expect("no errors in the console", real.length === 0,
         "\n         " + real.slice(0, 10).join("\n         "));

  await browser.close();
  await site.close();

  console.log();
  console.log(failures ? `e2e: ${failures} failed` : "e2e: everything passed");
  if (failures) process.exit(1);
}

await main();
