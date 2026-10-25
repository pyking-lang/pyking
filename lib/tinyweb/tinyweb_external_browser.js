// The JavaScript implementation of the names declared in
// tinyweb_external.pyk for web: a program compiled to JavaScript and
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
  accent: "accent-color", width: "width", height: "height", align: "align-items",
  weight: "font-weight",
};

// What an `align` a program names is in CSS.
const ALIGNMENTS = { left: "flex-start", center: "center", right: "flex-end" };

// The place a kind's property goes. String -> String -> String
function placeOf(kind, property) {
  if (kind === "page") return property === "gap" || property === "align" ? "box" : "page";
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
function applyStyle(style, id, kind, property, given) {
  if (kind === "theme") {
    setTheme(style, given);
    return;
  }
  const css = PROPERTIES[property];
  if (!css) return;
  const value = property === "align" ? ALIGNMENTS[given] || "flex-start" : given;
  if (kind === "page" && property === "align") {
    // The box says where its elements stand on the element itself.
    style.box.style.setProperty(css, value);
    return;
  }
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
// --- drawing (step 1) ---

// A shape's numbers: the words tinyweb.pyk wrote, as numbers.
function numbersOf(text) {
  return text === "" ? [] : text.split(" ").map(Number);
}

// A rectangle with rounded corners, as a path. Context -> ... -> ()
function roundedRect(g, x, y, w, h, r) {
  const k = Math.max(0, Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2));
  g.moveTo(x + k, y);
  g.arcTo(x + w, y, x + w, y + h, k);
  g.arcTo(x + w, y + h, x, y + h, k);
  g.arcTo(x, y + h, x, y, k);
  g.arcTo(x, y, x + w, y, k);
  g.closePath();
}

// The outline of one shape, added to the context's path. Whether a filled
// arc is a slice from its centre is `slice`'s.
// Context -> String -> [Float] -> Bool -> ()
function shapePath(g, kind, n, slice) {
  switch (kind) {
    case "rect":
      if (n[4] > 0) roundedRect(g, n[0], n[1], n[2], n[3], n[4]);
      else g.rect(n[0], n[1], n[2], n[3]);
      break;
    case "circle":
      g.arc(n[0], n[1], Math.max(0, n[2]), 0, 2 * Math.PI);
      break;
    case "ellipse":
      g.ellipse(n[0], n[1], Math.max(0, n[2]), Math.max(0, n[3]), 0, 0, 2 * Math.PI);
      break;
    case "arc":
      if (slice) g.moveTo(n[0], n[1]);
      g.arc(n[0], n[1], Math.max(0, n[2]), n[3], n[4]);
      if (slice) g.closePath();
      break;
    case "line":
      g.moveTo(n[0], n[1]);
      g.lineTo(n[2], n[3]);
      break;
    case "lines":
      for (let i = 0; i + 3 < n.length; i += 4) {
        g.moveTo(n[i], n[i + 1]);
        g.lineTo(n[i + 2], n[i + 3]);
      }
      break;
    case "curve":
      g.moveTo(n[0], n[1]);
      g.quadraticCurveTo(n[2], n[3], n[4], n[5]);
      break;
    case "bezier":
      g.moveTo(n[0], n[1]);
      g.bezierCurveTo(n[2], n[3], n[4], n[5], n[6], n[7]);
      break;
    case "polygon":
    case "path":
      for (let i = 0; i + 1 < n.length; i += 2) {
        if (i === 0) g.moveTo(n[i], n[i + 1]);
        else g.lineTo(n[i], n[i + 1]);
      }
      if (kind === "polygon") g.closePath();
      break;
  }
}

// The gradients a canvas has been given, by the text that describes
// them, so a frame drawing the same one again does not make it again.
const GRADIENTS_KEPT = 64;

// What a color means on a context: a CSS color as it is, and a gradient
// tinyweb.pyk described -- "linear-gradient(x1 y1 x2 y2); 0 red; 1 blue",
// "radial-gradient(x1 y1 r1 x2 y2 r2); ...", "conic-gradient(x y
// angle); ..." -- as the gradient. Context -> Entry? -> String -> Paint
function paint(g, entry, color) {
  const open = color.indexOf("(");
  if (open < 0 || !color.slice(0, open).endsWith("-gradient")) return color;
  const close = color.indexOf(")", open);
  if (close < 0 || color.slice(close + 1, close + 2) !== ";") return color;
  const kept = entry ? entry.gradients : null;
  if (kept && kept.has(color)) return kept.get(color);
  const kind = color.slice(0, open);
  const n = numbersOf(color.slice(open + 1, close).trim());
  let gradient;
  if (kind === "linear-gradient") gradient = g.createLinearGradient(n[0], n[1], n[2], n[3]);
  else if (kind === "radial-gradient")
    gradient = g.createRadialGradient(n[0], n[1], Math.max(0, n[2]), n[3], n[4], Math.max(0, n[5]));
  else if (kind === "conic-gradient" && typeof g.createConicGradient === "function")
    gradient = g.createConicGradient(n[2], n[0], n[1]);
  else return "#000000";
  // A stop's color may itself hold brackets and commas, "rgba(0, 0, 0, 0.5)",
  // but never a semicolon.
  for (const stop of color.slice(close + 2).split(";")) {
    const text = stop.trim();
    const space = text.indexOf(" ");
    if (space < 0) continue;
    const at = Math.min(1, Math.max(0, Number(text.slice(0, space))));
    try {
      gradient.addColorStop(at, text.slice(space + 1).trim());
    } catch (error) {
      // A stop whose color the browser does not read is left out.
    }
  }
  if (kept) {
    if (kept.size >= GRADIENTS_KEPT) kept.delete(kept.keys().next().value);
    kept.set(color, gradient);
  }
  return gradient;
}

// Draws one shape: filled with `color` and outlined with `outline`, each
// unless it is "", at `alpha`, in the canvas's line style. The numbers
// are the kind's own (see tinyweb.pyk), as words or as an array;
// "erase" makes its rectangle transparent, and "circles" draws each
// circle on its own. Context -> Entry? -> String -> Numbers -> ... -> ()
function drawShape(g, entry, kind, numbers, color, outline, width, alpha) {
  const n = typeof numbers === "string" ? numbersOf(numbers) : numbers;
  if (kind === "erase") {
    g.clearRect(n[0], n[1], n[2], n[3]);
    return;
  }
  const before = g.globalAlpha;
  g.globalAlpha = before * alpha;
  if (kind === "circles") {
    // Each circle on its own, so where two overlap both show.
    if (color !== "") g.fillStyle = paint(g, entry, color);
    if (outline !== "") {
      g.strokeStyle = paint(g, entry, outline);
      g.lineWidth = width;
    }
    for (let i = 0; i + 2 < n.length; i += 3) {
      g.beginPath();
      g.arc(n[i], n[i + 1], Math.max(0, n[i + 2]), 0, 2 * Math.PI);
      if (color !== "") g.fill();
      if (outline !== "") g.stroke();
    }
    g.globalAlpha = before;
    return;
  }
  g.beginPath();
  shapePath(g, kind, n, color !== "");
  if (color !== "") {
    g.fillStyle = paint(g, entry, color);
    g.fill();
  }
  if (outline !== "") {
    g.strokeStyle = paint(g, entry, outline);
    g.lineWidth = width;
    g.stroke();
  }
  g.globalAlpha = before;
}

// The font text is written in. Int -> String -> Bool -> String
function fontOf(size, font, bold) {
  return `${bold ? "bold " : ""}${size}px ${font === "" ? "system-ui, sans-serif" : font}`;
}

// Writes text at (x, y): its left end there, its middle or its right end,
// as `align` says, and its top, middle, alphabetic baseline or bottom,
// as `baseline` says. An `outline` is drawn round the letters first.
// Context -> Entry? -> ... -> ()
function drawText(g, entry, x, y, words, color, size, font, align, baseline, bold, outline,
  outlineWidth, alpha) {
  const before = g.globalAlpha;
  g.globalAlpha = before * alpha;
  g.font = fontOf(size, font, bold);
  g.textBaseline = ["top", "middle", "alphabetic", "bottom"].includes(baseline) ? baseline : "top";
  g.textAlign = align === "center" || align === "right" ? align : "left";
  if (outline !== "") {
    g.strokeStyle = paint(g, entry, outline);
    g.lineWidth = outlineWidth;
    g.strokeText(words, x, y);
  }
  if (color !== "") {
    g.fillStyle = paint(g, entry, color);
    g.fillText(words, x, y);
  }
  g.globalAlpha = before;
}

// How wide `words` is written in that font, in pixels.
// String -> Int -> String -> Bool -> Float
function textWidth(words, size, font, bold) {
  if (typeof document === "undefined") return 0;
  if (!textWidth.context) textWidth.context = document.createElement("canvas").getContext("2d");
  const g = textWidth.context;
  if (!g) return 0;
  g.font = fontOf(size, font, bold);
  return g.measureText(words).width;
}

// The line style a canvas starts with: round ends and corners, no dashes.
// Context -> ()
function plainLines(g) {
  g.lineCap = "round";
  g.lineJoin = "round";
  if (typeof g.setLineDash === "function") g.setLineDash([]);
  g.lineDashOffset = 0;
}

// Changes what the next drawing on a canvas is drawn with. `entry` keeps
// the canvas's pixel ratio and how many `push`es are open.
// Context -> Entry -> String -> String -> String -> ()
function canvasState(g, entry, kind, value, numbers) {
  const n = numbersOf(numbers);
  switch (kind) {
    case "translate":
      g.translate(n[0], n[1]);
      break;
    case "rotate":
      g.rotate(n[0]);
      break;
    case "scale":
      g.scale(n[0], n[1]);
      break;
    case "push":
      g.save();
      entry.depth += 1;
      break;
    case "pop":
      if (entry.depth > 0) {
        g.restore();
        entry.depth -= 1;
      }
      break;
    case "reset":
      g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);
      break;
    case "shadow":
      g.shadowColor = value === "" ? "transparent" : value;
      g.shadowBlur = value === "" ? 0 : n[0];
      g.shadowOffsetX = value === "" ? 0 : n[1];
      g.shadowOffsetY = value === "" ? 0 : n[2];
      break;
    case "blend":
      g.globalCompositeOperation = value === "add" ? "lighter" : "source-over";
      break;
    case "line_style": {
      // value: the ends and the corners; numbers: the dash offset, then
      // the lengths of the dashes and the gaps.
      const [cap, join] = value.split(" ");
      g.lineCap = ["butt", "round", "square"].includes(cap) ? cap : "round";
      g.lineJoin = ["miter", "round", "bevel"].includes(join) ? join : "round";
      if (typeof g.setLineDash === "function") g.setLineDash(n.slice(1));
      g.lineDashOffset = n.length > 0 ? n[0] : 0;
      break;
    }
    case "clip":
      // value: the kind of shape the drawing is kept inside.
      g.beginPath();
      shapePath(g, value, n, false);
      g.clip();
      break;
  }
}

