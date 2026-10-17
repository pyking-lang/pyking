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

// BEGIN tinyweb style
// The page's look: a theme, what the program changed of it for every
// element of a kind, and what it changed of one element. A theme and a
// kind's style are rules of a stylesheet of the page's own, scoped to the
// element the page is mounted in, so the host page's own rules do not
// reach in; one element's style is set on the element. This block is
// copied into tinyweb_external_browser.js by tools/tinyweb/embed_page.py.

// Each theme: CSS declarations for each place on the page (PLACES).
const THEMES = {
  light: {
    page: { "background": "#f6f6f4", "color": "#1d1f21", "font-family": "system-ui, sans-serif", "font-size": "15px" },
    box: { "gap": "8px" },
    button: {
      "background": "#f0f2f5", "color": "#1f2328", "border": "1px solid #d4d8de",
      "border-radius": "5px", "padding": "5px 10px", "font-family": "inherit", "font-size": "14px",
    },
    "button:hover": { "border-color": "#2f5fc4" },
    "button:active": { "background": "#e3e7ec" },
    "slider input": { "accent-color": "#2f5fc4" },
    canvas: { "border": "1px solid #c9ced6" },
  },
  dark: {
    page: { "background": "#1d1f21", "color": "#e6e6e6", "font-family": "system-ui, sans-serif", "font-size": "15px" },
    box: { "gap": "8px" },
    button: {
      "background": "#2f333a", "color": "#e6e6e6", "border": "1px solid #454a52",
      "border-radius": "5px", "padding": "5px 10px", "font-family": "inherit", "font-size": "14px",
    },
    "button:hover": { "border-color": "#7aa2f7" },
    "button:active": { "background": "#3a3f47" },
    "slider input": { "accent-color": "#7aa2f7" },
    canvas: { "border": "1px solid #454a52" },
  },
  plain: {
    page: { "background": "#ffffff", "color": "#000000", "font-family": "system-ui, sans-serif" },
    box: { "gap": "8px" },
    canvas: { "border": "1px solid #8884" },
  },
  paper: {
    page: { "background": "#fbf6ea", "color": "#3b3024", "font-family": "Georgia, 'Times New Roman', serif", "font-size": "16px" },
    box: { "gap": "10px" },
    button: {
      "background": "#fffdf7", "color": "#3b3024", "border": "1px solid #3b3024",
      "border-radius": "2px", "padding": "5px 14px", "font-family": "inherit", "font-size": "15px",
    },
    "button:hover": { "background": "#f1e8d2" },
    "button:active": { "background": "#e6d9bb" },
    "slider input": { "accent-color": "#8a5a2b" },
    canvas: { "border": "1px solid #3b302466" },
  },
  retro: {
    page: { "background": "#0b1a0b", "color": "#39ff6a", "font-family": "'Courier New', monospace", "font-size": "15px" },
    box: { "gap": "10px" },
    button: {
      "background": "#0b1a0b", "color": "#39ff6a", "border": "2px solid #39ff6a",
      "border-radius": "0", "padding": "4px 12px", "font-family": "inherit", "font-size": "15px",
    },
    "button:hover": { "background": "#133313" },
    "button:active": { "background": "#39ff6a", "color": "#0b1a0b" },
    "slider input": { "accent-color": "#39ff6a" },
    canvas: { "border": "2px solid #39ff6a" },
  },
};

// Where each place is, after the page's scope.
const PLACES = {
  page: "",
  box: " > .tinyweb-page",
  button: " .tinyweb-page button",
  "button:hover": " .tinyweb-page button:hover",
  "button:active": " .tinyweb-page button:active",
  label: " .tinyweb-page .tinyweb-label",
  slider: " .tinyweb-page .tinyweb-slider",
  "slider input": " .tinyweb-page .tinyweb-slider input",
  canvas: " .tinyweb-page canvas",
};

// What each property a program names is in CSS.
const PROPERTIES = {
  background: "background", color: "color", border: "border", radius: "border-radius",
  font: "font-family", size: "font-size", padding: "padding", gap: "gap",
  accent: "accent-color", width: "width",
};

// The place a kind's property goes. String -> String -> String
function placeOf(kind, property) {
  if (kind === "page") return property === "gap" ? "box" : "page";
  if (kind === "slider") return property === "accent" || property === "width" ? "slider input" : "slider";
  return kind;
}

let styledPages = 0;

// Gives the page mounted in `host` a stylesheet of its own, in the
// default theme. Element -> Element -> Style
function styled(host, box) {
  styledPages += 1;
  const sheet = document.createElement("style");
  sheet.setAttribute("data-tinyweb-style", String(styledPages));
  const style = { host, box, sheet, rules: null, elements: new Map(), name: String(styledPages) };
  host.setAttribute("data-tinyweb-page", style.name);
  (document.head || document.body).appendChild(sheet);
  setTheme(style, "light");
  return style;
}

