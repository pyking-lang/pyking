// The JavaScript implementation of the names declared in
// tinyweb_external.pyk that talks to its page in commands, for iweb,
// the playground and the notebook: wherever the interpreter runs the
// program. tinyweb_external_browser.js is the one web uses, which
// draws directly; the two do the same thing, which
// tests/test_tinyweb.py checks.
//
// A program talks to its page in *commands* -- {op: "circle", c, x, y,
// radius, color} and the rest -- and the page answers in *events* --
// {ev: "click", id} and the rest -- which call the functions the
// program handed over. How a command reaches the page depends on where
// the program runs, and is chosen once, below (`transport`):
//
//   - on a page (an iweb page): the renderer, tinyweb_page.js, is
//     mounted on the page and called directly;
//   - in a worker (the playground, a notebook): each command is posted
//     to the page as {type: "page", module: "tinyweb", data: [command]}
//     and the page mounts the same renderer with `mountPage`; an event
//     comes back through `pykDeliver`;
//   - anywhere else (node, under the test harness): headless, writing
//     each command to $PYKING_TINYWEB_LOG and delivering the events
//     $PYKING_TINYWEB_EVENTS lists, as every other implementation does.
//
// `web_init` does nothing here: the page is already there. See
// docs/libraries.md, "tinyweb".

import { mountPage } from "./tinyweb_page.js";


// Every identifier given out so far.
const names = new Set();
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

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

// The page's clock as the page last reported it: `t` seconds at `at`
// milliseconds of this side's own clock, and whether it is running.
let clock = { t: 0, at: now(), running: false };

// A new element's identifier: `name`, or `name` with the first number
// from 1 that makes it one nothing on the page has.
function fresh(name) {
  let found = name;
  for (let n = 1; names.has(found); n++) found = name + n;
  names.add(found);
  return found;
}

function send(command) {
  if (command.op !== "frame_done" && command.op !== "event_done") trace(logLine(command));
  transport().send(command);
}

// The tinyweb log, where the page running the program asks for it with
// `pykTinywebLog` (the playground's "tinyweb log"): each command as its
// line, and each event as `> ` and its line, as `pyk --tinyweb-log`
// prints them.
function trace(line) {
  if (typeof globalThis.pykTinywebLog === "function") globalThis.pykTinywebLog(line);
}

// An event as the line an events file holds for it.
function eventLine(event) {
  const q = JSON.stringify;
  switch (event.ev) {
    case "click": return `click ${q(event.id)}`;
    case "slide": return `slide ${q(event.id)} ${event.value}`;
    case "check": return `check ${q(event.id)} ${event.checked === true}`;
    case "pick": return `pick ${q(event.id)}`;
    case "choose": return `choose ${q(event.id)} ${event.value}`;
    case "enter": return `enter ${q(event.id)} ${q(event.text)}`;
    case "frame": return `frame ${Number(event.t).toFixed(3)}`;
    case "mouse": return `mouse ${q(event.c)} ${event.x} ${event.y}`;
    case "key": return `key ${event.key}`;
    case "key_up": return `key_up ${event.key}`;
    case "press": case "release": case "move":
      return `${event.ev} ${q(event.c)} ${event.x} ${event.y}`;
    case "measured": return `measured ${q(event.id)} ${event.width}`;
    default: return String(event.ev);
  }
}

export function canvas(width, height) {
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
  const id = fresh("measure");
  measures.set(id, answer);
  send({ op: "measure", id, words, size, font, bold });
}

export function watch_pointer(c, kind, f) {
  if (!pointers.has(c)) {
    pointers.set(c, { press: [], release: [], move: [], drag: [], x: 0, y: 0, down: false });
    send({ op: "on_pointer", c });
  }
  const seen = pointers.get(c);
  if (Array.isArray(seen[kind])) seen[kind].push(f);
}

