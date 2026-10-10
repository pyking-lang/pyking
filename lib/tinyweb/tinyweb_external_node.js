// The JavaScript implementation of the names declared in
// tinyweb_external.pyk for node24, where there is no page around the
// program. tinyweb_external_browser.js is the one web24 uses, and
// tinyweb_external_interpreter.js the one iweb24, the playground and
// the notebook use.
//
// A program talks to its page in commands and the page answers in
// events (docs/libraries.md, "tinyweb"). Where they go:
//
//   - $PYKING_TINYWEB_LOG set: no page. Each command is a line in that
//     file, and once the top level has ended the events
//     $PYKING_TINYWEB_EVENTS lists are delivered -- how a program is
//     tested.
//   - otherwise `web_init(port)` serves the page, tinyweb_page.html and
//     tinyweb_page.js (copied into this file below), from node's own
//     http server: GET /commands is a stream of command batches
//     (server-sent events) and POST /events one event each, delivered
//     as it arrives -- after the top level, which runs to its end before
//     node looks at the server -- and answered with `event_done` once
//     what it caused has been sent.
//   - neither: the first call says `web_init` is missing, and the
//     program ends with status 1.

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const LOG = process.env.PYKING_TINYWEB_LOG;
const EVENTS = process.env.PYKING_TINYWEB_EVENTS;
const HERE = path.dirname(fileURLToPath(import.meta.url));

let last = 0;
let clock = 0;
const buttons = new Map();
const sliders = new Map();
const mice = new Map();
const frames = [];
const keys = [];
let after = false;
let hub = null;

// --- commands ---

const quote = (text) => JSON.stringify(text);

// A command as the one line every headless implementation writes.
function logLine(command) {
  const s = (x) => x.toFixed(3);
  const c = command;
  switch (c.op) {
    case "canvas": return `canvas ${c.id} ${c.width} ${c.height}`;
    case "clear": return `clear ${c.c} ${c.color}`;
    case "circle": return `circle ${c.c} ${c.x} ${c.y} ${c.radius} ${c.color}`;
    case "rect": return `rect ${c.c} ${c.x} ${c.y} ${c.width} ${c.height} ${c.color}`;
    case "line": return `line ${c.c} ${c.x1} ${c.y1} ${c.x2} ${c.y2} ${c.color} ${c.width}`;
    case "text": return `text ${c.c} ${c.x} ${c.y} ${c.color} ${c.size} ${quote(c.words)}`;
    case "button": return `button ${c.id} ${quote(c.title)}`;
    case "label": return `label ${c.id} ${quote(c.text)}`;
    case "set_label": return `set_label ${c.id} ${quote(c.text)}`;
    case "slider": return `slider ${c.id} ${c.low} ${c.high} ${c.value}`;
    case "load": return `load ${c.id} ${quote(c.name)}`;
    case "play": return `play ${c.sample} ${s(c.at)} ${s(c.volume)} ${s(c.rate)}`;
    case "on_mouse": return `on_mouse ${c.c}`;
    default: return c.op;
  }
}

function writeLog(line) {
  fs.appendFileSync(LOG, line + "\n");
}

// What every function but `web_init` needs first: a log to write to,
// or a page served.
function ready() {
  if (LOG !== undefined) {
    if (!after) {
      after = true;
      setTimeout(afterProgram, 0);
    }
    return;
  }
  if (hub === null) {
    refuse("tinyweb: call tinyweb.web_init(port) before anything else, " +
      "or set PYKING_TINYWEB_LOG");
  }
}

// Ends the program with `message`, and with status 1.
function refuse(message) {
  fs.writeSync(2, message + "\n");
  process.exit(1);
}

function send(command) {
  ready();
  if (LOG !== undefined) {
    if (command.op !== "frame_done" && command.op !== "event_done") writeLog(logLine(command));
  } else {
    hub.send(command);
  }
}

function fresh() {
  last += 1;
  return last;
}

// --- the functions tinyweb_external.pyk declares ---

export function web_init(port) {
  if (LOG !== undefined || hub !== null) return;
  if (!(port >= 0 && port <= 65535)) {
    refuse(`tinyweb: cannot serve the page on port ${port}: a port is a number from 0 to 65535`);
  }
  hub = new Hub(port);
}

export function canvas(width, height) {
  ready();
  const id = fresh();
  send({ op: "canvas", id, width, height });
  return id;
}

