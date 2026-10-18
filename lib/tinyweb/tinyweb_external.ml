(* The OCaml implementation of the names declared in
   tinyweb_external.pyk: what the ocaml5.5 target links, and what the
   interpreter loads as a plugin -- the same file, which
   tinyweb_external_plugin.ml beside it joins to the interpreter.

   A program talks to its page in commands and the page answers in
   events (docs/libraries.md, "tinyweb"). Where the program runs decides
   where they go:

   - $PYKING_TINYWEB_LOG set: no page. Each command is a line in that
     file, and once the top level has ended the events
     $PYKING_TINYWEB_EVENTS lists are delivered -- how a program is
     tested.
   - otherwise `web_init port` serves the page, tinyweb_page.html and
     tinyweb_page.js (copied into this file below): GET /commands is a
     stream of command batches (server-sent events) and POST /events one
     event each. The server is one `select` loop on this thread, so it
     answers once the top level has ended -- or, in the REPL, whenever
     the prompt is waiting. Each event is answered with `event_done`
     once what it caused has been sent.
   - neither: the first call says `web_init` is missing, and the program
     ends with status 1.

   What runs once the top level has ended is `after_program`: a compiled
   program runs it from `at_exit`, and the interpreter, which sets
   `hosted`, runs it itself. `descriptors` and `handle` are how the REPL
   serves the page while it waits for a line. *)

let log_file = Stdlib.Sys.getenv_opt "PYKING_TINYWEB_LOG"
let events_file = Stdlib.Sys.getenv_opt "PYKING_TINYWEB_EVENTS"

