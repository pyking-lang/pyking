// A headless Chromium for the suites' browser drivers
// (tests/tinyweb/chrome.mjs, tests/notebook/page.mjs,
// tests/lsp/playground.mjs): starting it, and talking to it over the
// DevTools protocol with node's own WebSocket -- no package needed.
//
// It is started with the flags Puppeteer uses, which keep a full Google
// Chrome -- what a Mac has, where Linux usually has a headless shell --
// from throttling a tab that is not in front, asking the keychain for a
// password, or updating and syncing in the background. Every call
// answers within CALL_TIMEOUT or fails saying which call it was, and
// every pending call fails when the connection closes, so a hung browser
// is reported rather than waited on.
//
// Functions:
//   launch(browser, profile) -- starts Chromium on a fresh profile.
//   connect(profile, onEvent) -- {send, close} over its DevTools socket.
//   progress(text) -- says how far a driver has got, for the suite to show.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

/** How long one call to Chromium may take before it is reported as hung. */
const CALL_TIMEOUT = 60000;

const FLAGS = [
  "--headless", "--no-sandbox", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check", "--remote-debugging-port=0",
  "--disable-background-networking", "--disable-background-timer-throttling",
  "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
  "--disable-component-update", "--disable-default-apps", "--disable-extensions",
  "--disable-sync", "--disable-hang-monitor", "--disable-ipc-flooding-protection",
  "--disable-popup-blocking", "--disable-prompt-on-repost", "--metrics-recording-only",
  "--password-store=basic", "--use-mock-keychain",
  "--disable-features=Translate,OptimizationHints,MediaRouter,"
    + "CalculateNativeWinOcclusion,AutofillServerCommunication",
];

/** Says how far a driver has got: a line on stderr the suite prints as it
 *  arrives (tests/suite.py, `run_with_progress`). String -> () */
export function progress(text) {
  process.stderr.write(`progress: ${text}\n`);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Starts Chromium on the profile directory, showing about:blank.
 *  String -> String -> ChildProcess */
export function launch(browser, profile) {
  return spawn(browser, [...FLAGS, `--user-data-dir=${profile}`, "about:blank"],
    { stdio: "ignore" });
}

/** Connects to the Chromium started on the profile: `send(method, params,
 *  sessionId)` answers the call's result, and `onEvent` is handed every
 *  message that answers no call. String -> (Object -> ())? ->
 *  Promise<{send, close}> */
export async function connect(profile, onEvent = () => {}) {
  const file = path.join(profile, "DevToolsActivePort");
  let port = null;
  for (let i = 0; i < 300 && !port; i++) {
    if (fs.existsSync(file)) port = Number(fs.readFileSync(file, "utf8").split("\n")[0]) || null;
    if (!port) await sleep(100);
  }
  if (!port) throw new Error("Chromium did not start");
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  const waiting = new Map();
  let next = 1;
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data);
    if (data.id !== undefined && waiting.has(data.id)) {
      const { resolve, reject } = waiting.get(data.id);
      waiting.delete(data.id);
      if (data.error) reject(new Error(data.error.message));
      else resolve(data.result);
    } else {
      onEvent(data);
    }
  };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error("cannot reach Chromium"));
  });
  socket.onclose = () => {
    for (const { reject } of waiting.values()) reject(new Error("the connection to Chromium closed"));
    waiting.clear();
  };
  const send = (method, params = {}, sessionId = undefined) => {
    const id = next++;
    socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiting.delete(id);
        const what = params.expression ? `${method} ${params.expression.slice(0, 80)}` : method;
        reject(new Error(`Chromium did not answer ${what} in ${CALL_TIMEOUT / 1000} s`));
      }, CALL_TIMEOUT);
      waiting.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
    });
  };
  return { send, close: () => socket.close() };
}
