// The JavaScript implementation of the names declared in
// tinyweb_external.pyk for web24: a program compiled to JavaScript and
// running on its own page, which it draws on directly. Nothing passes
// between the program and the page as commands here -- each function
// does to the page what tinyweb_page.js does for the command of the
// same name, which is what tinyweb_external_interpreter.js sends where
// the interpreter runs the program. tests/test_tinyweb.py runs every
// tinyweb program both ways and holds them to drawing the same things.
//
// The page is mounted on `pykPageRoot` where the page names one, and at
// the end of its body otherwise, the first time a function needs it.
// `web_init` does nothing here: the page is already there. See
// docs/libraries.md, "tinyweb". Keep this file and tinyweb_page.js in
// step: the operations each makes on the page, and their order, are what
// the test compares.

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

let page = null;
let last = 0;

function fresh() {
  last += 1;
  return last;
}

// The page this program draws on: made the first time anything needs
// it.
function mounted() {
  if (page === null) {
    if (typeof document === "undefined") {
      throw new Error("tinyweb: this implementation draws on a web page, and there is none here");
    }
    const root = globalThis.pykPageRoot || document.body;
    page = mount(root, { standalone: !globalThis.pykPageRoot });
  }
  return page;
}

function mount(element, { standalone }) {
  const box = document.createElement("div");
  box.className = "tinyweb-page";
  box.style.cssText =
    "display:flex;flex-direction:column;align-items:flex-start;gap:8px;" +
    "font-family:system-ui,sans-serif;outline:none";
  element.appendChild(box);

  const state = {
    box,
    canvases: new Map(),
    labels: new Map(),
    samples: new Map(),
    frames: [],
    keys: [],
    start: now(),
    audio: null,
    offset: 0,
    frameWanted: false,
    keyTarget: standalone ? window : box,
  };

  if (!standalone) box.tabIndex = 0;
  box.addEventListener("pointerdown", () => startAudio(state));
  state.keyTarget.addEventListener("keydown", (event) => {
    startAudio(state);
    for (const pressed of state.keys.slice()) pressed(event.key);
  });
  return state;
}

// The page's clock: the audio clock once sound has started, and until
// then the seconds since the page was mounted. `offset` joins the two,
// so the clock never goes back.
function running(state) {
  return state.audio !== null && state.audio.state === "running";
}

function clockNow(state) {
  return running(state)
    ? state.audio.currentTime + state.offset
    : (now() - state.start) / 1000;
}

// Sound may start only after the reader did something, so every gesture
// is a chance to start it.
function startAudio(state) {
  if (state.audio === null) {
    const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
    if (!Context) return;
    const before = clockNow(state);
    const audio = new Context();
    state.audio = audio;
    state.offset = before - audio.currentTime;
    audio.onstatechange = () => {
      if (audio.state === "running") {
        state.offset = (now() - state.start) / 1000 - audio.currentTime;
      }
    };
  }
  if (state.audio.state === "suspended") state.audio.resume();
}

function draw(c, paint) {
  const entry = mounted().canvases.get(c);
  if (entry) paint(entry.context, entry);
}

// --- the functions tinyweb_external.pyk declares ---

export function web_init(port) {}

export function canvas(width, height) {
  const state = mounted();
  const id = fresh();
  const element = document.createElement("canvas");
  element.setAttribute("data-tinyweb-id", String(id));
  const ratio = globalThis.devicePixelRatio || 1;
  element.width = Math.round(width * ratio);
  element.height = Math.round(height * ratio);
  element.style.width = width + "px";
  element.style.height = height + "px";
  element.style.border = "1px solid #8884";
  element.style.background = "#ffffff";
  const context = element.getContext("2d");
  context.scale(ratio, ratio);
  const entry = { element, context, width, height, mice: [] };
  state.canvases.set(id, entry);
  element.addEventListener("click", (event) => {
    if (entry.mice.length === 0) return;
    const bounds = element.getBoundingClientRect();
    const x = Math.round(((event.clientX - bounds.left) * width) / bounds.width);
    const y = Math.round(((event.clientY - bounds.top) * height) / bounds.height);
    for (const click of entry.mice.slice()) click(x, y);
  });
  state.box.appendChild(element);
  return id;
}