(* Set by the interpreter's plugin, which runs `after_program` itself. *)
let hosted = ref false

(* Where a library sample is looked for, after beside the program: beside
   the executable, and in the build/ beside it, where `pyk compile` leaves
   the assets when it puts the executable outside. *)
let assets =
  let here = Filename.dirname Stdlib.Sys.executable_name in
  ref
    [
      Filename.concat here "tinyweb_assets";
      Filename.concat (Filename.concat here "build") "tinyweb_assets";
    ]

(* BEGIN tinyweb page *)
(* written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit *)
let page_html = String.concat "" [
  "<!doctype html>\n";
  "<!-- The page a program serves after tinyweb.web_init: tinyweb_page.js\n";
  "     carries out the commands the program sends over /commands, and every\n";
  "     event is posted back to /events, in order. Each native\n";
  "     implementation carries a copy of this file, written into it by\n";
  "     tools/tinyweb/embed_page.py. See docs/libraries.md, \"tinyweb\". -->\n";
  "<html lang=\"en\">\n";
  "<head>\n";
  "<meta charset=\"utf-8\">\n";
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n";
  "<title>tinyweb</title>\n";
  "<style>\n";
  "  body { margin: 0; padding: 16px; min-height: 100vh; box-sizing: border-box; }\n";
  "  .tinyweb-ended { margin-top: 12px; color: #666666; font-size: 14px; }\n";
  "</style>\n";
  "</head>\n";
  "<body>\n";
  "<script type=\"module\">\n";
  "import { mountPage } from \"./tinyweb_page.js\";\n";
  "\n";
  "// One event at a time, so the program sees them in the order they\n";
  "// happened.\n";
  "let posting = Promise.resolve();\n";
  "function post(event) {\n";
  "  posting = posting\n";
  "    .then(() => fetch(\"/events\", { method: \"POST\", body: JSON.stringify(event) }))\n";
  "    .catch(() => {});\n";
  "}\n";
  "\n";
  "const page = mountPage(document.body, post, { standalone: true });\n";
  "const stream = new EventSource(\"/commands\");\n";
  "stream.onmessage = (message) => page.receive(JSON.parse(message.data));\n";
  "stream.onerror = () => {\n";
  "  stream.close();\n";
  "  page.freeze();\n";
  "  const ended = document.createElement(\"div\");\n";
  "  ended.className = \"tinyweb-ended\";\n";
  "  ended.textContent = \"The program has stopped.\";\n";
  "  document.body.appendChild(ended);\n";
  "};\n";
  "</script>\n";
  "</body>\n";
  "</html>\n";
]
let page_js = String.concat "" [
  "// tinyweb's page: the renderer that carries out the commands a program\n";
  "// sends and reports the events its reader causes. It is the one copy of\n";
  "// that code, used wherever a program talks to its page in commands:\n";
  "//\n";
  "//   - on an iweb24 page, where tinyweb_external_interpreter.js mounts it\n";
  "//     and calls it directly;\n";
  "//   - in the playground and the notebook, where the program runs on a\n";
  "//     worker and tools/webrun/assets/pages.js mounts it on the page;\n";
  "//   - on the page a compiled program serves after `web_init`, where\n";
  "//     tinyweb_page.html mounts it and the commands arrive from the\n";
  "//     program over HTTP. Each native implementation carries a copy of\n";
  "//     this file and of tinyweb_page.html, written into it by\n";
  "//     tools/tinyweb/embed_page.py.\n";
  "//\n";
  "// A command is a plain object such as {op: \"circle\", c, x, y, radius,\n";
  "// color}, and an event one such as {ev: \"click\", id}; see\n";
  "// docs/libraries.md, \"tinyweb\". The web24 implementation,\n";
  "// tinyweb_external_browser.js, does what this file does without the\n";
  "// commands in between. Keep the file ASCII: it is embedded in C.\n";
  "\n";
  "function now() {\n";
  "  return typeof performance !== \"undefined\" ? performance.now() : Date.now();\n";
  "}\n";
  "\n";
  "// BEGIN tinyweb style\n";
  "// The page's look: a theme, what the program changed of it for every\n";
  "// element of a kind, and what it changed of one element. A theme and a\n";
  "// kind's style are rules of a stylesheet of the page's own, scoped to the\n";
  "// element the page is mounted in, so the host page's own rules do not\n";
  "// reach in; one element's style is set on the element. This block is\n";
  "// copied into tinyweb_external_browser.js by tools/tinyweb/embed_page.py.\n";
  "\n";
  "// Each theme: CSS declarations for each place on the page (PLACES).\n";
  "const THEMES = {\n";
  "  light: {\n";
  "    page: { \"background\": \"#f6f6f4\", \"color\": \"#1d1f21\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n";
  "    box: { \"gap\": \"8px\" },\n";
  "    button: {\n";
  "      \"background\": \"#f0f2f5\", \"color\": \"#1f2328\", \"border\": \"1px solid #d4d8de\",\n";
  "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n";
  "    },\n";
  "    \"button:hover\": { \"border-color\": \"#2f5fc4\" },\n";
  "    \"button:active\": { \"background\": \"#e3e7ec\" },\n";
  "    \"slider input\": { \"accent-color\": \"#2f5fc4\" },\n";
  "    canvas: { \"border\": \"1px solid #c9ced6\" },\n";
  "  },\n";
  "  dark: {\n";
  "    page: { \"background\": \"#1d1f21\", \"color\": \"#e6e6e6\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n";
  "    box: { \"gap\": \"8px\" },\n";
  "    button: {\n";
  "      \"background\": \"#2f333a\", \"color\": \"#e6e6e6\", \"border\": \"1px solid #454a52\",\n";
  "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n";
  "    },\n";
  "    \"button:hover\": { \"border-color\": \"#7aa2f7\" },\n";
  "    \"button:active\": { \"background\": \"#3a3f47\" },\n";
  "    \"slider input\": { \"accent-color\": \"#7aa2f7\" },\n";
  "    canvas: { \"border\": \"1px solid #454a52\" },\n";
  "  },\n";
  "  plain: {\n";
  "    page: { \"background\": \"#ffffff\", \"color\": \"#000000\", \"font-family\": \"system-ui, sans-serif\" },\n";
  "    box: { \"gap\": \"8px\" },\n";
  "    canvas: { \"border\": \"1px solid #8884\" },\n";
  "  },\n";
  "  paper: {\n";
  "    page: { \"background\": \"#fbf6ea\", \"color\": \"#3b3024\", \"font-family\": \"Georgia, 'Times New Roman', serif\", \"font-size\": \"16px\" },\n";
  "    box: { \"gap\": \"10px\" },\n";
  "    button: {\n";
  "      \"background\": \"#fffdf7\", \"color\": \"#3b3024\", \"border\": \"1px solid #3b3024\",\n";
  "      \"border-radius\": \"2px\", \"padding\": \"5px 14px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n";
  "    },\n";
  "    \"button:hover\": { \"background\": \"#f1e8d2\" },\n";
  "    \"button:active\": { \"background\": \"#e6d9bb\" },\n";
  "    \"slider input\": { \"accent-color\": \"#8a5a2b\" },\n";
  "    canvas: { \"border\": \"1px solid #3b302466\" },\n";
  "  },\n";
  "  retro: {\n";
  "    page: { \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"font-family\": \"'Courier New', monospace\", \"font-size\": \"15px\" },\n";
  "    box: { \"gap\": \"10px\" },\n";
  "    button: {\n";
  "      \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"border\": \"2px solid #39ff6a\",\n";
  "      \"border-radius\": \"0\", \"padding\": \"4px 12px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n";
  "    },\n";
  "    \"button:hover\": { \"background\": \"#133313\" },\n";
  "    \"button:active\": { \"background\": \"#39ff6a\", \"color\": \"#0b1a0b\" },\n";
  "    \"slider input\": { \"accent-color\": \"#39ff6a\" },\n";
  "    canvas: { \"border\": \"2px solid #39ff6a\" },\n";
  "  },\n";
  "};\n";
  "\n";
  "// Where each place is, after the page's scope.\n";
  "const PLACES = {\n";
  "  page: \"\",\n";
  "  box: \" > .tinyweb-page\",\n";
  "  button: \" .tinyweb-page button\",\n";
  "  \"button:hover\": \" .tinyweb-page button:hover\",\n";
  "  \"button:active\": \" .tinyweb-page button:active\",\n";
  "  label: \" .tinyweb-page .tinyweb-label\",\n";
  "  slider: \" .tinyweb-page .tinyweb-slider\",\n";
  "  \"slider input\": \" .tinyweb-page .tinyweb-slider input\",\n";
  "  canvas: \" .tinyweb-page canvas\",\n";
  "};\n";
  "\n";
  "// What each property a program names is in CSS.\n";
  "const PROPERTIES = {\n";
  "  background: \"background\", color: \"color\", border: \"border\", radius: \"border-radius\",\n";
  "  font: \"font-family\", size: \"font-size\", padding: \"padding\", gap: \"gap\",\n";
  "  accent: \"accent-color\", width: \"width\", height: \"height\", align: \"align-items\",\n";
  "  weight: \"font-weight\",\n";
  "};\n";
  "\n";
  "// What an `align` a program names is in CSS.\n";
  "const ALIGNMENTS = { left: \"flex-start\", center: \"center\", right: \"flex-end\" };\n";
  "\n";
  "// The place a kind's property goes. String -> String -> String\n";
  "function placeOf(kind, property) {\n";
  "  if (kind === \"page\") return property === \"gap\" || property === \"align\" ? \"box\" : \"page\";\n";
  "  if (kind === \"slider\") return property === \"accent\" || property === \"width\" ? \"slider input\" : \"slider\";\n";
  "  return kind;\n";
  "}\n";
  "\n";
  "let styledPages = 0;\n";
  "\n";
  "// Gives the page mounted in `host` a stylesheet of its own, in the\n";
  "// default theme. Element -> Element -> Style\n";
  "function styled(host, box) {\n";
  "  styledPages += 1;\n";
  "  const sheet = document.createElement(\"style\");\n";
  "  sheet.setAttribute(\"data-tinyweb-style\", String(styledPages));\n";
  "  const style = { host, box, sheet, rules: null, elements: new Map(), name: String(styledPages) };\n";
  "  host.setAttribute(\"data-tinyweb-page\", style.name);\n";
  "  (document.head || document.body).appendChild(sheet);\n";
  "  setTheme(style, \"light\");\n";
  "  return style;\n";
  "}\n";
  "\n";
  "// Writes the stylesheet from the rules. Style -> ()\n";
  "function writeSheet(style) {\n";
  "  // The scope three times over, so the host page's rules for a button or\n";
  "  // a body do not outweigh the page's own.\n";
  "  const scope = `[data-tinyweb-page=\"${style.name}\"]`.repeat(3);\n";
  "  const text = [];\n";
  "  for (const place of Object.keys(PLACES)) {\n";
  "    const declarations = style.rules[place];\n";
  "    if (!declarations || Object.keys(declarations).length === 0) continue;\n";
  "    const body = Object.entries(declarations).map(([k, v]) => `${k}: ${v};`).join(\" \");\n";
  "    text.push(`${scope}${PLACES[place]} { ${body} }`);\n";
  "  }\n";
  "  style.sheet.textContent = text.join(\"\\n\");\n";
  "}\n";
  "\n";
  "// Puts the page in a theme, forgetting what was changed for each kind.\n";
  "// An unknown name changes nothing. Style -> String -> ()\n";
  "function setTheme(style, name) {\n";
  "  const theme = THEMES[name];\n";
  "  if (!theme) return;\n";
  "  style.rules = {};\n";
  "  for (const [place, declarations] of Object.entries(theme)) {\n";
  "    style.rules[place] = { ...declarations };\n";
  "  }\n";
  "  writeSheet(style);\n";
  "}\n";
  "\n";
  "// Remembers a page element by its id, so that its own style can be set.\n";
  "// Style -> Int -> Element -> ()\n";
  "function remember(style, id, element) {\n";
  "  style.elements.set(id, element);\n";
  "}\n";
  "\n";
  "// Carries out one style command: a theme, a property of every element\n";
  "// of a kind, or a property of the element `id` (kind \"element\").\n";
  "// Style -> Int -> String -> String -> String -> ()\n";
  "function applyStyle(style, id, kind, property, given) {\n";
  "  if (kind === \"theme\") {\n";
  "    setTheme(style, given);\n";
  "    return;\n";
  "  }\n";
  "  const css = PROPERTIES[property];\n";
  "  if (!css) return;\n";
  "  const value = property === \"align\" ? ALIGNMENTS[given] || \"flex-start\" : given;\n";
  "  if (kind === \"page\" && property === \"align\") {\n";
  "    // The box says where its elements stand on the element itself.\n";
  "    style.box.style.setProperty(css, value);\n";
  "    return;\n";
  "  }\n";
  "  if (kind === \"element\") {\n";
  "    let element = style.elements.get(id);\n";
  "    if (!element) return;\n";
  "    // A slider's own properties are its input's; the rest are its row's.\n";
  "    if (element.tagName === \"INPUT\" && property !== \"accent\" && property !== \"width\") {\n";
  "      element = element.parentNode;\n";
  "    }\n";
  "    element.style.setProperty(css, value);\n";
  "    return;\n";
  "  }\n";
  "  const place = placeOf(kind, property);\n";
  "  if (!(place in PLACES)) return;\n";
  "  if (!style.rules[place]) style.rules[place] = {};\n";
  "  style.rules[place][css] = value;\n";
  "  writeSheet(style);\n";
  "}\n";
  "\n";
  "// Takes the page's look off the element it was mounted in. Style -> ()\n";
  "function unstyled(style) {\n";
  "  style.sheet.remove();\n";
  "  if (style.host.getAttribute(\"data-tinyweb-page\") === style.name) {\n";
  "    style.host.removeAttribute(\"data-tinyweb-page\");\n";
  "  }\n";
  "}\n";
  "// What the splash screen says until the program sets it.\n";
  "const SPLASH_TEXT = \"Click to Start\";\n";
  "\n";
  "// The splash screen: the whole window dimmed, and `text` in white in\n";
  "// its middle under a play sign. String -> Element\n";
  "function splashScreen(text) {\n";
  "  const screen = document.createElement(\"div\");\n";
  "  screen.className = \"tinyweb-splash\";\n";
  "  screen.setAttribute(\"role\", \"button\");\n";
  "  screen.style.cssText =\n";
  "    \"position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;\" +\n";
  "    \"align-items:center;justify-content:center;gap:24px;background:rgba(0,0,0,0.62);\" +\n";
  "    \"color:#ffffff;cursor:pointer;user-select:none;font-family:system-ui,sans-serif\";\n";
  "  const ring = document.createElement(\"div\");\n";
  "  ring.style.cssText =\n";
  "    \"width:88px;height:88px;border-radius:50%;border:3px solid #ffffff;display:flex;\" +\n";
  "    \"align-items:center;justify-content:center;box-shadow:0 0 36px rgba(255,255,255,0.35)\";\n";
  "  const sign = document.createElement(\"div\");\n";
  "  sign.style.cssText =\n";
  "    \"width:0;height:0;margin-left:9px;border-top:19px solid transparent;\" +\n";
  "    \"border-bottom:19px solid transparent;border-left:32px solid #ffffff\";\n";
  "  ring.appendChild(sign);\n";
  "  const words = document.createElement(\"div\");\n";
  "  words.textContent = text;\n";
  "  words.style.cssText =\n";
  "    \"font-size:34px;font-weight:600;letter-spacing:0.03em;text-align:center;\" +\n";
  "    \"padding:0 24px;text-shadow:0 2px 14px rgba(0,0,0,0.6)\";\n";
  "  screen.append(ring, words);\n";
  "  return screen;\n";
  "}\n";
  "\n";
  "// Whether the reader has already done something on this page, which is\n";
  "// all a browser asks before it plays a sound. () -> Bool\n";
  "function readerActive() {\n";
  "  return Boolean(globalThis.navigator?.userActivation?.hasBeenActive);\n";
  "}\n";
  "// --- drawing (step 1) ---\n";
  "\n";
  "// A shape's numbers: the words tinyweb.pyk wrote, as numbers.\n";
  "function numbersOf(text) {\n";
  "  return text === \"\" ? [] : text.split(\" \").map(Number);\n";
  "}\n";
  "\n";
  "// A rectangle with rounded corners, as a path. Context -> ... -> ()\n";
  "function roundedRect(g, x, y, w, h, r) {\n";
  "  const k = Math.max(0, Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2));\n";
  "  g.moveTo(x + k, y);\n";
  "  g.arcTo(x + w, y, x + w, y + h, k);\n";
  "  g.arcTo(x + w, y + h, x, y + h, k);\n";
  "  g.arcTo(x, y + h, x, y, k);\n";
  "  g.arcTo(x, y, x + w, y, k);\n";
  "  g.closePath();\n";
  "}\n";
  "\n";
  "// The outline of one shape, added to the context's path. Whether a filled\n";
  "// arc is a slice from its centre is `slice`'s.\n";
  "// Context -> String -> [Float] -> Bool -> ()\n";
  "function shapePath(g, kind, n, slice) {\n";
  "  const degrees = Math.PI / 180;\n";
  "  switch (kind) {\n";
  "    case \"rect\":\n";
  "      if (n[4] > 0) roundedRect(g, n[0], n[1], n[2], n[3], n[4]);\n";
  "      else g.rect(n[0], n[1], n[2], n[3]);\n";
  "      break;\n";
  "    case \"circle\":\n";
  "      g.arc(n[0], n[1], Math.max(0, n[2]), 0, 2 * Math.PI);\n";
  "      break;\n";
  "    case \"ellipse\":\n";
  "      g.ellipse(n[0], n[1], Math.max(0, n[2]), Math.max(0, n[3]), 0, 0, 2 * Math.PI);\n";
  "      break;\n";
  "    case \"arc\":\n";
  "      if (slice) g.moveTo(n[0], n[1]);\n";
  "      g.arc(n[0], n[1], Math.max(0, n[2]), n[3] * degrees, n[4] * degrees);\n";
  "      if (slice) g.closePath();\n";
  "      break;\n";
  "    case \"line\":\n";
  "      g.moveTo(n[0], n[1]);\n";
  "      g.lineTo(n[2], n[3]);\n";
  "      break;\n";
  "    case \"lines\":\n";
  "      for (let i = 0; i + 3 < n.length; i += 4) {\n";
  "        g.moveTo(n[i], n[i + 1]);\n";
  "        g.lineTo(n[i + 2], n[i + 3]);\n";
  "      }\n";
  "      break;\n";
  "    case \"curve\":\n";
  "      g.moveTo(n[0], n[1]);\n";
  "      g.quadraticCurveTo(n[2], n[3], n[4], n[5]);\n";
  "      break;\n";
  "    case \"bezier\":\n";
  "      g.moveTo(n[0], n[1]);\n";
  "      g.bezierCurveTo(n[2], n[3], n[4], n[5], n[6], n[7]);\n";
  "      break;\n";
  "    case \"polygon\":\n";
  "    case \"path\":\n";
  "      for (let i = 0; i + 1 < n.length; i += 2) {\n";
  "        if (i === 0) g.moveTo(n[i], n[i + 1]);\n";
  "        else g.lineTo(n[i], n[i + 1]);\n";
  "      }\n";
  "      if (kind === \"polygon\") g.closePath();\n";
  "      break;\n";
  "  }\n";
  "}\n";
  "\n";
  "// The gradients a canvas has been given, by the text that describes\n";
  "// them, so a frame drawing the same one again does not make it again.\n";
  "const GRADIENTS_KEPT = 64;\n";
  "\n";
  "// What a color means on a context: a CSS color as it is, and a gradient\n";
  "// tinyweb.pyk described -- \"linear-gradient(x1 y1 x2 y2); 0 red; 1 blue\",\n";
  "// \"radial-gradient(x1 y1 r1 x2 y2 r2); ...\", \"conic-gradient(x y\n";
  "// angle); ...\" -- as the gradient. Context -> Entry? -> String -> Paint\n";
  "function paint(g, entry, color) {\n";
  "  const open = color.indexOf(\"(\");\n";
  "  if (open < 0 || !color.slice(0, open).endsWith(\"-gradient\")) return color;\n";
  "  const close = color.indexOf(\")\", open);\n";
  "  if (close < 0 || color.slice(close + 1, close + 2) !== \";\") return color;\n";
  "  const kept = entry ? entry.gradients : null;\n";
  "  if (kept && kept.has(color)) return kept.get(color);\n";
  "  const kind = color.slice(0, open);\n";
  "  const n = numbersOf(color.slice(open + 1, close).trim());\n";
  "  let gradient;\n";
  "  if (kind === \"linear-gradient\") gradient = g.createLinearGradient(n[0], n[1], n[2], n[3]);\n";
  "  else if (kind === \"radial-gradient\")\n";
  "    gradient = g.createRadialGradient(n[0], n[1], Math.max(0, n[2]), n[3], n[4], Math.max(0, n[5]));\n";
  "  else if (kind === \"conic-gradient\" && typeof g.createConicGradient === \"function\")\n";
  "    gradient = g.createConicGradient((n[2] * Math.PI) / 180, n[0], n[1]);\n";
  "  else return \"#000000\";\n";
  "  // A stop's color may itself hold brackets and commas, \"rgba(0, 0, 0, 0.5)\",\n";
  "  // but never a semicolon.\n";
  "  for (const stop of color.slice(close + 2).split(\";\")) {\n";
  "    const text = stop.trim();\n";
  "    const space = text.indexOf(\" \");\n";
  "    if (space < 0) continue;\n";
  "    const at = Math.min(1, Math.max(0, Number(text.slice(0, space))));\n";
  "    try {\n";
  "      gradient.addColorStop(at, text.slice(space + 1).trim());\n";
  "    } catch (error) {\n";
  "      // A stop whose color the browser does not read is left out.\n";
  "    }\n";
  "  }\n";
  "  if (kept) {\n";
  "    if (kept.size >= GRADIENTS_KEPT) kept.delete(kept.keys().next().value);\n";
  "    kept.set(color, gradient);\n";
  "  }\n";
  "  return gradient;\n";
  "}\n";
  "\n";
  "// Draws one shape: filled with `color` and outlined with `outline`, each\n";
  "// unless it is \"\", at `alpha`, in the canvas's line style. The numbers\n";
  "// are the kind's own (see tinyweb.pyk), as words or as an array;\n";
  "// \"erase\" makes its rectangle transparent, and \"circles\" draws each\n";
  "// circle on its own. Context -> Entry? -> String -> Numbers -> ... -> ()\n";
  "function drawShape(g, entry, kind, numbers, color, outline, width, alpha) {\n";
  "  const n = typeof numbers === \"string\" ? numbersOf(numbers) : numbers;\n";
  "  if (kind === \"erase\") {\n";
  "    g.clearRect(n[0], n[1], n[2], n[3]);\n";
  "    return;\n";
  "  }\n";
  "  const before = g.globalAlpha;\n";
  "  g.globalAlpha = before * alpha;\n";
  "  if (kind === \"circles\") {\n";
  "    // Each circle on its own, so where two overlap both show.\n";
  "    if (color !== \"\") g.fillStyle = paint(g, entry, color);\n";
  "    if (outline !== \"\") {\n";
  "      g.strokeStyle = paint(g, entry, outline);\n";
  "      g.lineWidth = width;\n";
  "    }\n";
  "    for (let i = 0; i + 2 < n.length; i += 3) {\n";
  "      g.beginPath();\n";
  "      g.arc(n[i], n[i + 1], Math.max(0, n[i + 2]), 0, 2 * Math.PI);\n";
  "      if (color !== \"\") g.fill();\n";
  "      if (outline !== \"\") g.stroke();\n";
  "    }\n";
  "    g.globalAlpha = before;\n";
  "    return;\n";
  "  }\n";
  "  g.beginPath();\n";
  "  shapePath(g, kind, n, color !== \"\");\n";
  "  if (color !== \"\") {\n";
  "    g.fillStyle = paint(g, entry, color);\n";
  "    g.fill();\n";
  "  }\n";
  "  if (outline !== \"\") {\n";
  "    g.strokeStyle = paint(g, entry, outline);\n";
  "    g.lineWidth = width;\n";
  "    g.stroke();\n";
  "  }\n";
  "  g.globalAlpha = before;\n";
  "}\n";
  "\n";
  "// The font text is written in. Int -> String -> Bool -> String\n";
  "function fontOf(size, font, bold) {\n";
  "  return `${bold ? \"bold \" : \"\"}${size}px ${font === \"\" ? \"system-ui, sans-serif\" : font}`;\n";
  "}\n";
  "\n";
  "// Writes text at (x, y): its left end there, its middle or its right end,\n";
  "// as `align` says, and its top, middle, alphabetic baseline or bottom,\n";
  "// as `baseline` says. An `outline` is drawn round the letters first.\n";
  "// Context -> Entry? -> ... -> ()\n";
  "function drawText(g, entry, x, y, words, color, size, font, align, baseline, bold, outline,\n";
  "  outlineWidth, alpha) {\n";
  "  const before = g.globalAlpha;\n";
  "  g.globalAlpha = before * alpha;\n";
  "  g.font = fontOf(size, font, bold);\n";
  "  g.textBaseline = [\"top\", \"middle\", \"alphabetic\", \"bottom\"].includes(baseline) ? baseline : \"top\";\n";
  "  g.textAlign = align === \"center\" || align === \"right\" ? align : \"left\";\n";
  "  if (outline !== \"\") {\n";
  "    g.strokeStyle = paint(g, entry, outline);\n";
  "    g.lineWidth = outlineWidth;\n";
  "    g.strokeText(words, x, y);\n";
  "  }\n";
  "  if (color !== \"\") {\n";
  "    g.fillStyle = paint(g, entry, color);\n";
  "    g.fillText(words, x, y);\n";
  "  }\n";
  "  g.globalAlpha = before;\n";
  "}\n";
  "\n";
  "// How wide `words` is written in that font, in pixels.\n";
  "// String -> Int -> String -> Bool -> Float\n";
  "function textWidth(words, size, font, bold) {\n";
  "  if (typeof document === \"undefined\") return 0;\n";
  "  if (!textWidth.context) textWidth.context = document.createElement(\"canvas\").getContext(\"2d\");\n";
  "  const g = textWidth.context;\n";
  "  if (!g) return 0;\n";
  "  g.font = fontOf(size, font, bold);\n";
  "  return g.measureText(words).width;\n";
  "}\n";
  "\n";
  "// The line style a canvas starts with: round ends and corners, no dashes.\n";
  "// Context -> ()\n";
  "function plainLines(g) {\n";
  "  g.lineCap = \"round\";\n";
  "  g.lineJoin = \"round\";\n";
  "  if (typeof g.setLineDash === \"function\") g.setLineDash([]);\n";
  "  g.lineDashOffset = 0;\n";
  "}\n";
  "\n";
  "// Changes what the next drawing on a canvas is drawn with. `entry` keeps\n";
  "// the canvas's pixel ratio and how many `push`es are open.\n";
  "// Context -> Entry -> String -> String -> String -> ()\n";
  "function canvasState(g, entry, kind, value, numbers) {\n";
  "  const n = numbersOf(numbers);\n";
  "  switch (kind) {\n";
  "    case \"translate\":\n";
  "      g.translate(n[0], n[1]);\n";
  "      break;\n";
  "    case \"rotate\":\n";
  "      g.rotate((n[0] * Math.PI) / 180);\n";
  "      break;\n";
  "    case \"scale\":\n";
  "      g.scale(n[0], n[1]);\n";
  "      break;\n";
  "    case \"push\":\n";
  "      g.save();\n";
  "      entry.depth += 1;\n";
  "      break;\n";
  "    case \"pop\":\n";
  "      if (entry.depth > 0) {\n";
  "        g.restore();\n";
  "        entry.depth -= 1;\n";
  "      }\n";
  "      break;\n";
  "    case \"reset\":\n";
  "      g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n";
  "      break;\n";
  "    case \"shadow\":\n";
  "      g.shadowColor = value === \"\" ? \"transparent\" : value;\n";
  "      g.shadowBlur = value === \"\" ? 0 : n[0];\n";
  "      g.shadowOffsetX = value === \"\" ? 0 : n[1];\n";
  "      g.shadowOffsetY = value === \"\" ? 0 : n[2];\n";
  "      break;\n";
  "    case \"blend\":\n";
  "      g.globalCompositeOperation = value === \"add\" ? \"lighter\" : \"source-over\";\n";
  "      break;\n";
  "    case \"line_style\": {\n";
  "      // value: the ends and the corners; numbers: the dash offset, then\n";
  "      // the lengths of the dashes and the gaps.\n";
  "      const [cap, join] = value.split(\" \");\n";
  "      g.lineCap = [\"butt\", \"round\", \"square\"].includes(cap) ? cap : \"round\";\n";
  "      g.lineJoin = [\"miter\", \"round\", \"bevel\"].includes(join) ? join : \"round\";\n";
  "      if (typeof g.setLineDash === \"function\") g.setLineDash(n.slice(1));\n";
  "      g.lineDashOffset = n.length > 0 ? n[0] : 0;\n";
  "      break;\n";
  "    }\n";
  "    case \"clip\":\n";
  "      // value: the kind of shape the drawing is kept inside.\n";
  "      g.beginPath();\n";
  "      shapePath(g, value, n, false);\n";
  "      g.clip();\n";
  "      break;\n";
  "  }\n";
  "}\n";
  "\n";
  "// A canvas as it starts: every `push` closed, no transformation but the\n";
  "// pixel ratio, no shadow, no blending, no clipping and plain lines. What\n";
  "// `clear` begins with. Context -> Entry -> ()\n";
  "function freshState(g, entry) {\n";
  "  while (entry.depth > 0) {\n";
  "    g.restore();\n";
  "    entry.depth -= 1;\n";
  "  }\n";
  "  g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n";
  "  g.globalAlpha = 1;\n";
  "  g.shadowColor = \"transparent\";\n";
  "  g.shadowBlur = 0;\n";
  "  g.shadowOffsetX = 0;\n";
  "  g.shadowOffsetY = 0;\n";
  "  g.globalCompositeOperation = \"source-over\";\n";
  "  plainLines(g);\n";
  "}\n";
  "\n";
  "// Starts loading a picture: beside the page first, then among the ones\n";
  "// tinyweb ships beside `base`. Answers what `drawPicture` draws once it\n";
  "// has loaded. String -> String -> Picture\n";
  "function loadPicture(name, base) {\n";
  "  const picture = { element: null, ready: false, retried: false };\n";
  "  if (typeof Image === \"undefined\") return picture;\n";
  "  const element = new Image();\n";
  "  picture.element = element;\n";
  "  element.onload = () => {\n";
  "    picture.ready = true;\n";
  "  };\n";
  "  element.onerror = () => {\n";
  "    if (picture.retried) {\n";
  "      console.error(`tinyweb: cannot load the picture ${name}`);\n";
  "      return;\n";
  "    }\n";
  "    picture.retried = true;\n";
  "    element.src = new URL(\"tinyweb_assets/\" + name, base).href;\n";
  "  };\n";
  "  element.src = new URL(name, document.baseURI).href;\n";
  "  return picture;\n";
  "}\n";
  "\n";
  "// Draws a picture that has loaded; one still loading is not drawn.\n";
  "// Context -> Picture? -> ... -> ()\n";
  "function drawPicture(g, picture, x, y, width, height, alpha) {\n";
  "  if (!picture || !picture.ready) return;\n";
  "  const before = g.globalAlpha;\n";
  "  g.globalAlpha = before * alpha;\n";
  "  g.drawImage(picture.element, x, y, width, height);\n";
  "  g.globalAlpha = before;\n";
  "}\n";
  "\n";
  "// Keeps the pointer's moves and its release coming to the canvas it went\n";
  "// down on, wherever it goes. Element -> Event -> ()\n";
  "function capture(element, event) {\n";
  "  try {\n";
  "    if (element.setPointerCapture) element.setPointerCapture(event.pointerId);\n";
  "  } catch (error) {\n";
  "    // A pointer the browser does not know of, as a test's is, is not held.\n";
  "  }\n";
  "}\n";
  "\n";
  "// --- bitmaps (step 5) ---\n";
  "\n";
  "// The bytes of a bitmap's rectangle as they arrive: a base64 string from\n";
  "// a program on another host, or the bytes themselves. Data -> Uint8ClampedArray\n";
  "function bitmapBytes(data) {\n";
  "  if (typeof data !== \"string\") {\n";
  "    return ArrayBuffer.isView(data)\n";
  "      ? new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)\n";
  "      : new Uint8ClampedArray(data);\n";
  "  }\n";
  "  const text = atob(data);\n";
  "  const bytes = new Uint8ClampedArray(text.length);\n";
  "  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);\n";
  "  return bytes;\n";
  "}\n";
  "\n";
  "// A bitmap as the page keeps it: a canvas of its own, its pixels.\n";
  "// Int -> Int -> Surface\n";
  "function bitmapSurface(width, height) {\n";
  "  const element = document.createElement(\"canvas\");\n";
  "  element.width = Math.max(1, width);\n";
  "  element.height = Math.max(1, height);\n";
  "  return { element, context: element.getContext(\"2d\"), width, height };\n";
  "}\n";
  "\n";
  "// Puts the rectangle (rx, ry, rw, rh) of a bitmap's pixels on its\n";
  "// surface. Surface -> Int -> Int -> Int -> Int -> Data -> ()\n";
  "function updateSurface(surface, rx, ry, rw, rh, data) {\n";
  "  if (rw <= 0 || rh <= 0) return;\n";
  "  const bytes = bitmapBytes(data);\n";
  "  if (bytes.length !== rw * rh * 4) return;\n";
  "  surface.context.putImageData(new ImageData(bytes, rw, rh), rx, ry);\n";
  "}\n";
  "\n";
  "// Draws a bitmap's surface with its top left corner at (x, y), each pixel\n";
  "// `scale` pixels across: sharp squares when it grows, smooth when it\n";
  "// shrinks. Context -> Surface -> Float -> Float -> Float -> ()\n";
  "function drawSurface(g, surface, x, y, scale) {\n";
  "  const smoothing = g.imageSmoothingEnabled;\n";
  "  g.imageSmoothingEnabled = scale < 1;\n";
  "  g.drawImage(surface.element, x, y, surface.width * scale, surface.height * scale);\n";
  "  g.imageSmoothingEnabled = smoothing;\n";
  "}\n";
  "\n";
  "// A box whose elements go side by side, wrapping where the page is too\n";
  "// narrow for them, or one below another. String -> Bool -> Element\n";
  "function rowElement(id, across = true) {\n";
  "  const row = document.createElement(\"div\");\n";
  "  row.className = across ? \"tinyweb-row\" : \"tinyweb-column\";\n";
  "  row.setAttribute(\"data-tinyweb-id\", id);\n";
  "  row.style.cssText = across\n";
  "    ? \"display:flex;flex-direction:row;flex-wrap:wrap;align-items:center;gap:8px\"\n";
  "    : \"display:flex;flex-direction:column;align-items:flex-start;gap:6px\";\n";
  "  return row;\n";
  "}\n";
  "\n";
  "// --- widgets (step 2) ---\n";
  "\n";
  "// A checkbox or a radio button with its title beside it: the row, and\n";
  "// the input in it. String -> String -> String -> Bool -> (Element, Element)\n";
  "function choiceRow(type, id, title, checked) {\n";
  "  const row = document.createElement(\"label\");\n";
  "  row.className = type === \"checkbox\" ? \"tinyweb-check\" : \"tinyweb-radio\";\n";
  "  row.style.cssText = \"display:flex;align-items:center;gap:6px\";\n";
  "  const input = document.createElement(\"input\");\n";
  "  input.type = type;\n";
  "  input.setAttribute(\"data-tinyweb-id\", id);\n";
  "  input.checked = checked;\n";
  "  const text = document.createElement(\"span\");\n";
  "  text.textContent = title;\n";
  "  row.append(input, text);\n";
  "  return { row, input };\n";
  "}\n";
  "\n";
  "// A dropdown of the options, one per line of `options`, the one at\n";
  "// `chosen` chosen. String -> String -> Int -> Element\n";
  "function choiceElement(id, options, chosen) {\n";
  "  const select = document.createElement(\"select\");\n";
  "  select.className = \"tinyweb-choice\";\n";
  "  select.setAttribute(\"data-tinyweb-id\", id);\n";
  "  options.split(\"\\n\").forEach((text, position) => {\n";
  "    const option = document.createElement(\"option\");\n";
  "    option.value = String(position);\n";
  "    option.textContent = text;\n";
  "    select.appendChild(option);\n";
  "  });\n";
  "  select.value = String(chosen);\n";
  "  return select;\n";
  "}\n";
  "\n";
  "// A line to type text into. String -> String -> Element\n";
  "function textInputElement(id, placeholder) {\n";
  "  const input = document.createElement(\"input\");\n";
  "  input.type = \"text\";\n";
  "  input.className = \"tinyweb-text\";\n";
  "  input.setAttribute(\"data-tinyweb-id\", id);\n";
  "  input.placeholder = placeholder;\n";
  "  return input;\n";
  "}\n";
  "\n";
  "// A field for a whole number from `low` to `high`. ... -> Element\n";
  "function numberElement(id, low, high, value) {\n";
  "  const input = document.createElement(\"input\");\n";
  "  input.type = \"number\";\n";
  "  input.className = \"tinyweb-number\";\n";
  "  input.setAttribute(\"data-tinyweb-id\", id);\n";
  "  input.min = String(low);\n";
  "  input.max = String(high);\n";
  "  input.value = String(value);\n";
  "  return input;\n";
  "}\n";
  "\n";
  "// Whether a key press is the reader typing into a field, which the page\n";
  "// does not report as a key. Event -> Bool\n";
  "function typedInField(event) {\n";
  "  const target = event.target;\n";
  "  return !!target && typeof target.tagName === \"string\"\n";
  "    && (target.tagName === \"SELECT\"\n";
  "      || (target.tagName === \"INPUT\" && (target.type === \"text\" || target.type === \"number\")));\n";
  "}\n";
  "// END tinyweb style\n";
  "\n";
  "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n";
  "// `receive(commands)` carries out a batch of commands, and `send(event)`\n";
  "// is how the page reports one. `standalone` is true where the page is\n";
  "// the whole document, which is where a key press is listened for; a\n";
  "// page inside another (a notebook cell) listens on `element`, which\n";
  "// takes the focus when clicked. `activated` is true where the reader\n";
  "// started the program with a click or a key, as in the playground and\n";
  "// a notebook, and the page then never shows the splash screen.\n";
  "export function mountPage(element, sendEvent, { standalone = false, activated = false } = {}) {\n";
  "  const box = document.createElement(\"div\");\n";
  "  box.className = \"tinyweb-page\";\n";
  "  box.style.cssText =\n";
  "    \"display:flex;flex-direction:column;align-items:flex-start;outline:none\";\n";
  "  element.appendChild(box);\n";
  "  const look = styled(element, box);\n";
  "\n";
  "  const canvases = new Map();\n";
  "  const labels = new Map();\n";
  "  const samples = new Map();\n";
  "  const pictures = new Map();\n";
  "  // What `set_checked` and `set_value` change, by identifier, and each\n";
  "  // group of radio buttons.\n";
  "  const checks = new Map();\n";
  "  const values = new Map();\n";
  "  const groups = new Map();\n";
  "  const bitmaps = new Map();\n";
  "  // Where an element made now goes: the page, or a row it was put inside.\n";
  "  const rows = new Map();\n";
  "  let parent = box;\n";
  "  // The keys held down, reported again as released when the page loses\n";
  "  // the focus.\n";
  "  const heldKeys = new Set();\n";
  "  let start = now();\n";
  "  let audio = null;\n";
  "  let offset = 0;\n";
  "  let frameWanted = false;\n";
  "  let frameWaiting = false;\n";
  "  let frameRequest = 0;\n";
  "  let closed = false;\n";
  "  // Inside another page the keys go to the element the page is mounted\n";
  "  // in, which takes the focus when anything in it is clicked; that page\n";
  "  // shows the focus (:focus-within).\n";
  "  const keyTarget = standalone ? window : element;\n";
  "  let keysWanted = false;\n";
  "  // The splash screen: what it says, whether it has been shown (or is\n";
  "  // not needed), and while it is shown the element, the commands held\n";
  "  // until it is dismissed, and the clock where it stopped.\n";
  "  let splashText = SPLASH_TEXT;\n";
  "  let splashDone = activated;\n";
  "  let splash = null;\n";
  "  let held = null;\n";
  "  let heldClock = 0;\n";
  "  let heldAt = 0;\n";
  "\n";
  "  let focusable = false;    // whether mounting made `element` focusable\n";
  "\n";
  "  function takeFocus(event) {\n";
  "    // A slider keeps the focus for its arrow keys.\n";
  "    if (!event.target.closest(\"input\")) element.focus({ preventScroll: true });\n";
  "  }\n";
  "\n";
  "  if (!standalone) {\n";
  "    focusable = element.tabIndex < 0;\n";
  "    if (focusable) element.tabIndex = 0;\n";
  "    element.addEventListener(\"click\", takeFocus);\n";
  "  }\n";
  "\n";
  "  // The page's clock: the audio clock once sound has started, and until\n";
  "  // then the seconds since the page was mounted. `offset` joins the two,\n";
  "  // so the clock never goes back.\n";
  "  function running() {\n";
  "    return audio !== null && audio.state === \"running\";\n";
  "  }\n";
  "\n";
  "  function clockNow() {\n";
  "    if (held !== null) return heldClock;\n";
  "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n";
  "  }\n";
  "\n";
  "  function report(event) {\n";
  "    if (!closed && held === null) sendEvent({ ...event, t: clockNow(), running: running() });\n";
  "  }\n";
  "\n";
  "  // Whether a sound now would need the splash screen first.\n";
  "  function splashWanted() {\n";
  "    return !splashDone && splashText !== \"\" && !running() && !readerActive();\n";
  "  }\n";
  "\n";
  "  // Shows the splash screen and holds what comes after it: the commands,\n";
  "  // the frames and the clock.\n";
  "  function showSplash() {\n";
  "    splashDone = true;\n";
  "    heldClock = clockNow();\n";
  "    heldAt = now();\n";
  "    held = [];\n";
  "    splash = splashScreen(splashText);\n";
  "    splash.addEventListener(\"click\", dismissSplash);\n";
  "    window.addEventListener(\"keydown\", dismissSplash, true);\n";
  "    document.body.appendChild(splash);\n";
  "  }\n";
  "\n";
  "  // The reader's click or key: the splash screen goes, sound starts, the\n";
  "  // clock goes on from where it stopped, and what was held is carried out.\n";
  "  function dismissSplash(event) {\n";
  "    if (held === null) return;\n";
  "    event?.preventDefault?.();\n";
  "    event?.stopImmediatePropagation?.();\n";
  "    window.removeEventListener(\"keydown\", dismissSplash, true);\n";
  "    splash.remove();\n";
  "    splash = null;\n";
  "    start += now() - heldAt;\n";
  "    const pending = held;\n";
  "    held = null;\n";
  "    startAudio();\n";
  "    for (const command of pending) carryOut(command);\n";
  "  }\n";
  "\n";
  "  // Sound may start only after the reader did something, so every\n";
  "  // gesture is a chance to start it.\n";
  "  function startAudio() {\n";
  "    if (audio === null) {\n";
  "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n";
  "      if (!Context) return;\n";
  "      const before = clockNow();\n";
  "      audio = new Context();\n";
  "      offset = before - audio.currentTime;\n";
  "      audio.onstatechange = () => {\n";
  "        if (audio.state === \"running\") offset = (now() - start) / 1000 - audio.currentTime;\n";
  "      };\n";
  "    }\n";
  "    if (audio.state === \"suspended\") audio.resume();\n";
  "  }\n";
  "\n";
  "  box.addEventListener(\"pointerdown\", startAudio);\n";
  "\n";
  "  function onKey(event) {\n";
  "    if (held !== null) {\n";
  "      dismissSplash(event);\n";
  "      return;\n";
  "    }\n";
  "    startAudio();\n";
  "    if (!keysWanted || typedInField(event)) return;\n";
  "    // Arrows and the space bar move the program's world, not the page.\n";
  "    if (standalone && [\"ArrowUp\", \"ArrowDown\", \"ArrowLeft\", \"ArrowRight\", \" \"].includes(event.key)) {\n";
  "      event.preventDefault?.();\n";
  "    }\n";
  "    heldKeys.add(event.key);\n";
  "    report({ ev: \"key\", key: event.key });\n";
  "  }\n";
  "  keyTarget.addEventListener(\"keydown\", onKey);\n";
  "\n";
  "  function onKeyUp(event) {\n";
  "    if (!keysWanted) return;\n";
  "    if (heldKeys.delete(event.key)) report({ ev: \"key_up\", key: event.key });\n";
  "  }\n";
  "  keyTarget.addEventListener(\"keyup\", onKeyUp);\n";
  "\n";
  "  // A key released while the page did not have the focus is never\n";
  "  // reported, so leaving the page lets go of every key.\n";
  "  function onBlur() {\n";
  "    for (const key of heldKeys) report({ ev: \"key_up\", key });\n";
  "    heldKeys.clear();\n";
  "  }\n";
  "  window.addEventListener(\"blur\", onBlur);\n";
  "\n";
  "  function loadSample(name) {\n";
  "    const decoder = new OfflineAudioContext(1, 1, 44100);\n";
  "    const fetchArray = (url) =>\n";
  "      fetch(url).then((response) => {\n";
  "        if (!response.ok) throw new Error(`${name}: ${response.status}`);\n";
  "        return response.arrayBuffer();\n";
  "      });\n";
  "    return fetchArray(new URL(name, document.baseURI))\n";
  "      .catch(() => fetchArray(new URL(\"tinyweb_assets/\" + name, import.meta.url)))\n";
  "      .then((bytes) => decoder.decodeAudioData(bytes))\n";
  "      .catch((error) => {\n";
  "        console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);\n";
  "        return null;\n";
  "      });\n";
  "  }\n";
  "\n";
  "  function play({ sample, at, volume, rate }) {\n";
  "    startAudio();\n";
  "    const loading = samples.get(sample);\n";
  "    if (!loading || audio === null) return;\n";
  "    loading.then((buffer) => {\n";
  "      if (buffer === null || closed) return;\n";
  "      const source = audio.createBufferSource();\n";
  "      source.buffer = buffer;\n";
  "      source.playbackRate.value = rate;\n";
  "      const gain = audio.createGain();\n";
  "      gain.gain.value = volume;\n";
  "      source.connect(gain).connect(audio.destination);\n";
  "      source.start(Math.max(audio.currentTime, at - offset));\n";
  "    });\n";
  "  }\n";
  "\n";
  "  function frame() {\n";
  "    if (closed) return;\n";
  "    if (!frameWaiting && held === null) {\n";
  "      frameWaiting = true;\n";
  "      report({ ev: \"frame\" });\n";
  "    }\n";
  "    frameRequest = requestAnimationFrame(frame);\n";
  "  }\n";
  "\n";
  "  function newCanvas({ id, width, height }) {\n";
  "    const element = document.createElement(\"canvas\");\n";
  "    element.setAttribute(\"data-tinyweb-id\", String(id));\n";
  "    const ratio = globalThis.devicePixelRatio || 1;\n";
  "    element.width = Math.round(width * ratio);\n";
  "    element.height = Math.round(height * ratio);\n";
  "    element.style.width = width + \"px\";\n";
  "    element.style.height = height + \"px\";\n";
  "    element.style.background = \"#ffffff\";\n";
  "    const context = element.getContext(\"2d\");\n";
  "    context.scale(ratio, ratio);\n";
  "    plainLines(context);\n";
  "    const entry = {\n";
  "      element, context, width, height, mouse: false, pointer: false, ratio, depth: 0,\n";
  "      gradients: new Map(),\n";
  "    };\n";
  "    canvases.set(id, entry);\n";
  "    remember(look, id, element);\n";
  "    const where = (event) => {\n";
  "      const bounds = element.getBoundingClientRect();\n";
  "      return {\n";
  "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n";
  "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n";
  "      };\n";
  "    };\n";
  "    element.addEventListener(\"click\", (event) => {\n";
  "      if (entry.mouse) report({ ev: \"mouse\", c: id, ...where(event) });\n";
  "    });\n";
  "    // A browser reports a move at most once a frame already.\n";
  "    element.addEventListener(\"pointerdown\", (event) => {\n";
  "      if (!entry.pointer) return;\n";
  "      capture(element, event);\n";
  "      startAudio();\n";
  "      report({ ev: \"press\", c: id, ...where(event) });\n";
  "    });\n";
  "    element.addEventListener(\"pointerup\", (event) => {\n";
  "      if (entry.pointer) report({ ev: \"release\", c: id, ...where(event) });\n";
  "    });\n";
  "    element.addEventListener(\"pointermove\", (event) => {\n";
  "      if (entry.pointer) report({ ev: \"move\", c: id, ...where(event) });\n";
  "    });\n";
  "    element.addEventListener(\"contextmenu\", (event) => {\n";
  "      if (entry.pointer) event.preventDefault?.();\n";
  "    });\n";
  "    element.style.touchAction = \"none\";\n";
  "    parent.appendChild(element);\n";
  "  }\n";
  "\n";
  "  function draw(c, paint) {\n";
  "    const entry = canvases.get(c);\n";
  "    if (entry) paint(entry.context, entry);\n";
  "  }\n";
  "\n";
  "  function carryOut(command) {\n";
  "    switch (command.op) {\n";
  "      case \"canvas\":\n";
  "        newCanvas(command);\n";
  "        break;\n";
  "      case \"clear\":\n";
  "        draw(command.c, (g, entry) => {\n";
  "          freshState(g, entry);\n";
  "          g.fillStyle = paint(g, entry, command.color);\n";
  "          g.fillRect(0, 0, entry.width, entry.height);\n";
  "        });\n";
  "        break;\n";
  "      case \"shape\":\n";
  "        draw(command.c, (g, entry) => drawShape(g, entry, command.kind, command.numbers,\n";
  "          command.color, command.outline, command.width, command.alpha));\n";
  "        break;\n";
  "      case \"text\":\n";
  "        draw(command.c, (g, entry) => drawText(g, entry, command.x, command.y, command.words,\n";
  "          command.color, command.size, command.font, command.align, command.baseline,\n";
  "          command.bold, command.outline, command.outline_width, command.alpha));\n";
  "        break;\n";
  "      case \"measure\": {\n";
  "        // Answered once the code that asked has finished, as any event is.\n";
  "        const width = textWidth(command.words, command.size, command.font, command.bold);\n";
  "        queueMicrotask(() => report({ ev: \"measured\", id: command.id, width }));\n";
  "        break;\n";
  "      }\n";
  "      case \"bitmap\": {\n";
  "        let surface = bitmaps.get(command.id);\n";
  "        if (!surface || surface.width !== command.width || surface.height !== command.height) {\n";
  "          surface = bitmapSurface(command.width, command.height);\n";
  "          bitmaps.set(command.id, surface);\n";
  "        }\n";
  "        const [rx, ry, rw, rh] = command.rect;\n";
  "        updateSurface(surface, rx, ry, rw, rh, command.data);\n";
  "        draw(command.c, (g) => drawSurface(g, surface, command.x, command.y, command.scale));\n";
  "        break;\n";
  "      }\n";
  "      case \"state\":\n";
  "        draw(command.c, (g, entry) => canvasState(g, entry, command.kind, command.value,\n";
  "          command.numbers));\n";
  "        break;\n";
  "      case \"image_load\":\n";
  "        pictures.set(command.id, loadPicture(command.name, import.meta.url));\n";
  "        break;\n";
  "      case \"image\":\n";
  "        draw(command.c, (g) => drawPicture(g, pictures.get(command.picture), command.x,\n";
  "          command.y, command.width, command.height, command.alpha));\n";
  "        break;\n";
  "      case \"checkbox\": {\n";
  "        const { row, input } = choiceRow(\"checkbox\", command.id, command.title, command.checked);\n";
  "        input.addEventListener(\"change\", () => {\n";
  "          startAudio();\n";
  "          report({ ev: \"check\", id: command.id, checked: input.checked });\n";
  "        });\n";
  "        checks.set(command.id, (on) => { input.checked = on; });\n";
  "        remember(look, command.id, input);\n";
  "        parent.appendChild(row);\n";
  "        break;\n";
  "      }\n";
  "      case \"radio\": {\n";
  "        const members = groups.get(command.group) || [];\n";
  "        groups.set(command.group, members);\n";
  "        const first = members.length === 0;\n";
  "        const { row, input } = choiceRow(\"radio\", command.id, command.title,\n";
  "          command.chosen || first);\n";
  "        input.name = `${look.name}:${command.group}`;\n";
  "        const choose = () => {\n";
  "          for (const other of members) other.checked = other === input;\n";
  "        };\n";
  "        if (command.chosen) choose();\n";
  "        members.push(input);\n";
  "        input.addEventListener(\"change\", () => {\n";
  "          startAudio();\n";
  "          choose();\n";
  "          report({ ev: \"pick\", id: command.id });\n";
  "        });\n";
  "        checks.set(command.id, (on) => {\n";
  "          if (on) choose();\n";
  "          else input.checked = false;\n";
  "        });\n";
  "        remember(look, command.id, input);\n";
  "        parent.appendChild(row);\n";
  "        break;\n";
  "      }\n";
  "      case \"choice\": {\n";
  "        const select = choiceElement(command.id, command.options, command.chosen);\n";
  "        select.addEventListener(\"change\", () => {\n";
  "          startAudio();\n";
  "          report({ ev: \"choose\", id: command.id, value: Number(select.value) });\n";
  "        });\n";
  "        values.set(command.id, (value) => { select.value = String(value); });\n";
  "        remember(look, command.id, select);\n";
  "        parent.appendChild(select);\n";
  "        break;\n";
  "      }\n";
  "      case \"text_input\": {\n";
  "        const input = textInputElement(command.id, command.placeholder);\n";
  "        input.addEventListener(\"keydown\", (event) => {\n";
  "          if (event.key === \"Enter\") {\n";
  "            startAudio();\n";
  "            report({ ev: \"enter\", id: command.id, text: input.value });\n";
  "          }\n";
  "        });\n";
  "        remember(look, command.id, input);\n";
  "        parent.appendChild(input);\n";
  "        break;\n";
  "      }\n";
  "      case \"number\": {\n";
  "        const input = numberElement(command.id, command.low, command.high, command.value);\n";
  "        input.addEventListener(\"change\", () => {\n";
  "          startAudio();\n";
  "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n";
  "        });\n";
  "        values.set(command.id, (value) => { input.value = String(value); });\n";
  "        remember(look, command.id, input);\n";
  "        parent.appendChild(input);\n";
  "        break;\n";
  "      }\n";
  "      case \"set_checked\":\n";
  "        if (checks.has(command.id)) checks.get(command.id)(command.checked);\n";
  "        break;\n";
  "      case \"set_value\":\n";
  "        if (values.has(command.id)) values.get(command.id)(command.value);\n";
  "        break;\n";
  "      case \"button\": {\n";
  "        const button = document.createElement(\"button\");\n";
  "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n";
  "        button.textContent = command.title;\n";
  "        button.addEventListener(\"click\", () => {\n";
  "          startAudio();\n";
  "          report({ ev: \"click\", id: command.id });\n";
  "        });\n";
  "        remember(look, command.id, button);\n";
  "        parent.appendChild(button);\n";
  "        break;\n";
  "      }\n";
  "      case \"label\": {\n";
  "        const text = document.createElement(\"div\");\n";
  "        text.className = \"tinyweb-label\";\n";
  "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n";
  "        text.textContent = command.text;\n";
  "        labels.set(command.id, text);\n";
  "        remember(look, command.id, text);\n";
  "        parent.appendChild(text);\n";
  "        break;\n";
  "      }\n";
  "      case \"row\":\n";
  "      case \"column\": {\n";
  "        const row = rowElement(command.id, command.op === \"row\");\n";
  "        rows.set(command.id, row);\n";
  "        remember(look, command.id, row);\n";
  "        parent.appendChild(row);\n";
  "        break;\n";
  "      }\n";
  "      case \"inside\":\n";
  "        parent = rows.get(command.id) || box;\n";
  "        break;\n";
  "      case \"outside\":\n";
  "        parent = box;\n";
  "        break;\n";
  "      case \"set_label\":\n";
  "        // A label's text, or a button's title.\n";
  "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n";
  "        else if (look.elements.get(command.id)?.tagName === \"BUTTON\") {\n";
  "          look.elements.get(command.id).textContent = command.text;\n";
  "        }\n";
  "        break;\n";
  "      case \"slider\": {\n";
  "        const row = document.createElement(\"label\");\n";
  "        row.className = \"tinyweb-slider\";\n";
  "        row.style.cssText = \"display:flex;align-items:center;gap:8px\";\n";
  "        const input = document.createElement(\"input\");\n";
  "        input.type = \"range\";\n";
  "        input.setAttribute(\"data-tinyweb-id\", String(command.id));\n";
  "        input.min = String(command.low);\n";
  "        input.max = String(command.high);\n";
  "        input.value = String(command.value);\n";
  "        const shown = document.createElement(\"span\");\n";
  "        shown.textContent = input.value;\n";
  "        input.addEventListener(\"input\", () => {\n";
  "          shown.textContent = input.value;\n";
  "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n";
  "        });\n";
  "        row.append(input, shown);\n";
  "        values.set(command.id, (value) => {\n";
  "          input.value = String(value);\n";
  "          shown.textContent = input.value;\n";
  "        });\n";
  "        remember(look, command.id, input);\n";
  "        parent.appendChild(row);\n";
  "        break;\n";
  "      }\n";
  "      case \"style\":\n";
  "        applyStyle(look, command.id, command.kind, command.prop, command.value);\n";
  "        break;\n";
  "      case \"load\":\n";
  "        samples.set(command.id, loadSample(command.name));\n";
  "        break;\n";
  "      case \"play\":\n";
  "        if (splashWanted()) {\n";
  "          showSplash();\n";
  "          held.push(command);\n";
  "        } else {\n";
  "          play(command);\n";
  "        }\n";
  "        break;\n";
  "      case \"splash\":\n";
  "        if (splashWanted()) showSplash();\n";
  "        break;\n";
  "      case \"splash_text\":\n";
  "        splashText = command.text;\n";
  "        break;\n";
  "      case \"on_frame\":\n";
  "        if (!frameWanted) {\n";
  "          frameWanted = true;\n";
  "          frameRequest = requestAnimationFrame(frame);\n";
  "        }\n";
  "        break;\n";
  "      case \"frame_done\":\n";
  "        frameWaiting = false;\n";
  "        break;\n";
  "      case \"on_mouse\": {\n";
  "        const entry = canvases.get(command.c);\n";
  "        if (entry) entry.mouse = true;\n";
  "        break;\n";
  "      }\n";
  "      case \"on_pointer\": {\n";
  "        const entry = canvases.get(command.c);\n";
  "        if (entry) entry.pointer = true;\n";
  "        break;\n";
  "      }\n";
  "      case \"on_key\":\n";
  "        keysWanted = true;\n";
  "        // Inside another page the keys go where the focus is, which is\n";
  "        // still the Run button that started the program; one typing in\n";
  "        // an editor keeps it.\n";
  "        if (!standalone && !typing()) element.focus({ preventScroll: true });\n";
  "        break;\n";
  "    }\n";
  "  }\n";
  "\n";
  "  function typing() {\n";
  "    const active = document.activeElement;\n";
  "    return !!active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));\n";
  "  }\n";
  "\n";
  "  function freeze() {\n";
  "    if (closed) return;\n";
  "    closed = true;\n";
  "    cancelAnimationFrame(frameRequest);\n";
  "    if (splash !== null) {\n";
  "      window.removeEventListener(\"keydown\", dismissSplash, true);\n";
  "      splash.remove();\n";
  "    }\n";
  "    keyTarget.removeEventListener(\"keydown\", onKey);\n";
  "    keyTarget.removeEventListener(\"keyup\", onKeyUp);\n";
  "    window.removeEventListener(\"blur\", onBlur);\n";
  "    if (!standalone) element.removeEventListener(\"click\", takeFocus);\n";
  "    if (audio !== null) audio.close();\n";
  "  }\n";
  "\n";
  "  return {\n";
  "    receive(commands) {\n";
  "      if (closed) return;\n";
  "      for (const command of commands) {\n";
  "        if (held !== null) held.push(command);\n";
  "        else carryOut(command);\n";
  "      }\n";
  "    },\n";
  "    // Stops: no more events, frames or sound, and what is shown stays.\n";
  "    freeze,\n";
  "    close() {\n";
  "      freeze();\n";
  "      box.remove();\n";
  "      unstyled(look);\n";
  "      if (focusable) {\n";
  "        element.removeAttribute(\"tabindex\");\n";
  "        element.blur();\n";
  "      }\n";
  "    },\n";
  "  };\n";
  "}\n";
]
(* END tinyweb page *)

(* Ends the program with `message`: with status 1 in a compiled
   program, and as a runtime error under the interpreter, which in the
   REPL leaves the session running. *)
let refuse message =
  if !hosted then failwith message
  else (
    Stdlib.flush Stdlib.stdout;
    prerr_endline message;
    Stdlib.exit 1)

(* --- commands --- *)

type value = I of int | F of float | S of string | B of bool | L of int list | FL of float list

(* {op, fields}: what the page is told, in the order its fields are
   written. *)
type command = { op : string; fields : (string * value) list }

(* A string as JSON writes it, which is also how a log line quotes one. *)
let quote text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    text;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let rec json_of_value v =
  match v with
  | I n -> string_of_int n
  | F x ->
      let text = Printf.sprintf "%.17g" x in
      if Float.is_integer x && not (String.contains text 'e') then text ^ ".0" else text
  | S s -> quote s
  | B b -> string_of_bool b
  | L ns -> "[" ^ String.concat "," (List.map string_of_int ns) ^ "]"
  | FL xs -> "[" ^ String.concat "," (List.map (fun x -> json_of_value (F x)) xs) ^ "]"

let json_of_command command =
  "{"
  ^ String.concat ","
      ((quote "op" ^ ":" ^ quote command.op)
      :: List.map (fun (k, v) -> quote k ^ ":" ^ json_of_value v) command.fields)
  ^ "}"

let field command name =
  match List.assoc_opt name command.fields with
  | Some (I n) -> string_of_int n
  | Some (F x) -> Printf.sprintf "%.3f" x
  | Some (S s) -> s
  | Some (B b) -> string_of_bool b
  | Some (L ns) -> String.concat " " (List.map string_of_int ns)
  | Some (FL xs) -> String.concat " " (List.map (Printf.sprintf "%.3f") xs)
  | None -> ""

let quoted command name =
  match List.assoc_opt name command.fields with
  | Some (S s) -> quote s
  | Some (I _) | Some (F _) | Some (B _) | Some (L _) | Some (FL _) | None -> "\"\""

(* A command as the one line every headless implementation writes: each
   identifier quoted, and an element's text after it only where the two
   differ. *)
let log_line command =
  let f = field command in
  let q = quoted command in
  let named id text = if f id = f text then [ q id ] else [ q id; q text ] in
  let words =
    match command.op with
    | "canvas" -> [ "canvas"; q "id"; f "width"; f "height" ]
    | "clear" -> [ "clear"; q "c"; f "color" ]
    | "shape" -> [ f "kind"; q "c"; f "numbers"; q "color"; q "outline"; f "width"; f "alpha" ]
    | "text" ->
        [ "text"; q "c"; f "x"; f "y"; q "color"; f "size"; q "font"; f "align"; f "baseline";
          f "bold"; q "outline"; f "outline_width"; f "alpha"; q "words" ]
    | "measure" -> [ "measure"; q "id"; f "size"; q "font"; f "bold"; q "words" ]
    | "on_pointer" -> [ "on_pointer"; q "c" ]
    | ("row" | "column" | "inside") as op -> [ op; q "id" ]
    | "bitmap" ->
        [ "bitmap"; q "c"; q "id"; f "x"; f "y"; f "scale"; f "width"; f "height"; f "rect";
          f "digest" ]
    | "state" ->
        [ f "kind"; q "c" ]
        @ (if f "value" = "" then [] else [ q "value" ])
        @ if f "numbers" = "" then [] else [ f "numbers" ]
    | "image_load" -> "load_image" :: named "id" "name"
    | "image" ->
        [ "image"; q "c"; q "picture"; f "x"; f "y"; f "width"; f "height"; f "alpha" ]
    | "button" -> "button" :: named "id" "title"
    | "label" -> "label" :: named "id" "text"
    | "set_label" -> [ "set_label"; q "id"; q "text" ]
    | "slider" -> [ "slider"; q "id"; f "low"; f "high"; f "value" ]
    | "checkbox" -> ("checkbox" :: named "id" "title") @ [ f "checked" ]
    | "radio" -> ("radio" :: named "id" "title") @ [ q "group"; f "chosen" ]
    | "choice" -> [ "choice"; q "id"; f "chosen"; q "options" ]
    | "text_input" -> "text_input" :: named "id" "placeholder"
    | "number" -> [ "number"; q "id"; f "low"; f "high"; f "value" ]
    | "set_checked" -> [ "set_checked"; q "id"; f "checked" ]
    | "set_value" -> [ "set_value"; q "id"; f "value" ]
    | "load" -> "load" :: named "id" "name"
    | "play" -> [ "play"; q "sample"; f "at"; f "volume"; f "rate" ]
    | "on_mouse" -> [ "on_mouse"; q "c" ]
    | "style" -> [ "style"; q "id"; f "kind"; f "prop"; q "value" ]
    | "splash_text" -> [ "splash_text"; q "text" ]
    | op -> [ op ]
  in
  String.concat " " words

(* Whether the log is printed on standard error too, as the page runs:
   what `pyk --tinyweb-log` asks for. *)
let trace = Stdlib.Sys.getenv_opt "PYKING_TINYWEB_TRACE" <> None

(* An event as the line an events file holds for it. *)
let event_line event =
  let text name = Option.value ~default:"" (List.assoc_opt name event) in
  match List.assoc_opt "ev" event with
  | Some "click" -> "click " ^ quote (text "id")
  | Some "slide" -> "slide " ^ quote (text "id") ^ " " ^ text "value"
  | Some "check" -> "check " ^ quote (text "id") ^ " " ^ text "checked"
  | Some "pick" -> "pick " ^ quote (text "id")
  | Some "choose" -> "choose " ^ quote (text "id") ^ " " ^ text "value"
  | Some "enter" -> "enter " ^ quote (text "id") ^ " " ^ quote (text "text")
  | Some "frame" -> (
      match float_of_string_opt (text "t") with
      | Some t -> Printf.sprintf "frame %.3f" t
      | None -> "frame " ^ text "t")
  | Some "mouse" -> "mouse " ^ quote (text "c") ^ " " ^ text "x" ^ " " ^ text "y"
  | Some "key" -> "key " ^ text "key"
  | Some "key_up" -> "key_up " ^ text "key"
  | Some (("press" | "release" | "move") as kind) ->
      kind ^ " " ^ quote (text "c") ^ " " ^ text "x" ^ " " ^ text "y"
  | Some "measured" -> "measured " ^ quote (text "id") ^ " " ^ text "width"
  | Some other -> other
  | None -> ""

let write_log line =
  match log_file with
  | None -> ()
  | Some path ->
      let channel =
        Stdlib.open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path
      in
      Stdlib.output_string channel (line ^ "\n");
      Stdlib.close_out channel

(* --- the server --- *)

(* One page connected to /commands. *)
type client = { socket : Unix.file_descr }

let listener : Unix.file_descr option ref = ref None
let clients : client list ref = ref []
let history : command list ref = ref []
let pending : command list ref = ref []
let batching = ref false
let events : (string * string) list Queue.t = Queue.create ()

(* Whether an event has been delivered: until one is, the program is in
   its top level, whose sound a page connecting later still plays. *)
let delivered = ref false

(* The commands a page connecting now has to be sent, once `command` has
   been: everything but sound a callback played and frame bookkeeping,
   less what a later command has made invisible. *)
let kept history command =
  let drawing = [ "clear"; "shape"; "text"; "state"; "image"; "bitmap" ] in
  let same name h = List.assoc_opt name h.fields = List.assoc_opt name command.fields in
  match command.op with
  | "play" when !delivered -> history
  | "frame_done" | "event_done" -> history
  | "clear" ->
      List.filter (fun h -> not (List.mem h.op drawing && same "c" h)) history @ [ command ]
  | ("set_label" | "set_checked" | "set_value") as op ->
      List.filter (fun h -> not (h.op = op && same "id" h)) history @ [ command ]
  | _ -> history @ [ command ]

let write_all socket text =
  let bytes = Bytes.of_string text in
  let rec go offset =
    if offset < Bytes.length bytes then
      go (offset + Unix.write socket bytes offset (Bytes.length bytes - offset))
  in
  go 0

let close_quietly socket = try Unix.close socket with Unix.Unix_error _ -> ()

(* Sends a batch to one page, answering whether it is still there. *)
let send_to client batch =
  let text = "data: [" ^ String.concat "," (List.map json_of_command batch) ^ "]\n\n" in
  try
    write_all client.socket text;
    true
  with Unix.Unix_error _ ->
    close_quietly client.socket;
    false

let send_batch batch = clients := List.filter (fun client -> send_to client batch) !clients

let flush_pending () =
  let batch = !pending in
  pending := [];
  if batch <> [] then send_batch batch

let content_type path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".html" -> "text/html; charset=utf-8"
  | ".js" -> "text/javascript; charset=utf-8"
  | ".css" -> "text/css; charset=utf-8"
  | ".json" -> "application/json"
  | ".wav" -> "audio/wav"
  | ".mp3" -> "audio/mpeg"
  | ".ogg" -> "audio/ogg"
  | ".png" -> "image/png"
  | ".jpg" -> "image/jpeg"
  | ".svg" -> "image/svg+xml"
  | _ -> "application/octet-stream"

let reply socket status kind body =
  let reason = match status with 200 -> "OK" | 204 -> "No Content" | 400 -> "Bad Request" | _ -> "Not Found" in
  (try
     write_all socket
       (Printf.sprintf
          "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s"
          status reason kind (String.length body) body)
   with Unix.Unix_error _ -> ());
  close_quietly socket

let read_file path =
  let channel = open_in_bin path in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  text

(* The file a page asks for by `path`: beside where the program runs,
   and a library sample from tinyweb_assets/ beside the program or the
   library. *)
let static path =
  let parts = List.filter (fun p -> p <> "" && p <> ".") (String.split_on_char '/' path) in
  if parts = [] || List.mem ".." parts then None
  else
    let relative = String.concat Filename.dir_sep parts in
    let places =
      Stdlib.Sys.getcwd ()
      :: (if List.hd parts = "tinyweb_assets" then List.map Filename.dirname !assets else [])
    in
    List.find_map
      (fun place ->
        let candidate = Filename.concat place relative in
        if Stdlib.Sys.file_exists candidate && not (Stdlib.Sys.is_directory candidate) then Some candidate
        else None)
      places

(* --- events, as the page writes them --- *)

(* The JSON string starting just after the opening quote at `i` of
   `text`, decoded, and where it ends. *)
let string_at text i =
  let n = String.length text in
  let buffer = Buffer.create 16 in
  let rec go i =
    if i >= n then (Buffer.contents buffer, i)
    else
      match text.[i] with
      | '"' -> (Buffer.contents buffer, i + 1)
      | '\\' when i + 1 < n -> (
          match text.[i + 1] with
          | 'n' -> Buffer.add_char buffer '\n'; go (i + 2)
          | 't' -> Buffer.add_char buffer '\t'; go (i + 2)
          | 'r' -> Buffer.add_char buffer '\r'; go (i + 2)
          | 'b' -> Buffer.add_char buffer '\b'; go (i + 2)
          | 'f' -> Buffer.add_char buffer '\012'; go (i + 2)
          | 'u' when i + 5 < n ->
              let code = int_of_string ("0x" ^ String.sub text (i + 2) 4) in
              Buffer.add_utf_8_uchar buffer
                (if Uchar.is_valid code then Uchar.of_int code else Uchar.rep);
              go (i + 6)
          | c -> Buffer.add_char buffer c; go (i + 2))
      | c -> Buffer.add_char buffer c; go (i + 1)
  in
  go i

(* The fields of one flat JSON object, each as its text: a string
   decoded, anything else as written. *)
let parse_object text =
  let n = String.length text in
  let rec space i = if i < n && String.contains " \t\r\n" text.[i] then space (i + 1) else i in
  let string_at = string_at text in
  let rec fields i acc =
    let i = space i in
    if i >= n || text.[i] = '}' then List.rev acc
    else if text.[i] = ',' || text.[i] = '{' then fields (i + 1) acc
    else if text.[i] = '"' then
      let key, i = string_at (i + 1) in
      let i = space i in
      let i = if i < n && text.[i] = ':' then space (i + 1) else i in
      if i < n && text.[i] = '"' then
        let value, i = string_at (i + 1) in
        fields i ((key, value) :: acc)
      else
        let stop = ref i in
        while !stop < n && not (String.contains ",} \t\r\n" text.[!stop]) do incr stop done;
        fields !stop ((key, String.sub text i (!stop - i)) :: acc)
    else List.rev acc
  in
  fields 0 []

(* One request on a socket just accepted, read whole: the request line,
   the headers, and the body its Content-Length says. *)
let read_request socket =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let header_end () =
    let text = Buffer.contents buffer in
    let rec find i =
      if i + 3 >= String.length text then None
      else if String.sub text i 4 = "\r\n\r\n" then Some i
      else find (i + 1)
    in
    find 0
  in
  let rec headers () =
    match header_end () with
    | Some at -> Some at
    | None ->
        let got = Unix.read socket chunk 0 (Bytes.length chunk) in
        if got = 0 then None
        else (
          Buffer.add_subbytes buffer chunk 0 got;
          headers ())
  in
  match headers () with
  | None -> None
  | Some at ->
      let text = Buffer.contents buffer in
      let head = String.sub text 0 at in
      let lines = String.split_on_char '\n' head in
      let length =
        List.fold_left
          (fun found line ->
            match String.index_opt line ':' with
            | Some colon
              when String.lowercase_ascii (String.trim (String.sub line 0 colon))
                   = "content-length" ->
                int_of_string_opt
                  (String.trim (String.sub line (colon + 1) (String.length line - colon - 1)))
                |> Option.value ~default:found
            | _ -> found)
          0 lines
      in
      let rec body () =
        if Buffer.length buffer - (at + 4) >= length then
          Buffer.sub buffer (at + 4) length
        else
          let got = Unix.read socket chunk 0 (Bytes.length chunk) in
          if got = 0 then Buffer.sub buffer (at + 4) (Buffer.length buffer - at - 4)
          else (
            Buffer.add_subbytes buffer chunk 0 got;
            body ())
      in
      let request_line = String.trim (List.hd lines) in
      match String.split_on_char ' ' request_line with
      | meth :: target :: _ ->
          let path = match String.index_opt target '?' with Some q -> String.sub target 0 q | None -> target in
          Some (meth, path, body ())
      | _ -> None

let serve socket =
  match (try read_request socket with Unix.Unix_error _ -> None) with
  | None -> close_quietly socket
  | Some ("GET", ("/" | "/index.html"), _) ->
      reply socket 200 "text/html; charset=utf-8" page_html
  | Some ("GET", "/tinyweb_page.js", _) ->
      reply socket 200 "text/javascript; charset=utf-8" page_js
  | Some ("GET", "/commands", _) -> (
      try
        write_all socket
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n: tinyweb\n\n";
        let client = { socket } in
        if !history = [] || send_to client !history then clients := !clients @ [ client ]
      with Unix.Unix_error _ -> close_quietly socket)
  | Some ("POST", "/events", body) ->
      Queue.add (parse_object body) events;
      (try
         write_all socket
           "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
       with Unix.Unix_error _ -> ());
      close_quietly socket
  | Some ("GET", path, _) -> (
      match static path with
      | Some found -> reply socket 200 (content_type found) (read_file found)
      | None -> reply socket 404 "text/plain" "not found\n")
  | Some _ -> reply socket 404 "text/plain" "not found\n"

(* Answers whatever is waiting on the server's sockets, waiting up to
   `timeout` seconds (forever where negative) for something to. *)
let poll timeout =
  match !listener with
  | None -> ()
  | Some server -> (
      let watched = server :: List.map (fun c -> c.socket) !clients in
      match Unix.select watched [] [] timeout with
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
      | ready, _, _ ->
          List.iter
            (fun socket ->
              if socket == server then (
                match Unix.accept ~cloexec:true server with
                | client, _ ->
                    Unix.setsockopt_float client Unix.SO_RCVTIMEO 5.0;
                    serve client
                | exception Unix.Unix_error _ -> ())
              else
                (* A page's stream has nothing to say: readable means it
                   has gone. *)
                let gone =
                  try Unix.read socket (Bytes.create 64) 0 64 = 0
                  with Unix.Unix_error _ -> true
                in
                if gone then (
                  close_quietly socket;
                  clients := List.filter (fun c -> c.socket != socket) !clients))
            ready)

(* --- the program's side --- *)

let names : string list ref = ref []
let clock = ref 0.0
let buttons : (string * (unit -> unit)) list ref = ref []
let sliders : (string * (int -> unit)) list ref = ref []
let checks : (string * (bool -> unit)) list ref = ref []
let radios : (string * (unit -> unit)) list ref = ref []
let choices : (string * (int -> unit)) list ref = ref []
let texts : (string * (string -> unit)) list ref = ref []
let frames : (float -> unit) list ref = ref []
let mice : (string * (int -> int -> unit)) list ref = ref []
let keys : (string -> unit) list ref = ref []
let key_ups : (string -> unit) list ref = ref []

(* The keys held down now, from the key events delivered so far. *)
let down : string list ref = ref []
let keys_on = ref false

(* A canvas's pointer: the functions watching it, by kind, and where it
   was last seen. *)
type watched = {
  mutable watchers : (string * (int -> int -> unit)) list;
  mutable x : int;
  mutable y : int;
  mutable held : bool;
}

let pointers : (string * watched) list ref = ref []
let measures : (string * (float -> unit)) list ref = ref []
let after_registered = ref false
let running_after = ref false

let rec after_program () =
  if not !running_after then (
    running_after := true;
    match log_file with
    | Some _ -> deliver_file ()
    | None ->
        if !listener <> None then (
          batching := true;
          while true do
            poll (-1.0);
            deliver_queued ()
          done))

(* Every event the page has posted, in order, each followed by
   `event_done`. *)
and deliver_queued () =
  while not (Queue.is_empty events) do
    deliver (Queue.pop events);
    send { op = "event_done"; fields = [] };
    flush_pending ();
    Stdlib.flush Stdlib.stdout
  done

and deliver event =
  delivered := true;
  if trace then prerr_endline ("> " ^ event_line event);
  let text name = Option.value ~default:"" (List.assoc_opt name event) in
  let number name = Option.bind (List.assoc_opt name event) float_of_string_opt in
  let int name = Option.value ~default:0 (Option.map int_of_float (number name)) in
  (match number "t" with Some t -> clock := t | None -> ());
  let each table id f = List.iter (fun (key, g) -> if key = id then f g) table in
  match List.assoc_opt "ev" event with
  | Some "click" -> each !buttons (text "id") (fun f -> f ())
  | Some "slide" -> each !sliders (text "id") (fun f -> f (int "value"))
  | Some "check" -> each !checks (text "id") (fun f -> f (text "checked" = "true"))
  | Some "pick" -> each !radios (text "id") (fun f -> f ())
  | Some "choose" -> each !choices (text "id") (fun f -> f (int "value"))
  | Some "enter" -> each !texts (text "id") (fun f -> f (text "text"))
  | Some "frame" ->
      List.iter (fun f -> f !clock) !frames;
      send { op = "frame_done"; fields = [] }
  | Some "mouse" -> each !mice (text "c") (fun f -> f (int "x") (int "y"))
  | Some "key" ->
      let key = Option.value ~default:"" (List.assoc_opt "key" event) in
      if not (List.mem key !down) then down := key :: !down;
      List.iter (fun f -> f key) !keys
  | Some "key_up" ->
      let key = Option.value ~default:"" (List.assoc_opt "key" event) in
      down := List.filter (fun k -> k <> key) !down;
      List.iter (fun f -> f key) !key_ups
  | Some (("press" | "release" | "move") as kind) -> (
      match List.assoc_opt (text "c") !pointers with
      | None -> ()
      | Some seen ->
          seen.x <- int "x";
          seen.y <- int "y";
          if kind = "press" then seen.held <- true;
          if kind = "release" then seen.held <- false;
          let kinds = if kind = "move" && seen.held then [ "move"; "drag" ] else [ kind ] in
          List.iter
            (fun k ->
              List.iter (fun (w, f) -> if w = k then f seen.x seen.y) seen.watchers)
            kinds)
  | Some "measured" -> (
      let id = text "id" in
      match List.assoc_opt id !measures with
      | None -> ()
      | Some answer ->
          measures := List.remove_assoc id !measures;
          answer (Option.value ~default:0.0 (number "width")))
  | _ -> ()

(* The events file, once the top level has ended: each line logged as
   it is delivered. *)
and deliver_file () =
  match events_file with
  | Some path when Stdlib.Sys.file_exists path ->
      let lines = String.split_on_char '\n' (read_file path) in
      List.iter
        (fun line ->
          if String.trim line <> "" then (
            write_log ("> " ^ line);
            let event =
              if String.length line > 4 && String.sub line 0 4 = "key " then
                Some [ ("ev", "key"); ("key", String.sub line 4 (String.length line - 4)) ]
              else if String.length line > 7 && String.sub line 0 7 = "key_up " then
                Some [ ("ev", "key_up"); ("key", String.sub line 7 (String.length line - 7)) ]
              else event_of_line (String.trim line)
            in
            match event with
            | Some event -> deliver event
            | None -> write_log ("! unknown event: " ^ line)))
        lines
  | _ -> ()

(* One line of an events file other than a key, as the event the page
   would send: a frame's time, or the element it is on as a quoted string
   and the numbers after it. *)
and event_of_line line =
  let words s = List.filter (fun w -> w <> "") (String.split_on_char ' ' s) in
  match String.index_opt line ' ' with
  | None -> None
  | Some space -> (
      let kind = String.sub line 0 space in
      let after = String.trim (String.sub line space (String.length line - space)) in
      if kind = "frame" then
        match words after with [ t ] -> Some [ ("ev", "frame"); ("t", t) ] | _ -> None
      else if after = "" || after.[0] <> '"' then None
      else
        let id, stop = string_at after 1 in
        let tail = String.trim (String.sub after stop (String.length after - stop)) in
        let rest = words tail in
        match (kind, rest) with
        | "enter", _ ->
            if tail = "" || tail.[0] <> '"' then None
            else
              let typed, stop = string_at tail 1 in
              if String.trim (String.sub tail stop (String.length tail - stop)) = "" then
                Some [ ("ev", "enter"); ("id", id); ("text", typed) ]
              else None
        | "check", [ ("true" | "false") as on ] ->
            Some [ ("ev", "check"); ("id", id); ("checked", on) ]
        | "pick", [] -> Some [ ("ev", "pick"); ("id", id) ]
        | "choose", [ value ] -> Some [ ("ev", "choose"); ("id", id); ("value", value) ]
        | "click", [] -> Some [ ("ev", "click"); ("id", id) ]
        | "slide", [ value ] -> Some [ ("ev", "slide"); ("id", id); ("value", value) ]
        | (("mouse" | "press" | "release" | "move") as kind), [ x; y ] ->
            Some [ ("ev", kind); ("c", id); ("x", x); ("y", y) ]
        | "measured", [ width ] -> Some [ ("ev", "measured"); ("id", id); ("width", width) ]
        | _ -> None)

(* Says what every function but `web_init` needs first: a log to write
   to, or a page served. *)
and ready () =
  match log_file with
  | Some _ ->
      if not (!hosted || !after_registered) then (
        after_registered := true;
        at_exit after_program)
  | None ->
      if !listener = None then
        refuse
          "tinyweb: call tinyweb.web_init(port) before anything else, or set \
           PYKING_TINYWEB_LOG"

and send command =
  ready ();
  if trace && command.op <> "frame_done" && command.op <> "event_done" then
    prerr_endline (log_line command);
  match log_file with
  | Some _ -> if command.op <> "frame_done" && command.op <> "event_done" then write_log (log_line command)
  | None ->
      history := kept !history command;
      pending := !pending @ [ command ];
      if not !batching then flush_pending ()


(* --- the functions tinyweb_external.pyk declares --- *)

let web_start port =
  if log_file = None && !listener = None then (
    if port < 0 || port > 65535 then
      refuse
        (Printf.sprintf
           "tinyweb: cannot serve the page on port %d: a port is a number from 0 to 65535"
           port);
    Stdlib.Sys.set_signal Stdlib.Sys.sigpipe Stdlib.Sys.Signal_ignore;
    let server = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt server Unix.SO_REUSEADDR true;
    (try Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, port))
     with Unix.Unix_error (error, _, _) ->
       close_quietly server;
       refuse
         (Printf.sprintf "tinyweb: cannot serve the page on port %d: %s" port
            (Unix.error_message error)));
    Unix.listen server 16;
    listener := Some server;
    let bound =
      match Unix.getsockname server with
      | Unix.ADDR_INET (_, p) -> p
      | Unix.ADDR_UNIX _ -> port
    in
    print_string (Printf.sprintf "tinyweb: http://127.0.0.1:%d/\n" bound);
    Stdlib.flush Stdlib.stdout;
    if not !hosted then at_exit after_program)

