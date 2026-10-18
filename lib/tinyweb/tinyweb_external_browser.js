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
  const degrees = Math.PI / 180;
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
      g.arc(n[0], n[1], Math.max(0, n[2]), n[3] * degrees, n[4] * degrees);
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
    gradient = g.createConicGradient((n[2] * Math.PI) / 180, n[0], n[1]);
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
      g.rotate((n[0] * Math.PI) / 180);
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
// has loaded. String -> String -> Picture
function loadPicture(name, base) {
  const picture = { element: null, ready: false, retried: false };
  if (typeof Image === "undefined") return picture;
  const element = new Image();
  picture.element = element;
  element.onload = () => {
    picture.ready = true;
  };
  element.onerror = () => {
    if (picture.retried) {
      console.error(`tinyweb: cannot load the picture ${name}`);
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
      || (target.tagName === "INPUT" && (target.type === "text" || target.type === "number")));
}
// END tinyweb style

let page = null;
// Every identifier given out so far.
const names = new Set();

// A new element's identifier: `name`, or `name` with the first number
// from 1 that makes it one nothing on the page has.
function fresh(name) {
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
  };

  if (!standalone) box.tabIndex = 0;
  box.addEventListener("pointerdown", () => startAudio(state));
  state.keyTarget.addEventListener("keydown", (event) => {
    if (state.held !== null) {
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

// The canvas `c` when it can be drawn on now: there is no splash screen
// holding what the program does. String -> Entry?
function drawable(c) {
  const state = mounted();
  return state.held === null ? state.canvases.get(c) : undefined;
}

// --- the functions tinyweb_external.pyk declares ---

export function web_init(port) {}

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
  draw(c, (g) => drawPicture(g, state.pictures.get(picture), x, y, width, height, alpha));
}

export function make_checkbox(title, checked, onChange) {
  const state = mounted();
  const id = fresh(title);
  act(state, () => {
    const { row, input } = choiceRow("checkbox", id, title, checked);
    input.addEventListener("change", () => {
      startAudio(state);
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

export function bitmap(width, height) {
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
