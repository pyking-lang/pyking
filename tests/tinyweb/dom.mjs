// A page with nothing behind it, for running tinyweb's browser
// implementations under node: just enough of the DOM, a 2D canvas, Web
// Audio, fetch and requestAnimationFrame for tinyweb_page.js and
// tinyweb_external_browser.js to run, each recording what was asked of
// it. tests/tinyweb/drive.mjs installs it, runs a program against it and
// delivers its events; tests/test_tinyweb.py compares what the two
// implementations made of the same program.
//
// What is recorded is what a reader would see and hear: every drawing
// call on a canvas, with the state it was made in; every sound started;
// and, after each step, the page's elements as a tree, the head's
// stylesheets included. Nothing about
// the order elements were made in is, since two implementations may
// build the same page in different steps.
//
// Functions:
//   install(clock) -- puts the page's globals in place, answering the
//     recording and what drives it.

// An element's inline style: each property set is an own field, which
// is what a snapshot lists.
class FakeStyle {
  setProperty(name, value) {
    this[name] = String(value);
  }

  removeProperty(name) {
    delete this[name];
  }
}

class FakeNode {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.attributes = new Map();
    this.style = new FakeStyle();
    this.text = "";
  }

  appendChild(child) {
    if (child.parentNode !== null) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  append(...children) {
    for (const child of children) this.appendChild(child);
  }

  removeChild(child) {
    this.children = this.children.filter((c) => c !== child);
    child.parentNode = null;
  }

  remove() {
    if (this.parentNode !== null) this.parentNode.removeChild(this);
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(listener);
  }

  removeEventListener(type, listener) {
    if (this.listeners.has(type)) {
      this.listeners.set(type, this.listeners.get(type).filter((l) => l !== listener));
    }
  }

  dispatch(type, event = {}) {
    for (const listener of (this.listeners.get(type) || []).slice()) listener({ type, ...event });
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  get textContent() {
    return this.children.length > 0
      ? this.children.map((c) => c.textContent).join("")
      : this.text;
  }

  set textContent(value) {
    this.children = [];
    this.text = String(value);
  }

  // Every element at or under this one, in document order.
  *walk() {
    yield this;
    for (const child of this.children) yield* child.walk();
  }

  getBoundingClientRect() {
    const width = parseFloat(this.style.width) || 0;
    const height = parseFloat(this.style.height) || 0;
    return { left: 0, top: 0, width, height };
  }

  getContext() {
    if (!this.context) this.context = recordingContext(this);
    return this.context;
  }
}

let record = null;

// A 2D context that writes down each call, with the state it was made
// in, under the canvas's tinyweb id.
function recordingContext(canvas) {
  const name = () => "canvas " + canvas.getAttribute("data-tinyweb-id");
  const state = {};
  const call = (method) => (...args) => {
    const style = ["fill", "fillRect", "fillText"].includes(method)
      ? ` fill=${state.fillStyle}`
      : ["stroke"].includes(method)
        ? ` stroke=${state.strokeStyle} width=${state.lineWidth} cap=${state.lineCap}`
        : "";
    const font = method === "fillText" ? ` font=${state.font} baseline=${state.textBaseline}` : "";
    record.push(`${name()}: ${method}(${args.map((a) => JSON.stringify(a)).join(", ")})${style}${font}`);
  };
  const context = {};
  for (const method of ["scale", "fillRect", "beginPath", "arc", "fill", "moveTo",
    "lineTo", "stroke", "fillText"]) {
    context[method] = call(method);
  }
  for (const property of ["fillStyle", "strokeStyle", "lineWidth", "lineCap", "font",
    "textBaseline"]) {
    Object.defineProperty(context, property, {
      get: () => state[property],
      set: (value) => { state[property] = value; },
    });
  }
  return context;
}

// The page's elements under `root`, one line each, indented by depth.
function snapshot(root) {
  const lines = [];
  const visit = (node, depth) => {
    const parts = [node.tagName.toLowerCase()];
    for (const [k, v] of [...node.attributes.entries()].sort()) parts.push(`${k}=${v}`);
    if (node.className) parts.push(`class=${node.className}`);
    for (const key of ["type", "min", "max", "value", "width", "height", "tabIndex"]) {
      if (node[key] !== undefined) parts.push(`${key}=${node[key]}`);
    }
    const style = Object.entries(node.style).filter(([, v]) => v !== "" && v !== undefined)
      .sort().map(([k, v]) => `${k}:${v}`).join(";");
    if (style) parts.push(`style{${style}}`);
    if (node.children.length === 0 && node.text !== "") parts.push(JSON.stringify(node.text));
    lines.push("  ".repeat(depth) + parts.join(" "));
    for (const child of node.children) visit(child, depth + 1);
  };
  visit(root, 0);
  return lines;
}

export function install() {
  record = [];
  const clock = { now: 0 };
  const frames = [];
  const head = new FakeNode("head");
  const body = new FakeNode("body");
  const windowListeners = new FakeNode("window");

  globalThis.performance = { now: () => clock.now };
  globalThis.document = {
    head,
    body,
    baseURI: "http://page.test/",
    createElement: (tag) => new FakeNode(tag),
  };
  globalThis.window = windowListeners;
  globalThis.devicePixelRatio = 1;
  globalThis.requestAnimationFrame = (f) => {
    frames.push(f);
    return frames.length;
  };
  globalThis.cancelAnimationFrame = () => {};

  // Only a library sample is found, and only beside the library: a
  // page's own directory holds none here.
  globalThis.fetch = (url) => {
    const text = String(url);
    const found = text.startsWith("file:") && text.includes("/tinyweb_assets/");
    const name = text.slice(text.lastIndexOf("/") + 1);
    return Promise.resolve({
      ok: found,
      status: found ? 200 : 404,
      arrayBuffer: () => Promise.resolve({ sample: name }),
    });
  };

  class FakeAudioContext {
    constructor() {
      this.state = "running";
      this.destination = { node: "speakers" };
      record.push("audio: started");
    }

    get currentTime() {
      return clock.now / 1000;
    }

    resume() {
      this.state = "running";
    }

    close() {
      this.state = "closed";
    }

    createBufferSource() {
      const source = {
        buffer: null,
        playbackRate: { value: 1 },
        gainNode: null,
        connect: (gain) => {
          source.gainNode = gain;
          return gain;
        },
        start: (when) => {
          record.push(`audio: play ${source.buffer.sample} at ${when.toFixed(3)} ` +
            `rate ${source.playbackRate.value} volume ${source.gainNode.gain.value}`);
        },
      };
      return source;
    }

    createGain() {
      const gain = { gain: { value: 1 }, connect: (to) => to };
      return gain;
    }
  }

  globalThis.AudioContext = FakeAudioContext;
  globalThis.OfflineAudioContext = class {
    decodeAudioData(bytes) {
      return Promise.resolve({ sample: bytes.sample });
    }
  };

  const element = (id) => {
    for (const node of body.walk()) {
      if (node.getAttribute("data-tinyweb-id") === String(id)) return node;
    }
    return null;
  };
  const pageBox = () => {
    for (const node of body.walk()) if (node.className === "tinyweb-page") return node;
    return null;
  };
  // A gesture reaches the page's box on its way to what was touched.
  const touch = () => pageBox()?.dispatch("pointerdown");

  return {
    record,
    // The head holds each page's stylesheet, so its look is compared too.
    snapshot: () => [...snapshot(head), ...snapshot(body)],
    // Delivers one line of an events file the way a reader would cause
    // it, answering whether the line named something there.
    deliver(line) {
      if (line.startsWith("key ")) {
        windowListeners.dispatch("keydown", { key: line.slice(4) });
        pageBox()?.dispatch("keydown", { key: line.slice(4) });
        return true;
      }
      const words = line.trim().split(/\s+/);
      const target = element(words[1]);
      switch (words[0]) {
        case "click":
          if (target === null) return false;
          touch();
          target.dispatch("click");
          return true;
        case "slide":
          if (target === null) return false;
          touch();
          target.value = words[2];
          target.dispatch("input");
          return true;
        case "mouse":
          if (target === null) return false;
          touch();
          target.dispatch("click", { clientX: Number(words[2]), clientY: Number(words[3]) });
          return true;
        case "frame": {
          clock.now = Number(words[1]) * 1000;
          const due = frames.splice(0, frames.length);
          for (const f of due) f(clock.now);
          return true;
        }
        default:
          return false;
      }
    },
  };
}