(* A new element's identifier: `name`, or `name` with the first number
   from 1 that makes it one nothing on the page has. *)
let fresh name =
  let rec pick n =
    let found = if n = 0 then name else name ^ string_of_int n in
    if List.mem found !names then pick (n + 1) else found
  in
  let found = pick 0 in
  names := found :: !names;
  found

let canvas width height =
  ready ();
  let id = fresh "canvas" in
  send { op = "canvas"; fields = [ ("id", S id); ("width", I width); ("height", I height) ] };
  id

let fill_canvas c color = send { op = "clear"; fields = [ ("c", S c); ("color", S color) ] }

let draw_shape c kind numbers color outline width alpha =
  send
    {
      op = "shape";
      fields =
        [ ("c", S c); ("kind", S kind); ("numbers", S numbers); ("color", S color);
          ("outline", S outline); ("width", F width); ("alpha", F alpha) ];
    }

let draw_floats c kind numbers color outline width alpha =
  send
    {
      op = "shape";
      fields =
        [ ("c", S c); ("kind", S kind); ("numbers", FL numbers); ("color", S color);
          ("outline", S outline); ("width", F width); ("alpha", F alpha) ];
    }

let draw_pairs c kind items =
  draw_floats c kind (List.concat_map (fun (x, y) -> [ x; y ]) items)