export function fill_canvas(c, color) {
  send({ op: "clear", c, color });
}

export function draw_circle(c, x, y, radius, color) {
  send({ op: "circle", c, x, y, radius, color });
}

export function draw_rect(c, x, y, width, height, color) {
  send({ op: "rect", c, x, y, width, height, color });
}

export function draw_line(c, x1, y1, x2, y2, color, width) {
  send({ op: "line", c, x1, y1, x2, y2, color, width });
}

export function draw_text(c, x, y, words, color, size) {
  send({ op: "text", c, x, y, color, size, words });
}

export function make_button(title, onClick) {
  ready();
  const id = fresh();
  buttons.set(id, onClick);
  send({ op: "button", id, title });
  return id;
}

export function label(text) {
  ready();
  const id = fresh();
  send({ op: "label", id, text });
  return id;
}

export function set_label(id, text) {
  send({ op: "set_label", id, text });
}

export function make_slider(low, high, value, onChange) {
  ready();
  const id = fresh();
  sliders.set(id, onChange);
  send({ op: "slider", id, low, high, value });
  return id;
}

export function load_sample(name) {
  ready();
  const id = fresh();
  send({ op: "load", id, name });
  return id;
}

export function play_sample(sample, at, volume, rate) {
  send({ op: "play", sample, at, volume, rate });
}

export function time() {
  ready();
  return clock;
}

export function on_frame(draw) {
  ready();
  frames.push(draw);
  send({ op: "on_frame" });
}

export function on_mouse(c, click) {
  ready();
  if (!mice.has(c)) mice.set(c, []);
  mice.get(c).push(click);
  send({ op: "on_mouse", c });
}

export function on_key(pressed) {
  ready();
  keys.push(pressed);
  send({ op: "on_key" });
}

// --- events ---

// Calls what the program handed over for one event, in the order it was
// handed over.
function deliver(event) {
  if (typeof event.t === "number") clock = event.t;
  switch (event.ev) {
    case "click":
      if (buttons.has(event.id)) buttons.get(event.id)();
      break;
    case "slide":
      if (sliders.has(event.id)) sliders.get(event.id)(Math.trunc(event.value));
      break;
    case "frame":
      for (const draw of frames.slice()) draw(clock);
      send({ op: "frame_done" });
      break;
    case "mouse":
      for (const click of (mice.get(event.c) || []).slice()) {
        click(Math.trunc(event.x), Math.trunc(event.y));
      }
      break;
    case "key":
      for (const pressed of keys.slice()) pressed(String(event.key));
      break;
  }
}

// One line of an events file as the event the page would send.
function parseEvent(line) {
  if (line.startsWith("key ")) return { ev: "key", key: line.slice(4) };
  const words = line.trim().split(/\s+/);
  const n = (i) => Number(words[i]);
  switch (words[0]) {
    case "click": return words.length === 2 ? { ev: "click", id: n(1) } : null;
    case "slide": return words.length === 3 ? { ev: "slide", id: n(1), value: n(2) } : null;
    case "frame": return words.length === 2 ? { ev: "frame", t: n(1) } : null;
    case "mouse":
      return words.length === 4 ? { ev: "mouse", c: n(1), x: n(2), y: n(3) } : null;
    default: return null;
  }
}

// The events file's events, once the top level has ended.
function afterProgram() {
  if (!EVENTS || !fs.existsSync(EVENTS)) return;
  for (const line of fs.readFileSync(EVENTS, "utf8").split("\n")) {
    if (line.trim() === "") continue;
    writeLog("> " + line);
    const event = parseEvent(line);
    if (event === null) writeLog("! unknown event: " + line);
    else deliver(event);
  }
}

// --- the server ---

const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json",
  ".wav": "audio/wav", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
  ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml",
};

const DRAWING = new Set(["clear", "circle", "rect", "line", "text"]);

// The commands a page connecting now has to be sent, once `command` has
// been: everything but sound and frame bookkeeping, less what a later
// command has made invisible.
function kept(history, command) {
  switch (command.op) {
    case "play": case "frame_done": case "event_done": return history;
    case "clear":
      return history.filter((h) => !(DRAWING.has(h.op) && h.c === command.c)).concat([command]);
    case "set_label":
      return history.filter((h) => !(h.op === "set_label" && h.id === command.id))
        .concat([command]);
    default: return history.concat([command]);
  }
}