export function pointer(c, which) {
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

export function make_bitmap(width, height, background) {
  const id = fresh("bitmap");
  const w = Math.max(1, width);
  const h = Math.max(1, height);
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 3; i < data.length; i += 4) data[i] = 255;
  bitmaps.set(id, { width: w, height: h, data, x1: 0, y1: 0, x2: w, y2: h });
  fill_bitmap(id, background);
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

// The changed rectangle's bytes are sent as they are; the page and the
// log both take them that way.
export function draw_bitmap(c, b, x, y, scale) {
  const bm = bitmaps.get(b);
  if (bm === undefined) return;
  const changed = bm.x2 > bm.x1 && bm.y2 > bm.y1;
  const rect = changed ? [bm.x1, bm.y1, bm.x2 - bm.x1, bm.y2 - bm.y1] : [0, 0, 0, 0];
  const [rx, ry, rw, rh] = rect;
  const bytes = new Uint8ClampedArray(rw * rh * 4);
  for (let r = 0; r < rh; r++) {
    const from = ((ry + r) * bm.width + rx) * 4;
    bytes.set(bm.data.subarray(from, from + rw * 4), r * rw * 4);
  }
  Object.assign(bm, { x1: bm.width, y1: bm.height, x2: 0, y2: 0 });
  send({ op: "bitmap", c, id: b, width: bm.width, height: bm.height, x, y, scale, rect,
    data: bytes });
}

export function set_state(c, kind, value, numbers) {
  send({ op: "state", c, kind, value, numbers });
}

export function load_image(name) {
  const id = fresh(name);
  send({ op: "image_load", id, name });
  return id;
}

export function draw_image(c, picture, x, y, width, height, alpha) {
  send({ op: "image", c, picture, x, y, width, height, alpha });
}

export function make_checkbox(title, checked, onChange) {
  const id = fresh(title);
  checks.set(id, onChange);
  send({ op: "checkbox", id, title, checked });
  return id;
}

export function make_radio(group, title, chosen, onPick) {
  const id = fresh(title);
  radios.set(id, () => onPick(title));
  send({ op: "radio", id, group, title, chosen });
  return id;
}

export function make_choice(options, chosen, onChange) {
  const id = fresh("choice");
  choices.set(id, onChange);
  send({ op: "choice", id, options, chosen });
  return id;
}

export function make_text_input(placeholder, onEnter) {
  const id = fresh(placeholder === "" ? "text" : placeholder);
  texts.set(id, onEnter);
  send({ op: "text_input", id, placeholder });
  return id;
}

export function make_number_input(low, high, value, onChange) {
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
  const id = fresh(title);
  buttons.set(id, onClick);
  send({ op: "button", id, title });
  return id;
}

export function label(text) {
  const id = fresh(text);
  send({ op: "label", id, text });
  return id;
}

export function row() {
  const id = fresh("row");
  send({ op: "row", id });
  return id;
}

export function column() {
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
  const id = fresh("slider");
  sliders.set(id, onChange);
  send({ op: "slider", id, low, high, value });
  return id;
}

export function load_sample(name) {
  const id = fresh(name);
  send({ op: "load", id, name });
  return id;
}

export function play_sample(sample, at, volume, rate) {
  send({ op: "play", sample, at, volume, rate });
}

export function splash() {
  send({ op: "splash" });
}

export function set_splash(message) {
  send({ op: "splash_text", text: message });
}

// The page's clock never stops, so it is what the page last said plus
// the time since; with no page, it is what the events said and nothing
// else.
export function time() {
  return transport().headless ? clock.t : clock.t + (now() - clock.at) / 1000;
}

export function on_frame(draw) {
  frames.push(draw);
  send({ op: "on_frame" });
}

export function on_mouse(c, click) {
  if (!mice.has(c)) mice.set(c, []);
  mice.get(c).push(click);
  send({ op: "on_mouse", c });
}

export function web_start(port) {}

export function on_key(pressed) {
  keys.push(pressed);
  send({ op: "on_key" });
}

export function on_key_up(released) {
  keyUps.push(released);
  send({ op: "on_key" });
}

export function key_down(key) {
  if (!keysOn && keys.length === 0 && keyUps.length === 0) {
    keysOn = true;
    send({ op: "on_key" });
  }
  return down.has(key);
}

// One event from the page: the functions the program handed over for
// it are called, in the order they were handed over. A function that
// answers a promise -- one the debugger is running, a slice at a time
// -- is waited for before the next is called, and so is what follows
// them, so the event answers a promise too.
export function pykDeliver(event) {
  trace("> " + eventLine(event));
  if (typeof event.t === "number") {
    clock = { t: event.t, at: now(), running: Boolean(event.running) };
  }
  const calls = [];
  let after = null;
  const each = (fs, ...args) => { for (const f of fs) calls.push(() => f(...args)); };
  switch (event.ev) {
    case "click":
      if (buttons.has(event.id)) each([buttons.get(event.id)]);
      break;
    case "slide":
      if (sliders.has(event.id)) each([sliders.get(event.id)], event.value);
      break;
    case "check":
      if (checks.has(event.id)) each([checks.get(event.id)], event.checked === true);
      break;
    case "pick":
      if (radios.has(event.id)) each([radios.get(event.id)]);
      break;
    case "choose":
      if (choices.has(event.id)) each([choices.get(event.id)], event.value);
      break;
    case "enter":
      if (texts.has(event.id)) each([texts.get(event.id)], String(event.text));
      break;
    case "frame":
      each(frames.slice(), event.t);
      after = () => send({ op: "frame_done" });
      break;
    case "mouse":
      each((mice.get(event.c) || []).slice(), event.x, event.y);
      break;
    case "key":
      down.add(event.key);
      each(keys.slice(), event.key);
      break;
    case "key_up":
      down.delete(event.key);
      each(keyUps.slice(), event.key);
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
      for (const kind of kinds) each(seen[kind].slice(), seen.x, seen.y);
      break;
    }
    case "measured": {
      const answer = measures.get(event.id);
      if (answer === undefined) break;
      measures.delete(event.id);
      each([answer], Number(event.width));
      break;
    }
  }
  return callInTurn(calls, after);
}