let draw_triples c kind items =
  draw_floats c kind (List.concat_map (fun (x, y, r) -> [ x; y; r ]) items)

let draw_quads c kind items =
  draw_floats c kind (List.concat_map (fun (a, b, c, d) -> [ a; b; c; d ]) items)

let draw_text c x y words color size font align baseline bold outline outline_width alpha =
  send
    {
      op = "text";
      fields =
        [ ("c", S c); ("x", F x); ("y", F y); ("words", S words); ("color", S color);
          ("size", I size); ("font", S font); ("align", S align); ("baseline", S baseline);
          ("bold", B bold); ("outline", S outline); ("outline_width", F outline_width);
          ("alpha", F alpha) ];
    }

let measure words size font bold answer =
  ready ();
  let id = fresh "measure" in
  measures := !measures @ [ (id, answer) ];
  send
    {
      op = "measure";
      fields =
        [ ("id", S id); ("words", S words); ("size", I size); ("font", S font); ("bold", B bold) ];
    }

let watch_pointer c kind f =
  ready ();
  let seen =
    match List.assoc_opt c !pointers with
    | Some seen -> seen
    | None ->
        let seen = { watchers = []; x = 0; y = 0; held = false } in
        pointers := !pointers @ [ (c, seen) ];
        send { op = "on_pointer"; fields = [ ("c", S c) ] };
        seen
  in
  if List.mem kind [ "press"; "release"; "move"; "drag" ] then
    seen.watchers <- seen.watchers @ [ (kind, f) ]