// Writes the stylesheet from the rules. Style -> ()
function writeSheet(style) {
  // The scope three times over, so the host page's rules for a button or
  // a body do not outweigh the page's own.
  const scope = `[data-tinyweb-page="${style.name}"]`.repeat(3);
  const text = [];
  for (const place of Object.keys(PLACES)) {
    const declarations = style.rules[place];
    if (!declarations || Object.keys(declarations).length === 0) continue;
    const body = Object.entries(declarations).map(([k, v]) => `${k}: ${v};`).join(" ");
    text.push(`${scope}${PLACES[place]} { ${body} }`);
  }
  style.sheet.textContent = text.join("\n");
}

// Puts the page in a theme, forgetting what was changed for each kind.
// An unknown name changes nothing. Style -> String -> ()
function setTheme(style, name) {
  const theme = THEMES[name];
  if (!theme) return;
  style.rules = {};
  for (const [place, declarations] of Object.entries(theme)) {
    style.rules[place] = { ...declarations };
  }
  writeSheet(style);
}

// Remembers a page element by its id, so that its own style can be set.
// Style -> Int -> Element -> ()
function remember(style, id, element) {
  style.elements.set(id, element);
}

// Carries out one style command: a theme, a property of every element
// of a kind, or a property of the element `id` (kind "element").
// Style -> Int -> String -> String -> String -> ()
function applyStyle(style, id, kind, property, value) {
  if (kind === "theme") {
    setTheme(style, value);
    return;
  }
  const css = PROPERTIES[property];
  if (!css) return;
  if (kind === "element") {
    let element = style.elements.get(id);
    if (!element) return;
    // A slider's own properties are its input's; the rest are its row's.
    if (element.tagName === "INPUT" && property !== "accent" && property !== "width") {
      element = element.parentNode;
    }
    element.style.setProperty(css, value);
    return;
  }
  const place = placeOf(kind, property);
  if (!(place in PLACES)) return;
  if (!style.rules[place]) style.rules[place] = {};
  style.rules[place][css] = value;
  writeSheet(style);
}

// Takes the page's look off the element it was mounted in. Style -> ()
function unstyled(style) {
  style.sheet.remove();
  if (style.host.getAttribute("data-tinyweb-page") === style.name) {
    style.host.removeAttribute("data-tinyweb-page");
  }
}
// What the splash screen says until the program sets it.
const SPLASH_TEXT = "Click to Start";

// The splash screen: the whole window dimmed, and `text` in white in
// its middle under a play sign. String -> Element
function splashScreen(text) {
  const screen = document.createElement("div");
  screen.className = "tinyweb-splash";
  screen.setAttribute("role", "button");
  screen.style.cssText =
    "position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;" +
    "align-items:center;justify-content:center;gap:24px;background:rgba(0,0,0,0.62);" +
    "color:#ffffff;cursor:pointer;user-select:none;font-family:system-ui,sans-serif";
  const ring = document.createElement("div");
  ring.style.cssText =
    "width:88px;height:88px;border-radius:50%;border:3px solid #ffffff;display:flex;" +
    "align-items:center;justify-content:center;box-shadow:0 0 36px rgba(255,255,255,0.35)";
  const sign = document.createElement("div");
  sign.style.cssText =
    "width:0;height:0;margin-left:9px;border-top:19px solid transparent;" +
    "border-bottom:19px solid transparent;border-left:32px solid #ffffff";
  ring.appendChild(sign);
  const words = document.createElement("div");
  words.textContent = text;
  words.style.cssText =
    "font-size:34px;font-weight:600;letter-spacing:0.03em;text-align:center;" +
    "padding:0 24px;text-shadow:0 2px 14px rgba(0,0,0,0.6)";
  screen.append(ring, words);
  return screen;
}