// A canvas as it starts: every `push` closed, no transformation but the
// pixel ratio, no shadow, no blending, no clipping and plain lines. What
// `clear` begins with. Context -> Entry -> ()
function freshState(g, entry) {
  while (entry.depth > 0) {
    g.restore();
    entry.depth -= 1;
  }
  g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);
  g.globalAlpha = 1;
  g.shadowColor = "transparent";
  g.shadowBlur = 0;
  g.shadowOffsetX = 0;
  g.shadowOffsetY = 0;
  g.globalCompositeOperation = "source-over";
  plainLines(g);
}

// Starts loading a picture: beside the page first, then among the ones
// tinyweb ships beside `base`. Answers what `drawPicture` draws once it
// has loaded; `loading` is true until it has loaded or failed, and then
// each function in `settled` is called. String -> String -> Picture
function loadPicture(name, base) {
  const picture = { element: null, ready: false, retried: false, loading: false, settled: [] };
  if (typeof Image === "undefined") return picture;
  const element = new Image();
  picture.element = element;
  picture.loading = true;
  const settle = () => {
    picture.loading = false;
    for (const then of picture.settled.splice(0)) then();
  };
  element.onload = () => {
    picture.ready = true;
    settle();
  };
  element.onerror = () => {
    if (picture.retried) {
      console.error(`tinyweb: cannot load the picture ${name}`);
      settle();
      return;
    }
    picture.retried = true;
    element.src = new URL("tinyweb_assets/" + name, base).href;
  };
  element.src = new URL(name, document.baseURI).href;
  return picture;
}

// Draws a picture that has loaded; one still loading is not drawn.
// Context -> Picture? -> ... -> ()
function drawPicture(g, picture, x, y, width, height, alpha) {
  if (!picture || !picture.ready) return;
  const before = g.globalAlpha;
  g.globalAlpha = before * alpha;
  g.drawImage(picture.element, x, y, width, height);
  g.globalAlpha = before;
}

// Keeps the pointer's moves and its release coming to the canvas it went
// down on, wherever it goes. Element -> Event -> ()
function capture(element, event) {
  try {
    if (element.setPointerCapture) element.setPointerCapture(event.pointerId);
  } catch (error) {
    // A pointer the browser does not know of, as a test's is, is not held.
  }
}

// --- bitmaps (step 5) ---