let pointer c which =
  ready ();
  match List.assoc_opt c !pointers with
  | None -> 0
  | Some seen -> (
      match which with "x" -> seen.x | "y" -> seen.y | _ -> if seen.held then 1 else 0)

(* --- bitmaps --- *)

(* A bitmap's pixels, four bytes each, and the rectangle that changed
   since it was last shown. *)
type bitmap = {
  bw : int;
  bh : int;
  data : Bytes.t;
  mutable x1 : int;
  mutable y1 : int;
  mutable x2 : int;
  mutable y2 : int;
}

let bitmaps : (string, bitmap) Hashtbl.t = Hashtbl.create 8

(* FNV-1a, 32 bits, of the bytes: what the log says of a bitmap's
   pixels. *)
let digest data =
  let h = ref 0x811c9dc5 in
  Bytes.iter
    (fun c -> h := ((!h lxor Char.code c) * 16777619) land 0xFFFFFFFF)
    data;
  Printf.sprintf "%08x" !h

let base64 data =
  let table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = Bytes.length data in
  let out = Buffer.create ((n + 2) / 3 * 4) in
  let byte i = if i < n then Char.code (Bytes.get data i) else 0 in
  let i = ref 0 in
  while !i < n do
    let b = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) lor byte (!i + 2) in
    Buffer.add_char out table.[(b lsr 18) land 63];
    Buffer.add_char out table.[(b lsr 12) land 63];
    Buffer.add_char out (if !i + 1 < n then table.[(b lsr 6) land 63] else '=');
    Buffer.add_char out (if !i + 2 < n then table.[b land 63] else '=');
    i := !i + 3
  done;
  Buffer.contents out

