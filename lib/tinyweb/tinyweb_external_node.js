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
const checks = new Map();
const radios = new Map();
const choices = new Map();
const texts = new Map();
const mice = new Map();
const frames = [];
const keys = [];
const keyUps = [];
// The keys held down now, from the key events delivered so far.
const down = new Set();
let keysOn = false;
// Each canvas's pointer: the functions watching it, by kind, and where
// it was last seen.
const pointers = new Map();
const measures = new Map();
const bitmaps = new Map();
let after = false;
let hub = null;

// --- commands ---

const quote = (text) => JSON.stringify(text);

// A number with three digits after the point, as C's "%.3f" writes it:
// a number exactly halfway between two is rounded to the even one, where
// toFixed would round it up. Float -> String
function fixed3(x) {
  if (!Number.isFinite(x)) return String(x);
  const negative = x < 0 || Object.is(x, -0);
  const a = Math.abs(x);
  // Halfway exactly only where a is a multiple of 1/16 ending in 5 at
  // the fourth place, which a double holds exactly.
  if (Number.isInteger(a * 16) && a.toFixed(4).endsWith("5")) {
    const below = Math.floor(a * 1000);
    const even = below % 2 === 0 ? below : below + 1;
    return (negative ? "-" : "") + (even / 1000).toFixed(3);
  }
  return (negative ? "-" : "") + a.toFixed(3);
}