// The bytes of a bitmap's rectangle as they arrive: a base64 string from
// a program on another host, or the bytes themselves. Data -> Uint8ClampedArray
function bitmapBytes(data) {
  if (typeof data !== "string") {
    return ArrayBuffer.isView(data)
      ? new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)
      : new Uint8ClampedArray(data);
  }
  const text = atob(data);
  const bytes = new Uint8ClampedArray(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

// A bitmap as the page keeps it: a canvas of its own, its pixels.
// Int -> Int -> Surface
function bitmapSurface(width, height) {
  const element = document.createElement("canvas");
  element.width = Math.max(1, width);
  element.height = Math.max(1, height);
  return { element, context: element.getContext("2d"), width, height };
}

// Puts the rectangle (rx, ry, rw, rh) of a bitmap's pixels on its
// surface. Surface -> Int -> Int -> Int -> Int -> Data -> ()
function updateSurface(surface, rx, ry, rw, rh, data) {
  if (rw <= 0 || rh <= 0) return;
  const bytes = bitmapBytes(data);
  if (bytes.length !== rw * rh * 4) return;
  surface.context.putImageData(new ImageData(bytes, rw, rh), rx, ry);
}

// Draws a bitmap's surface with its top left corner at (x, y), each pixel
// `scale` pixels across: sharp squares when it grows, smooth when it
// shrinks. Context -> Surface -> Float -> Float -> Float -> ()
function drawSurface(g, surface, x, y, scale) {
  const smoothing = g.imageSmoothingEnabled;
  g.imageSmoothingEnabled = scale < 1;
  g.drawImage(surface.element, x, y, surface.width * scale, surface.height * scale);
  g.imageSmoothingEnabled = smoothing;
}

// A box whose elements go side by side, wrapping where the page is too
// narrow for them, or one below another. String -> Bool -> Element
function rowElement(id, across = true) {
  const row = document.createElement("div");
  row.className = across ? "tinyweb-row" : "tinyweb-column";
  row.setAttribute("data-tinyweb-id", id);
  row.style.cssText = across
    ? "display:flex;flex-direction:row;flex-wrap:wrap;align-items:center;gap:8px"
    : "display:flex;flex-direction:column;align-items:flex-start;gap:6px";
  return row;
}

// --- widgets (step 2) ---

// A checkbox or a radio button with its title beside it: the row, and
// the input in it. String -> String -> String -> Bool -> (Element, Element)
function choiceRow(type, id, title, checked) {
  const row = document.createElement("label");
  row.className = type === "checkbox" ? "tinyweb-check" : "tinyweb-radio";
  row.style.cssText = "display:flex;align-items:center;gap:6px";
  const input = document.createElement("input");
  input.type = type;
  input.setAttribute("data-tinyweb-id", id);
  input.checked = checked;
  const text = document.createElement("span");
  text.textContent = title;
  row.append(input, text);
  return { row, input };
}

// A dropdown of the options, one per line of `options`, the one at
// `chosen` chosen. String -> String -> Int -> Element
function choiceElement(id, options, chosen) {
  const select = document.createElement("select");
  select.className = "tinyweb-choice";
  select.setAttribute("data-tinyweb-id", id);
  options.split("\n").forEach((text, position) => {
    const option = document.createElement("option");
    option.value = String(position);
    option.textContent = text;
    select.appendChild(option);
  });
  select.value = String(chosen);
  return select;
}

// A line to type text into. String -> String -> Element
function textInputElement(id, placeholder) {
  const input = document.createElement("input");
  input.type = "text";
  input.className = "tinyweb-text";
  input.setAttribute("data-tinyweb-id", id);
  input.placeholder = placeholder;
  return input;
}

// A field for a whole number from `low` to `high`. ... -> Element
function numberElement(id, low, high, value) {
  const input = document.createElement("input");
  input.type = "number";
  input.className = "tinyweb-number";
  input.setAttribute("data-tinyweb-id", id);
  input.min = String(low);
  input.max = String(high);
  input.value = String(value);
  return input;
}

// Whether a key press is the reader typing into a field, which the page
// does not report as a key. Event -> Bool
function typedInField(event) {
  const target = event.target;
  return !!target && typeof target.tagName === "string"
    && (target.tagName === "SELECT"
      || target.tagName === "TEXTAREA"
      || (target.tagName === "INPUT" && (target.type === "text" || target.type === "number")));
}

// --- the engine: sound, the beat, timers and changing the page ---
// What every `cmd` command does, the same for the page a program sends
// commands to and for web, which calls it directly: makeEngine(host)
// answers {command(cmd), reports(withSound), frozen(), held(cmd), close()}.
// `host` is what the engine needs of the page:
//   audio() -- the AudioContext once sound has started, or null
//   startAudio() -- starts sound, where the reader has already done something
//   clock() -- the page's clock, in seconds
//   toAudio(t) -- a time on the page's clock as a time on the audio clock
//   thaw(t) -- the clock goes on from `t` after a pause
//   sample(id) -- a sample's loading, a Promise of its AudioBuffer (or null)
//   addSample(id, loading) -- a sample loaded another way: a file the reader chose
//   element(id) -- an element by its identifier; forget(id) when it is removed
//   remember(id, element), place(element) -- a new element, put on the page
//   canvas(id) -- a canvas's {element, width, height}
//   send(event) -- reports an event to the program

// How far ahead the beat is scheduled, and how often it is looked at.
const LOOKAHEAD = 0.15;
const TICK_MS = 25;

// The numbers a command carries. String -> [Float]
function engineNumbers(text) {
  return text === "" || text === undefined ? [] : String(text).trim().split(/\s+/).map(Number);
}

// A buffer played backwards, made once per buffer. AudioContext -> AudioBuffer -> AudioBuffer
const reversedBuffers = new WeakMap();
function reversedOf(context, buffer) {
  let done = reversedBuffers.get(buffer);
  if (done) return done;
  done = context.createBuffer(buffer.numberOfChannels, buffer.length, buffer.sampleRate);
  for (let k = 0; k < buffer.numberOfChannels; k++) {
    const from = buffer.getChannelData(k);
    const to = done.getChannelData(k);
    for (let i = 0, n = from.length; i < n; i++) to[i] = from[n - 1 - i];
  }
  reversedBuffers.set(buffer, done);
  return done;
}

// A reverb's impulse: two seconds of noise dying away. AudioContext -> AudioBuffer
function impulseOf(context) {
  const length = Math.round(context.sampleRate * 2);
  const impulse = context.createBuffer(2, length, context.sampleRate);
  // The same noise every time, so a render comes out the same.
  let seed = 22222;
  const random = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    return seed / 2147483648;
  };
  for (let k = 0; k < 2; k++) {
    const data = impulse.getChannelData(k);
    for (let i = 0; i < length; i++) data[i] = (random() * 2 - 1) * Math.pow(1 - i / length, 3);
  }
  return impulse;
}

// A channel's settings as `channel_style` gives them.
const CHANNEL_DEFAULT = { volume: 1, pan: 0, echo: 0, echoTime: 0.3, feedback: 0.35, reverb: 0, lowPass: 0 };

// The sound graph of one AudioContext: a master volume, an analyser on
// it, and the channels each sound goes through: volume, pan, a low-pass
// filter, and sends to an echo and a reverb. AudioContext -> {..}
function soundGraph(context) {
  const master = context.createGain();
  const analyser = context.createAnalyser ? context.createAnalyser() : null;
  if (analyser) {
    master.connect(analyser);
    analyser.connect(context.destination);
  } else {
    master.connect(context.destination);
  }
  const channels = new Map();
  let impulse = null;
  function channel(n) {
    let ch = channels.get(n);
    if (ch) return ch;
    const input = context.createGain();
    const panner = context.createStereoPanner ? context.createStereoPanner() : null;
    const filter = context.createBiquadFilter();
    filter.type = "lowpass";
    filter.frequency.value = 22050;
    const out = context.createGain();
    if (panner) input.connect(panner).connect(filter);
    else input.connect(filter);
    filter.connect(out);
    out.connect(master);
    const delay = context.createDelay(5);
    const feedback = context.createGain();
    const echo = context.createGain();
    echo.gain.value = 0;
    out.connect(echo);
    echo.connect(delay);
    delay.connect(feedback);
    feedback.connect(delay);
    delay.connect(master);
    const reverb = context.createGain();
    reverb.gain.value = 0;
    let convolver = null;
    ch = { input, panner, filter, out, delay, feedback, echo, reverb, convolver };
    channels.set(n, ch);
    return ch;
  }
  function style(n, settings) {
    const ch = channel(n);
    ch.out.gain.value = settings.volume;
    if (ch.panner) ch.panner.pan.value = Math.max(-1, Math.min(1, settings.pan));
    ch.filter.frequency.value = settings.lowPass > 0 ? settings.lowPass : 22050;
    ch.echo.gain.value = settings.echo;
    ch.delay.delayTime.value = Math.max(0.001, Math.min(5, settings.echoTime));
    ch.feedback.gain.value = Math.max(0, Math.min(0.95, settings.feedback));
    if (settings.reverb > 0 && ch.convolver === null && context.createConvolver) {
      if (impulse === null) impulse = impulseOf(context);
      ch.convolver = context.createConvolver();
      ch.convolver.buffer = impulse;
      ch.out.connect(ch.reverb);
      ch.reverb.connect(ch.convolver);
      ch.convolver.connect(master);
    }
    ch.reverb.gain.value = settings.reverb;
  }
  return { context, master, analyser, channel, style };
}

// A WAV file of a rendered buffer, 16 bits, as bytes. AudioBuffer -> Uint8Array
function wavBytes(buffer) {
  const channels = buffer.numberOfChannels;
  const frames = buffer.length;
  const bytes = new Uint8Array(44 + frames * channels * 2);
  const view = new DataView(bytes.buffer);
  const text = (at, s) => { for (let i = 0; i < s.length; i++) bytes[at + i] = s.charCodeAt(i); };
  text(0, "RIFF");
  view.setUint32(4, 36 + frames * channels * 2, true);
  text(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, buffer.sampleRate, true);
  view.setUint32(28, buffer.sampleRate * channels * 2, true);
  view.setUint16(32, channels * 2, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, frames * channels * 2, true);
  const data = [];
  for (let k = 0; k < channels; k++) data.push(buffer.getChannelData(k));
  let at = 44;
  for (let i = 0; i < frames; i++) {
    for (let k = 0; k < channels; k++) {
      const v = Math.max(-1, Math.min(1, data[k][i]));
      view.setInt16(at, v < 0 ? v * 0x8000 : v * 0x7fff, true);
      at += 2;
    }
  }
  return bytes;
}