let bitmap width height =
  ready ();
  let id = fresh "bitmap" in
  let w = max 1 width and h = max 1 height in
  let data = Bytes.make (w * h * 4) '\000' in
  for i = 0 to (w * h) - 1 do
    Bytes.set data ((i * 4) + 3) '\255'
  done;
  Hashtbl.replace bitmaps id { bw = w; bh = h; data; x1 = 0; y1 = 0; x2 = w; y2 = h };
  id

let set_pixel b x y color =
  match Hashtbl.find_opt bitmaps b with
  | Some bm when x >= 0 && y >= 0 && x < bm.bw && y < bm.bh ->
      let at = ((y * bm.bw) + x) * 4 in
      Bytes.set bm.data at (Char.unsafe_chr ((color lsr 16) land 255));
      Bytes.set bm.data (at + 1) (Char.unsafe_chr ((color lsr 8) land 255));
      Bytes.set bm.data (at + 2) (Char.unsafe_chr (color land 255));
      if x < bm.x1 then bm.x1 <- x;
      if y < bm.y1 then bm.y1 <- y;
      if x >= bm.x2 then bm.x2 <- x + 1;
      if y >= bm.y2 then bm.y2 <- y + 1
  | _ -> ()

let get_pixel b x y =
  match Hashtbl.find_opt bitmaps b with
  | Some bm when x >= 0 && y >= 0 && x < bm.bw && y < bm.bh ->
      let at = ((y * bm.bw) + x) * 4 in
      let byte i = Char.code (Bytes.get bm.data (at + i)) in
      (byte 0 lsl 16) lor (byte 1 lsl 8) lor byte 2
  | _ -> 0

