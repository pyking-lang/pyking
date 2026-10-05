// The JavaScript implementation of the names declared in
// tinyweb_external.pyk, for web24 and iweb24.
//
// A program talks to its page in *commands* -- {op: "circle", c, x, y,
// radius, color} and the rest -- and the page answers in *events* --
// {ev: "click", id} and the rest -- which call the functions the
// program handed over. How a command reaches the page depends on where
// the program runs, and is chosen once, below (`transport`):
//
//   - on a page (a web24 or iweb24 page): the renderer at the end of
//     this file is mounted on the page and called directly;
//   - in a worker (the playground, a notebook): each command is posted
//     to the page as {type: "page", module: "tinyweb", data: [command]}
//     and the page mounts the same renderer, from this same file, with
//     `mountPage`; an event comes back through `pykDeliver`;
//   - anywhere else (node, under the test harness): headless, writing
//     each command to $PYKING_PAGE_LOG and delivering the events
//     $PYKING_PAGE_EVENTS lists, as tinyweb_external_node.js does.
//
// tinyweb_external_node.js is a copy of this file: under node there is
// no page, so the same code is headless there. tests/test_site.py checks
// the two are the same. See docs/libraries.md, "tinyweb".

// --- the program's side ---

let last = 0;
const buttons = new Map();
const sliders = new Map();
const mice = new Map();
const frames = [];
const keys = [];

// The page's clock as the page last reported it: `t` seconds at `at`
// milliseconds of this side's own clock, and whether it is running.
let clock = { t: 0, at: 0, running: false };

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

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