// Offers `blob` to the reader as a file called `name`. Blob -> String -> ()
function offerDownload(blob, name) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = name;
  link.style.display = "none";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 10000);
}

function makeEngine(host) {
  let graph = null;              // the live context's sound graph
  const settings = new Map();    // channel -> its settings, for every graph
  let masterVolume = 1;
  const voices = new Map();      // voice -> {source, gain}
  const sounding = new Set();    // every source started and not yet ended
  // The beat: tempo and swing, and where the beat was at some time, so a
  // change of tempo goes on from where the beat is.
  let bpm = 120;
  let swingAmount = 0;
  let anchor = null;             // {time, beat}
  const beats = new Map();       // watcher -> {steps, next}
  const timers = new Map();      // timer -> {at, every}
  let ticker = 0;
  let frozen = null;             // the clock, while the program has paused it
  let listening = null;          // {bins, smoothing}
  let rendering = null;          // {id, name, seconds, commands}
  let closed = false;

  function live() {
    const context = host.audio();
    if (!context) return null;
    if (graph === null || graph.context !== context) {
      graph = soundGraph(context);
      graph.master.gain.value = masterVolume;
      for (const [n, s] of settings) graph.style(n, s);
      if (listening) listen(listening.bins, listening.smoothing);
    }
    return graph;
  }

  function beatAt(t) {
    return anchor === null ? 0 : anchor.beat + ((t - anchor.time) * bpm) / 60;
  }

  // When step `k` of a beat cut into `steps` steps sounds. Int -> Int -> Float
  function stepTime(k, steps) {
    const at = anchor.time + ((k / steps - anchor.beat) * 60) / bpm;
    return k % 2 === 1 ? at + (swingAmount * 60) / bpm / steps : at;
  }

  function tick() {
    if (closed) return;
    const t = host.clock();
    if (frozen !== null) return;
    for (const [id, timer] of [...timers]) {
      if (t + 0.0005 < timer.at) continue;
      if (timer.every > 0) {
        while (timer.at <= t + 0.0005) timer.at += timer.every;
      } else {
        timers.delete(id);
      }
      host.send({ ev: "cb", id, kind: "timer" });
    }
    for (const [id, watcher] of beats) {
      for (let guard = 0; guard < 64; guard++) {
        const at = stepTime(watcher.next, watcher.steps);
        if (at > t + LOOKAHEAD) break;
        host.send({ ev: "cb", id, kind: "beat",
          reports: { beat: [watcher.next, Math.max(at, t), beatAt(t)] } });
        watcher.next += 1;
      }
    }
    if (timers.size === 0 && beats.size === 0) {
      clearInterval(ticker);
      ticker = 0;
    }
  }

  function ticking() {
    if (ticker === 0 && !closed) ticker = setInterval(tick, TICK_MS);
  }

  // Starts one sound on `g`'s context: a sample (`play` and `start`) or a
  // tone, at `at` on that context's clock. Answers its source.
  function sound(g, kind, sample, buffer, n, toTime) {
    const context = g.context;
    if (kind === "tone") {
      const [frequency, at, duration, volume, pan, channel] = n;
      const when = Math.max(context.currentTime, toTime(at));
      const length = Math.max(0.02, duration);
      const oscillator = context.createOscillator();
      oscillator.type = ["sine", "square", "triangle", "sawtooth"].includes(sample) ? sample : "sine";
      oscillator.frequency.value = frequency;
      const gain = context.createGain();
      const attack = Math.min(0.01, length / 4);
      const release = Math.min(0.05, length / 4);
      gain.gain.setValueAtTime(0, when);
      gain.gain.linearRampToValueAtTime(volume, when + attack);
      gain.gain.setValueAtTime(volume, when + length - release);
      gain.gain.linearRampToValueAtTime(0, when + length);
      const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;
      if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));
      oscillator.connect(gain);
      (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);
      oscillator.start(when);
      oscillator.stop(when + length + 0.01);
      return { source: oscillator, gain };
    }
    const [at, volume, rate, pan, channel, reverse, loop] = n;
    const source = context.createBufferSource();
    source.buffer = reverse ? reversedOf(context, buffer) : buffer;
    source.playbackRate.value = rate > 0 ? rate : 1;
    source.loop = !!loop;
    const gain = context.createGain();
    gain.gain.value = volume;
    const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;
    if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));
    source.connect(gain);
    (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);
    source.start(Math.max(context.currentTime, toTime(at)));
    return { source, gain };
  }

  // A sound command on the live context.
  function playLive(cmd) {
    const n = engineNumbers(cmd.numbers);
    if (cmd.kind === "tone") {
      host.startAudio();
      const g = live();
      if (!g) return;
      const made = sound(g, "tone", cmd.text, null, n, host.toAudio);
      sounding.add(made.source);
      made.source.onended = () => sounding.delete(made.source);
      return;
    }
    const sample = cmd.kind === "play" ? cmd.id : cmd.text;
    host.startAudio();
    const loading = host.sample(sample);
    if (!loading) return;
    const voice = cmd.kind === "start" ? cmd.id : null;
    if (voice !== null) voices.set(voice, { source: null, gain: null, stopped: null });
    loading.then((buffer) => {
      const g = live();
      if (buffer === null || closed || !g) return;
      const entry = voice === null ? null : voices.get(voice);
      if (entry && entry.stopped !== null && entry.stopped <= host.clock()) return;
      const made = sound(g, "sample", sample, buffer, n, host.toAudio);
      sounding.add(made.source);
      made.source.onended = () => {
        sounding.delete(made.source);
        if (voice !== null && voices.get(voice)?.source === made.source) voices.delete(voice);
      };
      if (entry) {
        entry.source = made.source;
        entry.gain = made.gain;
        if (entry.stopped !== null) made.source.stop(Math.max(g.context.currentTime, host.toAudio(entry.stopped)));
        if (entry.fade) fadeVoice(entry, ...entry.fade);
      }
    });
  }

  function fadeVoice(entry, volume, over) {
    const g = live();
    if (!g || entry.gain === null) {
      entry.fade = [volume, over];
      return;
    }
    const now = g.context.currentTime;
    const param = entry.gain.gain;
    param.cancelScheduledValues(now);
    param.setValueAtTime(param.value, now);
    if (over > 0) param.linearRampToValueAtTime(volume, now + over);
    else param.setValueAtTime(volume, now);
  }

  function stopAll() {
    const g = live();
    for (const source of sounding) {
      try {
        source.stop(g ? g.context.currentTime : 0);
      } catch {
        // already stopped
      }
    }
    sounding.clear();
    for (const entry of voices.values()) entry.stopped = -Infinity;
    voices.clear();
  }

  function listen(bins, smoothing) {
    listening = { bins, smoothing };
    const g = graph;
    if (!g || !g.analyser) return;
    let size = 32;
    while (size < bins * 2 && size < 32768) size *= 2;
    g.analyser.fftSize = size;
    g.analyser.smoothingTimeConstant = Math.max(0, Math.min(0.99, smoothing));
  }

  // What the page reports with an event: where the beat is, how late
  // sound comes out, whether it is running; and with a frame, what the
  // program listens to. Bool -> {..}
  // The analyser's arrays, kept from frame to frame.
  const scratch = { spectrum: new Uint8Array(0), samples: new Float32Array(0) };

  function reports(withSound) {
    const context = host.audio();
    const t = host.clock();
    const latency = context ? (context.outputLatency || 0) + (context.baseLatency || 0) : 0;
    const out = { clock: [beatAt(t), latency, context && context.state === "running" ? 1 : 0] };
    if (withSound && listening !== null) {
      const g = live();
      const bins = listening.bins;
      const level = [0];
      const band = new Array(bins).fill(0);
      const wave = new Array(bins).fill(0);
      if (g && g.analyser && g.analyser.getByteFrequencyData) {
        const a = g.analyser;
        if (scratch.spectrum.length !== a.frequencyBinCount) {
          scratch.spectrum = new Uint8Array(a.frequencyBinCount);
          scratch.samples = new Float32Array(a.fftSize);
        }
        const spectrum = scratch.spectrum;
        a.getByteFrequencyData(spectrum);
        const per = spectrum.length / bins;
        for (let k = 0; k < bins; k++) {
          let peak = 0;
          for (let i = Math.floor(k * per); i < Math.max(Math.floor((k + 1) * per), Math.floor(k * per) + 1); i++) {
            peak = Math.max(peak, spectrum[Math.min(i, spectrum.length - 1)]);
          }
          band[k] = Math.round((peak / 255) * 1000) / 1000;
        }
        const samples = scratch.samples;
        a.getFloatTimeDomainData(samples);
        let sum = 0;
        for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
        level[0] = Math.round(Math.min(1, Math.sqrt(sum / samples.length) * Math.SQRT2) * 1000) / 1000;
        const step = samples.length / bins;
        for (let k = 0; k < bins; k++) wave[k] = Math.round(samples[Math.floor(k * step)] * 1000) / 1000;
      }
      out.level = level;
      out.band = band;
      out.wave = wave;
    }
    return out;
  }

  // Renders what was scheduled between `render` and `render_end` offline,
  // offers it as a WAV file and reports how long that took and how loud
  // its loudest sample is.
  function finishRender(job) {
    const Offline = globalThis.OfflineAudioContext;
    const done = (took, peak) =>
      host.send({ ev: "cb", id: job.id, kind: "rendered", reports: { rendered: [took, peak] } });
    if (!Offline) {
      done(0, 0);
      return;
    }
    const rate = 44100;
    const context = new Offline(2, Math.max(1, Math.ceil(job.seconds * rate)), rate);
    const g = soundGraph(context);
    g.master.gain.value = masterVolume;
    for (const [n, s] of settings) g.style(n, s);
    const wanted = job.commands.filter((c) => c.kind !== "tone")
      .map((c) => host.sample(c.kind === "play" ? c.id : c.text) || Promise.resolve(null));
    Promise.all(wanted).then((buffers) => {
      let b = 0;
      for (const c of job.commands) {
        const n = engineNumbers(c.numbers);
        if (c.kind === "tone") {
          sound(g, "tone", c.text, null, n, (t) => t);
        } else {
          const buffer = buffers[b++];
          if (buffer) sound(g, "sample", null, buffer, n, (t) => t);
        }
      }
      const started = typeof performance !== "undefined" ? performance.now() : Date.now();
      return context.startRendering().then((buffer) => {
        const took = ((typeof performance !== "undefined" ? performance.now() : Date.now()) - started) / 1000;
        let peak = 0;
        for (let k = 0; k < buffer.numberOfChannels; k++) {
          const data = buffer.getChannelData(k);
          for (let i = 0; i < data.length; i++) peak = Math.max(peak, Math.abs(data[i]));
        }
        offerDownload(new Blob([wavBytes(buffer)], { type: "audio/wav" }), job.name);
        done(Math.round(took * 1000) / 1000, Math.round(peak * 1000) / 1000);
      });
    }).catch((error) => {
      console.error(`tinyweb: rendering ${job.name} failed: ${error.message}`);
      done(0, 0);
    });
  }

  // An element whose `display` the program sets: a slider's row, not
  // its input.
  function shown(element) {
    return element.tagName === "INPUT" && element.type === "range" ? element.parentNode : element;
  }

  function value(id, text) {
    host.send({ ev: "report", reports: { ["value." + id]: String(text) } });
  }

  function command(cmd) {
    const n = engineNumbers(cmd.numbers);
    if (rendering !== null && ["play", "start", "tone"].includes(cmd.kind)) {
      rendering.commands.push(cmd);
      return;
    }
    switch (cmd.kind) {
      // --- sound ---
      case "play":
      case "start":
      case "tone":
        playLive(cmd);
        break;
      case "stop": {
        const entry = voices.get(cmd.id);
        if (!entry) break;
        const at = n[0] || 0;
        entry.stopped = at;
        const g = live();
        if (entry.source && g) entry.source.stop(Math.max(g.context.currentTime, host.toAudio(at)));
        break;
      }
      case "fade": {
        const entry = voices.get(cmd.id);
        if (entry) fadeVoice(entry, n[0] ?? 0, n[1] ?? 0);
        break;
      }
      case "stop_all":
        stopAll();
        break;
      case "master": {
        masterVolume = n[0] ?? 1;
        const g = live();
        if (g) g.master.gain.value = masterVolume;
        break;
      }
      case "channel": {
        const ch = Number(cmd.id) || 0;
        const s = { volume: n[0] ?? 1, pan: n[1] ?? 0, echo: n[2] ?? 0, echoTime: n[3] ?? 0.3,
          feedback: n[4] ?? 0.35, reverb: n[5] ?? 0, lowPass: n[6] ?? 0 };
        settings.set(ch, s);
        const g = live();
        if (g) g.style(ch, s);
        break;
      }
      case "listen":
        listen(Math.max(1, Math.min(1024, Math.round(n[0] || 32))), n[1] ?? 0.8);
        live();
        break;
      case "tempo": {
        const t = host.clock();
        anchor = anchor === null ? null : { time: t, beat: beatAt(t) };
        bpm = Math.max(1, n[0] || 120);
        break;
      }
      case "swing":
        swingAmount = Math.max(0, Math.min(0.9, n[0] || 0));
        break;
      case "beat": {
        const t = host.clock();
        const steps = Math.max(1, Math.round(n[0] || 1));
        if (anchor === null) anchor = { time: t + 0.05, beat: 0 };
        // The first step not yet passed, from where the beat is.
        // `+ 0` makes a -0 at the very start a 0: a step is a whole number.
        let next = Math.ceil(beatAt(t) * steps - 1e-9) + 0;
        while (stepTime(next, steps) < t) next += 1;
        beats.set(cmd.id, { steps, next });
        ticking();
        break;
      }
      case "beat_stop":
        beats.delete(cmd.id);
        break;
      case "audio": {
        const context = host.audio();
        if (cmd.text === "pause" && frozen === null) {
          frozen = host.clock();
          if (context && context.state === "running") context.suspend();
        } else if (cmd.text === "resume" && frozen !== null) {
          const at = frozen;
          if (context) {
            context.resume().then(() => {
              host.thaw(at);
              frozen = null;
            });
          } else {
            host.thaw(at);
            frozen = null;
          }
        }
        break;
      }
      case "render":
        rendering = { id: cmd.id, name: cmd.text, seconds: n[0] || 1, commands: [] };
        break;
      case "render_end":
        if (rendering !== null) {
          const job = rendering;
          rendering = null;
          finishRender(job);
        }
        break;
      // --- timers ---
      case "after":
      case "every": {
        const seconds = Math.max(0, n[0] || 0);
        timers.set(cmd.id, { at: host.clock() + seconds, every: cmd.kind === "every" ? Math.max(0.001, seconds) : 0 });
        ticking();
        break;
      }
      case "cancel":
        timers.delete(cmd.id);
        beats.delete(cmd.id);
        break;
      // --- changing what is on the page ---
      case "set_text": {
        const element = host.element(cmd.id);
        if (!element) break;
        if (element.tagName === "INPUT" || element.tagName === "TEXTAREA") element.value = cmd.text;
        else element.textContent = cmd.text;
        break;
      }
      case "visible": {
        const element = host.element(cmd.id);
        if (element) shown(element).style.display = n[0] ? "" : "none";
        break;
      }
      case "enabled": {
        const element = host.element(cmd.id);
        if (element) element.disabled = !n[0];
        break;
      }
      case "remove": {
        const element = host.element(cmd.id);
        if (element) shown(element).remove();
        host.forget(cmd.id);
        break;
      }
      case "text_area": {
        const area = document.createElement("textarea");
        area.setAttribute("data-tinyweb-id", String(cmd.id));
        area.value = cmd.text;
        area.rows = Math.max(1, Math.round(n[0] || 4));
        area.cols = Math.max(1, Math.round(n[1] || 40));
        area.addEventListener("input", () => {
          host.send({ ev: "cb", id: cmd.id, kind: "change", reports: { ["value." + cmd.id]: area.value } });
        });
        host.remember(cmd.id, area);
        host.place(area);
        break;
      }
      case "file_button": {
        const button = document.createElement("button");
        button.setAttribute("data-tinyweb-id", String(cmd.id));
        button.textContent = cmd.text;
        const input = document.createElement("input");
        input.type = "file";
        input.style.display = "none";
        button.addEventListener("click", () => {
          host.startAudio();
          input.click();
        });
        // The input is inside the button: its own click is not the button's.
        input.addEventListener("click", (event) => event.stopPropagation());
        input.addEventListener("change", () => {
          const file = input.files && input.files[0];
          if (!file) return;
          file.arrayBuffer().then((bytes) => {
            if (/^audio\//.test(file.type) || /\.(wav|mp3|ogg|m4a|flac|aac)$/i.test(file.name)) {
              const decoder = new OfflineAudioContext(1, 1, 44100);
              const loading = decoder.decodeAudioData(bytes).catch(() => null);
              host.addSample(cmd.id, loading);
              loading.then(() => host.send({ ev: "cb", id: cmd.id, kind: "loaded",
                reports: { file: file.name, ["file.text"]: "" } }));
            } else {
              const text = new TextDecoder().decode(bytes);
              host.send({ ev: "cb", id: cmd.id, kind: "loaded", reports: { file: file.name, ["file.text"]: text } });
            }
          });
        });
        host.remember(cmd.id, button);
        host.place(button);
        button.appendChild(input);
        break;
      }
      case "cursor": {
        const target = cmd.id === "" ? document.body : host.canvas(cmd.id)?.element;
        if (target) target.style.cursor = cmd.text || "auto";
        break;
      }
      case "save_canvas": {
        const entry = host.canvas(cmd.id);
        if (!entry || !entry.element.toBlob) break;
        const out = document.createElement("canvas");
        out.width = entry.width;
        out.height = entry.height;
        const g = out.getContext("2d");
        g.fillStyle = "#ffffff";
        g.fillRect(0, 0, out.width, out.height);
        g.drawImage(entry.element, 0, 0, out.width, out.height);
        out.toBlob((blob) => { if (blob) offerDownload(blob, cmd.text); }, "image/png");
        break;
      }
      case "download":
        offerDownload(new Blob([cmd.text], { type: "text/plain" }), cmd.id);
        break;
    }
  }

  return {
    command,
    reports,
    value,
    // The clock while the program has paused it, or null.
    frozen: () => frozen,
    // Whether a command needs sound, which may need the splash screen first.
    sounds: (cmd) => ["play", "start", "tone"].includes(cmd.kind),
    close() {
      closed = true;
      clearInterval(ticker);
      ticker = 0;
      stopAll();
    },
  };
}
// END tinyweb style