let fill_bitmap b color =
  match Hashtbl.find_opt bitmaps b with
  | None -> ()
  | Some bm ->
      for i = 0 to (bm.bw * bm.bh) - 1 do
        Bytes.set bm.data (i * 4) (Char.unsafe_chr ((color lsr 16) land 255));
        Bytes.set bm.data ((i * 4) + 1) (Char.unsafe_chr ((color lsr 8) land 255));
        Bytes.set bm.data ((i * 4) + 2) (Char.unsafe_chr (color land 255))
      done;
      bm.x1 <- 0;
      bm.y1 <- 0;
      bm.x2 <- bm.bw;
      bm.y2 <- bm.bh

let draw_bitmap c b x y scale =
  match Hashtbl.find_opt bitmaps b with
  | None -> ()
  | Some bm ->
      let rx, ry, rw, rh =
        if bm.x2 > bm.x1 && bm.y2 > bm.y1 then (bm.x1, bm.y1, bm.x2 - bm.x1, bm.y2 - bm.y1)
        else (0, 0, 0, 0)
      in
      let rect = Bytes.create (rw * rh * 4) in
      for r = 0 to rh - 1 do
        Bytes.blit bm.data ((((ry + r) * bm.bw) + rx) * 4) rect (r * rw * 4) (rw * 4)
      done;
      bm.x1 <- bm.bw;
      bm.y1 <- bm.bh;
      bm.x2 <- 0;
      bm.y2 <- 0;
      send
        {
          op = "bitmap";
          fields =
            [ ("c", S c); ("id", S b); ("width", I bm.bw); ("height", I bm.bh); ("x", I x);
              ("y", I y); ("scale", F scale); ("rect", L [ rx; ry; rw; rh ]);
              ("data", S (base64 rect)); ("digest", S (digest rect)) ];
        }

