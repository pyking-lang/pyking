// Runs tinyweb pages in a real, headless Chromium and records what each
// drew, showed and played, through the DevTools protocol over node's own
// WebSocket -- no package needed. tests/test_tinyweb.py serves the pages
// and compares what this answers.
//
// For each page: tests/tinyweb/chrome_page.js is injected before the
// page's own scripts, the page is loaded, and once it says its program's
// top level has ended (`__pykDone`) the events of the .events file are
// delivered one at a time, the page recorded after each.
//
// A URL written `served:<url>` is a page a program serves itself: its
// commands arrive from the program, so it is ready once they stop
// arriving, and an event is done once the program has answered it.
//
// Usage: node chrome.mjs <chromium> <events file> <url> [<url> ...]
// Writes [{record, stdout} | {error}] as JSON, one per URL.

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [browser, eventsFile, ...urls] = process.argv.slice(2);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const injected = fs.readFileSync(path.join(HERE, "chrome_page.js"), "utf8");
const events = fs.existsSync(eventsFile)
  ? fs.readFileSync(eventsFile, "utf8").split("\n").filter((l) => l.trim() !== "")
  : [];
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "pyk-chrome-"));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const chrome = spawn(browser, [
  "--headless", "--no-sandbox", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check", "--remote-debugging-port=0",
  `--user-data-dir=${profile}`, "about:blank",
], { stdio: "ignore" });

// The port Chromium chose, from the file it writes into its profile.
async function debuggingPort() {
  const file = path.join(profile, "DevToolsActivePort");
  for (let i = 0; i < 300; i++) {
    if (fs.existsSync(file)) {
      const first = fs.readFileSync(file, "utf8").split("\n")[0];
      if (first !== "") return Number(first);
    }
    await sleep(100);
  }
  throw new Error("Chromium did not start");
}

// One connection to the browser, sessions multiplexed over it.
class Protocol {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.next = 1;
    this.waiting = new Map();
    this.socket.onmessage = (message) => {
      const data = JSON.parse(message.data);
      if (data.id !== undefined && this.waiting.has(data.id)) {
        const { resolve, reject } = this.waiting.get(data.id);
        this.waiting.delete(data.id);
        if (data.error) reject(new Error(data.error.message));
        else resolve(data.result);
      }
    };
  }

  open() {
    return new Promise((resolve, reject) => {
      this.socket.onopen = resolve;
      this.socket.onerror = () => reject(new Error("cannot reach Chromium"));
    });
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.next++;
    this.socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
  }
}

async function evaluate(protocol, session, expression) {
  const result = await protocol.send("Runtime.evaluate",
    { expression, awaitPromise: true, returnByValue: true }, session);
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.exception?.description
      || result.exceptionDetails.text);
  }
  return result.result.value;
}

async function run(protocol, given) {
  const served = given.startsWith("served:");
  const url = served ? given.slice("served:".length) : given;
  const { targetId } = await protocol.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await protocol.send("Target.attachToTarget", { targetId, flatten: true });
  try {
    await protocol.send("Page.enable", {}, sessionId);
    await protocol.send("Runtime.enable", {}, sessionId);
    await protocol.send("Page.addScriptToEvaluateOnNewDocument", { source: injected }, sessionId);
    await protocol.send("Page.navigate", { url }, sessionId);
    let done = false;
    for (let i = 0; i < 600 && !done; i++) {
      await sleep(100);
      try {
        done = await evaluate(protocol, sessionId,
          served ? "__pykQuiet()" : "globalThis.__pykDone === true");
      } catch {
        done = false;
      }
    }
    if (!done) return { error: `${url}: the program's top level never ended` };
    await evaluate(protocol, sessionId, "__pykSettle()");
    await evaluate(protocol, sessionId, "__pykSnapshot('--- the top level has ended')");
    for (const line of events) {
      const before = served ? await evaluate(protocol, sessionId, "__pykAnswered()") : 0;
      const found = await evaluate(protocol, sessionId, `__pykDeliver(${JSON.stringify(line)})`);
      for (let i = 0; served && found && i < 300; i++) {
        if (await evaluate(protocol, sessionId, "__pykAnswered()") > before) break;
        await sleep(20);
      }
      await evaluate(protocol, sessionId, "__pykSettle()");
      await evaluate(protocol, sessionId,
        `__pykSnapshot(${JSON.stringify((found ? "--- after " : "--- nothing for ") + line)})`);
    }
    return JSON.parse(await evaluate(protocol, sessionId, "__pykResult()"));
  } catch (error) {
    return { error: `${url}: ${error.message}` };
  } finally {
    await protocol.send("Target.closeTarget", { targetId }).catch(() => {});
  }
}

let results = [];
try {
  const port = await debuggingPort();
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const protocol = new Protocol(version.webSocketDebuggerUrl);
  await protocol.open();
  for (const url of urls) results.push(await run(protocol, url));
  protocol.socket.close();
} catch (error) {
  results = urls.map(() => ({ error: error.message }));
} finally {
  chrome.kill();
  await sleep(200);
  fs.rmSync(profile, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(results));