// A command as the one line every headless implementation writes.
function logLine(command) {
  const s = fixed3;
  const q = (x) => JSON.stringify(x);
  const c = command;
  const named = (id, text) => q(id) + (id === text ? "" : " " + q(text));
  switch (c.op) {
    case "canvas": return `canvas ${q(c.id)} ${c.width} ${c.height}`;
    case "clear": return `clear ${q(c.c)} ${c.color}`;
    case "shape":
      return `${c.kind} ${q(c.c)} ${typeof c.numbers === "string" ? c.numbers : c.numbers.map(s).join(" ")} ` +
        `${q(c.color)} ${q(c.outline)} ${s(c.width)} ${s(c.alpha)}`;
    case "text":
      return `text ${q(c.c)} ${s(c.x)} ${s(c.y)} ${q(c.color)} ${c.size} ${q(c.font)} ${c.align} ` +
        `${c.baseline} ${c.bold} ${q(c.outline)} ${s(c.outline_width)} ${s(c.alpha)} ${q(c.words)}`;
    case "measure": return `measure ${q(c.id)} ${c.size} ${q(c.font)} ${c.bold} ${q(c.words)}`;
    case "on_pointer": return `on_pointer ${q(c.c)}`;
    case "row": case "column": case "inside": return `${c.op} ${q(c.id)}`;
    case "bitmap":
      return `bitmap ${q(c.c)} ${q(c.id)} ${c.x} ${c.y} ${s(c.scale)} ${c.width} ${c.height} ` +
        `${c.rect.join(" ")} ${c.digest}`;
    case "state":
      return [c.kind, q(c.c)].concat(c.value === "" ? [] : [q(c.value)])
        .concat(c.numbers === "" ? [] : [c.numbers]).join(" ");
    case "image_load": return `load_image ${named(c.id, c.name)}`;
    case "image":
      return `image ${q(c.c)} ${q(c.picture)} ${c.x} ${c.y} ${c.width} ${c.height} ${s(c.alpha)}`;
    case "button": return `button ${named(c.id, c.title)}`;
    case "label": return `label ${named(c.id, c.text)}`;
    case "set_label": return `set_label ${q(c.id)} ${q(c.text)}`;
    case "slider": return `slider ${q(c.id)} ${c.low} ${c.high} ${c.value}`;
    case "checkbox": return `checkbox ${named(c.id, c.title)} ${c.checked}`;
    case "radio": return `radio ${named(c.id, c.title)} ${q(c.group)} ${c.chosen}`;
    case "choice": return `choice ${q(c.id)} ${c.chosen} ${q(c.options)}`;
    case "text_input": return `text_input ${named(c.id, c.placeholder)}`;
    case "number": return `number ${q(c.id)} ${c.low} ${c.high} ${c.value}`;
    case "set_checked": return `set_checked ${q(c.id)} ${c.checked}`;
    case "set_value": return `set_value ${q(c.id)} ${c.value}`;
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

export function web_start(port) {
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

export function draw_shape(c, kind, numbers, color, outline, width, alpha) {
  send({ op: "shape", c, kind, numbers, color, outline, width, alpha });
}

// A list of tuples as the one array of numbers the page reads.
// [[Float]] -> [Float]
function flat(items) {
  const numbers = [];
  for (const item of items) for (const x of item) numbers.push(x);
  return numbers;
}

export function draw_pairs(c, kind, items, color, outline, width, alpha) {
  draw_shape(c, kind, flat(items), color, outline, width, alpha);
}

export function draw_triples(c, kind, items, color, outline, width, alpha) {
  draw_shape(c, kind, flat(items), color, outline, width, alpha);
}

export function draw_quads(c, kind, items, color, outline, width, alpha) {
  draw_shape(c, kind, flat(items), color, outline, width, alpha);
}

export function draw_text(c, x, y, words, color, size, font, align, baseline, bold, outline,
  outlineWidth, alpha) {
  send({ op: "text", c, x, y, words, color, size, font, align, baseline, bold, outline,
    outline_width: outlineWidth, alpha });
}

export function measure(words, size, font, bold, answer) {
  ready();
  const id = fresh("measure");
  measures.set(id, answer);
  send({ op: "measure", id, words, size, font, bold });
}

export function watch_pointer(c, kind, f) {
  ready();
  if (!pointers.has(c)) {
    pointers.set(c, { press: [], release: [], move: [], drag: [], x: 0, y: 0, down: false });
    send({ op: "on_pointer", c });
  }
  const seen = pointers.get(c);
  if (Array.isArray(seen[kind])) seen[kind].push(f);
}

export function pointer(c, which) {
  ready();
  const seen = pointers.get(c);
  if (seen === undefined) return 0;
  if (which === "x") return seen.x;
  if (which === "y") return seen.y;
  return seen.down ? 1 : 0;
}

// --- bitmaps ---

// FNV-1a, 32 bits, of the bytes: what the log says of a bitmap's pixels.
function digest(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 16777619) >>> 0;
  return h.toString(16).padStart(8, "0");
}

export function bitmap(width, height) {
  ready();
  const id = fresh("bitmap");
  const w = Math.max(1, width);
  const h = Math.max(1, height);
  const data = new Uint8Array(w * h * 4);
  for (let i = 3; i < data.length; i += 4) data[i] = 255;
  bitmaps.set(id, { width: w, height: h, data, x1: 0, y1: 0, x2: w, y2: h });
  return id;
}

export function set_pixel(b, x, y, color) {
  const bm = bitmaps.get(b);
  if (bm === undefined || x < 0 || y < 0 || x >= bm.width || y >= bm.height) return;
  const at = (y * bm.width + x) * 4;
  bm.data[at] = (color >> 16) & 255;
  bm.data[at + 1] = (color >> 8) & 255;
  bm.data[at + 2] = color & 255;
  if (x < bm.x1) bm.x1 = x;
  if (y < bm.y1) bm.y1 = y;
  if (x >= bm.x2) bm.x2 = x + 1;
  if (y >= bm.y2) bm.y2 = y + 1;
}

export function get_pixel(b, x, y) {
  const bm = bitmaps.get(b);
  if (bm === undefined || x < 0 || y < 0 || x >= bm.width || y >= bm.height) return 0;
  const at = (y * bm.width + x) * 4;
  return (bm.data[at] << 16) | (bm.data[at + 1] << 8) | bm.data[at + 2];
}

export function fill_bitmap(b, color) {
  const bm = bitmaps.get(b);
  if (bm === undefined) return;
  for (let at = 0; at < bm.data.length; at += 4) {
    bm.data[at] = (color >> 16) & 255;
    bm.data[at + 1] = (color >> 8) & 255;
    bm.data[at + 2] = color & 255;
  }
  Object.assign(bm, { x1: 0, y1: 0, x2: bm.width, y2: bm.height });
}

export function draw_bitmap(c, b, x, y, scale) {
  const bm = bitmaps.get(b);
  if (bm === undefined) return;
  const changed = bm.x2 > bm.x1 && bm.y2 > bm.y1;
  const rect = changed ? [bm.x1, bm.y1, bm.x2 - bm.x1, bm.y2 - bm.y1] : [0, 0, 0, 0];
  const [rx, ry, rw, rh] = rect;
  const bytes = new Uint8Array(rw * rh * 4);
  for (let r = 0; r < rh; r++) {
    const from = ((ry + r) * bm.width + rx) * 4;
    bytes.set(bm.data.subarray(from, from + rw * 4), r * rw * 4);
  }
  Object.assign(bm, { x1: bm.width, y1: bm.height, x2: 0, y2: 0 });
  send({ op: "bitmap", c, id: b, width: bm.width, height: bm.height, x, y, scale, rect,
    data: Buffer.from(bytes).toString("base64"), digest: digest(bytes) });
}

export function set_state(c, kind, value, numbers) {
  send({ op: "state", c, kind, value, numbers });
}

export function load_image(name) {
  ready();
  const id = fresh(name);
  send({ op: "image_load", id, name });
  return id;
}

export function draw_image(c, picture, x, y, width, height, alpha) {
  send({ op: "image", c, picture, x, y, width, height, alpha });
}

export function make_checkbox(title, checked, onChange) {
  ready();
  const id = fresh(title);
  checks.set(id, onChange);
  send({ op: "checkbox", id, title, checked });
  return id;
}

export function make_radio(group, title, chosen, onPick) {
  ready();
  const id = fresh(title);
  radios.set(id, () => onPick(title));
  send({ op: "radio", id, group, title, chosen });
  return id;
}

export function make_choice(options, chosen, onChange) {
  ready();
  const id = fresh("choice");
  choices.set(id, onChange);
  send({ op: "choice", id, options, chosen });
  return id;
}

export function make_text_input(placeholder, onEnter) {
  ready();
  const id = fresh(placeholder === "" ? "text" : placeholder);
  texts.set(id, onEnter);
  send({ op: "text_input", id, placeholder });
  return id;
}

export function make_number_input(low, high, value, onChange) {
  ready();
  const id = fresh("number");
  sliders.set(id, onChange);
  send({ op: "number", id, low, high, value });
  return id;
}

export function set_checked(id, checked) {
  send({ op: "set_checked", id, checked });
}

export function set_value(id, value) {
  send({ op: "set_value", id, value });
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

export function row() {
  ready();
  const id = fresh("row");
  send({ op: "row", id });
  return id;
}

export function column() {
  ready();
  const id = fresh("column");
  send({ op: "column", id });
  return id;
}

export function inside(id) {
  send({ op: "inside", id });
}

export function outside() {
  send({ op: "outside" });
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

export function on_key_up(released) {
  ready();
  keyUps.push(released);
  send({ op: "on_key" });
}

export function key_down(key) {
  ready();
  if (!keysOn && keys.length === 0 && keyUps.length === 0) {
    keysOn = true;
    send({ op: "on_key" });
  }
  return down.has(key);
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
    case "check":
      if (checks.has(event.id)) checks.get(event.id)(event.checked === true);
      break;
    case "pick":
      if (radios.has(event.id)) radios.get(event.id)();
      break;
    case "choose":
      if (choices.has(event.id)) choices.get(event.id)(Math.trunc(event.value));
      break;
    case "enter":
      if (texts.has(event.id)) texts.get(event.id)(String(event.text));
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
      down.add(String(event.key));
      for (const pressed of keys.slice()) pressed(String(event.key));
      break;
    case "key_up":
      down.delete(String(event.key));
      for (const released of keyUps.slice()) released(String(event.key));
      break;
    case "press":
    case "release":
    case "move": {
      const seen = pointers.get(event.c);
      if (seen === undefined) break;
      seen.x = Math.trunc(event.x);
      seen.y = Math.trunc(event.y);
      if (event.ev === "press") seen.down = true;
      if (event.ev === "release") seen.down = false;
      const kinds = event.ev === "move" && seen.down ? ["move", "drag"] : [event.ev];
      for (const kind of kinds) for (const f of seen[kind].slice()) f(seen.x, seen.y);
      break;
    }
    case "measured": {
      const answer = measures.get(event.id);
      if (answer === undefined) break;
      measures.delete(event.id);
      answer(Number(event.width));
      break;
    }
  }
}

// One line of an events file as the event the page would send.
function parseEvent(line) {
  if (line.startsWith("key ")) return { ev: "key", key: line.slice(4) };
  if (line.startsWith("key_up ")) return { ev: "key_up", key: line.slice(7) };
  const kind = line.trim().split(/\s+/)[0];
  const after = line.trim().slice(kind.length).trim();
  if (kind === "frame") {
    const t = Number(after);
    return after !== "" && !Number.isNaN(t) ? { ev: "frame", t } : null;
  }
  // The element is a quoted string, which may hold spaces; so is the text
  // an `enter` carries.
  const quoted = /^"(?:[^"\\]|\\.)*"/;
  const first = quoted.exec(after);
  if (first === null) return null;
  let id;
  try {
    id = JSON.parse(first[0]);
  } catch {
    return null;
  }
  const rest = after.slice(first[0].length).trim();
  if (kind === "enter") {
    const second = quoted.exec(rest);
    if (second === null || rest.slice(second[0].length).trim() !== "") return null;
    try {
      return { ev: "enter", id, text: JSON.parse(second[0]) };
    } catch {
      return null;
    }
  }
  const words = rest === "" ? [] : rest.split(/\s+/);
  if (kind === "check") {
    return words.length === 1 && (words[0] === "true" || words[0] === "false")
      ? { ev: "check", id, checked: words[0] === "true" } : null;
  }
  const n = words.map(Number);
  if (n.some(Number.isNaN)) return null;
  switch (kind) {
    case "click": return n.length === 0 ? { ev: "click", id } : null;
    case "pick": return n.length === 0 ? { ev: "pick", id } : null;
    case "slide": return n.length === 1 ? { ev: "slide", id, value: n[0] } : null;
    case "choose": return n.length === 1 ? { ev: "choose", id, value: n[0] } : null;
    case "mouse": case "press": case "release": case "move":
      return n.length === 2 ? { ev: kind, c: id, x: n[0], y: n[1] } : null;
    case "measured": return n.length === 1 ? { ev: "measured", id, width: n[0] } : null;
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

const DRAWING = new Set(["clear", "shape", "text", "state", "image", "bitmap"]);

// The commands a page connecting now has to be sent, once `command` has
// been: everything but sound a callback played and frame bookkeeping,
// less what a later command has made invisible.
function kept(history, command) {
  switch (command.op) {
    case "play": return delivered ? history : history.concat([command]);
    case "frame_done": case "event_done": return history;
    case "clear":
      return history.filter((h) => !(DRAWING.has(h.op) && h.c === command.c)).concat([command]);
    case "set_label": case "set_checked": case "set_value":
      return history.filter((h) => !(h.op === command.op && h.id === command.id))
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
  "  accent: \"accent-color\", width: \"width\", height: \"height\", align: \"align-items\",\n",
  "  weight: \"font-weight\",\n",
  "};\n",
  "\n",
  "// What an `align` a program names is in CSS.\n",
  "const ALIGNMENTS = { left: \"flex-start\", center: \"center\", right: \"flex-end\" };\n",
  "\n",
  "// The place a kind's property goes. String -> String -> String\n",
  "function placeOf(kind, property) {\n",
  "  if (kind === \"page\") return property === \"gap\" || property === \"align\" ? \"box\" : \"page\";\n",
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
  "function applyStyle(style, id, kind, property, given) {\n",
  "  if (kind === \"theme\") {\n",
  "    setTheme(style, given);\n",
  "    return;\n",
  "  }\n",
  "  const css = PROPERTIES[property];\n",
  "  if (!css) return;\n",
  "  const value = property === \"align\" ? ALIGNMENTS[given] || \"flex-start\" : given;\n",
  "  if (kind === \"page\" && property === \"align\") {\n",
  "    // The box says where its elements stand on the element itself.\n",
  "    style.box.style.setProperty(css, value);\n",
  "    return;\n",
  "  }\n",
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
  "// --- drawing (step 1) ---\n",
  "\n",
  "// A shape's numbers: the words tinyweb.pyk wrote, as numbers.\n",
  "function numbersOf(text) {\n",
  "  return text === \"\" ? [] : text.split(\" \").map(Number);\n",
  "}\n",
  "\n",
  "// A rectangle with rounded corners, as a path. Context -> ... -> ()\n",
  "function roundedRect(g, x, y, w, h, r) {\n",
  "  const k = Math.max(0, Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2));\n",
  "  g.moveTo(x + k, y);\n",
  "  g.arcTo(x + w, y, x + w, y + h, k);\n",
  "  g.arcTo(x + w, y + h, x, y + h, k);\n",
  "  g.arcTo(x, y + h, x, y, k);\n",
  "  g.arcTo(x, y, x + w, y, k);\n",
  "  g.closePath();\n",
  "}\n",
  "\n",
  "// The outline of one shape, added to the context's path. Whether a filled\n",
  "// arc is a slice from its centre is `slice`'s.\n",
  "// Context -> String -> [Float] -> Bool -> ()\n",
  "function shapePath(g, kind, n, slice) {\n",
  "  const degrees = Math.PI / 180;\n",
  "  switch (kind) {\n",
  "    case \"rect\":\n",
  "      if (n[4] > 0) roundedRect(g, n[0], n[1], n[2], n[3], n[4]);\n",
  "      else g.rect(n[0], n[1], n[2], n[3]);\n",
  "      break;\n",
  "    case \"circle\":\n",
  "      g.arc(n[0], n[1], Math.max(0, n[2]), 0, 2 * Math.PI);\n",
  "      break;\n",
  "    case \"ellipse\":\n",
  "      g.ellipse(n[0], n[1], Math.max(0, n[2]), Math.max(0, n[3]), 0, 0, 2 * Math.PI);\n",
  "      break;\n",
  "    case \"arc\":\n",
  "      if (slice) g.moveTo(n[0], n[1]);\n",
  "      g.arc(n[0], n[1], Math.max(0, n[2]), n[3] * degrees, n[4] * degrees);\n",
  "      if (slice) g.closePath();\n",
  "      break;\n",
  "    case \"line\":\n",
  "      g.moveTo(n[0], n[1]);\n",
  "      g.lineTo(n[2], n[3]);\n",
  "      break;\n",
  "    case \"lines\":\n",
  "      for (let i = 0; i + 3 < n.length; i += 4) {\n",
  "        g.moveTo(n[i], n[i + 1]);\n",
  "        g.lineTo(n[i + 2], n[i + 3]);\n",
  "      }\n",
  "      break;\n",
  "    case \"curve\":\n",
  "      g.moveTo(n[0], n[1]);\n",
  "      g.quadraticCurveTo(n[2], n[3], n[4], n[5]);\n",
  "      break;\n",
  "    case \"bezier\":\n",
  "      g.moveTo(n[0], n[1]);\n",
  "      g.bezierCurveTo(n[2], n[3], n[4], n[5], n[6], n[7]);\n",
  "      break;\n",
  "    case \"polygon\":\n",
  "    case \"path\":\n",
  "      for (let i = 0; i + 1 < n.length; i += 2) {\n",
  "        if (i === 0) g.moveTo(n[i], n[i + 1]);\n",
  "        else g.lineTo(n[i], n[i + 1]);\n",
  "      }\n",
  "      if (kind === \"polygon\") g.closePath();\n",
  "      break;\n",
  "  }\n",
  "}\n",
  "\n",
  "// The gradients a canvas has been given, by the text that describes\n",
  "// them, so a frame drawing the same one again does not make it again.\n",
  "const GRADIENTS_KEPT = 64;\n",
  "\n",
  "// What a color means on a context: a CSS color as it is, and a gradient\n",
  "// tinyweb.pyk described -- \"linear-gradient(x1 y1 x2 y2); 0 red; 1 blue\",\n",
  "// \"radial-gradient(x1 y1 r1 x2 y2 r2); ...\", \"conic-gradient(x y\n",
  "// angle); ...\" -- as the gradient. Context -> Entry? -> String -> Paint\n",
  "function paint(g, entry, color) {\n",
  "  const open = color.indexOf(\"(\");\n",
  "  if (open < 0 || !color.slice(0, open).endsWith(\"-gradient\")) return color;\n",
  "  const close = color.indexOf(\")\", open);\n",
  "  if (close < 0 || color.slice(close + 1, close + 2) !== \";\") return color;\n",
  "  const kept = entry ? entry.gradients : null;\n",
  "  if (kept && kept.has(color)) return kept.get(color);\n",
  "  const kind = color.slice(0, open);\n",
  "  const n = numbersOf(color.slice(open + 1, close).trim());\n",
  "  let gradient;\n",
  "  if (kind === \"linear-gradient\") gradient = g.createLinearGradient(n[0], n[1], n[2], n[3]);\n",
  "  else if (kind === \"radial-gradient\")\n",
  "    gradient = g.createRadialGradient(n[0], n[1], Math.max(0, n[2]), n[3], n[4], Math.max(0, n[5]));\n",
  "  else if (kind === \"conic-gradient\" && typeof g.createConicGradient === \"function\")\n",
  "    gradient = g.createConicGradient((n[2] * Math.PI) / 180, n[0], n[1]);\n",
  "  else return \"#000000\";\n",
  "  // A stop's color may itself hold brackets and commas, \"rgba(0, 0, 0, 0.5)\",\n",
  "  // but never a semicolon.\n",
  "  for (const stop of color.slice(close + 2).split(\";\")) {\n",
  "    const text = stop.trim();\n",
  "    const space = text.indexOf(\" \");\n",
  "    if (space < 0) continue;\n",
  "    const at = Math.min(1, Math.max(0, Number(text.slice(0, space))));\n",
  "    try {\n",
  "      gradient.addColorStop(at, text.slice(space + 1).trim());\n",
  "    } catch (error) {\n",
  "      // A stop whose color the browser does not read is left out.\n",
  "    }\n",
  "  }\n",
  "  if (kept) {\n",
  "    if (kept.size >= GRADIENTS_KEPT) kept.delete(kept.keys().next().value);\n",
  "    kept.set(color, gradient);\n",
  "  }\n",
  "  return gradient;\n",
  "}\n",
  "\n",
  "// Draws one shape: filled with `color` and outlined with `outline`, each\n",
  "// unless it is \"\", at `alpha`, in the canvas's line style. The numbers\n",
  "// are the kind's own (see tinyweb.pyk), as words or as an array;\n",
  "// \"erase\" makes its rectangle transparent, and \"circles\" draws each\n",
  "// circle on its own. Context -> Entry? -> String -> Numbers -> ... -> ()\n",
  "function drawShape(g, entry, kind, numbers, color, outline, width, alpha) {\n",
  "  const n = typeof numbers === \"string\" ? numbersOf(numbers) : numbers;\n",
  "  if (kind === \"erase\") {\n",
  "    g.clearRect(n[0], n[1], n[2], n[3]);\n",
  "    return;\n",
  "  }\n",
  "  const before = g.globalAlpha;\n",
  "  g.globalAlpha = before * alpha;\n",
  "  if (kind === \"circles\") {\n",
  "    // Each circle on its own, so where two overlap both show.\n",
  "    if (color !== \"\") g.fillStyle = paint(g, entry, color);\n",
  "    if (outline !== \"\") {\n",
  "      g.strokeStyle = paint(g, entry, outline);\n",
  "      g.lineWidth = width;\n",
  "    }\n",
  "    for (let i = 0; i + 2 < n.length; i += 3) {\n",
  "      g.beginPath();\n",
  "      g.arc(n[i], n[i + 1], Math.max(0, n[i + 2]), 0, 2 * Math.PI);\n",
  "      if (color !== \"\") g.fill();\n",
  "      if (outline !== \"\") g.stroke();\n",
  "    }\n",
  "    g.globalAlpha = before;\n",
  "    return;\n",
  "  }\n",
  "  g.beginPath();\n",
  "  shapePath(g, kind, n, color !== \"\");\n",
  "  if (color !== \"\") {\n",
  "    g.fillStyle = paint(g, entry, color);\n",
  "    g.fill();\n",
  "  }\n",
  "  if (outline !== \"\") {\n",
  "    g.strokeStyle = paint(g, entry, outline);\n",
  "    g.lineWidth = width;\n",
  "    g.stroke();\n",
  "  }\n",
  "  g.globalAlpha = before;\n",
  "}\n",
  "\n",
  "// The font text is written in. Int -> String -> Bool -> String\n",
  "function fontOf(size, font, bold) {\n",
  "  return `${bold ? \"bold \" : \"\"}${size}px ${font === \"\" ? \"system-ui, sans-serif\" : font}`;\n",
  "}\n",
  "\n",
  "// Writes text at (x, y): its left end there, its middle or its right end,\n",
  "// as `align` says, and its top, middle, alphabetic baseline or bottom,\n",
  "// as `baseline` says. An `outline` is drawn round the letters first.\n",
  "// Context -> Entry? -> ... -> ()\n",
  "function drawText(g, entry, x, y, words, color, size, font, align, baseline, bold, outline,\n",
  "  outlineWidth, alpha) {\n",
  "  const before = g.globalAlpha;\n",
  "  g.globalAlpha = before * alpha;\n",
  "  g.font = fontOf(size, font, bold);\n",
  "  g.textBaseline = [\"top\", \"middle\", \"alphabetic\", \"bottom\"].includes(baseline) ? baseline : \"top\";\n",
  "  g.textAlign = align === \"center\" || align === \"right\" ? align : \"left\";\n",
  "  if (outline !== \"\") {\n",
  "    g.strokeStyle = paint(g, entry, outline);\n",
  "    g.lineWidth = outlineWidth;\n",
  "    g.strokeText(words, x, y);\n",
  "  }\n",
  "  if (color !== \"\") {\n",
  "    g.fillStyle = paint(g, entry, color);\n",
  "    g.fillText(words, x, y);\n",
  "  }\n",
  "  g.globalAlpha = before;\n",
  "}\n",
  "\n",
  "// How wide `words` is written in that font, in pixels.\n",
  "// String -> Int -> String -> Bool -> Float\n",
  "function textWidth(words, size, font, bold) {\n",
  "  if (typeof document === \"undefined\") return 0;\n",
  "  if (!textWidth.context) textWidth.context = document.createElement(\"canvas\").getContext(\"2d\");\n",
  "  const g = textWidth.context;\n",
  "  if (!g) return 0;\n",
  "  g.font = fontOf(size, font, bold);\n",
  "  return g.measureText(words).width;\n",
  "}\n",
  "\n",
  "// The line style a canvas starts with: round ends and corners, no dashes.\n",
  "// Context -> ()\n",
  "function plainLines(g) {\n",
  "  g.lineCap = \"round\";\n",
  "  g.lineJoin = \"round\";\n",
  "  if (typeof g.setLineDash === \"function\") g.setLineDash([]);\n",
  "  g.lineDashOffset = 0;\n",
  "}\n",
  "\n",
  "// Changes what the next drawing on a canvas is drawn with. `entry` keeps\n",
  "// the canvas's pixel ratio and how many `push`es are open.\n",
  "// Context -> Entry -> String -> String -> String -> ()\n",
  "function canvasState(g, entry, kind, value, numbers) {\n",
  "  const n = numbersOf(numbers);\n",
  "  switch (kind) {\n",
  "    case \"translate\":\n",
  "      g.translate(n[0], n[1]);\n",
  "      break;\n",
  "    case \"rotate\":\n",
  "      g.rotate((n[0] * Math.PI) / 180);\n",
  "      break;\n",
  "    case \"scale\":\n",
  "      g.scale(n[0], n[1]);\n",
  "      break;\n",
  "    case \"push\":\n",
  "      g.save();\n",
  "      entry.depth += 1;\n",
  "      break;\n",
  "    case \"pop\":\n",
  "      if (entry.depth > 0) {\n",
  "        g.restore();\n",
  "        entry.depth -= 1;\n",
  "      }\n",
  "      break;\n",
  "    case \"reset\":\n",
  "      g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
  "      break;\n",
  "    case \"shadow\":\n",
  "      g.shadowColor = value === \"\" ? \"transparent\" : value;\n",
  "      g.shadowBlur = value === \"\" ? 0 : n[0];\n",
  "      g.shadowOffsetX = value === \"\" ? 0 : n[1];\n",
  "      g.shadowOffsetY = value === \"\" ? 0 : n[2];\n",
  "      break;\n",
  "    case \"blend\":\n",
  "      g.globalCompositeOperation = value === \"add\" ? \"lighter\" : \"source-over\";\n",
  "      break;\n",
  "    case \"line_style\": {\n",
  "      // value: the ends and the corners; numbers: the dash offset, then\n",
  "      // the lengths of the dashes and the gaps.\n",
  "      const [cap, join] = value.split(\" \");\n",
  "      g.lineCap = [\"butt\", \"round\", \"square\"].includes(cap) ? cap : \"round\";\n",
  "      g.lineJoin = [\"miter\", \"round\", \"bevel\"].includes(join) ? join : \"round\";\n",
  "      if (typeof g.setLineDash === \"function\") g.setLineDash(n.slice(1));\n",
  "      g.lineDashOffset = n.length > 0 ? n[0] : 0;\n",
  "      break;\n",
  "    }\n",
  "    case \"clip\":\n",
  "      // value: the kind of shape the drawing is kept inside.\n",
  "      g.beginPath();\n",
  "      shapePath(g, value, n, false);\n",
  "      g.clip();\n",
  "      break;\n",
  "  }\n",
  "}\n",
  "\n",
  "// A canvas as it starts: every `push` closed, no transformation but the\n",
  "// pixel ratio, no shadow, no blending, no clipping and plain lines. What\n",
  "// `clear` begins with. Context -> Entry -> ()\n",
  "function freshState(g, entry) {\n",
  "  while (entry.depth > 0) {\n",
  "    g.restore();\n",
  "    entry.depth -= 1;\n",
  "  }\n",
  "  g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
  "  g.globalAlpha = 1;\n",
  "  g.shadowColor = \"transparent\";\n",
  "  g.shadowBlur = 0;\n",
  "  g.shadowOffsetX = 0;\n",
  "  g.shadowOffsetY = 0;\n",
  "  g.globalCompositeOperation = \"source-over\";\n",
  "  plainLines(g);\n",
  "}\n",
  "\n",
  "// Starts loading a picture: beside the page first, then among the ones\n",
  "// tinyweb ships beside `base`. Answers what `drawPicture` draws once it\n",
  "// has loaded. String -> String -> Picture\n",
  "function loadPicture(name, base) {\n",
  "  const picture = { element: null, ready: false, retried: false };\n",
  "  if (typeof Image === \"undefined\") return picture;\n",
  "  const element = new Image();\n",
  "  picture.element = element;\n",
  "  element.onload = () => {\n",
  "    picture.ready = true;\n",
  "  };\n",
  "  element.onerror = () => {\n",
  "    if (picture.retried) {\n",
  "      console.error(`tinyweb: cannot load the picture ${name}`);\n",
  "      return;\n",
  "    }\n",
  "    picture.retried = true;\n",
  "    element.src = new URL(\"tinyweb_assets/\" + name, base).href;\n",
  "  };\n",
  "  element.src = new URL(name, document.baseURI).href;\n",
  "  return picture;\n",
  "}\n",
  "\n",
  "// Draws a picture that has loaded; one still loading is not drawn.\n",
  "// Context -> Picture? -> ... -> ()\n",
  "function drawPicture(g, picture, x, y, width, height, alpha) {\n",
  "  if (!picture || !picture.ready) return;\n",
  "  const before = g.globalAlpha;\n",
  "  g.globalAlpha = before * alpha;\n",
  "  g.drawImage(picture.element, x, y, width, height);\n",
  "  g.globalAlpha = before;\n",
  "}\n",
  "\n",
  "// Keeps the pointer's moves and its release coming to the canvas it went\n",
  "// down on, wherever it goes. Element -> Event -> ()\n",
  "function capture(element, event) {\n",
  "  try {\n",
  "    if (element.setPointerCapture) element.setPointerCapture(event.pointerId);\n",
  "  } catch (error) {\n",
  "    // A pointer the browser does not know of, as a test's is, is not held.\n",
  "  }\n",
  "}\n",
  "\n",
  "// --- bitmaps (step 5) ---\n",
  "\n",
  "// The bytes of a bitmap's rectangle as they arrive: a base64 string from\n",
  "// a program on another host, or the bytes themselves. Data -> Uint8ClampedArray\n",
  "function bitmapBytes(data) {\n",
  "  if (typeof data !== \"string\") {\n",
  "    return ArrayBuffer.isView(data)\n",
  "      ? new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)\n",
  "      : new Uint8ClampedArray(data);\n",
  "  }\n",
  "  const text = atob(data);\n",
  "  const bytes = new Uint8ClampedArray(text.length);\n",
  "  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);\n",
  "  return bytes;\n",
  "}\n",
  "\n",
  "// A bitmap as the page keeps it: a canvas of its own, its pixels.\n",
  "// Int -> Int -> Surface\n",
  "function bitmapSurface(width, height) {\n",
  "  const element = document.createElement(\"canvas\");\n",
  "  element.width = Math.max(1, width);\n",
  "  element.height = Math.max(1, height);\n",
  "  return { element, context: element.getContext(\"2d\"), width, height };\n",
  "}\n",
  "\n",
  "// Puts the rectangle (rx, ry, rw, rh) of a bitmap's pixels on its\n",
  "// surface. Surface -> Int -> Int -> Int -> Int -> Data -> ()\n",
  "function updateSurface(surface, rx, ry, rw, rh, data) {\n",
  "  if (rw <= 0 || rh <= 0) return;\n",
  "  const bytes = bitmapBytes(data);\n",
  "  if (bytes.length !== rw * rh * 4) return;\n",
  "  surface.context.putImageData(new ImageData(bytes, rw, rh), rx, ry);\n",
  "}\n",
  "\n",
  "// Draws a bitmap's surface with its top left corner at (x, y), each pixel\n",
  "// `scale` pixels across: sharp squares when it grows, smooth when it\n",
  "// shrinks. Context -> Surface -> Float -> Float -> Float -> ()\n",
  "function drawSurface(g, surface, x, y, scale) {\n",
  "  const smoothing = g.imageSmoothingEnabled;\n",
  "  g.imageSmoothingEnabled = scale < 1;\n",
  "  g.drawImage(surface.element, x, y, surface.width * scale, surface.height * scale);\n",
  "  g.imageSmoothingEnabled = smoothing;\n",
  "}\n",
  "\n",
  "// A box whose elements go side by side, wrapping where the page is too\n",
  "// narrow for them, or one below another. String -> Bool -> Element\n",
  "function rowElement(id, across = true) {\n",
  "  const row = document.createElement(\"div\");\n",
  "  row.className = across ? \"tinyweb-row\" : \"tinyweb-column\";\n",
  "  row.setAttribute(\"data-tinyweb-id\", id);\n",
  "  row.style.cssText = across\n",
  "    ? \"display:flex;flex-direction:row;flex-wrap:wrap;align-items:center;gap:8px\"\n",
  "    : \"display:flex;flex-direction:column;align-items:flex-start;gap:6px\";\n",
  "  return row;\n",
  "}\n",
  "\n",
  "// --- widgets (step 2) ---\n",
  "\n",
  "// A checkbox or a radio button with its title beside it: the row, and\n",
  "// the input in it. String -> String -> String -> Bool -> (Element, Element)\n",
  "function choiceRow(type, id, title, checked) {\n",
  "  const row = document.createElement(\"label\");\n",
  "  row.className = type === \"checkbox\" ? \"tinyweb-check\" : \"tinyweb-radio\";\n",
  "  row.style.cssText = \"display:flex;align-items:center;gap:6px\";\n",
  "  const input = document.createElement(\"input\");\n",
  "  input.type = type;\n",
  "  input.setAttribute(\"data-tinyweb-id\", id);\n",
  "  input.checked = checked;\n",
  "  const text = document.createElement(\"span\");\n",
  "  text.textContent = title;\n",
  "  row.append(input, text);\n",
  "  return { row, input };\n",
  "}\n",
  "\n",
  "// A dropdown of the options, one per line of `options`, the one at\n",
  "// `chosen` chosen. String -> String -> Int -> Element\n",
  "function choiceElement(id, options, chosen) {\n",
  "  const select = document.createElement(\"select\");\n",
  "  select.className = \"tinyweb-choice\";\n",
  "  select.setAttribute(\"data-tinyweb-id\", id);\n",
  "  options.split(\"\\n\").forEach((text, position) => {\n",
  "    const option = document.createElement(\"option\");\n",
  "    option.value = String(position);\n",
  "    option.textContent = text;\n",
  "    select.appendChild(option);\n",
  "  });\n",
  "  select.value = String(chosen);\n",
  "  return select;\n",
  "}\n",
  "\n",
  "// A line to type text into. String -> String -> Element\n",
  "function textInputElement(id, placeholder) {\n",
  "  const input = document.createElement(\"input\");\n",
  "  input.type = \"text\";\n",
  "  input.className = \"tinyweb-text\";\n",
  "  input.setAttribute(\"data-tinyweb-id\", id);\n",
  "  input.placeholder = placeholder;\n",
  "  return input;\n",
  "}\n",
  "\n",
  "// A field for a whole number from `low` to `high`. ... -> Element\n",
  "function numberElement(id, low, high, value) {\n",
  "  const input = document.createElement(\"input\");\n",
  "  input.type = \"number\";\n",
  "  input.className = \"tinyweb-number\";\n",
  "  input.setAttribute(\"data-tinyweb-id\", id);\n",
  "  input.min = String(low);\n",
  "  input.max = String(high);\n",
  "  input.value = String(value);\n",
  "  return input;\n",
  "}\n",
  "\n",
  "// Whether a key press is the reader typing into a field, which the page\n",
  "// does not report as a key. Event -> Bool\n",
  "function typedInField(event) {\n",
  "  const target = event.target;\n",
  "  return !!target && typeof target.tagName === \"string\"\n",
  "    && (target.tagName === \"SELECT\"\n",
  "      || (target.tagName === \"INPUT\" && (target.type === \"text\" || target.type === \"number\")));\n",
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
  "  const pictures = new Map();\n",
  "  // What `set_checked` and `set_value` change, by identifier, and each\n",
  "  // group of radio buttons.\n",
  "  const checks = new Map();\n",
  "  const values = new Map();\n",
  "  const groups = new Map();\n",
  "  const bitmaps = new Map();\n",
  "  // Where an element made now goes: the page, or a row it was put inside.\n",
  "  const rows = new Map();\n",
  "  let parent = box;\n",
  "  // The keys held down, reported again as released when the page loses\n",
  "  // the focus.\n",
  "  const heldKeys = new Set();\n",
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
  "    if (!keysWanted || typedInField(event)) return;\n",
  "    // Arrows and the space bar move the program's world, not the page.\n",
  "    if (standalone && [\"ArrowUp\", \"ArrowDown\", \"ArrowLeft\", \"ArrowRight\", \" \"].includes(event.key)) {\n",
  "      event.preventDefault?.();\n",
  "    }\n",
  "    heldKeys.add(event.key);\n",
  "    report({ ev: \"key\", key: event.key });\n",
  "  }\n",
  "  keyTarget.addEventListener(\"keydown\", onKey);\n",
  "\n",
  "  function onKeyUp(event) {\n",
  "    if (!keysWanted) return;\n",
  "    if (heldKeys.delete(event.key)) report({ ev: \"key_up\", key: event.key });\n",
  "  }\n",
  "  keyTarget.addEventListener(\"keyup\", onKeyUp);\n",
  "\n",
  "  // A key released while the page did not have the focus is never\n",
  "  // reported, so leaving the page lets go of every key.\n",
  "  function onBlur() {\n",
  "    for (const key of heldKeys) report({ ev: \"key_up\", key });\n",
  "    heldKeys.clear();\n",
  "  }\n",
  "  window.addEventListener(\"blur\", onBlur);\n",
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
  "    plainLines(context);\n",
  "    const entry = {\n",
  "      element, context, width, height, mouse: false, pointer: false, ratio, depth: 0,\n",
  "      gradients: new Map(),\n",
  "    };\n",
  "    canvases.set(id, entry);\n",
  "    remember(look, id, element);\n",
  "    const where = (event) => {\n",
  "      const bounds = element.getBoundingClientRect();\n",
  "      return {\n",
  "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
  "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
  "      };\n",
  "    };\n",
  "    element.addEventListener(\"click\", (event) => {\n",
  "      if (entry.mouse) report({ ev: \"mouse\", c: id, ...where(event) });\n",
  "    });\n",
  "    // A browser reports a move at most once a frame already.\n",
  "    element.addEventListener(\"pointerdown\", (event) => {\n",
  "      if (!entry.pointer) return;\n",
  "      capture(element, event);\n",
  "      startAudio();\n",
  "      report({ ev: \"press\", c: id, ...where(event) });\n",
  "    });\n",
  "    element.addEventListener(\"pointerup\", (event) => {\n",
  "      if (entry.pointer) report({ ev: \"release\", c: id, ...where(event) });\n",
  "    });\n",
  "    element.addEventListener(\"pointermove\", (event) => {\n",
  "      if (entry.pointer) report({ ev: \"move\", c: id, ...where(event) });\n",
  "    });\n",
  "    element.addEventListener(\"contextmenu\", (event) => {\n",
  "      if (entry.pointer) event.preventDefault?.();\n",
  "    });\n",
  "    element.style.touchAction = \"none\";\n",
  "    parent.appendChild(element);\n",
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
  "          freshState(g, entry);\n",
  "          g.fillStyle = paint(g, entry, command.color);\n",
  "          g.fillRect(0, 0, entry.width, entry.height);\n",
  "        });\n",
  "        break;\n",
  "      case \"shape\":\n",
  "        draw(command.c, (g, entry) => drawShape(g, entry, command.kind, command.numbers,\n",
  "          command.color, command.outline, command.width, command.alpha));\n",
  "        break;\n",
  "      case \"text\":\n",
  "        draw(command.c, (g, entry) => drawText(g, entry, command.x, command.y, command.words,\n",
  "          command.color, command.size, command.font, command.align, command.baseline,\n",
  "          command.bold, command.outline, command.outline_width, command.alpha));\n",
  "        break;\n",
  "      case \"measure\": {\n",
  "        // Answered once the code that asked has finished, as any event is.\n",
  "        const width = textWidth(command.words, command.size, command.font, command.bold);\n",
  "        queueMicrotask(() => report({ ev: \"measured\", id: command.id, width }));\n",
  "        break;\n",
  "      }\n",
  "      case \"bitmap\": {\n",
  "        let surface = bitmaps.get(command.id);\n",
  "        if (!surface || surface.width !== command.width || surface.height !== command.height) {\n",
  "          surface = bitmapSurface(command.width, command.height);\n",
  "          bitmaps.set(command.id, surface);\n",
  "        }\n",
  "        const [rx, ry, rw, rh] = command.rect;\n",
  "        updateSurface(surface, rx, ry, rw, rh, command.data);\n",
  "        draw(command.c, (g) => drawSurface(g, surface, command.x, command.y, command.scale));\n",
  "        break;\n",
  "      }\n",
  "      case \"state\":\n",
  "        draw(command.c, (g, entry) => canvasState(g, entry, command.kind, command.value,\n",
  "          command.numbers));\n",
  "        break;\n",
  "      case \"image_load\":\n",
  "        pictures.set(command.id, loadPicture(command.name, import.meta.url));\n",
  "        break;\n",
  "      case \"image\":\n",
  "        draw(command.c, (g) => drawPicture(g, pictures.get(command.picture), command.x,\n",
  "          command.y, command.width, command.height, command.alpha));\n",
  "        break;\n",
  "      case \"checkbox\": {\n",
  "        const { row, input } = choiceRow(\"checkbox\", command.id, command.title, command.checked);\n",
  "        input.addEventListener(\"change\", () => {\n",
  "          startAudio();\n",
  "          report({ ev: \"check\", id: command.id, checked: input.checked });\n",
  "        });\n",
  "        checks.set(command.id, (on) => { input.checked = on; });\n",
  "        remember(look, command.id, input);\n",
  "        parent.appendChild(row);\n",
  "        break;\n",
  "      }\n",
  "      case \"radio\": {\n",
  "        const members = groups.get(command.group) || [];\n",
  "        groups.set(command.group, members);\n",
  "        const first = members.length === 0;\n",
  "        const { row, input } = choiceRow(\"radio\", command.id, command.title,\n",
  "          command.chosen || first);\n",
  "        input.name = `${look.name}:${command.group}`;\n",
  "        const choose = () => {\n",
  "          for (const other of members) other.checked = other === input;\n",
  "        };\n",
  "        if (command.chosen) choose();\n",
  "        members.push(input);\n",
  "        input.addEventListener(\"change\", () => {\n",
  "          startAudio();\n",
  "          choose();\n",
  "          report({ ev: \"pick\", id: command.id });\n",
  "        });\n",
  "        checks.set(command.id, (on) => {\n",
  "          if (on) choose();\n",
  "          else input.checked = false;\n",
  "        });\n",
  "        remember(look, command.id, input);\n",
  "        parent.appendChild(row);\n",
  "        break;\n",
  "      }\n",
  "      case \"choice\": {\n",
  "        const select = choiceElement(command.id, command.options, command.chosen);\n",
  "        select.addEventListener(\"change\", () => {\n",
  "          startAudio();\n",
  "          report({ ev: \"choose\", id: command.id, value: Number(select.value) });\n",
  "        });\n",
  "        values.set(command.id, (value) => { select.value = String(value); });\n",
  "        remember(look, command.id, select);\n",
  "        parent.appendChild(select);\n",
  "        break;\n",
  "      }\n",
  "      case \"text_input\": {\n",
  "        const input = textInputElement(command.id, command.placeholder);\n",
  "        input.addEventListener(\"keydown\", (event) => {\n",
  "          if (event.key === \"Enter\") {\n",
  "            startAudio();\n",
  "            report({ ev: \"enter\", id: command.id, text: input.value });\n",
  "          }\n",
  "        });\n",
  "        remember(look, command.id, input);\n",
  "        parent.appendChild(input);\n",
  "        break;\n",
  "      }\n",
  "      case \"number\": {\n",
  "        const input = numberElement(command.id, command.low, command.high, command.value);\n",
  "        input.addEventListener(\"change\", () => {\n",
  "          startAudio();\n",
  "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n",
  "        });\n",
  "        values.set(command.id, (value) => { input.value = String(value); });\n",
  "        remember(look, command.id, input);\n",
  "        parent.appendChild(input);\n",
  "        break;\n",
  "      }\n",
  "      case \"set_checked\":\n",
  "        if (checks.has(command.id)) checks.get(command.id)(command.checked);\n",
  "        break;\n",
  "      case \"set_value\":\n",
  "        if (values.has(command.id)) values.get(command.id)(command.value);\n",
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
  "        parent.appendChild(button);\n",
  "        break;\n",
  "      }\n",
  "      case \"label\": {\n",
  "        const text = document.createElement(\"div\");\n",
  "        text.className = \"tinyweb-label\";\n",
  "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
  "        text.textContent = command.text;\n",
  "        labels.set(command.id, text);\n",
  "        remember(look, command.id, text);\n",
  "        parent.appendChild(text);\n",
  "        break;\n",
  "      }\n",
  "      case \"row\":\n",
  "      case \"column\": {\n",
  "        const row = rowElement(command.id, command.op === \"row\");\n",
  "        rows.set(command.id, row);\n",
  "        remember(look, command.id, row);\n",
  "        parent.appendChild(row);\n",
  "        break;\n",
  "      }\n",
  "      case \"inside\":\n",
  "        parent = rows.get(command.id) || box;\n",
  "        break;\n",
  "      case \"outside\":\n",
  "        parent = box;\n",
  "        break;\n",
  "      case \"set_label\":\n",
  "        // A label's text, or a button's title.\n",
  "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
  "        else if (look.elements.get(command.id)?.tagName === \"BUTTON\") {\n",
  "          look.elements.get(command.id).textContent = command.text;\n",
  "        }\n",
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
  "        values.set(command.id, (value) => {\n",
  "          input.value = String(value);\n",
  "          shown.textContent = input.value;\n",
  "        });\n",
  "        remember(look, command.id, input);\n",
  "        parent.appendChild(row);\n",
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
  "      case \"on_pointer\": {\n",
  "        const entry = canvases.get(command.c);\n",
  "        if (entry) entry.pointer = true;\n",
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
  "    keyTarget.removeEventListener(\"keyup\", onKeyUp);\n",
  "    window.removeEventListener(\"blur\", onBlur);\n",
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
