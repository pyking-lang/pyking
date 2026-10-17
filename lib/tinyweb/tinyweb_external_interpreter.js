// The JavaScript implementation of the names declared in
// tinyweb_external.pyk that talks to its page in commands, for iweb24,
// the playground and the notebook: wherever the interpreter runs the
// program. tinyweb_external_browser.js is the one web24 uses, which
// draws directly; the two do the same thing, which
// tests/test_tinyweb.py checks.
//
// A program talks to its page in *commands* -- {op: "circle", c, x, y,
// radius, color} and the rest -- and the page answers in *events* --
// {ev: "click", id} and the rest -- which call the functions the
// program handed over. How a command reaches the page depends on where
// the program runs, and is chosen once, below (`transport`):
//
//   - on a page (an iweb24 page): the renderer, tinyweb_page.js, is
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


let last = 0;
const buttons = new Map();
const sliders = new Map();
const mice = new Map();
const frames = [];
const keys = [];

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

// The page's clock as the page last reported it: `t` seconds at `at`
// milliseconds of this side's own clock, and whether it is running.
let clock = { t: 0, at: now(), running: false };

function fresh() {
  last += 1;
  return last;
}

function send(command) {
  transport().send(command);
}

export function canvas(width, height) {
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
  const id = fresh();
  buttons.set(id, onClick);
  send({ op: "button", id, title });
  return id;
}

export function label(text) {
  const id = fresh();
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
  const id = fresh();
  sliders.set(id, onChange);
  send({ op: "slider", id, low, high, value });
  return id;
}

export function load_sample(name) {
  const id = fresh();
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

export function web_init(port) {}

export function on_key(pressed) {
  keys.push(pressed);
  send({ op: "on_key" });
}

// One event from the page: the functions the program handed over for
// it are called, in the order they were handed over.
export function pykDeliver(event) {
  if (typeof event.t === "number") {
    clock = { t: event.t, at: now(), running: Boolean(event.running) };
  }
  switch (event.ev) {
    case "click":
      if (buttons.has(event.id)) buttons.get(event.id)();
      break;
    case "slide":
      if (sliders.has(event.id)) sliders.get(event.id)(event.value);
      break;
    case "frame":
      for (const draw of frames) draw(event.t);
      send({ op: "frame_done" });
      break;
    case "mouse":
      for (const click of mice.get(event.c) || []) click(event.x, event.y);
      break;
    case "key":
      for (const pressed of keys) pressed(event.key);
      break;
  }
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

// A command as the one line the headless implementations all write.
function logLine(command) {
  const q = JSON.stringify;
  const s = (x) => x.toFixed(3);
  switch (command.op) {
    case "canvas": return `canvas ${command.id} ${command.width} ${command.height}`;
    case "clear": return `clear ${command.c} ${command.color}`;
    case "circle": {
      const { c, x, y, radius, color } = command;
      return `circle ${c} ${x} ${y} ${radius} ${color}`;
    }
    case "rect": {
      const { c, x, y, width, height, color } = command;
      return `rect ${c} ${x} ${y} ${width} ${height} ${color}`;
    }
    case "line": {
      const { c, x1, y1, x2, y2, color, width } = command;
      return `line ${c} ${x1} ${y1} ${x2} ${y2} ${color} ${width}`;
    }
    case "text": {
      const { c, x, y, color, size, words } = command;
      return `text ${c} ${x} ${y} ${color} ${size} ${q(words)}`;
    }
    case "button": return `button ${command.id} ${q(command.title)}`;
    case "label": return `label ${command.id} ${q(command.text)}`;
    case "set_label": return `set_label ${command.id} ${q(command.text)}`;
    case "slider": {
      const { id, low, high, value } = command;
      return `slider ${id} ${low} ${high} ${value}`;
    }
    case "load": return `load ${command.id} ${q(command.name)}`;
    case "play": {
      const { sample, at, volume, rate } = command;
      return `play ${sample} ${s(at)} ${s(volume)} ${s(rate)}`;
    }
    case "on_frame": return "on_frame";
    case "on_mouse": return `on_mouse ${command.c}`;
    case "style": {
      const { id, kind, prop, value } = command;
      return `style ${id} ${kind} ${prop} ${q(value)}`;
    }
    case "on_key": return "on_key";
    case "splash_text": return `splash_text ${q(command.text)}`;
    default: return command.op;
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