// The file a page asks for by `url`: beside where the program runs, and
// a library sample from tinyweb_assets/ beside this file.
function staticFile(url) {
  const parts = decodeURIComponent(url).split("/").filter((p) => p !== "" && p !== ".");
  if (parts.length === 0 || parts.includes("..")) return null;
  const places = [process.cwd()];
  if (parts[0] === "tinyweb_assets") places.push(HERE);
  for (const place of places) {
    const candidate = path.join(place, ...parts);
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // not here
    }
  }
  return null;
}

class Hub {
  constructor(port) {
    this.history = [];
    this.pending = [];
    this.clients = new Set();
    this.batching = false;
    this.server = http.createServer((request, response) => this.serve(request, response));
    this.server.on("error", (error) => {
      refuse(`tinyweb: cannot serve the page on port ${port}: ${error.message}`);
    });
    this.server.listen(port, "127.0.0.1", () => {
      process.stdout.write(`tinyweb: http://127.0.0.1:${this.server.address().port}/\n`);
    });
  }

  send(command) {
    this.history = kept(this.history, command);
    this.pending.push(command);
    if (!this.batching) this.flush();
  }

  flush() {
    if (this.pending.length === 0) return;
    const text = `data: ${JSON.stringify(this.pending)}\n\n`;
    this.pending = [];
    for (const client of this.clients) client.write(text);
  }

  // Stops serving: every page is let go and the server closed, so node
  // ends once the program has nothing else to do.
  close() {
    for (const client of this.clients) client.end();
    this.clients.clear();
    this.server.closeAllConnections();
    this.server.close();
  }

  serve(request, response) {
    const url = request.url.split("?")[0];
    const reply = (status, body, type) => {
      response.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
      response.end(body);
    };
    if (request.method === "POST" && url === "/events") {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        let event = null;
        try {
          event = JSON.parse(body);
        } catch {
          return reply(400, "bad event\n", "text/plain");
        }
        response.writeHead(204);
        response.end();
        this.receive(event);
      });
      return;
    }
    if (request.method !== "GET") return reply(404, "not found\n", "text/plain");
    if (url === "/" || url === "/index.html") return reply(200, PAGE_HTML, TYPES[".html"]);
    if (url === "/tinyweb_page.js") return reply(200, PAGE_JS, TYPES[".js"]);
    if (url === "/commands") {
      response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
      response.write(": tinyweb\n\n");
      if (this.history.length > 0) response.write(`data: ${JSON.stringify(this.history)}\n\n`);
      this.clients.add(response);
      request.on("close", () => this.clients.delete(response));
      return;
    }
    const found = staticFile(url);
    if (found === null) return reply(404, "not found\n", "text/plain");
    reply(200, fs.readFileSync(found), TYPES[path.extname(found)] || "application/octet-stream");
  }

  // One event the page posted: what it causes, then `event_done`. A
  // callback that fails -- `sys.exit` among them -- stops the server and
  // is left to fail as it would have anywhere else.
  receive(event) {
    if (event === null || typeof event !== "object") return;
    this.batching = true;
    try {
      deliver(event);
      send({ op: "event_done" });
      this.flush();
    } catch (error) {
      this.close();
      throw error;
    } finally {
      this.batching = false;
    }
  }
}

