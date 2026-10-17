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

// Every identifier given out so far.
const names = new Set();
let clock = 0;
// Whether an event has been delivered: until one is, the program is in
// its top level, whose sound a page connecting later still plays.
let delivered = false;
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
  const q = (x) => JSON.stringify(x);
  const c = command;
  const named = (id, text) => q(id) + (id === text ? "" : " " + q(text));
  switch (c.op) {
    case "canvas": return `canvas ${q(c.id)} ${c.width} ${c.height}`;
    case "clear": return `clear ${q(c.c)} ${c.color}`;
    case "circle": return `circle ${q(c.c)} ${c.x} ${c.y} ${c.radius} ${c.color}`;
    case "rect": return `rect ${q(c.c)} ${c.x} ${c.y} ${c.width} ${c.height} ${c.color}`;
    case "line": return `line ${q(c.c)} ${c.x1} ${c.y1} ${c.x2} ${c.y2} ${c.color} ${c.width}`;
    case "text": return `text ${q(c.c)} ${c.x} ${c.y} ${c.color} ${c.size} ${q(c.words)}`;
    case "button": return `button ${named(c.id, c.title)}`;
    case "label": return `label ${named(c.id, c.text)}`;
    case "set_label": return `set_label ${q(c.id)} ${q(c.text)}`;
    case "slider": return `slider ${q(c.id)} ${c.low} ${c.high} ${c.value}`;
    case "load": return `load ${named(c.id, c.name)}`;
    case "play": return `play ${q(c.sample)} ${s(c.at)} ${s(c.volume)} ${s(c.rate)}`;
    case "on_mouse": return `on_mouse ${q(c.c)}`;
    case "style": return `style ${q(c.id)} ${c.kind} ${c.prop} ${q(c.value)}`;
    case "splash_text": return `splash_text ${q(c.text)}`;
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

// A new element's identifier: `name`, or `name` with the first number
// from 1 that makes it one nothing on the page has.
function fresh(name) {
  let found = name;
  for (let n = 1; names.has(found); n++) found = name + n;
  names.add(found);
  return found;
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
  const id = fresh("canvas");
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
  const id = fresh(title);
  buttons.set(id, onClick);
  send({ op: "button", id, title });
  return id;
}

export function label(text) {
  ready();
  const id = fresh(text);
  send({ op: "label", id, text });
  return id;
}

export function set_label(id, text) {
  send({ op: "set_label", id, text });
}

export function apply_style(id, kind, property, value) {
  send({ op: "style", id, kind, prop: property, value });
}

export function make_slider(low, high, value, onChange) {
  ready();
  const id = fresh("slider");
  sliders.set(id, onChange);
  send({ op: "slider", id, low, high, value });
  return id;
}

export function load_sample(name) {
  ready();
  const id = fresh(name);
  send({ op: "load", id, name });
  return id;
}

export function play_sample(sample, at, volume, rate) {
  send({ op: "play", sample, at, volume, rate });
}

export function splash() {
  ready();
  send({ op: "splash" });
}

export function set_splash(message) {
  ready();
  send({ op: "splash_text", text: message });
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
  delivered = true;
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
  const kind = line.trim().split(/\s+/)[0];
  const after = line.trim().slice(kind.length).trim();
  if (kind === "frame") {
    const t = Number(after);
    return after !== "" && !Number.isNaN(t) ? { ev: "frame", t } : null;
  }
  // The element is a quoted string, which may hold spaces.
  const quoted = /^"(?:[^"\\]|\\.)*"/.exec(after);
  if (quoted === null) return null;
  let id;
  try {
    id = JSON.parse(quoted[0]);
  } catch {
    return null;
  }
  const rest = after.slice(quoted[0].length).trim();
  const n = rest === "" ? [] : rest.split(/\s+/).map(Number);
  if (n.some(Number.isNaN)) return null;
  switch (kind) {
    case "click": return n.length === 0 ? { ev: "click", id } : null;
    case "slide": return n.length === 1 ? { ev: "slide", id, value: n[0] } : null;
    case "mouse": return n.length === 2 ? { ev: "mouse", c: id, x: n[0], y: n[1] } : null;
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
// been: everything but sound a callback played and frame bookkeeping,
// less what a later command has made invisible.
function kept(history, command) {
  switch (command.op) {
    case "play": return delivered ? history : history.concat([command]);
    case "frame_done": case "event_done": return history;
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
  "  body { margin: 0; padding: 16px; min-height: 100vh; box-sizing: border-box; }\n",
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
  "// BEGIN tinyweb style\n",
  "// The page's look: a theme, what the program changed of it for every\n",
  "// element of a kind, and what it changed of one element. A theme and a\n",
  "// kind's style are rules of a stylesheet of the page's own, scoped to the\n",
  "// element the page is mounted in, so the host page's own rules do not\n",
  "// reach in; one element's style is set on the element. This block is\n",
  "// copied into tinyweb_external_browser.js by tools/tinyweb/embed_page.py.\n",
  "\n",
  "// Each theme: CSS declarations for each place on the page (PLACES).\n",
  "const THEMES = {\n",
  "  light: {\n",
  "    page: { \"background\": \"#f6f6f4\", \"color\": \"#1d1f21\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
  "    box: { \"gap\": \"8px\" },\n",
  "    button: {\n",
  "      \"background\": \"#f0f2f5\", \"color\": \"#1f2328\", \"border\": \"1px solid #d4d8de\",\n",
  "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
  "    },\n",
  "    \"button:hover\": { \"border-color\": \"#2f5fc4\" },\n",
  "    \"button:active\": { \"background\": \"#e3e7ec\" },\n",
  "    \"slider input\": { \"accent-color\": \"#2f5fc4\" },\n",
  "    canvas: { \"border\": \"1px solid #c9ced6\" },\n",
  "  },\n",
  "  dark: {\n",
  "    page: { \"background\": \"#1d1f21\", \"color\": \"#e6e6e6\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
  "    box: { \"gap\": \"8px\" },\n",
  "    button: {\n",
  "      \"background\": \"#2f333a\", \"color\": \"#e6e6e6\", \"border\": \"1px solid #454a52\",\n",
  "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
  "    },\n",
  "    \"button:hover\": { \"border-color\": \"#7aa2f7\" },\n",
  "    \"button:active\": { \"background\": \"#3a3f47\" },\n",
  "    \"slider input\": { \"accent-color\": \"#7aa2f7\" },\n",
  "    canvas: { \"border\": \"1px solid #454a52\" },\n",
  "  },\n",
  "  plain: {\n",
  "    page: { \"background\": \"#ffffff\", \"color\": \"#000000\", \"font-family\": \"system-ui, sans-serif\" },\n",
  "    box: { \"gap\": \"8px\" },\n",
  "    canvas: { \"border\": \"1px solid #8884\" },\n",
  "  },\n",
  "  paper: {\n",
  "    page: { \"background\": \"#fbf6ea\", \"color\": \"#3b3024\", \"font-family\": \"Georgia, 'Times New Roman', serif\", \"font-size\": \"16px\" },\n",
  "    box: { \"gap\": \"10px\" },\n",
  "    button: {\n",
  "      \"background\": \"#fffdf7\", \"color\": \"#3b3024\", \"border\": \"1px solid #3b3024\",\n",
  "      \"border-radius\": \"2px\", \"padding\": \"5px 14px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
  "    },\n",
  "    \"button:hover\": { \"background\": \"#f1e8d2\" },\n",
  "    \"button:active\": { \"background\": \"#e6d9bb\" },\n",
  "    \"slider input\": { \"accent-color\": \"#8a5a2b\" },\n",
  "    canvas: { \"border\": \"1px solid #3b302466\" },\n",
  "  },\n",
  "  retro: {\n",
  "    page: { \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"font-family\": \"'Courier New', monospace\", \"font-size\": \"15px\" },\n",
  "    box: { \"gap\": \"10px\" },\n",
  "    button: {\n",
  "      \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"border\": \"2px solid #39ff6a\",\n",
  "      \"border-radius\": \"0\", \"padding\": \"4px 12px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
  "    },\n",
  "    \"button:hover\": { \"background\": \"#133313\" },\n",
  "    \"button:active\": { \"background\": \"#39ff6a\", \"color\": \"#0b1a0b\" },\n",
  "    \"slider input\": { \"accent-color\": \"#39ff6a\" },\n",
  "    canvas: { \"border\": \"2px solid #39ff6a\" },\n",
  "  },\n",
  "};\n",
  "\n",
  "// Where each place is, after the page's scope.\n",
  "const PLACES = {\n",
  "  page: \"\",\n",
  "  box: \" > .tinyweb-page\",\n",
  "  button: \" .tinyweb-page button\",\n",
  "  \"button:hover\": \" .tinyweb-page button:hover\",\n",
  "  \"button:active\": \" .tinyweb-page button:active\",\n",
  "  label: \" .tinyweb-page .tinyweb-label\",\n",
  "  slider: \" .tinyweb-page .tinyweb-slider\",\n",
  "  \"slider input\": \" .tinyweb-page .tinyweb-slider input\",\n",
  "  canvas: \" .tinyweb-page canvas\",\n",
  "};\n",
  "\n",
  "// What each property a program names is in CSS.\n",
  "const PROPERTIES = {\n",
  "  background: \"background\", color: \"color\", border: \"border\", radius: \"border-radius\",\n",
  "  font: \"font-family\", size: \"font-size\", padding: \"padding\", gap: \"gap\",\n",
  "  accent: \"accent-color\", width: \"width\",\n",
  "};\n",
  "\n",
  "// The place a kind's property goes. String -> String -> String\n",
  "function placeOf(kind, property) {\n",
  "  if (kind === \"page\") return property === \"gap\" ? \"box\" : \"page\";\n",
  "  if (kind === \"slider\") return property === \"accent\" || property === \"width\" ? \"slider input\" : \"slider\";\n",
  "  return kind;\n",
  "}\n",
  "\n",
  "let styledPages = 0;\n",
  "\n",
  "// Gives the page mounted in `host` a stylesheet of its own, in the\n",
  "// default theme. Element -> Element -> Style\n",
  "function styled(host, box) {\n",
  "  styledPages += 1;\n",
  "  const sheet = document.createElement(\"style\");\n",
  "  sheet.setAttribute(\"data-tinyweb-style\", String(styledPages));\n",
  "  const style = { host, box, sheet, rules: null, elements: new Map(), name: String(styledPages) };\n",
  "  host.setAttribute(\"data-tinyweb-page\", style.name);\n",
  "  (document.head || document.body).appendChild(sheet);\n",
  "  setTheme(style, \"light\");\n",
  "  return style;\n",
  "}\n",
  "\n",
  "// Writes the stylesheet from the rules. Style -> ()\n",
  "function writeSheet(style) {\n",
  "  // The scope three times over, so the host page's rules for a button or\n",
  "  // a body do not outweigh the page's own.\n",
  "  const scope = `[data-tinyweb-page=\"${style.name}\"]`.repeat(3);\n",
  "  const text = [];\n",
  "  for (const place of Object.keys(PLACES)) {\n",
  "    const declarations = style.rules[place];\n",
  "    if (!declarations || Object.keys(declarations).length === 0) continue;\n",
  "    const body = Object.entries(declarations).map(([k, v]) => `${k}: ${v};`).join(\" \");\n",
  "    text.push(`${scope}${PLACES[place]} { ${body} }`);\n",
  "  }\n",
  "  style.sheet.textContent = text.join(\"\\n\");\n",
  "}\n",
  "\n",
  "// Puts the page in a theme, forgetting what was changed for each kind.\n",
  "// An unknown name changes nothing. Style -> String -> ()\n",
  "function setTheme(style, name) {\n",
  "  const theme = THEMES[name];\n",
  "  if (!theme) return;\n",
  "  style.rules = {};\n",
  "  for (const [place, declarations] of Object.entries(theme)) {\n",
  "    style.rules[place] = { ...declarations };\n",
  "  }\n",
  "  writeSheet(style);\n",
  "}\n",
  "\n",
  "// Remembers a page element by its id, so that its own style can be set.\n",
  "// Style -> Int -> Element -> ()\n",
  "function remember(style, id, element) {\n",
  "  style.elements.set(id, element);\n",
  "}\n",
  "\n",
  "// Carries out one style command: a theme, a property of every element\n",
  "// of a kind, or a property of the element `id` (kind \"element\").\n",
  "// Style -> Int -> String -> String -> String -> ()\n",
  "function applyStyle(style, id, kind, property, value) {\n",
  "  if (kind === \"theme\") {\n",
  "    setTheme(style, value);\n",
  "    return;\n",
  "  }\n",
  "  const css = PROPERTIES[property];\n",
  "  if (!css) return;\n",
  "  if (kind === \"element\") {\n",
  "    let element = style.elements.get(id);\n",
  "    if (!element) return;\n",
  "    // A slider's own properties are its input's; the rest are its row's.\n",
  "    if (element.tagName === \"INPUT\" && property !== \"accent\" && property !== \"width\") {\n",
  "      element = element.parentNode;\n",
  "    }\n",
  "    element.style.setProperty(css, value);\n",
  "    return;\n",
  "  }\n",
  "  const place = placeOf(kind, property);\n",
  "  if (!(place in PLACES)) return;\n",
  "  if (!style.rules[place]) style.rules[place] = {};\n",
  "  style.rules[place][css] = value;\n",
  "  writeSheet(style);\n",
  "}\n",
  "\n",
  "// Takes the page's look off the element it was mounted in. Style -> ()\n",
  "function unstyled(style) {\n",
  "  style.sheet.remove();\n",
  "  if (style.host.getAttribute(\"data-tinyweb-page\") === style.name) {\n",
  "    style.host.removeAttribute(\"data-tinyweb-page\");\n",
  "  }\n",
  "}\n",
  "// What the splash screen says until the program sets it.\n",
  "const SPLASH_TEXT = \"Click to Start\";\n",
  "\n",
  "// The splash screen: the whole window dimmed, and `text` in white in\n",
  "// its middle under a play sign. String -> Element\n",
  "function splashScreen(text) {\n",
  "  const screen = document.createElement(\"div\");\n",
  "  screen.className = \"tinyweb-splash\";\n",
  "  screen.setAttribute(\"role\", \"button\");\n",
  "  screen.style.cssText =\n",
  "    \"position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;\" +\n",
  "    \"align-items:center;justify-content:center;gap:24px;background:rgba(0,0,0,0.62);\" +\n",
  "    \"color:#ffffff;cursor:pointer;user-select:none;font-family:system-ui,sans-serif\";\n",
  "  const ring = document.createElement(\"div\");\n",
  "  ring.style.cssText =\n",
  "    \"width:88px;height:88px;border-radius:50%;border:3px solid #ffffff;display:flex;\" +\n",
  "    \"align-items:center;justify-content:center;box-shadow:0 0 36px rgba(255,255,255,0.35)\";\n",
  "  const sign = document.createElement(\"div\");\n",
  "  sign.style.cssText =\n",
  "    \"width:0;height:0;margin-left:9px;border-top:19px solid transparent;\" +\n",
  "    \"border-bottom:19px solid transparent;border-left:32px solid #ffffff\";\n",
  "  ring.appendChild(sign);\n",
  "  const words = document.createElement(\"div\");\n",
  "  words.textContent = text;\n",
  "  words.style.cssText =\n",
  "    \"font-size:34px;font-weight:600;letter-spacing:0.03em;text-align:center;\" +\n",
  "    \"padding:0 24px;text-shadow:0 2px 14px rgba(0,0,0,0.6)\";\n",
  "  screen.append(ring, words);\n",
  "  return screen;\n",
  "}\n",
  "\n",
  "// Whether the reader has already done something on this page, which is\n",
  "// all a browser asks before it plays a sound. () -> Bool\n",
  "function readerActive() {\n",
  "  return Boolean(globalThis.navigator?.userActivation?.hasBeenActive);\n",
  "}\n",
  "// END tinyweb style\n",
  "\n",
  "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n",
  "// `receive(commands)` carries out a batch of commands, and `send(event)`\n",
  "// is how the page reports one. `standalone` is true where the page is\n",
  "// the whole document, which is where a key press is listened for; a\n",
  "// page inside another (a notebook cell) listens on `element`, which\n",
  "// takes the focus when clicked. `activated` is true where the reader\n",
  "// started the program with a click or a key, as in the playground and\n",
  "// a notebook, and the page then never shows the splash screen.\n",
  "export function mountPage(element, sendEvent, { standalone = false, activated = false } = {}) {\n",
  "  const box = document.createElement(\"div\");\n",
  "  box.className = \"tinyweb-page\";\n",
  "  box.style.cssText =\n",
  "    \"display:flex;flex-direction:column;align-items:flex-start;outline:none\";\n",
  "  element.appendChild(box);\n",
  "  const look = styled(element, box);\n",
  "\n",
  "  const canvases = new Map();\n",
  "  const labels = new Map();\n",
  "  const samples = new Map();\n",
  "  let start = now();\n",
  "  let audio = null;\n",
  "  let offset = 0;\n",
  "  let frameWanted = false;\n",
  "  let frameWaiting = false;\n",
  "  let frameRequest = 0;\n",
  "  let closed = false;\n",
  "  // Inside another page the keys go to the element the page is mounted\n",
  "  // in, which takes the focus when anything in it is clicked; that page\n",
  "  // shows the focus (:focus-within).\n",
  "  const keyTarget = standalone ? window : element;\n",
  "  let keysWanted = false;\n",
  "  // The splash screen: what it says, whether it has been shown (or is\n",
  "  // not needed), and while it is shown the element, the commands held\n",
  "  // until it is dismissed, and the clock where it stopped.\n",
  "  let splashText = SPLASH_TEXT;\n",
  "  let splashDone = activated;\n",
  "  let splash = null;\n",
  "  let held = null;\n",
  "  let heldClock = 0;\n",
  "  let heldAt = 0;\n",
  "\n",
  "  let focusable = false;    // whether mounting made `element` focusable\n",
  "\n",
  "  function takeFocus(event) {\n",
  "    // A slider keeps the focus for its arrow keys.\n",
  "    if (!event.target.closest(\"input\")) element.focus({ preventScroll: true });\n",
  "  }\n",
  "\n",
  "  if (!standalone) {\n",
  "    focusable = element.tabIndex < 0;\n",
  "    if (focusable) element.tabIndex = 0;\n",
  "    element.addEventListener(\"click\", takeFocus);\n",
  "  }\n",
  "\n",
  "  // The page's clock: the audio clock once sound has started, and until\n",
  "  // then the seconds since the page was mounted. `offset` joins the two,\n",
  "  // so the clock never goes back.\n",
  "  function running() {\n",
  "    return audio !== null && audio.state === \"running\";\n",
  "  }\n",
  "\n",
  "  function clockNow() {\n",
  "    if (held !== null) return heldClock;\n",
  "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
  "  }\n",
  "\n",
  "  function report(event) {\n",
  "    if (!closed && held === null) sendEvent({ ...event, t: clockNow(), running: running() });\n",
  "  }\n",
  "\n",
  "  // Whether a sound now would need the splash screen first.\n",
  "  function splashWanted() {\n",
  "    return !splashDone && splashText !== \"\" && !running() && !readerActive();\n",
  "  }\n",
  "\n",
  "  // Shows the splash screen and holds what comes after it: the commands,\n",
  "  // the frames and the clock.\n",
  "  function showSplash() {\n",
  "    splashDone = true;\n",
  "    heldClock = clockNow();\n",
  "    heldAt = now();\n",
  "    held = [];\n",
  "    splash = splashScreen(splashText);\n",
  "    splash.addEventListener(\"click\", dismissSplash);\n",
  "    window.addEventListener(\"keydown\", dismissSplash, true);\n",
  "    document.body.appendChild(splash);\n",
  "  }\n",
  "\n",
  "  // The reader's click or key: the splash screen goes, sound starts, the\n",
  "  // clock goes on from where it stopped, and what was held is carried out.\n",
  "  function dismissSplash(event) {\n",
  "    if (held === null) return;\n",
  "    event?.preventDefault?.();\n",
  "    event?.stopImmediatePropagation?.();\n",
  "    window.removeEventListener(\"keydown\", dismissSplash, true);\n",
  "    splash.remove();\n",
  "    splash = null;\n",
  "    start += now() - heldAt;\n",
  "    const pending = held;\n",
  "    held = null;\n",
  "    startAudio();\n",
  "    for (const command of pending) carryOut(command);\n",
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
  "    if (held !== null) {\n",
  "      dismissSplash(event);\n",
  "      return;\n",
  "    }\n",
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
  "    if (!frameWaiting && held === null) {\n",
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
  "    element.style.background = \"#ffffff\";\n",
  "    const context = element.getContext(\"2d\");\n",
  "    context.scale(ratio, ratio);\n",
  "    canvases.set(id, { element, context, width, height, mouse: false });\n",
  "    remember(look, id, element);\n",
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
  "        remember(look, command.id, button);\n",
  "        box.appendChild(button);\n",
  "        break;\n",
  "      }\n",
  "      case \"label\": {\n",
  "        const text = document.createElement(\"div\");\n",
  "        text.className = \"tinyweb-label\";\n",
  "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
  "        text.textContent = command.text;\n",
  "        labels.set(command.id, text);\n",
  "        remember(look, command.id, text);\n",
  "        box.appendChild(text);\n",
  "        break;\n",
  "      }\n",
  "      case \"set_label\":\n",
  "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
  "        break;\n",
  "      case \"slider\": {\n",
  "        const row = document.createElement(\"label\");\n",
  "        row.className = \"tinyweb-slider\";\n",
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
  "        remember(look, command.id, input);\n",
  "        box.appendChild(row);\n",
  "        break;\n",
  "      }\n",
  "      case \"style\":\n",
  "        applyStyle(look, command.id, command.kind, command.prop, command.value);\n",
  "        break;\n",
  "      case \"load\":\n",
  "        samples.set(command.id, loadSample(command.name));\n",
  "        break;\n",
  "      case \"play\":\n",
  "        if (splashWanted()) {\n",
  "          showSplash();\n",
  "          held.push(command);\n",
  "        } else {\n",
  "          play(command);\n",
  "        }\n",
  "        break;\n",
  "      case \"splash\":\n",
  "        if (splashWanted()) showSplash();\n",
  "        break;\n",
  "      case \"splash_text\":\n",
  "        splashText = command.text;\n",
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
  "        // Inside another page the keys go where the focus is, which is\n",
  "        // still the Run button that started the program; one typing in\n",
  "        // an editor keeps it.\n",
  "        if (!standalone && !typing()) element.focus({ preventScroll: true });\n",
  "        break;\n",
  "    }\n",
  "  }\n",
  "\n",
  "  function typing() {\n",
  "    const active = document.activeElement;\n",
  "    return !!active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));\n",
  "  }\n",
  "\n",
  "  function freeze() {\n",
  "    if (closed) return;\n",
  "    closed = true;\n",
  "    cancelAnimationFrame(frameRequest);\n",
  "    if (splash !== null) {\n",
  "      window.removeEventListener(\"keydown\", dismissSplash, true);\n",
  "      splash.remove();\n",
  "    }\n",
  "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
  "    if (!standalone) element.removeEventListener(\"click\", takeFocus);\n",
  "    if (audio !== null) audio.close();\n",
  "  }\n",
  "\n",
  "  return {\n",
  "    receive(commands) {\n",
  "      if (closed) return;\n",
  "      for (const command of commands) {\n",
  "        if (held !== null) held.push(command);\n",
  "        else carryOut(command);\n",
  "      }\n",
  "    },\n",
  "    // Stops: no more events, frames or sound, and what is shown stays.\n",
  "    freeze,\n",
  "    close() {\n",
  "      freeze();\n",
  "      box.remove();\n",
  "      unstyled(look);\n",
  "      if (focusable) {\n",
  "        element.removeAttribute(\"tabindex\");\n",
  "        element.blur();\n",
  "      }\n",
  "    },\n",
  "  };\n",
  "}\n",
].join("");
// END tinyweb page