let page = null;
// Every identifier given out so far.
const names = new Set();

// A new element's identifier: `name`, or `name` with the first number
// from 1 that makes it one nothing on the page has.
function fresh(name) {
  // An empty name would be the page's own identifier.
  if (name === "") name = "element";
  let found = name;
  for (let n = 1; names.has(found); n++) found = name + n;
  names.add(found);
  return found;
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
    // Where an element made now goes: the page, or a row it was put inside.
    parent: box,
    rows: new Map(),
    look: styled(element, box),
    canvases: new Map(),
    labels: new Map(),
    samples: new Map(),
    pictures: new Map(),
    // What `set_checked` and `set_value` change, by identifier, and each
    // group of radio buttons.
    checks: new Map(),
    values: new Map(),
    groups: new Map(),
    frames: [],
    keys: [],
    keyUps: [],
    // The keys held down now.
    down: new Set(),
    bitmaps: new Map(),
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
    // The picture what is held waits for.
    waitingFor: null,
    // The functions `watch` handed over, by element and kind; what the
    // page last reported, by name; and the engine carrying out `command`.
    watchers: new Map(),
    reports: new Map(),
    engine: null,
  };
  state.engine = makeEngine({
    audio: () => state.audio,
    startAudio: () => startAudio(state),
    clock: () => clockNow(state),
    toAudio: (t) => t - state.offset,
    thaw: (t) => {
      state.start = now() - t * 1000;
      if (running(state)) state.offset = t - state.audio.currentTime;
    },
    sample: (id) => state.samples.get(id),
    addSample: (id, loading) => state.samples.set(id, loading),
    element: (id) => state.look.elements.get(id),
    forget: (id) => state.look.elements.delete(id),
    remember: (id, made) => remember(state.look, id, made),
    place: (made) => state.parent.appendChild(made),
    canvas: (id) => state.canvases.get(id),
    send: (event) => queueMicrotask(() => deliverLocal(state, event)),
  });

  if (!standalone) box.tabIndex = 0;
  box.addEventListener("pointerdown", () => startAudio(state));
  state.keyTarget.addEventListener("keydown", (event) => {
    if (state.splash !== null) {
      dismissSplash(state, event);
      return;
    }
    startAudio(state);
    if (typedInField(event)) return;
    if (standalone && ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " "].includes(event.key)
      && (state.keys.length > 0 || state.keyUps.length > 0 || state.keysAsked)) {
      event.preventDefault?.();
    }
    state.down.add(event.key);
    for (const pressed of state.keys.slice()) pressed(event.key);
  });
  state.keyTarget.addEventListener("keyup", (event) => {
    if (!state.down.delete(event.key)) return;
    for (const released of state.keyUps.slice()) released(event.key);
  });
  // A key released while the page did not have the focus is never
  // reported, so leaving the page lets go of every key.
  window.addEventListener("blur", () => {
    const down = [...state.down];
    state.down.clear();
    for (const key of down) for (const released of state.keyUps.slice()) released(key);
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
  const paused = state.engine === null ? null : state.engine.frozen();
  if (paused !== null) return paused;
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
      if (audio.state !== "running") return;
      const paused = state.engine.frozen();
      state.offset = (paused !== null ? paused : (now() - state.start) / 1000) - audio.currentTime;
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
  if (state.splash === null) return;
  event?.preventDefault?.();
  event?.stopImmediatePropagation?.();
  window.removeEventListener("keydown", state.splash.dismiss, true);
  state.splash.element.remove();
  state.splash = null;
  startAudio(state);
  release(state);
}

// Holds what comes after a picture still loading, until it has loaded
// or failed: what the program does to the page, its frames and the
// clock. State -> Picture -> ()
function waitFor(state, picture) {
  if (state.held === null) {
    state.heldClock = clockNow(state);
    state.heldAt = now();
    state.held = [];
  }
  state.waitingFor = picture;
  picture.settled.push(() => {
    state.waitingFor = null;
    release(state);
  });
}

// Does what was held once nothing holds it any more. State -> ()
function release(state) {
  if (state.held === null || state.splash !== null || state.waitingFor !== null) return;
  state.start += now() - state.heldAt;
  const pending = state.held;
  state.held = null;
  for (const [i, effect] of pending.entries()) {
    if (state.held !== null) {
      state.held.push(...pending.slice(i));
      return;
    }
    effect();
  }
}

function draw(c, paint) {
  const state = mounted();
  act(state, () => {
    const entry = state.canvases.get(c);
    if (entry) paint(entry.context, entry);
  });
}

// The canvas `c` when it can be drawn on now: there is no splash screen
// holding what the program does. String -> Entry?
function drawable(c) {
  const state = mounted();
  return state.held === null ? state.canvases.get(c) : undefined;
}

// --- the functions tinyweb_external.pyk declares ---

export function web_start(port) {}

export function canvas(width, height) {
  const state = mounted();
  const id = fresh("canvas");
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
  plainLines(context);
  const entry = {
    element, context, width, height, mice: [], ratio, depth: 0, gradients: new Map(),
    watchers: { press: [], release: [], move: [], drag: [] },
    x: 0, y: 0, down: false,
  };
  state.canvases.set(id, entry);
  remember(state.look, id, element);
  const where = (event) => {
    const bounds = element.getBoundingClientRect();
    return [
      Math.round(((event.clientX - bounds.left) * width) / bounds.width),
      Math.round(((event.clientY - bounds.top) * height) / bounds.height),
    ];
  };
  const call = (kind, x, y) => {
    for (const f of entry.watchers[kind].slice()) f(x, y);
  };
  element.addEventListener("click", (event) => {
    if (entry.mice.length === 0) return;
    const [x, y] = where(event);
    for (const click of entry.mice.slice()) click(x, y);
  });
  // A browser reports a move at most once a frame already.
  element.addEventListener("pointerdown", (event) => {
    if (!entry.watched) return;
    capture(element, event);
    startAudio(state);
    [entry.x, entry.y] = where(event);
    entry.down = true;
    call("press", entry.x, entry.y);
  });
  element.addEventListener("pointerup", (event) => {
    if (!entry.watched) return;
    [entry.x, entry.y] = where(event);
    entry.down = false;
    call("release", entry.x, entry.y);
  });
  element.addEventListener("pointermove", (event) => {
    if (!entry.watched) return;
    [entry.x, entry.y] = where(event);
    call("move", entry.x, entry.y);
    if (entry.down) call("drag", entry.x, entry.y);
  });
  element.addEventListener("contextmenu", (event) => {
    if (entry.watched) event.preventDefault?.();
  });
  element.style.touchAction = "none";
  state.parent.appendChild(element);
}


export function fill_canvas(c, color) {
  draw(c, (g, entry) => {
    freshState(g, entry);
    g.fillStyle = paint(g, entry, color);
    g.fillRect(0, 0, entry.width, entry.height);
  });
}

export function draw_shape(c, kind, numbers, color, outline, width, alpha) {
  const entry = drawable(c);
  if (entry !== undefined) drawShape(entry.context, entry, kind, numbers, color, outline, width, alpha);
  else draw(c, (g, e) => drawShape(g, e, kind, numbers, color, outline, width, alpha));
}

// A list of tuples as the one array of numbers drawShape reads.
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
  draw(c, (g, entry) => drawText(g, entry, x, y, words, color, size, font, align, baseline, bold,
    outline, outlineWidth, alpha));
}