// Calls each function in turn, then `after`; where one answers a
// promise, the rest wait for it, and so does the answer.
function callInTurn(calls, after) {
  for (let k = 0; k < calls.length; k += 1) {
    const answer = calls[k]();
    if (answer && typeof answer.then === "function") {
      return answer.then(() => callInTurn(calls.slice(k + 1), after));
    }
  }
  if (after) after();
  return undefined;
}

// --- how commands reach the page ---

let chosen = null;

function transport() {
  if (chosen === null) {
    if (typeof document !== "undefined") {
      chosen = onPage();
    } else if (typeof WorkerGlobalScope !== "undefined" &&
               globalThis instanceof WorkerGlobalScope) {
      chosen = inWorker();
    } else {
      chosen = headless();
    }
  }
  return chosen;
}

// The page is here: mount the renderer on it, where the page says
// (`pykPageRoot`) or at the end of its body.
function onPage() {
  const root = globalThis.pykPageRoot || document.body;
  const page = mountPage(root, pykDeliver, { standalone: !globalThis.pykPageRoot });
  return { send: (command) => page.receive([command]) };
}

// The page is the worker's owner: commands go to it in batches, one per
// turn of the worker's event loop.
function inWorker() {
  let queue = [];
  return {
    send(command) {
      if (queue.length === 0) {
        queueMicrotask(() => {
          const data = queue;
          queue = [];
          globalThis.postMessage({ type: "page", module: "tinyweb", data });
        });
      }
      queue.push(command);
    },
  };
}

// No page at all: each command is a line in $PYKING_TINYWEB_LOG, and the
// events in $PYKING_TINYWEB_EVENTS are delivered once the program's own
// code has finished.
function headless() {
  const fs = globalThis.process?.getBuiltinModule?.("fs");
  const env = globalThis.process?.env || {};
  const log = (line) => {
    if (fs && env.PYKING_TINYWEB_LOG) fs.appendFileSync(env.PYKING_TINYWEB_LOG, line + "\n");
  };
  if (fs && env.PYKING_TINYWEB_EVENTS && fs.existsSync(env.PYKING_TINYWEB_EVENTS)) {
    setTimeout(() => {
      const text = fs.readFileSync(env.PYKING_TINYWEB_EVENTS, "utf8");
      for (const line of text.split("\n")) {
        if (line.trim() === "") continue;
        log("> " + line);
        const event = parseEvent(line);
        if (event === null) log("! unknown event: " + line);
        else pykDeliver(event);
      }
    }, 0);
  }
  return {
    headless: true,
    send(command) {
      if (command.op !== "frame_done") log(logLine(command));
    },
  };
}

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

// A command as the one line the headless implementations all write.
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
        `${c.rect.join(" ")} ${digest(c.data)}`;
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
