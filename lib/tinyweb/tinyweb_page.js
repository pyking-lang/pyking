// tinyweb's page: the renderer that carries out the commands a program
// sends and reports the events its reader causes. It is the one copy of
// that code, used wherever a program talks to its page in commands:
//
//   - on an iweb24 page, where tinyweb_external_interpreter.js mounts it
//     and calls it directly;
//   - in the playground and the notebook, where the program runs on a
//     worker and tools/webrun/assets/pages.js mounts it on the page;
//   - on the page a compiled program serves after `web_init`, where
//     tinyweb_page.html mounts it and the commands arrive from the
//     program over HTTP. Each native implementation carries a copy of
//     this file and of tinyweb_page.html, written into it by
//     tools/tinyweb/embed_page.py.
//
// A command is a plain object such as {op: "circle", c, x, y, radius,
// color}, and an event one such as {ev: "click", id}; see
// docs/libraries.md, "tinyweb". The web24 implementation,
// tinyweb_external_browser.js, does what this file does without the
// commands in between. Keep the file ASCII: it is embedded in C.

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
// END tinyweb style

// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:
// `receive(commands)` carries out a batch of commands, and `send(event)`
// is how the page reports one. `standalone` is true where the page is
// the whole document, which is where a key press is listened for; a
// page inside another (a notebook cell) listens on `element`, which
// takes the focus when clicked.
export function mountPage(element, sendEvent, { standalone = false } = {}) {
  const box = document.createElement("div");
  box.className = "tinyweb-page";
  box.style.cssText =
    "display:flex;flex-direction:column;align-items:flex-start;outline:none";
  element.appendChild(box);
  const look = styled(element, box);

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
  // Inside another page the keys go to the element the page is mounted
  // in, which takes the focus when anything in it is clicked; that page
  // shows the focus (:focus-within).
  const keyTarget = standalone ? window : element;
  let keysWanted = false;

  let focusable = false;    // whether mounting made `element` focusable

  function takeFocus(event) {
    // A slider keeps the focus for its arrow keys.
    if (!event.target.closest("input")) element.focus({ preventScroll: true });
  }

  if (!standalone) {
    focusable = element.tabIndex < 0;
    if (focusable) element.tabIndex = 0;
    element.addEventListener("click", takeFocus);
  }

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
    element.setAttribute("data-tinyweb-id", String(id));
    const ratio = globalThis.devicePixelRatio || 1;
    element.width = Math.round(width * ratio);
    element.height = Math.round(height * ratio);
    element.style.width = width + "px";
    element.style.height = height + "px";
    element.style.background = "#ffffff";
    const context = element.getContext("2d");
    context.scale(ratio, ratio);
    canvases.set(id, { element, context, width, height, mouse: false });
    remember(look, id, element);
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
        button.setAttribute("data-tinyweb-id", String(command.id));
        button.textContent = command.title;
        button.addEventListener("click", () => {
          startAudio();
          report({ ev: "click", id: command.id });
        });
        remember(look, command.id, button);
        box.appendChild(button);
        break;
      }
      case "label": {
        const text = document.createElement("div");
        text.className = "tinyweb-label";
        text.setAttribute("data-tinyweb-id", String(command.id));
        text.textContent = command.text;
        labels.set(command.id, text);
        remember(look, command.id, text);
        box.appendChild(text);
        break;
      }
      case "set_label":
        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;
        break;
      case "slider": {
        const row = document.createElement("label");
        row.className = "tinyweb-slider";
        row.style.cssText = "display:flex;align-items:center;gap:8px";
        const input = document.createElement("input");
        input.type = "range";
        input.setAttribute("data-tinyweb-id", String(command.id));
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
        remember(look, command.id, input);
        box.appendChild(row);
        break;
      }
      case "style":
        applyStyle(look, command.id, command.kind, command.prop, command.value);
        break;
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
        // Inside another page the keys go where the focus is, which is
        // still the Run button that started the program; one typing in
        // an editor keeps it.
        if (!standalone && !typing()) element.focus({ preventScroll: true });
        break;
    }
  }

  function typing() {
    const active = document.activeElement;
    return !!active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));
  }

  function freeze() {
    if (closed) return;
    closed = true;
    cancelAnimationFrame(frameRequest);
    keyTarget.removeEventListener("keydown", onKey);
    if (!standalone) element.removeEventListener("click", takeFocus);
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
      unstyled(look);
      if (focusable) {
        element.removeAttribute("tabindex");
        element.blur();
      }
    },
  };
}