export function measure(words, size, font, bold, answer) {
  const state = mounted();
  act(state, () => {
    const width = textWidth(words, size, font, bold);
    queueMicrotask(() => answer(width));
  });
}

export function set_state(c, kind, value, numbers) {
  draw(c, (g, entry) => canvasState(g, entry, kind, value, numbers));
}

export function load_image(name) {
  const state = mounted();
  const id = fresh(name);
  act(state, () => state.pictures.set(id, loadPicture(name, import.meta.url)));
  return id;
}

export function draw_image(c, picture, x, y, width, height, alpha) {
  const state = mounted();
  act(state, () => {
    const loaded = state.pictures.get(picture);
    if (loaded && loaded.loading) {
      waitFor(state, loaded);
      state.held.push(() => draw_image(c, picture, x, y, width, height, alpha));
      return;
    }
    const entry = state.canvases.get(c);
    if (entry) drawPicture(entry.context, loaded, x, y, width, height, alpha);
  });
}

export function make_checkbox(title, checked, onChange) {
  const state = mounted();
  const id = fresh(title);
  act(state, () => {
    const { row, input } = choiceRow("checkbox", id, title, checked);
    input.addEventListener("change", () => {
      startAudio(state);
      merge(state, { ["value." + id]: String(input.checked) });
      onChange(input.checked);
    });
    state.checks.set(id, (on) => { input.checked = on; });
    remember(state.look, id, input);
    state.parent.appendChild(row);
  });
  return id;
}

