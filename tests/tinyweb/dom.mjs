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

  // A link clicked to offer a file records the file's name.
  click() {
    if (this.tagName === "A" && this.download) record?.push(`download: ${this.download}`);
    this.dispatch("click");
  }

  getContext() {
    if (!this.context) this.context = recordingContext(this);
    return this.context;
  }
}

// One line of an events file: its kind, the element it is on (a quoted
// string), and the numbers after it.
const eventWords = (line) => {
  const found = /^(\w+)\s+("(?:[^"\\]|\\.)*")\s*(.*)$/.exec(line.trim());
  if (found === null) return line.trim().split(/\s+/);
  // An `enter` carries its text as a second quoted string.
  const text = /^"(?:[^"\\]|\\.)*"$/.exec(found[3]);
  if (text !== null) return [found[1], JSON.parse(found[2]), JSON.parse(text[0])];
  const rest = found[3] === "" ? [] : found[3].split(/\s+/);
  return [found[1], JSON.parse(found[2]), ...rest];
};

let record = null;

// A 2D context that writes down each call, with the state it was made
// in, under the canvas's tinyweb id. `save` and `restore` keep a stack of
// that state, as a real context does.
const STATE_DEFAULTS = {
  globalAlpha: 1, globalCompositeOperation: "source-over", shadowColor: "transparent",
  shadowBlur: 0, shadowOffsetX: 0, shadowOffsetY: 0, textAlign: "start",
  lineDashOffset: 0, dash: "", imageSmoothingEnabled: true,
};

// FNV-1a, 32 bits, of a bitmap's bytes: how a recording shows pixels.
function digest(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 16777619) >>> 0;
  return h.toString(16).padStart(8, "0");
}

// A gradient as a recording shows it: how it was made and its stops.
class FakeGradient {
  constructor(kind, args) {
    this.kind = kind;
    this.args = args;
    this.stops = [];
  }

  addColorStop(at, color) {
    this.stops.push(`${at} ${color}`);
  }

  toString() {
    return `${this.kind}(${this.args.join(",")}|${this.stops.join("|")})`;
  }
}

// Pixels, as a canvas holds them.
class FakeImageData {
  constructor(a, b, c) {
    if (typeof a === "number") {
      this.width = a;
      this.height = b;
      this.data = new Uint8ClampedArray(a * b * 4);
    } else {
      this.data = a;
      this.width = b;
      this.height = c === undefined ? a.length / 4 / b : c;
    }
  }

  get tinywebPicture() {
    return `pixels ${this.width}x${this.height} ${digest(this.data)}`;
  }
}

