// Injected into a tinyweb page in a real Chromium before any of its own
// scripts run (tests/tinyweb/chrome.mjs): the browser's own DOM, canvas
// and fetch do the work, and this records what they were asked to do.
// Three things are stood in for, so that two runs of one program record
// the same: the clock (`performance.now`, held still until a frame is
// delivered), animation frames (run only when one is delivered) and
// sound (an AudioContext that records what it is asked to play, at the
// held clock, rather than playing it).
//
// What the driver calls: __pykSnapshot(), __pykDeliver(line),
// __pykSettle(), __pykResult(); and __pykDone, which the page sets once
// the program's top level has ended. A page a program serves itself
// (tinyweb_page.html) sets no __pykDone: its commands arrive over
// /commands, so __pykQuiet() says when they have stopped arriving and
// __pykAnswered() how many events the program has answered.

(() => {
  const record = [];
  const printed = [];
  const clock = { now: 0 };
  const frames = [];

  performance.now = () => clock.now;
  window.requestAnimationFrame = (f) => {
    frames.push(f);
    return frames.length;
  };
  window.cancelAnimationFrame = () => {};

  const log = console.log.bind(console);
  console.log = (...parts) => {
    printed.push(parts.join(" "));
    log(...parts);
  };

  class RecordingAudioContext {
    constructor() {
      this.state = "running";
      this.destination = {};
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
          record.push(`audio: play ${source.buffer.bytes} bytes at ${when.toFixed(3)} ` +
            `rate ${source.playbackRate.value} volume ${source.gainNode.gain.value}`);
        },
      };
      return source;
    }

    createGain() {
      return { gain: { value: 1 }, connect: (to) => to };
    }
  }

  window.AudioContext = RecordingAudioContext;
  window.webkitAudioContext = RecordingAudioContext;
  window.OfflineAudioContext = class {
    decodeAudioData(bytes) {
      return Promise.resolve({ bytes: bytes.byteLength });
    }
  };

  // Each drawing call, with the state it is made in, under the canvas's
  // tinyweb id. The browser does the drawing too.
  const prototype = CanvasRenderingContext2D.prototype;
  // What a fill or a stroke is drawn with beyond its color, where it
  // differs from a fresh context's, so an ordinary drawing reads as before.
  const STATE = ["globalAlpha", "globalCompositeOperation", "shadowColor", "shadowBlur",
    "shadowOffsetX", "shadowOffsetY", "textAlign", "lineDashOffset", "imageSmoothingEnabled"];
  let defaults = null;
  const extras = (g) => {
    if (defaults === null) {
      const fresh = document.createElement("canvas").getContext("2d");
      defaults = Object.fromEntries(STATE.map((key) => [key, fresh[key]]));
    }
    return STATE.filter((key) => g[key] !== defaults[key]).map((key) => ` ${key}=${g[key]}`).join("");
  };
  // FNV-1a, 32 bits, of a bitmap's bytes: how a recording shows pixels.
  const digest = (bytes) => {
    let h = 0x811c9dc5;
    for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 16777619) >>> 0;
    return h.toString(16).padStart(8, "0");
  };
  const shown = (a) => (a instanceof HTMLImageElement
    ? a.src.slice(a.src.lastIndexOf("/") + 1)
    : a instanceof ImageData ? `pixels ${a.width}x${a.height} ${digest(a.data)}`
      : a instanceof HTMLCanvasElement ? `canvas ${a.width}x${a.height}`
        : JSON.stringify(a));
  for (const method of ["scale", "fillRect", "beginPath", "arc", "fill", "moveTo",
    "lineTo", "stroke", "fillText", "rect", "ellipse", "arcTo", "quadraticCurveTo",
    "closePath", "translate", "rotate", "setTransform", "drawImage", "save", "restore",
    "bezierCurveTo", "clearRect", "clip", "strokeText", "putImageData", "setLineDash"]) {
    const original = prototype[method];
    prototype[method] = function (...args) {
      const style = ["fill", "fillRect", "fillText"].includes(method)
        ? ` fill=${this.fillStyle}`
        : ["stroke", "strokeText"].includes(method)
          ? ` stroke=${this.strokeStyle} width=${this.lineWidth} cap=${this.lineCap}` +
            ` join=${this.lineJoin}`
          : "";
      const font = method === "fillText" || method === "strokeText"
        ? ` font=${this.font} baseline=${this.textBaseline}` : "";
      const drawn = ["fill", "fillRect", "fillText", "stroke", "strokeText", "drawImage",
        "clearRect"].includes(method) ? extras(this) : "";
      record.push(`canvas ${this.canvas.getAttribute("data-tinyweb-id")}: ` +
        `${method}(${args.map(shown).join(", ")})${style}${font}${drawn}`);
      return original.apply(this, args);
    };
  }

  const snapshot = () => {
    const lines = [];
    const visit = (node, depth) => {
      const parts = [node.tagName.toLowerCase()];
      for (const name of [...node.getAttributeNames()].sort()) {
        parts.push(`${name}=${node.getAttribute(name)}`);
      }
      if (node.tagName === "INPUT" || node.tagName === "SELECT") parts.push(`value=${node.value}`);
      if (node.tagName === "INPUT" && (node.type === "checkbox" || node.type === "radio")) {
        parts.push(`checked=${node.checked}`);
      }
      if (node.tagName === "CANVAS") parts.push(`size=${node.width}x${node.height}`);
      if (node.children.length === 0 && node.textContent !== "") {
        parts.push(JSON.stringify(node.textContent));
      }
      lines.push("  ".repeat(depth) + parts.join(" "));
      for (const child of node.children) visit(child, depth + 1);
    };
    const box = document.querySelector(".tinyweb-page");
    if (box !== null) visit(box, 0);
    return lines;
  };

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

  const element = (id) => document.querySelector(`[data-tinyweb-id="${CSS.escape(id)}"]`);
  const touch = (target) =>
    target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));

  window.__pykSnapshot = (title) => {
    record.push(title);
    for (const line of snapshot()) record.push("  | " + line);
  };

  window.__pykSettle = async () => {
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  };

  // A reader facing the splash screen clicks it away before anything
  // else; what it said is recorded.
  const pastSplash = () => {
    const splash = document.querySelector(".tinyweb-splash");
    if (splash === null) return;
    record.push(`splash: ${JSON.stringify(splash.textContent)} dismissed`);
    splash.click();
  };

  window.__pykDeliver = (line) => {
    record.push("> " + line);
    pastSplash();
    if (line.startsWith("key ")) {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: line.slice(4), bubbles: true }));
      return true;
    }
    if (line.startsWith("key_up ")) {
      window.dispatchEvent(new KeyboardEvent("keyup", { key: line.slice(7), bubbles: true }));
      return true;
    }
    const words = eventWords(line);
    const target = element(words[1]);
    switch (words[0]) {
      case "click":
        if (target === null) return false;
        touch(target);
        target.click();
        return true;
      case "slide":
        if (target === null) return false;
        touch(target);
        target.value = words[2];
        // A slider reports as it moves, a number field when it changes.
        target.dispatchEvent(new Event(target.type === "number" ? "change" : "input",
          { bubbles: true }));
        return true;
      case "check":
        if (target === null) return false;
        touch(target);
        target.checked = words[2] === "true";
        target.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      case "pick":
        if (target === null) return false;
        touch(target);
        target.checked = true;
        target.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      case "choose":
        if (target === null) return false;
        touch(target);
        target.value = words[2];
        target.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      case "enter":
        if (target === null) return false;
        touch(target);
        target.value = words[2];
        target.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
        return true;
      case "mouse": {
        if (target === null) return false;
        touch(target);
        const bounds = target.getBoundingClientRect();
        const width = parseFloat(target.style.width);
        const height = parseFloat(target.style.height);
        target.dispatchEvent(new MouseEvent("click", {
          bubbles: true,
          clientX: bounds.left + (Number(words[2]) * bounds.width) / width,
          clientY: bounds.top + (Number(words[3]) * bounds.height) / height,
        }));
        return true;
      }
      case "press":
      case "release":
      case "move": {
        if (target === null) return false;
        const bounds = target.getBoundingClientRect();
        const width = parseFloat(target.style.width);
        const height = parseFloat(target.style.height);
        const type = { press: "pointerdown", release: "pointerup", move: "pointermove" }[words[0]];
        target.dispatchEvent(new PointerEvent(type, {
          bubbles: true,
          pointerId: 1,
          clientX: bounds.left + (Number(words[2]) * bounds.width) / width,
          clientY: bounds.top + (Number(words[3]) * bounds.height) / height,
        }));
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
  };

  // The stream a served page reads its commands from, watched for when
  // they stop and for each `event_done`.
  let heard = false;
  let lastHeard = 0;
  let answered = 0;
  const Stream = window.EventSource;
  window.EventSource = class extends Stream {
    constructor(url) {
      super(url);
      this.addEventListener("message", (message) => {
        heard = true;
        lastHeard = Date.now();
        for (const command of JSON.parse(message.data)) {
          if (command.op === "event_done") answered += 1;
        }
      });
    }
  };
  window.__pykQuiet = () => heard && Date.now() - lastHeard > 1000;
  window.__pykAnswered = () => answered;

  window.__pykResult = () => JSON.stringify({ record, stdout: printed.join("\n") });
})();