export function make_radio(group, title, chosen, onPick) {
  const state = mounted();
  const id = fresh(title);
  act(state, () => {
    const members = state.groups.get(group) || [];
    state.groups.set(group, members);
    const first = members.length === 0;
    const { row, input } = choiceRow("radio", id, title, chosen || first);
    input.name = `${state.look.name}:${group}`;
    const choose = () => {
      for (const other of members) other.checked = other === input;
    };
    if (chosen) choose();
    members.push(input);
    input.addEventListener("change", () => {
      startAudio(state);
      choose();
      onPick(title);
    });
    state.checks.set(id, (on) => {
      if (on) choose();
      else input.checked = false;
    });
    remember(state.look, id, input);
    state.parent.appendChild(row);
  });
  return id;
}

export function make_choice(options, chosen, onChange) {
  const state = mounted();
  const id = fresh("choice");
  act(state, () => {
    const select = choiceElement(id, options, chosen);
    select.addEventListener("change", () => {
      startAudio(state);
      merge(state, { ["value." + id]: select.value });
      onChange(Number(select.value));
    });
    state.values.set(id, (value) => { select.value = String(value); });
    remember(state.look, id, select);
    state.parent.appendChild(select);
  });
  return id;
}

export function make_text_input(placeholder, onEnter) {
  const state = mounted();
  const id = fresh(placeholder === "" ? "text" : placeholder);
  act(state, () => {
    const input = textInputElement(id, placeholder);
    input.addEventListener("input", () => merge(state, { ["value." + id]: input.value }));
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        startAudio(state);
        onEnter(input.value);
      }
    });
    remember(state.look, id, input);
    state.parent.appendChild(input);
  });
  return id;
}

export function make_number_input(low, high, value, onChange) {
  const state = mounted();
  const id = fresh("number");
  act(state, () => {
    const input = numberElement(id, low, high, value);
    input.addEventListener("change", () => {
      startAudio(state);
      merge(state, { ["value." + id]: input.value });
      onChange(Number(input.value));
    });
    state.values.set(id, (v) => { input.value = String(v); });
    remember(state.look, id, input);
    state.parent.appendChild(input);
  });
  return id;
}

export function set_checked(id, checked) {
  const state = mounted();
  act(state, () => {
    if (state.checks.has(id)) state.checks.get(id)(checked);
  });
}

export function set_value(id, value) {
  const state = mounted();
  act(state, () => {
    if (state.values.has(id)) state.values.get(id)(value);
  });
}

export function make_button(title, onClick) {
  const state = mounted();
  const id = fresh(title);
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
  state.parent.appendChild(button);
}

export function label(text) {
  const state = mounted();
  const id = fresh(text);
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
  state.parent.appendChild(shown);
}

export function row() {
  const state = mounted();
  const id = fresh("row");
  act(state, () => {
    const row = rowElement(id);
    state.rows.set(id, row);
    remember(state.look, id, row);
    state.parent.appendChild(row);
  });
  return id;
}

export function column() {
  const state = mounted();
  const id = fresh("column");
  act(state, () => {
    const box = rowElement(id, false);
    state.rows.set(id, box);
    remember(state.look, id, box);
    state.parent.appendChild(box);
  });
  return id;
}

export function inside(id) {
  const state = mounted();
  act(state, () => {
    state.parent = state.rows.get(id) || state.box;
  });
}

export function outside() {
  const state = mounted();
  act(state, () => {
    state.parent = state.box;
  });
}