// Whether the reader has already done something on this page, which is
// all a browser asks before it plays a sound. () -> Bool
function readerActive() {
  return Boolean(globalThis.navigator?.userActivation?.hasBeenActive);
}
// END tinyweb style

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
    "display:flex;flex-direction:column;align-items:flex-start;outline:none";
  element.appendChild(box);

  const state = {
    box,
    look: styled(element, box),
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
    // The splash screen: what it says, whether it has been shown, and
    // while it is shown the element, what is held until it is dismissed,
    // and the clock where it stopped.
    splashText: SPLASH_TEXT,
    splashDone: false,
    splash: null,
    held: null,
    heldClock: 0,
    heldAt: 0,
  };

  if (!standalone) box.tabIndex = 0;
  box.addEventListener("pointerdown", () => startAudio(state));
  state.keyTarget.addEventListener("keydown", (event) => {
    if (state.held !== null) {
      dismissSplash(state, event);
      return;
    }
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
  if (state.held !== null) return state.heldClock;
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

// Does what a function does to the page now, or once the splash screen
// is dismissed while it is shown. State -> (() -> ()) -> ()
function act(state, effect) {
  if (state.held !== null) state.held.push(effect);
  else effect();
}

// Whether a sound now would need the splash screen first. State -> Bool
function splashWanted(state) {
  return !state.splashDone && state.splashText !== "" && !running(state) && !readerActive();
}

// Shows the splash screen and holds what comes after it: what the
// program does to the page, its frames and the clock. State -> ()
function showSplash(state) {
  state.splashDone = true;
  state.heldClock = clockNow(state);
  state.heldAt = now();
  state.held = [];
  const splash = splashScreen(state.splashText);
  const dismiss = (event) => dismissSplash(state, event);
  splash.addEventListener("click", dismiss);
  window.addEventListener("keydown", dismiss, true);
  state.splash = { element: splash, dismiss };
  document.body.appendChild(splash);
}

// The reader's click or key: the splash screen goes, sound starts, the
// clock goes on from where it stopped, and what was held is done.
// State -> Event -> ()
function dismissSplash(state, event) {
  if (state.held === null) return;
  event?.preventDefault?.();
  event?.stopImmediatePropagation?.();
  window.removeEventListener("keydown", state.splash.dismiss, true);
  state.splash.element.remove();
  state.splash = null;
  state.start += now() - state.heldAt;
  const pending = state.held;
  state.held = null;
  startAudio(state);
  for (const effect of pending) effect();
}

function draw(c, paint) {
  const state = mounted();
  act(state, () => {
    const entry = state.canvases.get(c);
    if (entry) paint(entry.context, entry);
  });
}

// --- the functions tinyweb_external.pyk declares ---

export function web_init(port) {}

export function canvas(width, height) {
  const state = mounted();
  const id = fresh();
  act(state, () => newCanvas(state, id, width, height));
  return id;
}

function newCanvas(state, id, width, height) {
  const element = document.createElement("canvas");
  element.setAttribute("data-tinyweb-id", String(id));
  const ratio = globalThis.devicePixelRatio || 1;
  element.width = Math.round(width * ratio);
  element.height = Math.round(height * ratio);
  element.style.width = width + "px";
  element.style.height = height + "px";
  element.style.background = "#ffffff";
  const context = element.getContext("2d");
  context.scale(ratio, ratio);
  const entry = { element, context, width, height, mice: [] };
  state.canvases.set(id, entry);
  remember(state.look, id, element);
  element.addEventListener("click", (event) => {
    if (entry.mice.length === 0) return;
    const bounds = element.getBoundingClientRect();
    const x = Math.round(((event.clientX - bounds.left) * width) / bounds.width);
    const y = Math.round(((event.clientY - bounds.top) * height) / bounds.height);
    for (const click of entry.mice.slice()) click(x, y);
  });
  state.box.appendChild(element);
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
  act(state, () => newButton(state, id, title, onClick));
  return id;
}

function newButton(state, id, title, onClick) {
  const button = document.createElement("button");
  button.setAttribute("data-tinyweb-id", String(id));
  button.textContent = title;
  button.addEventListener("click", () => {
    startAudio(state);
    onClick();
  });
  remember(state.look, id, button);
  state.box.appendChild(button);
}

export function label(text) {
  const state = mounted();
  const id = fresh();
  act(state, () => newLabel(state, id, text));
  return id;
}

function newLabel(state, id, text) {
  const shown = document.createElement("div");
  shown.className = "tinyweb-label";
  shown.setAttribute("data-tinyweb-id", String(id));
  shown.textContent = text;
  state.labels.set(id, shown);
  remember(state.look, id, shown);
  state.box.appendChild(shown);
}

export function set_label(id, text) {
  const state = mounted();
  act(state, () => {
    if (state.labels.has(id)) state.labels.get(id).textContent = text;
  });
}

export function make_slider(low, high, value, onChange) {
  const state = mounted();
  const id = fresh();
  act(state, () => newSlider(state, id, low, high, value, onChange));
  return id;
}

function newSlider(state, id, low, high, value, onChange) {
  const row = document.createElement("label");
  row.className = "tinyweb-slider";
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
  remember(state.look, id, input);
  state.box.appendChild(row);
}

export function apply_style(id, kind, property, value) {
  const state = mounted();
  act(state, () => applyStyle(state.look, id, kind, property, value));
}

export function load_sample(name) {
  const state = mounted();
  const id = fresh();
  act(state, () => loadSample(state, id, name));
  return id;
}

function loadSample(state, id, name) {
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
}

export function play_sample(sample, at, volume, rate) {
  const state = mounted();
  if (state.held === null && splashWanted(state)) showSplash(state);
  act(state, () => playSample(state, sample, at, volume, rate));
}

export function splash() {
  const state = mounted();
  act(state, () => {
    if (splashWanted(state)) showSplash(state);
  });
}

export function set_splash(message) {
  const state = mounted();
  act(state, () => {
    state.splashText = message;
  });
}

function playSample(state, sample, at, volume, rate) {
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
      if (state.held === null) {
        const t = clockNow(state);
        for (const f of state.frames.slice()) f(t);
      }
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
}

export function on_mouse(c, click) {
  const state = mounted();
  act(state, () => {
    const entry = state.canvases.get(c);
    if (entry) entry.mice.push(click);
  });
}

export function on_key(pressed) {
  mounted().keys.push(pressed);
}