export function time() {
  return clock.running ? clock.t + (now() - clock.at) / 1000 : clock.t;
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

// No page at all: each command is a line in $PYKING_PAGE_LOG, and the
// events in $PYKING_PAGE_EVENTS are delivered once the program's own
// code has finished.
function headless() {
  const fs = globalThis.process?.getBuiltinModule?.("fs");
  const env = globalThis.process?.env || {};
  const log = (line) => {
    if (fs && env.PYKING_PAGE_LOG) fs.appendFileSync(env.PYKING_PAGE_LOG, line + "\n");
  };
  if (fs && env.PYKING_PAGE_EVENTS && fs.existsSync(env.PYKING_PAGE_EVENTS)) {
    setTimeout(() => {
      const text = fs.readFileSync(env.PYKING_PAGE_EVENTS, "utf8");
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
    case "on_key": return "on_key";
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

// --- the page's side: the renderer ---

// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:
// `receive(commands)` carries out a batch of commands, and `send(event)`
// is how the page reports one. `standalone` is true where the page is
// the whole document, which is where a key press is listened for; a
// page inside another (a notebook cell) takes the focus when clicked.
export function mountPage(element, sendEvent, { standalone = false } = {}) {
  const box = document.createElement("div");
  box.className = "tinyweb-page";
  box.style.cssText =
    "display:flex;flex-direction:column;align-items:flex-start;gap:8px;" +
    "font-family:system-ui,sans-serif;outline:none";
  element.appendChild(box);

  const canvases = new Map();
  const labels = new Map();
  const samples = new Map();
  const start = now();
  let audio = null;
  let offset = 0;
  let frameWanted = false;
  let frameWaiting = false;
  let frameRequest = 0;
  let closed = false;
  const keyTarget = standalone ? window : box;
  let keysWanted = false;

  if (!standalone) box.tabIndex = 0;

  // The page's clock: the audio clock once sound has started, and until
  // then the seconds since the page was mounted. `offset` joins the two,
  // so the clock never goes back.
  function running() {
    return audio !== null && audio.state === "running";
  }

  function clockNow() {
    return running() ? audio.currentTime + offset : (now() - start) / 1000;
  }

  function report(event) {
    if (!closed) sendEvent({ ...event, t: clockNow(), running: running() });
  }

  // Sound may start only after the reader did something, so every
  // gesture is a chance to start it.
  function startAudio() {
    if (audio === null) {
      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
      if (!Context) return;
      const before = clockNow();
      audio = new Context();
      offset = before - audio.currentTime;
      audio.onstatechange = () => {
        if (audio.state === "running") offset = (now() - start) / 1000 - audio.currentTime;
      };
    }
    if (audio.state === "suspended") audio.resume();
  }

  box.addEventListener("pointerdown", startAudio);

  function onKey(event) {
    startAudio();
    if (keysWanted) report({ ev: "key", key: event.key });
  }
  keyTarget.addEventListener("keydown", onKey);

  function loadSample(name) {
    const decoder = new OfflineAudioContext(1, 1, 44100);
    const fetchArray = (url) =>
      fetch(url).then((response) => {
        if (!response.ok) throw new Error(`${name}: ${response.status}`);
        return response.arrayBuffer();
      });
    return fetchArray(new URL(name, document.baseURI))
      .catch(() => fetchArray(new URL("tinyweb_assets/" + name, import.meta.url)))
      .then((bytes) => decoder.decodeAudioData(bytes))
      .catch((error) => {
        console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);
        return null;
      });
  }

  function play({ sample, at, volume, rate }) {
    startAudio();
    const loading = samples.get(sample);
    if (!loading || audio === null) return;
    loading.then((buffer) => {
      if (buffer === null || closed) return;
      const source = audio.createBufferSource();
      source.buffer = buffer;
      source.playbackRate.value = rate;
      const gain = audio.createGain();
      gain.gain.value = volume;
      source.connect(gain).connect(audio.destination);
      source.start(Math.max(audio.currentTime, at - offset));
    });
  }

  function frame() {
    if (closed) return;
    if (!frameWaiting) {
      frameWaiting = true;
      report({ ev: "frame" });
    }
    frameRequest = requestAnimationFrame(frame);
  }

  function newCanvas({ id, width, height }) {
    const element = document.createElement("canvas");
    const ratio = globalThis.devicePixelRatio || 1;
    element.width = Math.round(width * ratio);
    element.height = Math.round(height * ratio);
    element.style.width = width + "px";
    element.style.height = height + "px";
    element.style.border = "1px solid #8884";
    element.style.background = "#ffffff";
    const context = element.getContext("2d");
    context.scale(ratio, ratio);
    canvases.set(id, { element, context, width, height, mouse: false });
    element.addEventListener("click", (event) => {
      const entry = canvases.get(id);
      if (!entry.mouse) return;
      const bounds = element.getBoundingClientRect();
      report({
        ev: "mouse",
        c: id,
        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),
        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),
      });
    });
    box.appendChild(element);
  }

  function draw(c, paint) {
    const entry = canvases.get(c);
    if (entry) paint(entry.context, entry);
  }

  function carryOut(command) {
    switch (command.op) {
      case "canvas":
        newCanvas(command);
        break;
      case "clear":
        draw(command.c, (g, entry) => {
          g.fillStyle = command.color;
          g.fillRect(0, 0, entry.width, entry.height);
        });
        break;
      case "circle":
        draw(command.c, (g) => {
          g.fillStyle = command.color;
          g.beginPath();
          g.arc(command.x, command.y, Math.max(0, command.radius), 0, 2 * Math.PI);
          g.fill();
        });
        break;
      case "rect":
        draw(command.c, (g) => {
          g.fillStyle = command.color;
          g.fillRect(command.x, command.y, command.width, command.height);
        });
        break;
      case "line":
        draw(command.c, (g) => {
          g.strokeStyle = command.color;
          g.lineWidth = command.width;
          g.lineCap = "round";
          g.beginPath();
          g.moveTo(command.x1, command.y1);
          g.lineTo(command.x2, command.y2);
          g.stroke();
        });
        break;
      case "text":
        draw(command.c, (g) => {
          g.fillStyle = command.color;
          g.font = `${command.size}px system-ui, sans-serif`;
          g.textBaseline = "top";
          g.fillText(command.words, command.x, command.y);
        });
        break;
      case "button": {
        const button = document.createElement("button");
        button.textContent = command.title;
        button.addEventListener("click", () => {
          startAudio();
          report({ ev: "click", id: command.id });
        });
        box.appendChild(button);
        break;
      }
      case "label": {
        const text = document.createElement("div");
        text.textContent = command.text;
        labels.set(command.id, text);
        box.appendChild(text);
        break;
      }
      case "set_label":
        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;
        break;
      case "slider": {
        const row = document.createElement("label");
        row.style.cssText = "display:flex;align-items:center;gap:8px";
        const input = document.createElement("input");
        input.type = "range";
        input.min = String(command.low);
        input.max = String(command.high);
        input.value = String(command.value);
        const shown = document.createElement("span");
        shown.textContent = input.value;
        input.addEventListener("input", () => {
          shown.textContent = input.value;
          report({ ev: "slide", id: command.id, value: Number(input.value) });
        });
        row.append(input, shown);
        box.appendChild(row);
        break;
      }
      case "load":
        samples.set(command.id, loadSample(command.name));
        break;
      case "play":
        play(command);
        break;
      case "on_frame":
        if (!frameWanted) {
          frameWanted = true;
          frameRequest = requestAnimationFrame(frame);
        }
        break;
      case "frame_done":
        frameWaiting = false;
        break;
      case "on_mouse": {
        const entry = canvases.get(command.c);
        if (entry) entry.mouse = true;
        break;
      }
      case "on_key":
        keysWanted = true;
        break;
    }
  }

  function freeze() {
    if (closed) return;
    closed = true;
    cancelAnimationFrame(frameRequest);
    keyTarget.removeEventListener("keydown", onKey);
    if (audio !== null) audio.close();
  }

  return {
    receive(commands) {
      if (!closed) for (const command of commands) carryOut(command);
    },
    // Stops: no more events, frames or sound, and what is shown stays.
    freeze,
    close() {
      freeze();
      box.remove();
    },
  };
}