export function set_label(id, text) {
  const state = mounted();
  act(state, () => {
    // A label's text, or a button's title.
    if (state.labels.has(id)) state.labels.get(id).textContent = text;
    else if (state.look.elements.get(id)?.tagName === "BUTTON") {
      state.look.elements.get(id).textContent = text;
    }
  });
}

export function make_slider(low, high, value, onChange) {
  const state = mounted();
  const id = fresh("slider");
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
    merge(state, { ["value." + id]: input.value });
    onChange(Number(input.value));
  });
  row.append(input, shown);
  state.values.set(id, (v) => {
    input.value = String(v);
    shown.textContent = input.value;
  });
  remember(state.look, id, input);
  state.parent.appendChild(row);
}

export function apply_style(id, kind, property, value) {
  const state = mounted();
  act(state, () => applyStyle(state.look, id, kind, property, value));
}

export function load_sample(name) {
  const state = mounted();
  const id = fresh(name);
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

export function time() {
  return clockNow(mounted());
}

// --- the generic functions: commands the engine carries out, and what
// the page reports back ---

// An event the engine reports: what it carries is kept, and the
// functions watching it are called. State -> Event -> ()
function deliverLocal(state, event) {
  merge(state, event.reports);
  if (event.ev === "cb") {
    for (const f of (state.watchers.get(event.id + "\u0000" + event.kind) || []).slice()) f();
  }
}

function merge(state, reports) {
  if (!reports) return;
  for (const [name, value] of Object.entries(reports)) {
    state.reports.set(name, typeof value === "string" ? value : Array.isArray(value) ? value : [value]);
  }
}

export function fresh_id(name) {
  mounted();
  return fresh(name);
}

export function command(kind, id, text, numbers, mode) {
  const state = mounted();
  const cmd = { op: "cmd", kind, id, text, numbers, mode };
  if (state.held === null && state.engine.sounds(cmd) && splashWanted(state)) showSplash(state);
  act(state, () => state.engine.command(cmd));
}

export function watch(id, kind, f) {
  const state = mounted();
  const key = id + "\u0000" + kind;
  if (!state.watchers.has(key)) state.watchers.set(key, []);
  state.watchers.get(key).push(f);
}

// What the page last reported under `name`; where the beat is, asked
// here, is as of now. State -> String -> Value?
function reported(name) {
  const state = mounted();
  if (name === "clock") merge(state, state.engine.reports(false));
  return state.reports.get(name);
}

export function report_number(name, k) {
  const value = reported(name);
  if (!Array.isArray(value) || k < 0 || k >= value.length) return 0.0;
  const n = Number(value[k]);
  return Number.isFinite(n) ? n : 0.0;
}

export function report_text(name) {
  const value = reported(name);
  return typeof value === "string" ? value : "";
}

export function report_count(name) {
  const value = reported(name);
  return Array.isArray(value) ? value.length : 0;
}

export function watch_text(id, kind, name, f) {
  watch(id, kind, () => f(report_text(name)));
}

export function watch_step(id, kind, f) {
  watch(id, kind, () => f(Math.trunc(report_number(kind, 0)) | 0, report_number(kind, 1)));
}

export function watch_pair(id, kind, f) {
  watch(id, kind, () => f(report_number(kind, 0), report_number(kind, 1)));
}

export function on_frame(drawFrame) {
  const state = mounted();
  state.frames.push(drawFrame);
  if (!state.frameWanted) {
    state.frameWanted = true;
    const frame = () => {
      if (state.held === null) {
        const t = clockNow(state);
        merge(state, state.engine.reports(true));
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

export function on_key_up(released) {
  mounted().keyUps.push(released);
}

export function key_down(key) {
  const state = mounted();
  state.keysAsked = true;
  return state.down.has(key);
}

export function watch_pointer(c, kind, f) {
  const state = mounted();
  act(state, () => {
    const entry = state.canvases.get(c);
    if (!entry || !(kind in entry.watchers)) return;
    entry.watched = true;
    entry.watchers[kind].push(f);
  });
}

export function pointer(c, which) {
  const entry = mounted().canvases.get(c);
  if (!entry) return 0;
  if (which === "x") return entry.x;
  if (which === "y") return entry.y;
  return entry.down ? 1 : 0;
}

// --- bitmaps ---

// The bitmap last named, so a loop setting its pixels finds it at once.
let lastBitmap = null;

function bitmapNamed(b) {
  if (lastBitmap !== null && lastBitmap.id === b) return lastBitmap;
  const found = mounted().bitmaps.get(b);
  if (found !== undefined) lastBitmap = found;
  return found;
}

// Widens a bitmap's changed rectangle to hold (x, y). Bitmap -> Int -> Int -> ()
function touched(bitmap, x, y) {
  if (x < bitmap.x1) bitmap.x1 = x;
  if (y < bitmap.y1) bitmap.y1 = y;
  if (x >= bitmap.x2) bitmap.x2 = x + 1;
  if (y >= bitmap.y2) bitmap.y2 = y + 1;
}

export function make_bitmap(width, height, background) {
  const state = mounted();
  const id = fresh("bitmap");
  const w = Math.max(1, width);
  const h = Math.max(1, height);
  const image = new ImageData(w, h);
  for (let i = 3; i < image.data.length; i += 4) image.data[i] = 255;
  state.bitmaps.set(id, {
    id, width: w, height: h, image, data: image.data, surface: null,
    x1: 0, y1: 0, x2: w, y2: h,
  });
  fill_bitmap(id, background);
  return id;
}

export function set_pixel(b, x, y, color) {
  const bitmap = bitmapNamed(b);
  if (bitmap === undefined || x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) return;
  const at = (y * bitmap.width + x) * 4;
  const data = bitmap.data;
  data[at] = (color >> 16) & 255;
  data[at + 1] = (color >> 8) & 255;
  data[at + 2] = color & 255;
  touched(bitmap, x, y);
}

export function get_pixel(b, x, y) {
  const bitmap = bitmapNamed(b);
  if (bitmap === undefined || x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) return 0;
  const at = (y * bitmap.width + x) * 4;
  const data = bitmap.data;
  return (data[at] << 16) | (data[at + 1] << 8) | data[at + 2];
}

export function fill_bitmap(b, color) {
  const bitmap = bitmapNamed(b);
  if (bitmap === undefined) return;
  const data = bitmap.data;
  const r = (color >> 16) & 255;
  const g = (color >> 8) & 255;
  const bl = color & 255;
  for (let at = 0; at < data.length; at += 4) {
    data[at] = r;
    data[at + 1] = g;
    data[at + 2] = bl;
  }
  bitmap.x1 = 0;
  bitmap.y1 = 0;
  bitmap.x2 = bitmap.width;
  bitmap.y2 = bitmap.height;
}

export function draw_bitmap(c, b, x, y, scale) {
  const bitmap = bitmapNamed(b);
  if (bitmap === undefined) return;
  // What changed is put on the bitmap's surface now, so that a pixel set
  // later is not shown by this call.
  if (bitmap.surface === null) bitmap.surface = bitmapSurface(bitmap.width, bitmap.height);
  if (bitmap.x2 > bitmap.x1 && bitmap.y2 > bitmap.y1) {
    const rw = bitmap.x2 - bitmap.x1;
    const rh = bitmap.y2 - bitmap.y1;
    const rect = new Uint8ClampedArray(rw * rh * 4);
    for (let r = 0; r < rh; r++) {
      const from = ((bitmap.y1 + r) * bitmap.width + bitmap.x1) * 4;
      rect.set(bitmap.data.subarray(from, from + rw * 4), r * rw * 4);
    }
    updateSurface(bitmap.surface, bitmap.x1, bitmap.y1, rw, rh, rect);
  }
  bitmap.x1 = bitmap.width;
  bitmap.y1 = bitmap.height;
  bitmap.x2 = 0;
  bitmap.y2 = 0;
  const surface = bitmap.surface;
  draw(c, (g) => drawSurface(g, surface, x, y, scale));
}