function recordingContext(canvas) {
  const name = () => "canvas " + canvas.getAttribute("data-tinyweb-id");
  let state = { ...STATE_DEFAULTS };
  const saved = [];
  // What a fill or a stroke is drawn with, beyond its color: only what
  // differs from a fresh context, so an ordinary drawing reads as before.
  const extras = () => Object.keys(STATE_DEFAULTS)
    .filter((key) => state[key] !== STATE_DEFAULTS[key])
    .map((key) => ` ${key}=${state[key]}`).join("");
  const call = (method) => (...args) => {
    const style = ["fill", "fillRect", "fillText"].includes(method)
      ? ` fill=${state.fillStyle}`
      : ["stroke", "strokeText"].includes(method)
        ? ` stroke=${state.strokeStyle} width=${state.lineWidth} cap=${state.lineCap}` +
          ` join=${state.lineJoin}`
        : "";
    const font = method === "fillText" || method === "strokeText"
      ? ` font=${state.font} baseline=${state.textBaseline}` : "";
    const drawn = ["fill", "fillRect", "fillText", "stroke", "strokeText", "drawImage", "clearRect"]
      .includes(method) ? extras() : "";
    const shown = args.map((a) => (a && a.tinywebPicture ? a.tinywebPicture
      : a instanceof FakeNode ? `${a.tagName.toLowerCase()} ${a.width}x${a.height}`
        : JSON.stringify(a)));
    record.push(`${name()}: ${method}(${shown.join(", ")})${style}${font}${drawn}`);
  };
  const context = {
    setLineDash(pattern) {
      state.dash = pattern.join(",");
    },
    measureText(text) {
      const size = Number((/(\d+(?:\.\d+)?)px/.exec(state.font) || [0, 10])[1]);
      return { width: text.length * size * 0.5 };
    },
    createLinearGradient: (...args) => new FakeGradient("linear", args),
    createRadialGradient: (...args) => new FakeGradient("radial", args),
    createConicGradient: (...args) => new FakeGradient("conic", args),
    save() {
      saved.push({ ...state });
      record.push(`${name()}: save()`);
    },
    restore() {
      if (saved.length > 0) state = saved.pop();
      record.push(`${name()}: restore()`);
    },
  };
  for (const method of ["scale", "fillRect", "beginPath", "arc", "fill", "moveTo",
    "lineTo", "stroke", "fillText", "rect", "ellipse", "arcTo", "quadraticCurveTo",
    "closePath", "translate", "rotate", "setTransform", "drawImage", "bezierCurveTo",
    "clearRect", "clip", "strokeText", "putImageData"]) {
    context[method] = call(method);
  }
  for (const property of ["fillStyle", "strokeStyle", "lineWidth", "lineCap", "lineJoin",
    "font", "textBaseline", ...Object.keys(STATE_DEFAULTS)]) {
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
    for (const key of ["type", "name", "min", "max", "value", "checked", "placeholder", "width",
      "height", "tabIndex"]) {
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
  globalThis.ImageData = FakeImageData;
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

  // An AudioParam: a value, and the schedule calls the page makes on it.
  const fakeParam = (value) => ({
    value,
    setValueAtTime(v) { this.value = v; return this; },
    linearRampToValueAtTime(v) { this.value = v; return this; },
    exponentialRampToValueAtTime(v) { this.value = v; return this; },
    setTargetAtTime(v) { this.value = v; return this; },
    cancelScheduledValues() { return this; },
  });
  // A buffer of `length` frames, silent.
  const fakeBuffer = (channels, length, sampleRate, sample) => {
    const data = Array.from({ length: channels }, () => new Float32Array(length));
    return {
      sample,
      numberOfChannels: channels,
      length,
      sampleRate,
      duration: length / sampleRate,
      getChannelData: (k) => data[k],
    };
  };
  // A node of the sound graph: connect answers what it was connected to,
  // so chains read as the page writes them.
  const fakeNode = (fields) => ({
    connect: (to) => to,
    disconnect: () => {},
    ...fields,
  });

  class FakeAudioContext {
    constructor() {
      this.state = "running";
      this.sampleRate = 44100;
      this.destination = { node: "speakers" };
      record.push("audio: started");
    }

    get currentTime() {
      return clock.now / 1000;
    }

    resume() {
      this.state = "running";
      return Promise.resolve();
    }

    suspend() {
      this.state = "suspended";
      return Promise.resolve();
    }

    close() {
      this.state = "closed";
      return Promise.resolve();
    }

    createBufferSource() {
      const source = {
        buffer: null,
        loop: false,
        playbackRate: fakeParam(1),
        gainNode: null,
        onended: null,
        connect: (gain) => {
          source.gainNode = gain;
          return gain;
        },
        disconnect: () => {},
        start: (when) => {
          record.push(`audio: play ${source.buffer.sample} at ${when.toFixed(3)} ` +
            `rate ${source.playbackRate.value} volume ${source.gainNode.gain.value}` +
            (source.loop ? " looping" : ""));
        },
        stop: () => {},
      };
      return source;
    }

    createOscillator() {
      const oscillator = {
        type: "sine",
        frequency: fakeParam(440),
        onended: null,
        connect: (to) => to,
        disconnect: () => {},
        start: (when) => {
          record.push(`audio: tone ${oscillator.type} ${oscillator.frequency.value} at ${when.toFixed(3)}`);
        },
        stop: () => {},
      };
      return oscillator;
    }

    createGain() {
      return fakeNode({ gain: fakeParam(1) });
    }

    createStereoPanner() {
      return fakeNode({ pan: fakeParam(0) });
    }

    createBiquadFilter() {
      return fakeNode({ type: "lowpass", frequency: fakeParam(350), Q: fakeParam(1) });
    }

    createDelay() {
      return fakeNode({ delayTime: fakeParam(0) });
    }

    createConvolver() {
      return fakeNode({ buffer: null });
    }

    createAnalyser() {
      const analyser = fakeNode({
        fftSize: 2048,
        smoothingTimeConstant: 0.8,
        getByteFrequencyData: (array) => array.fill(0),
        getFloatTimeDomainData: (array) => array.fill(0),
        getByteTimeDomainData: (array) => array.fill(128),
      });
      Object.defineProperty(analyser, "frequencyBinCount", { get: () => analyser.fftSize / 2 });
      return analyser;
    }

    createBuffer(channels, length, sampleRate) {
      return fakeBuffer(channels, length, sampleRate, "made");
    }
  }

  globalThis.AudioContext = FakeAudioContext;
  // A picture loads where a library sample would be found: only beside
  // the library, from tinyweb_assets/.
  globalThis.Image = class {
    set src(url) {
      const text = String(url);
      this.tinywebPicture = text.slice(text.lastIndexOf("/") + 1);
      const found = text.startsWith("file:") && text.includes("/tinyweb_assets/");
      setTimeout(() => (found ? this.onload?.() : this.onerror?.()), 0);
    }
  };
  // Decodes a sample, and renders a sound offline into silence of the
  // length asked for.
  globalThis.OfflineAudioContext = class extends FakeAudioContext {
    constructor(channels = 1, length = 1, sampleRate = 44100) {
      super();
      record.pop();
      this.channels = channels;
      this.length = length;
      this.sampleRate = sampleRate;
    }

    get currentTime() {
      return 0;
    }

    decodeAudioData(bytes) {
      return Promise.resolve(fakeBuffer(1, 4410, 44100, bytes.sample));
    }

    startRendering() {
      record.push(`audio: rendered ${(this.length / this.sampleRate).toFixed(3)} seconds`);
      return Promise.resolve(fakeBuffer(this.channels, this.length, this.sampleRate, "rendered"));
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
  // The file a `cb "id" "loaded"` picks, as the report lines before it say.
  const picked = {};
  // A gesture reaches the page's box on its way to what was touched.
  const touch = () => pageBox()?.dispatch("pointerdown");
  // A reader facing the splash screen clicks it away before anything
  // else; what it said is recorded.
  const pastSplash = () => {
    for (const node of body.walk()) {
      if (node.className === "tinyweb-splash") {
        record.push(`splash: ${JSON.stringify(node.textContent)} dismissed`);
        node.dispatch("click");
        return;
      }
    }
  };

  return {
    record,
    // The head holds each page's stylesheet, so its look is compared too.
    snapshot: () => [...snapshot(head), ...snapshot(body)],
    // Delivers one line of an events file the way a reader would cause
    // it, answering whether the line named something there.
    deliver(line) {
      pastSplash();
      if (line.startsWith("key ")) {
        windowListeners.dispatch("keydown", { key: line.slice(4) });
        pageBox()?.dispatch("keydown", { key: line.slice(4) });
        return true;
      }
      if (line.startsWith("key_up ")) {
        windowListeners.dispatch("keyup", { key: line.slice(7) });
        pageBox()?.dispatch("keyup", { key: line.slice(7) });
        return true;
      }
      const words = eventWords(line);
      const target = element(words[1]);
      switch (words[0]) {
        // What the page reports of a text area or a file picked, caused as
        // a reader would: the text typed, or the file chosen.
        case "report_text": {
          if (words[1].startsWith("value.")) {
            const area = element(words[1].slice(6));
            if (area === null) return false;
            area.value = words[2];
            return true;
          }
          if (words[1] !== "file" && words[1] !== "file.text") return false;
          picked[words[1]] = words[2];
          return true;
        }
        case "cb": {
          if (target === null) return false;
          if (words[2] === "change") {
            touch();
            target.dispatch("input");
            return true;
          }
          const input = words[2] === "loaded"
            ? target.children.find((c) => c.tagName === "INPUT" && c.type === "file") : undefined;
          if (input === undefined) return false;
          const text = picked["file.text"] || "";
          input.files = [{ name: picked.file || "file.txt", type: "",
            arrayBuffer: () => Promise.resolve(new TextEncoder().encode(text).buffer) }];
          input.dispatch("change");
          return true;
        }
        case "click":
          if (target === null) return false;
          touch();
          target.dispatch("click");
          return true;
        case "slide":
          if (target === null) return false;
          touch();
          target.value = words[2];
          // A slider reports as it moves, a number field when it changes.
          target.dispatch(target.type === "number" ? "change" : "input");
          return true;
        case "check":
          if (target === null) return false;
          touch();
          target.checked = words[2] === "true";
          target.dispatch("change");
          return true;
        case "pick":
          if (target === null) return false;
          touch();
          target.checked = true;
          target.dispatch("change");
          return true;
        case "choose":
          if (target === null) return false;
          touch();
          target.value = words[2];
          target.dispatch("change");
          return true;
        case "enter":
          if (target === null) return false;
          touch();
          target.value = words[2];
          target.dispatch("keydown", { key: "Enter" });
          return true;
        case "mouse":
          if (target === null) return false;
          touch();
          target.dispatch("click", { clientX: Number(words[2]), clientY: Number(words[3]) });
          return true;
        case "press":
        case "release":
        case "move": {
          if (target === null) return false;
          const type = { press: "pointerdown", release: "pointerup", move: "pointermove" }[words[0]];
          if (words[0] === "press") touch();
          target.dispatch(type, { clientX: Number(words[2]), clientY: Number(words[3]), pointerId: 1 });
          return true;
        }
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