let set_state c kind value numbers =
  send
    {
      op = "state";
      fields = [ ("c", S c); ("kind", S kind); ("value", S value); ("numbers", S numbers) ];
    }

let load_image name =
  ready ();
  let id = fresh name in
  send { op = "image_load"; fields = [ ("id", S id); ("name", S name) ] };
  id

let draw_image c picture x y width height alpha =
  send
    {
      op = "image";
      fields =
        [ ("c", S c); ("picture", S picture); ("x", I x); ("y", I y); ("width", I width);
          ("height", I height); ("alpha", F alpha) ];
    }

let make_checkbox title checked on_change =
  ready ();
  let id = fresh title in
  checks := !checks @ [ (id, on_change) ];
  send { op = "checkbox"; fields = [ ("id", S id); ("title", S title); ("checked", B checked) ] };
  id

let make_radio group title chosen on_pick =
  ready ();
  let id = fresh title in
  radios := !radios @ [ (id, fun () -> on_pick title) ];
  send
    {
      op = "radio";
      fields = [ ("id", S id); ("group", S group); ("title", S title); ("chosen", B chosen) ];
    };
  id

let make_choice options chosen on_change =
  ready ();
  let id = fresh "choice" in
  choices := !choices @ [ (id, on_change) ];
  send { op = "choice"; fields = [ ("id", S id); ("options", S options); ("chosen", I chosen) ] };
  id

let make_text_input placeholder on_enter =
  ready ();
  let id = fresh (if placeholder = "" then "text" else placeholder) in
  texts := !texts @ [ (id, on_enter) ];
  send { op = "text_input"; fields = [ ("id", S id); ("placeholder", S placeholder) ] };
  id

let make_number_input low high value on_change =
  ready ();
  let id = fresh "number" in
  sliders := !sliders @ [ (id, on_change) ];
  send
    {
      op = "number";
      fields = [ ("id", S id); ("low", I low); ("high", I high); ("value", I value) ];
    };
  id

let set_checked id checked =
  send { op = "set_checked"; fields = [ ("id", S id); ("checked", B checked) ] }

let set_value id value = send { op = "set_value"; fields = [ ("id", S id); ("value", I value) ] }

let make_button title on_click =
  ready ();
  let id = fresh title in
  buttons := !buttons @ [ (id, on_click) ];
  send { op = "button"; fields = [ ("id", S id); ("title", S title) ] };
  id

let label text =
  ready ();
  let id = fresh text in
  send { op = "label"; fields = [ ("id", S id); ("text", S text) ] };
  id

let row () =
  ready ();
  let id = fresh "row" in
  send { op = "row"; fields = [ ("id", S id) ] };
  id

let column () =
  ready ();
  let id = fresh "column" in
  send { op = "column"; fields = [ ("id", S id) ] };
  id

let inside id = send { op = "inside"; fields = [ ("id", S id) ] }
let outside () = send { op = "outside"; fields = [] }

let set_label id text = send { op = "set_label"; fields = [ ("id", S id); ("text", S text) ] }

let apply_style id kind property value =
  send
    {
      op = "style";
      fields = [ ("id", S id); ("kind", S kind); ("prop", S property); ("value", S value) ];
    }

let make_slider low high value on_change =
  ready ();
  let id = fresh "slider" in
  sliders := !sliders @ [ (id, on_change) ];
  send
    {
      op = "slider";
      fields = [ ("id", S id); ("low", I low); ("high", I high); ("value", I value) ];
    };
  id

let load_sample name =
  ready ();
  let id = fresh name in
  send { op = "load"; fields = [ ("id", S id); ("name", S name) ] };
  id

let play_sample sample at volume rate =
  send
    {
      op = "play";
      fields = [ ("sample", S sample); ("at", F at); ("volume", F volume); ("rate", F rate) ];
    }

let splash () =
  ready ();
  send { op = "splash"; fields = [] }

let set_splash message =
  ready ();
  send { op = "splash_text"; fields = [ ("text", S message) ] }

let time () =
  ready ();
  !clock

let on_frame draw =
  ready ();
  frames := !frames @ [ draw ];
  send { op = "on_frame"; fields = [] }

let on_mouse c click =
  ready ();
  mice := !mice @ [ (c, click) ];
  send { op = "on_mouse"; fields = [ ("c", S c) ] }

let on_key pressed =
  ready ();
  keys := !keys @ [ pressed ];
  send { op = "on_key"; fields = [] }

let on_key_up released =
  ready ();
  key_ups := !key_ups @ [ released ];
  send { op = "on_key"; fields = [] }

let key_down key =
  ready ();
  if not (!keys_on || !keys <> [] || !key_ups <> []) then (
    keys_on := true;
    send { op = "on_key"; fields = [] });
  List.mem key !down

(* --- for the REPL --- *)

(* What the server is waiting on: nothing until `web_init`. *)
let descriptors () =
  match !listener with
  | None -> []
  | Some server -> server :: List.map (fun c -> c.socket) !clients

(* Answers what is waiting and delivers what the page posted, without
   waiting for anything more. *)
let handle () =
  if !listener <> None then (
    poll 0.0;
    batching := true;
    deliver_queued ();
    batching := false)