export function fill_canvas(c, color) {
  draw(c, (g, entry) => {
    g.fillStyle = color;
    g.fillRect(0, 0, entry.width, entry.height);
  });
}

export function draw_circle(c, x, y, radius, color) {
  draw(c, (g) => {
    g.fillStyle = color;
    g.beginPath();
    g.arc(x, y, Math.max(0, radius), 0, 2 * Math.PI);
    g.fill();
  });
}

export function draw_rect(c, x, y, width, height, color) {
  draw(c, (g) => {
    g.fillStyle = color;
    g.fillRect(x, y, width, height);
  });
}

export function draw_line(c, x1, y1, x2, y2, color, width) {
  draw(c, (g) => {
    g.strokeStyle = color;
    g.lineWidth = width;
    g.lineCap = "round";
    g.beginPath();
    g.moveTo(x1, y1);
    g.lineTo(x2, y2);
    g.stroke();
  });
}

export function draw_text(c, x, y, words, color, size) {
  draw(c, (g) => {
    g.fillStyle = color;
    g.font = `${size}px system-ui, sans-serif`;
    g.textBaseline = "top";
    g.fillText(words, x, y);
  });
}

export function make_button(title, onClick) {
  const state = mounted();
  const id = fresh();
  const button = document.createElement("button");
  button.setAttribute("data-tinyweb-id", String(id));
  button.textContent = title;
  button.addEventListener("click", () => {
    startAudio(state);
    onClick();
  });
  state.box.appendChild(button);
  return id;
}

export function label(text) {
  const state = mounted();
  const id = fresh();
  const shown = document.createElement("div");
  shown.setAttribute("data-tinyweb-id", String(id));
  shown.textContent = text;
  state.labels.set(id, shown);
  state.box.appendChild(shown);
  return id;
}

export function set_label(id, text) {
  const state = mounted();
  if (state.labels.has(id)) state.labels.get(id).textContent = text;
}

export function make_slider(low, high, value, onChange) {
  const state = mounted();
  const id = fresh();
  const row = document.createElement("label");
  row.style.cssText = "display:flex;align-items:center;gap:8px";
  const input = document.createElement("input");
  input.type = "range";
  input.setAttribute("data-tinyweb-id", String(id));
  input.min = String(low);
  input.max = String(high);
  input.value = String(value);
  const shown = document.createElement("span");
  shown.textContent = input.value;
  input.addEventListener("input", () => {
    shown.textContent = input.value;
    onChange(Number(input.value));
  });
  row.append(input, shown);
  state.box.appendChild(row);
  return id;
}

export function load_sample(name) {
  const state = mounted();
  const id = fresh();
  const decoder = new OfflineAudioContext(1, 1, 44100);
  const fetchArray = (url) =>
    fetch(url).then((response) => {
      if (!response.ok) throw new Error(`${name}: ${response.status}`);
      return response.arrayBuffer();
    });
  state.samples.set(id, fetchArray(new URL(name, document.baseURI))
    .catch(() => fetchArray(new URL("tinyweb_assets/" + name, import.meta.url)))
    .then((bytes) => decoder.decodeAudioData(bytes))
    .catch((error) => {
      console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);
      return null;
    }));
  return id;
}

export function play_sample(sample, at, volume, rate) {
  const state = mounted();
  startAudio(state);
  const loading = state.samples.get(sample);
  if (!loading || state.audio === null) return;
  const audio = state.audio;
  loading.then((buffer) => {
    if (buffer === null) return;
    const source = audio.createBufferSource();
    source.buffer = buffer;
    source.playbackRate.value = rate;
    const gain = audio.createGain();
    gain.gain.value = volume;
    source.connect(gain).connect(audio.destination);
    source.start(Math.max(audio.currentTime, at - state.offset));
  });
}

export function time() {
  return clockNow(mounted());
}

export function on_frame(drawFrame) {
  const state = mounted();
  state.frames.push(drawFrame);
  if (!state.frameWanted) {
    state.frameWanted = true;
    const frame = () => {
      const t = clockNow(state);
      for (const f of state.frames.slice()) f(t);
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
}

export function on_mouse(c, click) {
  const entry = mounted().canvases.get(c);
  if (entry) entry.mice.push(click);
}

export function on_key(pressed) {
  mounted().keys.push(pressed);
}