// BEGIN tinyweb page
// written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit
const PAGE_HTML = [
  "<!doctype html>\n",
  "<!-- The page a program serves after tinyweb.web_init: tinyweb_page.js\n",
  "     carries out the commands the program sends over /commands, and every\n",
  "     event is posted back to /events, in order. Each native\n",
  "     implementation carries a copy of this file, written into it by\n",
  "     tools/tinyweb/embed_page.py. See docs/libraries.md, \"tinyweb\". -->\n",
  "<html lang=\"en\">\n",
  "<head>\n",
  "<meta charset=\"utf-8\">\n",
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
  "<title>tinyweb</title>\n",
  "<style>\n",
  "  body { margin: 16px; font-family: system-ui, sans-serif; background: #ffffff; color: #111111; }\n",
  "  .tinyweb-ended { margin-top: 12px; color: #666666; font-size: 14px; }\n",
  "</style>\n",
  "</head>\n",
  "<body>\n",
  "<script type=\"module\">\n",
  "import { mountPage } from \"./tinyweb_page.js\";\n",
  "\n",
  "// One event at a time, so the program sees them in the order they\n",
  "// happened.\n",
  "let posting = Promise.resolve();\n",
  "function post(event) {\n",
  "  posting = posting\n",
  "    .then(() => fetch(\"/events\", { method: \"POST\", body: JSON.stringify(event) }))\n",
  "    .catch(() => {});\n",
  "}\n",
  "\n",
  "const page = mountPage(document.body, post, { standalone: true });\n",
  "const stream = new EventSource(\"/commands\");\n",
  "stream.onmessage = (message) => page.receive(JSON.parse(message.data));\n",
  "stream.onerror = () => {\n",
  "  stream.close();\n",
  "  page.freeze();\n",
  "  const ended = document.createElement(\"div\");\n",
  "  ended.className = \"tinyweb-ended\";\n",
  "  ended.textContent = \"The program has stopped.\";\n",
  "  document.body.appendChild(ended);\n",
  "};\n",
  "</script>\n",
  "</body>\n",
  "</html>\n",
].join("");
const PAGE_JS = [
  "// tinyweb's page: the renderer that carries out the commands a program\n",
  "// sends and reports the events its reader causes. It is the one copy of\n",
  "// that code, used wherever a program talks to its page in commands:\n",
  "//\n",
  "//   - on an iweb24 page, where tinyweb_external_interpreter.js mounts it\n",
  "//     and calls it directly;\n",
  "//   - in the playground and the notebook, where the program runs on a\n",
  "//     worker and tools/webrun/assets/pages.js mounts it on the page;\n",
  "//   - on the page a compiled program serves after `web_init`, where\n",
  "//     tinyweb_page.html mounts it and the commands arrive from the\n",
  "//     program over HTTP. Each native implementation carries a copy of\n",
  "//     this file and of tinyweb_page.html, written into it by\n",
  "//     tools/tinyweb/embed_page.py.\n",
  "//\n",
  "// A command is a plain object such as {op: \"circle\", c, x, y, radius,\n",
  "// color}, and an event one such as {ev: \"click\", id}; see\n",
  "// docs/libraries.md, \"tinyweb\". The web24 implementation,\n",
  "// tinyweb_external_browser.js, does what this file does without the\n",
  "// commands in between. Keep the file ASCII: it is embedded in C.\n",
  "\n",
  "function now() {\n",
  "  return typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
  "}\n",
  "\n",
  "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n",
  "// `receive(commands)` carries out a batch of commands, and `send(event)`\n",
  "// is how the page reports one. `standalone` is true where the page is\n",
  "// the whole document, which is where a key press is listened for; a\n",
  "// page inside another (a notebook cell) takes the focus when clicked.\n",
  "export function mountPage(element, sendEvent, { standalone = false } = {}) {\n",
  "  const box = document.createElement(\"div\");\n",
  "  box.className = \"tinyweb-page\";\n",
  "  box.style.cssText =\n",
  "    \"display:flex;flex-direction:column;align-items:flex-start;gap:8px;\" +\n",
  "    \"font-family:system-ui,sans-serif;outline:none\";\n",
  "  element.appendChild(box);\n",
  "\n",
  "  const canvases = new Map();\n",
  "  const labels = new Map();\n",
  "  const samples = new Map();\n",
  "  const start = now();\n",
  "  let audio = null;\n",
  "  let offset = 0;\n",
  "  let frameWanted = false;\n",
  "  let frameWaiting = false;\n",
  "  let frameRequest = 0;\n",
  "  let closed = false;\n",
  "  const keyTarget = standalone ? window : box;\n",
  "  let keysWanted = false;\n",
  "\n",
  "  if (!standalone) box.tabIndex = 0;\n",
  "\n",
  "  // The page's clock: the audio clock once sound has started, and until\n",
  "  // then the seconds since the page was mounted. `offset` joins the two,\n",
  "  // so the clock never goes back.\n",
  "  function running() {\n",
  "    return audio !== null && audio.state === \"running\";\n",
  "  }\n",
  "\n",
  "  function clockNow() {\n",
  "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
  "  }\n",
  "\n",
  "  function report(event) {\n",
  "    if (!closed) sendEvent({ ...event, t: clockNow(), running: running() });\n",
  "  }\n",
  "\n",
  "  // Sound may start only after the reader did something, so every\n",
  "  // gesture is a chance to start it.\n",
  "  function startAudio() {\n",
  "    if (audio === null) {\n",
  "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n",
  "      if (!Context) return;\n",
  "      const before = clockNow();\n",
  "      audio = new Context();\n",
  "      offset = before - audio.currentTime;\n",
  "      audio.onstatechange = () => {\n",
  "        if (audio.state === \"running\") offset = (now() - start) / 1000 - audio.currentTime;\n",
  "      };\n",
  "    }\n",
  "    if (audio.state === \"suspended\") audio.resume();\n",
  "  }\n",
  "\n",
  "  box.addEventListener(\"pointerdown\", startAudio);\n",
  "\n",
  "  function onKey(event) {\n",
  "    startAudio();\n",
  "    if (keysWanted) report({ ev: \"key\", key: event.key });\n",
  "  }\n",
  "  keyTarget.addEventListener(\"keydown\", onKey);\n",
  "\n",
  "  function loadSample(name) {\n",
  "    const decoder = new OfflineAudioContext(1, 1, 44100);\n",
  "    const fetchArray = (url) =>\n",
  "      fetch(url).then((response) => {\n",
  "        if (!response.ok) throw new Error(`${name}: ${response.status}`);\n",
  "        return response.arrayBuffer();\n",
  "      });\n",
  "    return fetchArray(new URL(name, document.baseURI))\n",
  "      .catch(() => fetchArray(new URL(\"tinyweb_assets/\" + name, import.meta.url)))\n",
  "      .then((bytes) => decoder.decodeAudioData(bytes))\n",
  "      .catch((error) => {\n",
  "        console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);\n",
  "        return null;\n",
  "      });\n",
  "  }\n",
  "\n",
  "  function play({ sample, at, volume, rate }) {\n",
  "    startAudio();\n",
  "    const loading = samples.get(sample);\n",
  "    if (!loading || audio === null) return;\n",
  "    loading.then((buffer) => {\n",
  "      if (buffer === null || closed) return;\n",
  "      const source = audio.createBufferSource();\n",
  "      source.buffer = buffer;\n",
  "      source.playbackRate.value = rate;\n",
  "      const gain = audio.createGain();\n",
  "      gain.gain.value = volume;\n",
  "      source.connect(gain).connect(audio.destination);\n",
  "      source.start(Math.max(audio.currentTime, at - offset));\n",
  "    });\n",
  "  }\n",
  "\n",
  "  function frame() {\n",
  "    if (closed) return;\n",
  "    if (!frameWaiting) {\n",
  "      frameWaiting = true;\n",
  "      report({ ev: \"frame\" });\n",
  "    }\n",
  "    frameRequest = requestAnimationFrame(frame);\n",
  "  }\n",
  "\n",
  "  function newCanvas({ id, width, height }) {\n",
  "    const element = document.createElement(\"canvas\");\n",
  "    element.setAttribute(\"data-tinyweb-id\", String(id));\n",
  "    const ratio = globalThis.devicePixelRatio || 1;\n",
  "    element.width = Math.round(width * ratio);\n",
  "    element.height = Math.round(height * ratio);\n",
  "    element.style.width = width + \"px\";\n",
  "    element.style.height = height + \"px\";\n",
  "    element.style.border = \"1px solid #8884\";\n",
  "    element.style.background = \"#ffffff\";\n",
  "    const context = element.getContext(\"2d\");\n",
  "    context.scale(ratio, ratio);\n",
  "    canvases.set(id, { element, context, width, height, mouse: false });\n",
  "    element.addEventListener(\"click\", (event) => {\n",
  "      const entry = canvases.get(id);\n",
  "      if (!entry.mouse) return;\n",
  "      const bounds = element.getBoundingClientRect();\n",
  "      report({\n",
  "        ev: \"mouse\",\n",
  "        c: id,\n",
  "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
  "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
  "      });\n",
  "    });\n",
  "    box.appendChild(element);\n",
  "  }\n",
  "\n",
  "  function draw(c, paint) {\n",
  "    const entry = canvases.get(c);\n",
  "    if (entry) paint(entry.context, entry);\n",
  "  }\n",
  "\n",
  "  function carryOut(command) {\n",
  "    switch (command.op) {\n",
  "      case \"canvas\":\n",
  "        newCanvas(command);\n",
  "        break;\n",
  "      case \"clear\":\n",
  "        draw(command.c, (g, entry) => {\n",
  "          g.fillStyle = command.color;\n",
  "          g.fillRect(0, 0, entry.width, entry.height);\n",
  "        });\n",
  "        break;\n",
  "      case \"circle\":\n",
  "        draw(command.c, (g) => {\n",
  "          g.fillStyle = command.color;\n",
  "          g.beginPath();\n",
  "          g.arc(command.x, command.y, Math.max(0, command.radius), 0, 2 * Math.PI);\n",
  "          g.fill();\n",
  "        });\n",
  "        break;\n",
  "      case \"rect\":\n",
  "        draw(command.c, (g) => {\n",
  "          g.fillStyle = command.color;\n",
  "          g.fillRect(command.x, command.y, command.width, command.height);\n",
  "        });\n",
  "        break;\n",
  "      case \"line\":\n",
  "        draw(command.c, (g) => {\n",
  "          g.strokeStyle = command.color;\n",
  "          g.lineWidth = command.width;\n",
  "          g.lineCap = \"round\";\n",
  "          g.beginPath();\n",
  "          g.moveTo(command.x1, command.y1);\n",
  "          g.lineTo(command.x2, command.y2);\n",
  "          g.stroke();\n",
  "        });\n",
  "        break;\n",
  "      case \"text\":\n",
  "        draw(command.c, (g) => {\n",
  "          g.fillStyle = command.color;\n",
  "          g.font = `${command.size}px system-ui, sans-serif`;\n",
  "          g.textBaseline = \"top\";\n",
  "          g.fillText(command.words, command.x, command.y);\n",
  "        });\n",
  "        break;\n",
  "      case \"button\": {\n",
  "        const button = document.createElement(\"button\");\n",
  "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
  "        button.textContent = command.title;\n",
  "        button.addEventListener(\"click\", () => {\n",
  "          startAudio();\n",
  "          report({ ev: \"click\", id: command.id });\n",
  "        });\n",
  "        box.appendChild(button);\n",
  "        break;\n",
  "      }\n",
  "      case \"label\": {\n",
  "        const text = document.createElement(\"div\");\n",
  "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
  "        text.textContent = command.text;\n",
  "        labels.set(command.id, text);\n",
  "        box.appendChild(text);\n",
  "        break;\n",
  "      }\n",
  "      case \"set_label\":\n",
  "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
  "        break;\n",
  "      case \"slider\": {\n",
  "        const row = document.createElement(\"label\");\n",
  "        row.style.cssText = \"display:flex;align-items:center;gap:8px\";\n",
  "        const input = document.createElement(\"input\");\n",
  "        input.type = \"range\";\n",
  "        input.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
  "        input.min = String(command.low);\n",
  "        input.max = String(command.high);\n",
  "        input.value = String(command.value);\n",
  "        const shown = document.createElement(\"span\");\n",
  "        shown.textContent = input.value;\n",
  "        input.addEventListener(\"input\", () => {\n",
  "          shown.textContent = input.value;\n",
  "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n",
  "        });\n",
  "        row.append(input, shown);\n",
  "        box.appendChild(row);\n",
  "        break;\n",
  "      }\n",
  "      case \"load\":\n",
  "        samples.set(command.id, loadSample(command.name));\n",
  "        break;\n",
  "      case \"play\":\n",
  "        play(command);\n",
  "        break;\n",
  "      case \"on_frame\":\n",
  "        if (!frameWanted) {\n",
  "          frameWanted = true;\n",
  "          frameRequest = requestAnimationFrame(frame);\n",
  "        }\n",
  "        break;\n",
  "      case \"frame_done\":\n",
  "        frameWaiting = false;\n",
  "        break;\n",
  "      case \"on_mouse\": {\n",
  "        const entry = canvases.get(command.c);\n",
  "        if (entry) entry.mouse = true;\n",
  "        break;\n",
  "      }\n",
  "      case \"on_key\":\n",
  "        keysWanted = true;\n",
  "        break;\n",
  "    }\n",
  "  }\n",
  "\n",
  "  function freeze() {\n",
  "    if (closed) return;\n",
  "    closed = true;\n",
  "    cancelAnimationFrame(frameRequest);\n",
  "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
  "    if (audio !== null) audio.close();\n",
  "  }\n",
  "\n",
  "  return {\n",
  "    receive(commands) {\n",
  "      if (!closed) for (const command of commands) carryOut(command);\n",
  "    },\n",
  "    // Stops: no more events, frames or sound, and what is shown stays.\n",
  "    freeze,\n",
  "    close() {\n",
  "      freeze();\n",
  "      box.remove();\n",
  "    },\n",
  "  };\n",
  "}\n",
].join("");
// END tinyweb page
