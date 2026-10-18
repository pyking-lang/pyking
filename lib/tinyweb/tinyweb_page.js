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

// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:
// `receive(commands)` carries out a batch of commands, and `send(event)`
// is how the page reports one. `standalone` is true where the page is
// the whole document, which is where a key press is listened for; a
// page inside another (a notebook cell) listens on `element`, which
// takes the focus when clicked. `activated` is true where the reader
// started the program with a click or a key, as in the playground and
// a notebook, and the page then never shows the splash screen.
export function mountPage(element, sendEvent, { standalone = false, activated = false } = {}) {
  const box = document.createElement("div");
  box.className = "tinyweb-page";
  box.style.cssText =
    "display:flex;flex-direction:column;align-items:flex-start;outline:none";
  element.appendChild(box);
  const look = styled(element, box);

  const canvases = new Map();
  const labels = new Map();
  const samples = new Map();
  const pictures = new Map();
  // What `set_checked` and `set_value` change, by identifier, and each
  // group of radio buttons.
  const checks = new Map();
  const values = new Map();
  const groups = new Map();
  const bitmaps = new Map();
  // Where an element made now goes: the page, or a row it was put inside.
  const rows = new Map();
  let parent = box;
  // The keys held down, reported again as released when the page loses
  // the focus.
  const heldKeys = new Set();
  let start = now();
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
  // The splash screen: what it says, whether it has been shown (or is
  // not needed), and while it is shown the element, the commands held
  // until it is dismissed, and the clock where it stopped.
  let splashText = SPLASH_TEXT;
  let splashDone = activated;
  let splash = null;
  let held = null;
  let heldClock = 0;
  let heldAt = 0;

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
    if (held !== null) return heldClock;
    return running() ? audio.currentTime + offset : (now() - start) / 1000;
  }

  function report(event) {
    if (!closed && held === null) sendEvent({ ...event, t: clockNow(), running: running() });
  }

  // Whether a sound now would need the splash screen first.
  function splashWanted() {
    return !splashDone && splashText !== "" && !running() && !readerActive();
  }

  // Shows the splash screen and holds what comes after it: the commands,
  // the frames and the clock.
  function showSplash() {
    splashDone = true;
    heldClock = clockNow();
    heldAt = now();
    held = [];
    splash = splashScreen(splashText);
    splash.addEventListener("click", dismissSplash);
    window.addEventListener("keydown", dismissSplash, true);
    document.body.appendChild(splash);
  }

  // The reader's click or key: the splash screen goes, sound starts, the
  // clock goes on from where it stopped, and what was held is carried out.
  function dismissSplash(event) {
    if (held === null) return;
    event?.preventDefault?.();
    event?.stopImmediatePropagation?.();
    window.removeEventListener("keydown", dismissSplash, true);
    splash.remove();
    splash = null;
    start += now() - heldAt;
    const pending = held;
    held = null;
    startAudio();
    for (const command of pending) carryOut(command);
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
    if (held !== null) {
      dismissSplash(event);
      return;
    }
    startAudio();
    if (!keysWanted || typedInField(event)) return;
    // Arrows and the space bar move the program's world, not the page.
    if (standalone && ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " "].includes(event.key)) {
      event.preventDefault?.();
    }
    heldKeys.add(event.key);
    report({ ev: "key", key: event.key });
  }
  keyTarget.addEventListener("keydown", onKey);

  function onKeyUp(event) {
    if (!keysWanted) return;
    if (heldKeys.delete(event.key)) report({ ev: "key_up", key: event.key });
  }
  keyTarget.addEventListener("keyup", onKeyUp);

  // A key released while the page did not have the focus is never
  // reported, so leaving the page lets go of every key.
  function onBlur() {
    for (const key of heldKeys) report({ ev: "key_up", key });
    heldKeys.clear();
  }
  window.addEventListener("blur", onBlur);

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
    if (!frameWaiting && held === null) {
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
    plainLines(context);
    const entry = {
      element, context, width, height, mouse: false, pointer: false, ratio, depth: 0,
      gradients: new Map(),
    };
    canvases.set(id, entry);
    remember(look, id, element);
    const where = (event) => {
      const bounds = element.getBoundingClientRect();
      return {
        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),
        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),
      };
    };
    element.addEventListener("click", (event) => {
      if (entry.mouse) report({ ev: "mouse", c: id, ...where(event) });
    });
    // A browser reports a move at most once a frame already.
    element.addEventListener("pointerdown", (event) => {
      if (!entry.pointer) return;
      capture(element, event);
      startAudio();
      report({ ev: "press", c: id, ...where(event) });
    });
    element.addEventListener("pointerup", (event) => {
      if (entry.pointer) report({ ev: "release", c: id, ...where(event) });
    });
    element.addEventListener("pointermove", (event) => {
      if (entry.pointer) report({ ev: "move", c: id, ...where(event) });
    });
    element.addEventListener("contextmenu", (event) => {
      if (entry.pointer) event.preventDefault?.();
    });
    element.style.touchAction = "none";
    parent.appendChild(element);
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
          freshState(g, entry);
          g.fillStyle = paint(g, entry, command.color);
          g.fillRect(0, 0, entry.width, entry.height);
        });
        break;
      case "shape":
        draw(command.c, (g, entry) => drawShape(g, entry, command.kind, command.numbers,
          command.color, command.outline, command.width, command.alpha));
        break;
      case "text":
        draw(command.c, (g, entry) => drawText(g, entry, command.x, command.y, command.words,
          command.color, command.size, command.font, command.align, command.baseline,
          command.bold, command.outline, command.outline_width, command.alpha));
        break;
      case "measure": {
        // Answered once the code that asked has finished, as any event is.
        const width = textWidth(command.words, command.size, command.font, command.bold);
        queueMicrotask(() => report({ ev: "measured", id: command.id, width }));
        break;
      }
      case "bitmap": {
        let surface = bitmaps.get(command.id);
        if (!surface || surface.width !== command.width || surface.height !== command.height) {
          surface = bitmapSurface(command.width, command.height);
          bitmaps.set(command.id, surface);
        }
        const [rx, ry, rw, rh] = command.rect;
        updateSurface(surface, rx, ry, rw, rh, command.data);
        draw(command.c, (g) => drawSurface(g, surface, command.x, command.y, command.scale));
        break;
      }
      case "state":
        draw(command.c, (g, entry) => canvasState(g, entry, command.kind, command.value,
          command.numbers));
        break;
      case "image_load":
        pictures.set(command.id, loadPicture(command.name, import.meta.url));
        break;
      case "image":
        draw(command.c, (g) => drawPicture(g, pictures.get(command.picture), command.x,
          command.y, command.width, command.height, command.alpha));
        break;
      case "checkbox": {
        const { row, input } = choiceRow("checkbox", command.id, command.title, command.checked);
        input.addEventListener("change", () => {
          startAudio();
          report({ ev: "check", id: command.id, checked: input.checked });
        });
        checks.set(command.id, (on) => { input.checked = on; });
        remember(look, command.id, input);
        parent.appendChild(row);
        break;
      }
      case "radio": {
        const members = groups.get(command.group) || [];
        groups.set(command.group, members);
        const first = members.length === 0;
        const { row, input } = choiceRow("radio", command.id, command.title,
          command.chosen || first);
        input.name = `${look.name}:${command.group}`;
        const choose = () => {
          for (const other of members) other.checked = other === input;
        };
        if (command.chosen) choose();
        members.push(input);
        input.addEventListener("change", () => {
          startAudio();
          choose();
          report({ ev: "pick", id: command.id });
        });
        checks.set(command.id, (on) => {
          if (on) choose();
          else input.checked = false;
        });
        remember(look, command.id, input);
        parent.appendChild(row);
        break;
      }
      case "choice": {
        const select = choiceElement(command.id, command.options, command.chosen);
        select.addEventListener("change", () => {
          startAudio();
          report({ ev: "choose", id: command.id, value: Number(select.value) });
        });
        values.set(command.id, (value) => { select.value = String(value); });
        remember(look, command.id, select);
        parent.appendChild(select);
        break;
      }
      case "text_input": {
        const input = textInputElement(command.id, command.placeholder);
        input.addEventListener("keydown", (event) => {
          if (event.key === "Enter") {
            startAudio();
            report({ ev: "enter", id: command.id, text: input.value });
          }
        });
        remember(look, command.id, input);
        parent.appendChild(input);
        break;
      }
      case "number": {
        const input = numberElement(command.id, command.low, command.high, command.value);
        input.addEventListener("change", () => {
          startAudio();
          report({ ev: "slide", id: command.id, value: Number(input.value) });
        });
        values.set(command.id, (value) => { input.value = String(value); });
        remember(look, command.id, input);
        parent.appendChild(input);
        break;
      }
      case "set_checked":
        if (checks.has(command.id)) checks.get(command.id)(command.checked);
        break;
      case "set_value":
        if (values.has(command.id)) values.get(command.id)(command.value);
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
        parent.appendChild(button);
        break;
      }
      case "label": {
        const text = document.createElement("div");
        text.className = "tinyweb-label";
        text.setAttribute("data-tinyweb-id", String(command.id));
        text.textContent = command.text;
        labels.set(command.id, text);
        remember(look, command.id, text);
        parent.appendChild(text);
        break;
      }
      case "row":
      case "column": {
        const row = rowElement(command.id, command.op === "row");
        rows.set(command.id, row);
        remember(look, command.id, row);
        parent.appendChild(row);
        break;
      }
      case "inside":
        parent = rows.get(command.id) || box;
        break;
      case "outside":
        parent = box;
        break;
      case "set_label":
        // A label's text, or a button's title.
        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;
        else if (look.elements.get(command.id)?.tagName === "BUTTON") {
          look.elements.get(command.id).textContent = command.text;
        }
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
        values.set(command.id, (value) => {
          input.value = String(value);
          shown.textContent = input.value;
        });
        remember(look, command.id, input);
        parent.appendChild(row);
        break;
      }
      case "style":
        applyStyle(look, command.id, command.kind, command.prop, command.value);
        break;
      case "load":
        samples.set(command.id, loadSample(command.name));
        break;
      case "play":
        if (splashWanted()) {
          showSplash();
          held.push(command);
        } else {
          play(command);
        }
        break;
      case "splash":
        if (splashWanted()) showSplash();
        break;
      case "splash_text":
        splashText = command.text;
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
      case "on_pointer": {
        const entry = canvases.get(command.c);
        if (entry) entry.pointer = true;
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
    if (splash !== null) {
      window.removeEventListener("keydown", dismissSplash, true);
      splash.remove();
    }
    keyTarget.removeEventListener("keydown", onKey);
    keyTarget.removeEventListener("keyup", onKeyUp);
    window.removeEventListener("blur", onBlur);
    if (!standalone) element.removeEventListener("click", takeFocus);
    if (audio !== null) audio.close();
  }

  return {
    receive(commands) {
      if (closed) return;
      for (const command of commands) {
        if (held !== null) held.push(command);
        else carryOut(command);
      }
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
