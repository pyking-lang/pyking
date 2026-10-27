/* The C implementation of the names declared in tinyweb_external.pyk,
   for c89, c99 and c23. A name is tinyweb_<field>, a String is a
   const char *, a Float a double, and a Pyking function a pointer to a
   C function. Written in C89 with POSIX sockets, so that one file
   serves all three standards.

   A program talks to its page in commands and the page answers in
   events (docs/libraries.md, "tinyweb"). Where they go:

   - $PYKING_TINYWEB_LOG set: no page. Each command is a line in that
     file, and once the top level has ended the events
     $PYKING_TINYWEB_EVENTS lists are delivered -- how a program is
     tested.
   - otherwise tinyweb_web_init(port) serves the page,
     tinyweb_page.html and tinyweb_page.js (copied into this file
     below): GET /commands is a stream of command batches (server-sent
     events) and POST /events one event each. The server is one select
     loop, which runs once main has returned -- from atexit -- and
     delivers each event in the order it came, answered with
     `event_done` once what it caused has been sent.
   - neither: the first call says tinyweb_web_init is missing, and the
     program ends with status 1.

   Memory a command or an event needs is allocated and never freed,
   except what a page connecting late no longer needs to be sent. */

#define _POSIX_C_SOURCE 200112L
/* macOS hides INADDR_LOOPBACK under _POSIX_C_SOURCE unless this is set. */
#define _DARWIN_C_SOURCE

/* A Pyking Bool is bool from c99 on, and int in c89, which has none. */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#include <stdbool.h>
#elif !defined(TINYWEB_BOOL)
#define TINYWEB_BOOL
typedef int bool;
#define true 1
#define false 0
#endif

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

#ifndef INADDR_LOOPBACK
#define INADDR_LOOPBACK 0x7f000001UL
#endif

void tinyweb_web_start(int port);
const char *tinyweb_canvas(int width, int height);
void tinyweb_fill_canvas(const char *c, const char *color);
void tinyweb_draw_shape(const char *c, const char *kind, const char *numbers, const char *color,
                        const char *outline, double width, double alpha);
void tinyweb_draw_text(const char *c, double x, double y, const char *words, const char *color,
                       int size, const char *font, const char *align, const char *baseline,
                       bool bold, const char *outline, double outline_width, double alpha);
void tinyweb_set_state(const char *c, const char *kind, const char *value, const char *numbers);
void tinyweb_measure(const char *words, int size, const char *font, bool bold,
                     void (*answer)(double));
void tinyweb_watch_pointer(const char *c, const char *kind, void (*f)(int, int));
int tinyweb_pointer(const char *c, const char *which);
const char *tinyweb_load_image(const char *name);
void tinyweb_draw_image(const char *c, const char *picture, int x, int y, int width, int height,
                        double alpha);
const char *tinyweb_make_bitmap(int width, int height, int background);
void tinyweb_set_pixel(const char *b, int x, int y, int color);
int tinyweb_get_pixel(const char *b, int x, int y);
void tinyweb_fill_bitmap(const char *b, int color);
void tinyweb_draw_bitmap(const char *c, const char *b, int x, int y, double scale);
const char *tinyweb_make_button(const char *title, void (*on_click)(void));
const char *tinyweb_label(const char *text);
const char *tinyweb_row(void);
const char *tinyweb_column(void);
void tinyweb_inside(const char *id);
void tinyweb_outside(void);
void tinyweb_set_label(const char *id, const char *text);
const char *tinyweb_make_slider(int low, int high, int value, void (*on_change)(int));
const char *tinyweb_make_checkbox(const char *title, bool checked, void (*on_change)(bool));
const char *tinyweb_make_radio(const char *group, const char *title, bool chosen,
                               void (*on_pick)(const char *));
const char *tinyweb_make_choice(const char *options, int chosen, void (*on_change)(int));
const char *tinyweb_make_text_input(const char *placeholder, void (*on_enter)(const char *));
const char *tinyweb_make_number_input(int low, int high, int value, void (*on_change)(int));
void tinyweb_set_checked(const char *id, bool checked);
void tinyweb_set_value(const char *id, int value);
void tinyweb_apply_style(const char *id, const char *kind, const char *property, const char *value);
const char *tinyweb_load_sample(const char *name);
const char *tinyweb_fresh_id(const char *name);
void tinyweb_command(const char *kind, const char *id, const char *text, const char *numbers,
                     int mode);
void tinyweb_watch(const char *id, const char *kind, void (*f)(void));
double tinyweb_report_number(const char *name, int k);
const char *tinyweb_report_text(const char *name);
int tinyweb_report_count(const char *name);
void tinyweb_watch_text(const char *id, const char *kind, const char *name, void (*f)(const char *));
void tinyweb_watch_step(const char *id, const char *kind, void (*f)(int, double));
void tinyweb_watch_pair(const char *id, const char *kind, void (*f)(double, double));
void tinyweb_splash(void);
void tinyweb_set_splash(const char *message);
double tinyweb_time(void);
void tinyweb_sdelay(double time);
void tinyweb_on_frame(void (*draw)(double));
void tinyweb_on_mouse(const char *c, void (*click)(int, int));
void tinyweb_on_key(void (*pressed)(const char *));
void tinyweb_on_key_up(void (*released)(const char *));
bool tinyweb_key_down(const char *key);

/* BEGIN tinyweb page */
/* written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit */
static const char *const tinyweb_page_html[] = {
    "<!doctype html>\n",
    "<!-- The page a program serves after tinyweb.web_init: tinyweb_page.js\n",
    "     carries out the commands the program sends over /commands, and every\n",
    "     event is posted back to /events, in order. Each native\n",
    "     implementation carries a copy of this file, written into it by\n",
    "     tools/tinyweb/embed_page.py. See docs/libraries.md, \"tinyweb\". -->\n",
    "<html lang=\"en\">\n",
    "<head>\n",
    "<meta charset=\"utf-8\">\n",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
    "<title>tinyweb</title>\n",
    "<style>\n",
    "  body { margin: 0; padding: 16px; min-height: 100vh; box-sizing: border-box; }\n",
    "  .tinyweb-ended { margin-top: 12px; color: #666666; font-size: 14px; }\n",
    "</style>\n",
    "</head>\n",
    "<body>\n",
    "<script type=\"module\">\n",
    "import { mountPage } from \"./tinyweb_page.js\";\n",
    "\n",
    "// One event at a time, so the program sees them in the order they\n",
    "// happened.\n",
    "let posting = Promise.resolve();\n",
    "function post(event) {\n",
    "  posting = posting\n",
    "    .then(() => fetch(\"/events\", { method: \"POST\", body: JSON.stringify(event) }))\n",
    "    .catch(() => {});\n",
    "}\n",
    "\n",
    "const page = mountPage(document.body, post, { standalone: true });\n",
    "const stream = new EventSource(\"/commands\");\n",
    "stream.onmessage = (message) => page.receive(JSON.parse(message.data));\n",
    "stream.onerror = () => {\n",
    "  stream.close();\n",
    "  page.freeze();\n",
    "  const ended = document.createElement(\"div\");\n",
    "  ended.className = \"tinyweb-ended\";\n",
    "  ended.textContent = \"The program has stopped.\";\n",
    "  document.body.appendChild(ended);\n",
    "};\n",
    "</script>\n",
    "</body>\n",
    "</html>\n",
    0
};
static const char *const tinyweb_page_js[] = {
    "// tinyweb's page: the renderer that carries out the commands a program\n",
    "// sends and reports the events its reader causes. It is the one copy of\n",
    "// that code, used wherever a program talks to its page in commands:\n",
    "//\n",
    "//   - on an iweb page, where tinyweb_external_interpreter.js mounts it\n",
    "//     and calls it directly;\n",
    "//   - in the playground and the notebook, where the program runs on a\n",
    "//     worker and tools/webrun/assets/pages.js mounts it on the page;\n",
    "//   - on the page a compiled program serves after `web_init`, where\n",
    "//     tinyweb_page.html mounts it and the commands arrive from the\n",
    "//     program over HTTP. Each native implementation carries a copy of\n",
    "//     this file and of tinyweb_page.html, written into it by\n",
    "//     tools/tinyweb/embed_page.py.\n",
    "//\n",
    "// A command is a plain object such as {op: \"circle\", c, x, y, radius,\n",
    "// color}, and an event one such as {ev: \"click\", id}; see\n",
    "// docs/libraries.md, \"tinyweb\". The web implementation,\n",
    "// tinyweb_external_browser.js, does what this file does without the\n",
    "// commands in between. Keep the file ASCII: it is embedded in C.\n",
    "\n",
    "function now() {\n",
    "  return typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
    "}\n",
    "\n",
    "// BEGIN tinyweb style\n",
    "// The page's look: a theme, what the program changed of it for every\n",
    "// element of a kind, and what it changed of one element. A theme and a\n",
    "// kind's style are rules of a stylesheet of the page's own, scoped to the\n",
    "// element the page is mounted in, so the host page's own rules do not\n",
    "// reach in; one element's style is set on the element. This block is\n",
    "// copied into tinyweb_external_browser.js by tools/tinyweb/embed_page.py.\n",
    "\n",
    "// Each theme: CSS declarations for each place on the page (PLACES).\n",
    "const THEMES = {\n",
    "  light: {\n",
    "    page: { \"background\": \"#f6f6f4\", \"color\": \"#1d1f21\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
    "    box: { \"gap\": \"8px\" },\n",
    "    button: {\n",
    "      \"background\": \"#f0f2f5\", \"color\": \"#1f2328\", \"border\": \"1px solid #d4d8de\",\n",
    "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
    "    },\n",
    "    \"button:hover\": { \"border-color\": \"#2f5fc4\" },\n",
    "    \"button:active\": { \"background\": \"#e3e7ec\" },\n",
    "    \"slider input\": { \"accent-color\": \"#2f5fc4\" },\n",
    "    canvas: { \"border\": \"1px solid #c9ced6\" },\n",
    "  },\n",
    "  dark: {\n",
    "    page: { \"background\": \"#1d1f21\", \"color\": \"#e6e6e6\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
    "    box: { \"gap\": \"8px\" },\n",
    "    button: {\n",
    "      \"background\": \"#2f333a\", \"color\": \"#e6e6e6\", \"border\": \"1px solid #454a52\",\n",
    "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
    "    },\n",
    "    \"button:hover\": { \"border-color\": \"#7aa2f7\" },\n",
    "    \"button:active\": { \"background\": \"#3a3f47\" },\n",
    "    \"slider input\": { \"accent-color\": \"#7aa2f7\" },\n",
    "    canvas: { \"border\": \"1px solid #454a52\" },\n",
    "  },\n",
    "  plain: {\n",
    "    page: { \"background\": \"#ffffff\", \"color\": \"#000000\", \"font-family\": \"system-ui, sans-serif\" },\n",
    "    box: { \"gap\": \"8px\" },\n",
    "    canvas: { \"border\": \"1px solid #8884\" },\n",
    "  },\n",
    "  paper: {\n",
    "    page: { \"background\": \"#fbf6ea\", \"color\": \"#3b3024\", \"font-family\": \"Georgia, 'Times New Roman', serif\", \"font-size\": \"16px\" },\n",
    "    box: { \"gap\": \"10px\" },\n",
    "    button: {\n",
    "      \"background\": \"#fffdf7\", \"color\": \"#3b3024\", \"border\": \"1px solid #3b3024\",\n",
    "      \"border-radius\": \"2px\", \"padding\": \"5px 14px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
    "    },\n",
    "    \"button:hover\": { \"background\": \"#f1e8d2\" },\n",
    "    \"button:active\": { \"background\": \"#e6d9bb\" },\n",
    "    \"slider input\": { \"accent-color\": \"#8a5a2b\" },\n",
    "    canvas: { \"border\": \"1px solid #3b302466\" },\n",
    "  },\n",
    "  retro: {\n",
    "    page: { \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"font-family\": \"'Courier New', monospace\", \"font-size\": \"15px\" },\n",
    "    box: { \"gap\": \"10px\" },\n",
    "    button: {\n",
    "      \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"border\": \"2px solid #39ff6a\",\n",
    "      \"border-radius\": \"0\", \"padding\": \"4px 12px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
    "    },\n",
    "    \"button:hover\": { \"background\": \"#133313\" },\n",
    "    \"button:active\": { \"background\": \"#39ff6a\", \"color\": \"#0b1a0b\" },\n",
    "    \"slider input\": { \"accent-color\": \"#39ff6a\" },\n",
    "    canvas: { \"border\": \"2px solid #39ff6a\" },\n",
    "  },\n",
    "};\n",
    "\n",
    "// Where each place is, after the page's scope.\n",
    "const PLACES = {\n",
    "  page: \"\",\n",
    "  box: \" > .tinyweb-page\",\n",
    "  button: \" .tinyweb-page button\",\n",
    "  \"button:hover\": \" .tinyweb-page button:hover\",\n",
    "  \"button:active\": \" .tinyweb-page button:active\",\n",
    "  label: \" .tinyweb-page .tinyweb-label\",\n",
    "  slider: \" .tinyweb-page .tinyweb-slider\",\n",
    "  \"slider input\": \" .tinyweb-page .tinyweb-slider input\",\n",
    "  canvas: \" .tinyweb-page canvas\",\n",
    "};\n",
    "\n",
    "// What each property a program names is in CSS.\n",
    "const PROPERTIES = {\n",
    "  background: \"background\", color: \"color\", border: \"border\", radius: \"border-radius\",\n",
    "  font: \"font-family\", size: \"font-size\", padding: \"padding\", gap: \"gap\",\n",
    "  accent: \"accent-color\", width: \"width\", height: \"height\", align: \"align-items\",\n",
    "  weight: \"font-weight\",\n",
    "};\n",
    "\n",
    "// What an `align` a program names is in CSS.\n",
    "const ALIGNMENTS = { left: \"flex-start\", center: \"center\", right: \"flex-end\" };\n",
    "\n",
    "// The place a kind's property goes. String -> String -> String\n",
    "function placeOf(kind, property) {\n",
    "  if (kind === \"page\") return property === \"gap\" || property === \"align\" ? \"box\" : \"page\";\n",
    "  if (kind === \"slider\") return property === \"accent\" || property === \"width\" ? \"slider input\" : \"slider\";\n",
    "  return kind;\n",
    "}\n",
    "\n",
    "let styledPages = 0;\n",
    "\n",
    "// Gives the page mounted in `host` a stylesheet of its own, in the\n",
    "// default theme. Element -> Element -> Style\n",
    "function styled(host, box) {\n",
    "  styledPages += 1;\n",
    "  const sheet = document.createElement(\"style\");\n",
    "  sheet.setAttribute(\"data-tinyweb-style\", String(styledPages));\n",
    "  const style = { host, box, sheet, rules: null, elements: new Map(), name: String(styledPages) };\n",
    "  host.setAttribute(\"data-tinyweb-page\", style.name);\n",
    "  (document.head || document.body).appendChild(sheet);\n",
    "  setTheme(style, \"light\");\n",
    "  return style;\n",
    "}\n",
    "\n",
    "// Writes the stylesheet from the rules. Style -> ()\n",
    "function writeSheet(style) {\n",
    "  // The scope three times over, so the host page's rules for a button or\n",
    "  // a body do not outweigh the page's own.\n",
    "  const scope = `[data-tinyweb-page=\"${style.name}\"]`.repeat(3);\n",
    "  const text = [];\n",
    "  for (const place of Object.keys(PLACES)) {\n",
    "    const declarations = style.rules[place];\n",
    "    if (!declarations || Object.keys(declarations).length === 0) continue;\n",
    "    const body = Object.entries(declarations).map(([k, v]) => `${k}: ${v};`).join(\" \");\n",
    "    text.push(`${scope}${PLACES[place]} { ${body} }`);\n",
    "  }\n",
    "  style.sheet.textContent = text.join(\"\\n\");\n",
    "}\n",
    "\n",
    "// Puts the page in a theme, forgetting what was changed for each kind.\n",
    "// An unknown name changes nothing. Style -> String -> ()\n",
    "function setTheme(style, name) {\n",
    "  const theme = THEMES[name];\n",
    "  if (!theme) return;\n",
    "  style.rules = {};\n",
    "  for (const [place, declarations] of Object.entries(theme)) {\n",
    "    style.rules[place] = { ...declarations };\n",
    "  }\n",
    "  writeSheet(style);\n",
    "}\n",
    "\n",
    "// Remembers a page element by its id, so that its own style can be set.\n",
    "// Style -> Int -> Element -> ()\n",
    "function remember(style, id, element) {\n",
    "  style.elements.set(id, element);\n",
    "}\n",
    "\n",
    "// Carries out one style command: a theme, a property of every element\n",
    "// of a kind, or a property of the element `id` (kind \"element\").\n",
    "// Style -> Int -> String -> String -> String -> ()\n",
    "function applyStyle(style, id, kind, property, given) {\n",
    "  if (kind === \"theme\") {\n",
    "    setTheme(style, given);\n",
    "    return;\n",
    "  }\n",
    "  const css = PROPERTIES[property];\n",
    "  if (!css) return;\n",
    "  const value = property === \"align\" ? ALIGNMENTS[given] || \"flex-start\" : given;\n",
    "  if (kind === \"page\" && property === \"align\") {\n",
    "    // The box says where its elements stand on the element itself.\n",
    "    style.box.style.setProperty(css, value);\n",
    "    return;\n",
    "  }\n",
    "  if (kind === \"element\") {\n",
    "    let element = style.elements.get(id);\n",
    "    if (!element) return;\n",
    "    // A slider's own properties are its input's; the rest are its row's.\n",
    "    if (element.tagName === \"INPUT\" && property !== \"accent\" && property !== \"width\") {\n",
    "      element = element.parentNode;\n",
    "    }\n",
    "    element.style.setProperty(css, value);\n",
    "    return;\n",
    "  }\n",
    "  const place = placeOf(kind, property);\n",
    "  if (!(place in PLACES)) return;\n",
    "  if (!style.rules[place]) style.rules[place] = {};\n",
    "  style.rules[place][css] = value;\n",
    "  writeSheet(style);\n",
    "}\n",
    "\n",
    "// Takes the page's look off the element it was mounted in. Style -> ()\n",
    "function unstyled(style) {\n",
    "  style.sheet.remove();\n",
    "  if (style.host.getAttribute(\"data-tinyweb-page\") === style.name) {\n",
    "    style.host.removeAttribute(\"data-tinyweb-page\");\n",
    "  }\n",
    "}\n",
    "// What the splash screen says until the program sets it.\n",
    "const SPLASH_TEXT = \"Click to Start\";\n",
    "\n",
    "// The splash screen: the whole window dimmed, and `text` in white in\n",
    "// its middle under a play sign. String -> Element\n",
    "function splashScreen(text) {\n",
    "  const screen = document.createElement(\"div\");\n",
    "  screen.className = \"tinyweb-splash\";\n",
    "  screen.setAttribute(\"role\", \"button\");\n",
    "  screen.style.cssText =\n",
    "    \"position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;\" +\n",
    "    \"align-items:center;justify-content:center;gap:24px;background:rgba(0,0,0,0.62);\" +\n",
    "    \"color:#ffffff;cursor:pointer;user-select:none;font-family:system-ui,sans-serif\";\n",
    "  const ring = document.createElement(\"div\");\n",
    "  ring.style.cssText =\n",
    "    \"width:88px;height:88px;border-radius:50%;border:3px solid #ffffff;display:flex;\" +\n",
    "    \"align-items:center;justify-content:center;box-shadow:0 0 36px rgba(255,255,255,0.35)\";\n",
    "  const sign = document.createElement(\"div\");\n",
    "  sign.style.cssText =\n",
    "    \"width:0;height:0;margin-left:9px;border-top:19px solid transparent;\" +\n",
    "    \"border-bottom:19px solid transparent;border-left:32px solid #ffffff\";\n",
    "  ring.appendChild(sign);\n",
    "  const words = document.createElement(\"div\");\n",
    "  words.textContent = text;\n",
    "  words.style.cssText =\n",
    "    \"font-size:34px;font-weight:600;letter-spacing:0.03em;text-align:center;\" +\n",
    "    \"padding:0 24px;text-shadow:0 2px 14px rgba(0,0,0,0.6)\";\n",
    "  screen.append(ring, words);\n",
    "  return screen;\n",
    "}\n",
    "\n",
    "// Whether the reader has already done something on this page, which is\n",
    "// all a browser asks before it plays a sound. () -> Bool\n",
    "function readerActive() {\n",
    "  return Boolean(globalThis.navigator?.userActivation?.hasBeenActive);\n",
    "}\n",
    "// --- drawing (step 1) ---\n",
    "\n",
    "// A shape's numbers: the words tinyweb.pyk wrote, as numbers.\n",
    "function numbersOf(text) {\n",
    "  return text === \"\" ? [] : text.split(\" \").map(Number);\n",
    "}\n",
    "\n",
    "// A rectangle with rounded corners, as a path. Context -> ... -> ()\n",
    "function roundedRect(g, x, y, w, h, r) {\n",
    "  const k = Math.max(0, Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2));\n",
    "  g.moveTo(x + k, y);\n",
    "  g.arcTo(x + w, y, x + w, y + h, k);\n",
    "  g.arcTo(x + w, y + h, x, y + h, k);\n",
    "  g.arcTo(x, y + h, x, y, k);\n",
    "  g.arcTo(x, y, x + w, y, k);\n",
    "  g.closePath();\n",
    "}\n",
    "\n",
    "// The outline of one shape, added to the context's path. Whether a filled\n",
    "// arc is a slice from its centre is `slice`'s.\n",
    "// Context -> String -> [Float] -> Bool -> ()\n",
    "function shapePath(g, kind, n, slice) {\n",
    "  switch (kind) {\n",
    "    case \"rect\":\n",
    "      if (n[4] > 0) roundedRect(g, n[0], n[1], n[2], n[3], n[4]);\n",
    "      else g.rect(n[0], n[1], n[2], n[3]);\n",
    "      break;\n",
    "    case \"circle\":\n",
    "      g.arc(n[0], n[1], Math.max(0, n[2]), 0, 2 * Math.PI);\n",
    "      break;\n",
    "    case \"ellipse\":\n",
    "      g.ellipse(n[0], n[1], Math.max(0, n[2]), Math.max(0, n[3]), 0, 0, 2 * Math.PI);\n",
    "      break;\n",
    "    case \"arc\":\n",
    "      if (slice) g.moveTo(n[0], n[1]);\n",
    "      g.arc(n[0], n[1], Math.max(0, n[2]), n[3], n[4]);\n",
    "      if (slice) g.closePath();\n",
    "      break;\n",
    "    case \"line\":\n",
    "      g.moveTo(n[0], n[1]);\n",
    "      g.lineTo(n[2], n[3]);\n",
    "      break;\n",
    "    case \"lines\":\n",
    "      for (let i = 0; i + 3 < n.length; i += 4) {\n",
    "        g.moveTo(n[i], n[i + 1]);\n",
    "        g.lineTo(n[i + 2], n[i + 3]);\n",
    "      }\n",
    "      break;\n",
    "    case \"curve\":\n",
    "      g.moveTo(n[0], n[1]);\n",
    "      g.quadraticCurveTo(n[2], n[3], n[4], n[5]);\n",
    "      break;\n",
    "    case \"bezier\":\n",
    "      g.moveTo(n[0], n[1]);\n",
    "      g.bezierCurveTo(n[2], n[3], n[4], n[5], n[6], n[7]);\n",
    "      break;\n",
    "    case \"polygon\":\n",
    "    case \"path\":\n",
    "      for (let i = 0; i + 1 < n.length; i += 2) {\n",
    "        if (i === 0) g.moveTo(n[i], n[i + 1]);\n",
    "        else g.lineTo(n[i], n[i + 1]);\n",
    "      }\n",
    "      if (kind === \"polygon\") g.closePath();\n",
    "      break;\n",
    "  }\n",
    "}\n",
    "\n",
    "// The gradients a canvas has been given, by the text that describes\n",
    "// them, so a frame drawing the same one again does not make it again.\n",
    "const GRADIENTS_KEPT = 64;\n",
    "\n",
    "// What a color means on a context: a CSS color as it is, and a gradient\n",
    "// tinyweb.pyk described -- \"linear-gradient(x1 y1 x2 y2); 0 red; 1 blue\",\n",
    "// \"radial-gradient(x1 y1 r1 x2 y2 r2); ...\", \"conic-gradient(x y\n",
    "// angle); ...\" -- as the gradient. Context -> Entry? -> String -> Paint\n",
    "function paint(g, entry, color) {\n",
    "  const open = color.indexOf(\"(\");\n",
    "  if (open < 0 || !color.slice(0, open).endsWith(\"-gradient\")) return color;\n",
    "  const close = color.indexOf(\")\", open);\n",
    "  if (close < 0 || color.slice(close + 1, close + 2) !== \";\") return color;\n",
    "  const kept = entry ? entry.gradients : null;\n",
    "  if (kept && kept.has(color)) return kept.get(color);\n",
    "  const kind = color.slice(0, open);\n",
    "  const n = numbersOf(color.slice(open + 1, close).trim());\n",
    "  let gradient;\n",
    "  if (kind === \"linear-gradient\") gradient = g.createLinearGradient(n[0], n[1], n[2], n[3]);\n",
    "  else if (kind === \"radial-gradient\")\n",
    "    gradient = g.createRadialGradient(n[0], n[1], Math.max(0, n[2]), n[3], n[4], Math.max(0, n[5]));\n",
    "  else if (kind === \"conic-gradient\" && typeof g.createConicGradient === \"function\")\n",
    "    gradient = g.createConicGradient(n[2], n[0], n[1]);\n",
    "  else return \"#000000\";\n",
    "  // A stop's color may itself hold brackets and commas, \"rgba(0, 0, 0, 0.5)\",\n",
    "  // but never a semicolon.\n",
    "  for (const stop of color.slice(close + 2).split(\";\")) {\n",
    "    const text = stop.trim();\n",
    "    const space = text.indexOf(\" \");\n",
    "    if (space < 0) continue;\n",
    "    const at = Math.min(1, Math.max(0, Number(text.slice(0, space))));\n",
    "    try {\n",
    "      gradient.addColorStop(at, text.slice(space + 1).trim());\n",
    "    } catch (error) {\n",
    "      // A stop whose color the browser does not read is left out.\n",
    "    }\n",
    "  }\n",
    "  if (kept) {\n",
    "    if (kept.size >= GRADIENTS_KEPT) kept.delete(kept.keys().next().value);\n",
    "    kept.set(color, gradient);\n",
    "  }\n",
    "  return gradient;\n",
    "}\n",
    "\n",
    "// Draws one shape: filled with `color` and outlined with `outline`, each\n",
    "// unless it is \"\", at `alpha`, in the canvas's line style. The numbers\n",
    "// are the kind's own (see tinyweb.pyk), as words or as an array;\n",
    "// \"erase\" makes its rectangle transparent, and \"circles\" draws each\n",
    "// circle on its own. Context -> Entry? -> String -> Numbers -> ... -> ()\n",
    "function drawShape(g, entry, kind, numbers, color, outline, width, alpha) {\n",
    "  const n = typeof numbers === \"string\" ? numbersOf(numbers) : numbers;\n",
    "  if (kind === \"erase\") {\n",
    "    g.clearRect(n[0], n[1], n[2], n[3]);\n",
    "    return;\n",
    "  }\n",
    "  const before = g.globalAlpha;\n",
    "  g.globalAlpha = before * alpha;\n",
    "  if (kind === \"circles\") {\n",
    "    // Each circle on its own, so where two overlap both show.\n",
    "    if (color !== \"\") g.fillStyle = paint(g, entry, color);\n",
    "    if (outline !== \"\") {\n",
    "      g.strokeStyle = paint(g, entry, outline);\n",
    "      g.lineWidth = width;\n",
    "    }\n",
    "    for (let i = 0; i + 2 < n.length; i += 3) {\n",
    "      g.beginPath();\n",
    "      g.arc(n[i], n[i + 1], Math.max(0, n[i + 2]), 0, 2 * Math.PI);\n",
    "      if (color !== \"\") g.fill();\n",
    "      if (outline !== \"\") g.stroke();\n",
    "    }\n",
    "    g.globalAlpha = before;\n",
    "    return;\n",
    "  }\n",
    "  g.beginPath();\n",
    "  shapePath(g, kind, n, color !== \"\");\n",
    "  if (color !== \"\") {\n",
    "    g.fillStyle = paint(g, entry, color);\n",
    "    g.fill();\n",
    "  }\n",
    "  if (outline !== \"\") {\n",
    "    g.strokeStyle = paint(g, entry, outline);\n",
    "    g.lineWidth = width;\n",
    "    g.stroke();\n",
    "  }\n",
    "  g.globalAlpha = before;\n",
    "}\n",
    "\n",
    "// The font text is written in. Int -> String -> Bool -> String\n",
    "function fontOf(size, font, bold) {\n",
    "  return `${bold ? \"bold \" : \"\"}${size}px ${font === \"\" ? \"system-ui, sans-serif\" : font}`;\n",
    "}\n",
    "\n",
    "// Writes text at (x, y): its left end there, its middle or its right end,\n",
    "// as `align` says, and its top, middle, alphabetic baseline or bottom,\n",
    "// as `baseline` says. An `outline` is drawn round the letters first.\n",
    "// Context -> Entry? -> ... -> ()\n",
    "function drawText(g, entry, x, y, words, color, size, font, align, baseline, bold, outline,\n",
    "  outlineWidth, alpha) {\n",
    "  const before = g.globalAlpha;\n",
    "  g.globalAlpha = before * alpha;\n",
    "  g.font = fontOf(size, font, bold);\n",
    "  g.textBaseline = [\"top\", \"middle\", \"alphabetic\", \"bottom\"].includes(baseline) ? baseline : \"top\";\n",
    "  g.textAlign = align === \"center\" || align === \"right\" ? align : \"left\";\n",
    "  if (outline !== \"\") {\n",
    "    g.strokeStyle = paint(g, entry, outline);\n",
    "    g.lineWidth = outlineWidth;\n",
    "    g.strokeText(words, x, y);\n",
    "  }\n",
    "  if (color !== \"\") {\n",
    "    g.fillStyle = paint(g, entry, color);\n",
    "    g.fillText(words, x, y);\n",
    "  }\n",
    "  g.globalAlpha = before;\n",
    "}\n",
    "\n",
    "// How wide `words` is written in that font, in pixels.\n",
    "// String -> Int -> String -> Bool -> Float\n",
    "function textWidth(words, size, font, bold) {\n",
    "  if (typeof document === \"undefined\") return 0;\n",
    "  if (!textWidth.context) textWidth.context = document.createElement(\"canvas\").getContext(\"2d\");\n",
    "  const g = textWidth.context;\n",
    "  if (!g) return 0;\n",
    "  g.font = fontOf(size, font, bold);\n",
    "  return g.measureText(words).width;\n",
    "}\n",
    "\n",
    "// The line style a canvas starts with: round ends and corners, no dashes.\n",
    "// Context -> ()\n",
    "function plainLines(g) {\n",
    "  g.lineCap = \"round\";\n",
    "  g.lineJoin = \"round\";\n",
    "  if (typeof g.setLineDash === \"function\") g.setLineDash([]);\n",
    "  g.lineDashOffset = 0;\n",
    "}\n",
    "\n",
    "// Changes what the next drawing on a canvas is drawn with. `entry` keeps\n",
    "// the canvas's pixel ratio and how many `push`es are open.\n",
    "// Context -> Entry -> String -> String -> String -> ()\n",
    "function canvasState(g, entry, kind, value, numbers) {\n",
    "  const n = numbersOf(numbers);\n",
    "  switch (kind) {\n",
    "    case \"translate\":\n",
    "      g.translate(n[0], n[1]);\n",
    "      break;\n",
    "    case \"rotate\":\n",
    "      g.rotate(n[0]);\n",
    "      break;\n",
    "    case \"scale\":\n",
    "      g.scale(n[0], n[1]);\n",
    "      break;\n",
    "    case \"push\":\n",
    "      g.save();\n",
    "      entry.depth += 1;\n",
    "      break;\n",
    "    case \"pop\":\n",
    "      if (entry.depth > 0) {\n",
    "        g.restore();\n",
    "        entry.depth -= 1;\n",
    "      }\n",
    "      break;\n",
    "    case \"reset\":\n",
    "      g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
    "      break;\n",
    "    case \"shadow\":\n",
    "      g.shadowColor = value === \"\" ? \"transparent\" : value;\n",
    "      g.shadowBlur = value === \"\" ? 0 : n[0];\n",
    "      g.shadowOffsetX = value === \"\" ? 0 : n[1];\n",
    "      g.shadowOffsetY = value === \"\" ? 0 : n[2];\n",
    "      break;\n",
    "    case \"blend\":\n",
    "      g.globalCompositeOperation = value === \"add\" ? \"lighter\" : \"source-over\";\n",
    "      break;\n",
    "    case \"line_style\": {\n",
    "      // value: the ends and the corners; numbers: the dash offset, then\n",
    "      // the lengths of the dashes and the gaps.\n",
    "      const [cap, join] = value.split(\" \");\n",
    "      g.lineCap = [\"butt\", \"round\", \"square\"].includes(cap) ? cap : \"round\";\n",
    "      g.lineJoin = [\"miter\", \"round\", \"bevel\"].includes(join) ? join : \"round\";\n",
    "      if (typeof g.setLineDash === \"function\") g.setLineDash(n.slice(1));\n",
    "      g.lineDashOffset = n.length > 0 ? n[0] : 0;\n",
    "      break;\n",
    "    }\n",
    "    case \"clip\":\n",
    "      // value: the kind of shape the drawing is kept inside.\n",
    "      g.beginPath();\n",
    "      shapePath(g, value, n, false);\n",
    "      g.clip();\n",
    "      break;\n",
    "  }\n",
    "}\n",
    "\n",
    "// A canvas as it starts: every `push` closed, no transformation but the\n",
    "// pixel ratio, no shadow, no blending, no clipping and plain lines. What\n",
    "// `clear` begins with. Context -> Entry -> ()\n",
    "function freshState(g, entry) {\n",
    "  while (entry.depth > 0) {\n",
    "    g.restore();\n",
    "    entry.depth -= 1;\n",
    "  }\n",
    "  g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
    "  g.globalAlpha = 1;\n",
    "  g.shadowColor = \"transparent\";\n",
    "  g.shadowBlur = 0;\n",
    "  g.shadowOffsetX = 0;\n",
    "  g.shadowOffsetY = 0;\n",
    "  g.globalCompositeOperation = \"source-over\";\n",
    "  plainLines(g);\n",
    "}\n",
    "\n",
    "// Starts loading a picture: beside the page first, then among the ones\n",
    "// tinyweb ships beside `base`. Answers what `drawPicture` draws once it\n",
    "// has loaded; `loading` is true until it has loaded or failed, and then\n",
    "// each function in `settled` is called. String -> String -> Picture\n",
    "function loadPicture(name, base) {\n",
    "  const picture = { element: null, ready: false, retried: false, loading: false, settled: [] };\n",
    "  if (typeof Image === \"undefined\") return picture;\n",
    "  const element = new Image();\n",
    "  picture.element = element;\n",
    "  picture.loading = true;\n",
    "  const settle = () => {\n",
    "    picture.loading = false;\n",
    "    for (const then of picture.settled.splice(0)) then();\n",
    "  };\n",
    "  element.onload = () => {\n",
    "    picture.ready = true;\n",
    "    settle();\n",
    "  };\n",
    "  element.onerror = () => {\n",
    "    if (picture.retried) {\n",
    "      console.error(`tinyweb: cannot load the picture ${name}`);\n",
    "      settle();\n",
    "      return;\n",
    "    }\n",
    "    picture.retried = true;\n",
    "    element.src = new URL(\"tinyweb_assets/\" + name, base).href;\n",
    "  };\n",
    "  element.src = new URL(name, document.baseURI).href;\n",
    "  return picture;\n",
    "}\n",
    "\n",
    "// Draws a picture that has loaded; one still loading is not drawn.\n",
    "// Context -> Picture? -> ... -> ()\n",
    "function drawPicture(g, picture, x, y, width, height, alpha) {\n",
    "  if (!picture || !picture.ready) return;\n",
    "  const before = g.globalAlpha;\n",
    "  g.globalAlpha = before * alpha;\n",
    "  g.drawImage(picture.element, x, y, width, height);\n",
    "  g.globalAlpha = before;\n",
    "}\n",
    "\n",
    "// Keeps the pointer's moves and its release coming to the canvas it went\n",
    "// down on, wherever it goes. Element -> Event -> ()\n",
    "function capture(element, event) {\n",
    "  try {\n",
    "    if (element.setPointerCapture) element.setPointerCapture(event.pointerId);\n",
    "  } catch (error) {\n",
    "    // A pointer the browser does not know of, as a test's is, is not held.\n",
    "  }\n",
    "}\n",
    "\n",
    "// --- bitmaps (step 5) ---\n",
    "\n",
    "// The bytes of a bitmap's rectangle as they arrive: a base64 string from\n",
    "// a program on another host, or the bytes themselves. Data -> Uint8ClampedArray\n",
    "function bitmapBytes(data) {\n",
    "  if (typeof data !== \"string\") {\n",
    "    return ArrayBuffer.isView(data)\n",
    "      ? new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)\n",
    "      : new Uint8ClampedArray(data);\n",
    "  }\n",
    "  const text = atob(data);\n",
    "  const bytes = new Uint8ClampedArray(text.length);\n",
    "  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);\n",
    "  return bytes;\n",
    "}\n",
    "\n",
    "// A bitmap as the page keeps it: a canvas of its own, its pixels.\n",
    "// Int -> Int -> Surface\n",
    "function bitmapSurface(width, height) {\n",
    "  const element = document.createElement(\"canvas\");\n",
    "  element.width = Math.max(1, width);\n",
    "  element.height = Math.max(1, height);\n",
    "  return { element, context: element.getContext(\"2d\"), width, height };\n",
    "}\n",
    "\n",
    "// Puts the rectangle (rx, ry, rw, rh) of a bitmap's pixels on its\n",
    "// surface. Surface -> Int -> Int -> Int -> Int -> Data -> ()\n",
    "function updateSurface(surface, rx, ry, rw, rh, data) {\n",
    "  if (rw <= 0 || rh <= 0) return;\n",
    "  const bytes = bitmapBytes(data);\n",
    "  if (bytes.length !== rw * rh * 4) return;\n",
    "  surface.context.putImageData(new ImageData(bytes, rw, rh), rx, ry);\n",
    "}\n",
    "\n",
    "// Draws a bitmap's surface with its top left corner at (x, y), each pixel\n",
    "// `scale` pixels across: sharp squares when it grows, smooth when it\n",
    "// shrinks. Context -> Surface -> Float -> Float -> Float -> ()\n",
    "function drawSurface(g, surface, x, y, scale) {\n",
    "  const smoothing = g.imageSmoothingEnabled;\n",
    "  g.imageSmoothingEnabled = scale < 1;\n",
    "  g.drawImage(surface.element, x, y, surface.width * scale, surface.height * scale);\n",
    "  g.imageSmoothingEnabled = smoothing;\n",
    "}\n",
    "\n",
    "// A box whose elements go side by side, wrapping where the page is too\n",
    "// narrow for them, or one below another. String -> Bool -> Element\n",
    "function rowElement(id, across = true) {\n",
    "  const row = document.createElement(\"div\");\n",
    "  row.className = across ? \"tinyweb-row\" : \"tinyweb-column\";\n",
    "  row.setAttribute(\"data-tinyweb-id\", id);\n",
    "  row.style.cssText = across\n",
    "    ? \"display:flex;flex-direction:row;flex-wrap:wrap;align-items:center;gap:8px\"\n",
    "    : \"display:flex;flex-direction:column;align-items:flex-start;gap:6px\";\n",
    "  return row;\n",
    "}\n",
    "\n",
    "// --- widgets (step 2) ---\n",
    "\n",
    "// A checkbox or a radio button with its title beside it: the row, and\n",
    "// the input in it. String -> String -> String -> Bool -> (Element, Element)\n",
    "function choiceRow(type, id, title, checked) {\n",
    "  const row = document.createElement(\"label\");\n",
    "  row.className = type === \"checkbox\" ? \"tinyweb-check\" : \"tinyweb-radio\";\n",
    "  row.style.cssText = \"display:flex;align-items:center;gap:6px\";\n",
    "  const input = document.createElement(\"input\");\n",
    "  input.type = type;\n",
    "  input.setAttribute(\"data-tinyweb-id\", id);\n",
    "  input.checked = checked;\n",
    "  const text = document.createElement(\"span\");\n",
    "  text.textContent = title;\n",
    "  row.append(input, text);\n",
    "  return { row, input };\n",
    "}\n",
    "\n",
    "// A dropdown of the options, one per line of `options`, the one at\n",
    "// `chosen` chosen. String -> String -> Int -> Element\n",
    "function choiceElement(id, options, chosen) {\n",
    "  const select = document.createElement(\"select\");\n",
    "  select.className = \"tinyweb-choice\";\n",
    "  select.setAttribute(\"data-tinyweb-id\", id);\n",
    "  options.split(\"\\n\").forEach((text, position) => {\n",
    "    const option = document.createElement(\"option\");\n",
    "    option.value = String(position);\n",
    "    option.textContent = text;\n",
    "    select.appendChild(option);\n",
    "  });\n",
    "  select.value = String(chosen);\n",
    "  return select;\n",
    "}\n",
    "\n",
    "// A line to type text into. String -> String -> Element\n",
    "function textInputElement(id, placeholder) {\n",
    "  const input = document.createElement(\"input\");\n",
    "  input.type = \"text\";\n",
    "  input.className = \"tinyweb-text\";\n",
    "  input.setAttribute(\"data-tinyweb-id\", id);\n",
    "  input.placeholder = placeholder;\n",
    "  return input;\n",
    "}\n",
    "\n",
    "// A field for a whole number from `low` to `high`. ... -> Element\n",
    "function numberElement(id, low, high, value) {\n",
    "  const input = document.createElement(\"input\");\n",
    "  input.type = \"number\";\n",
    "  input.className = \"tinyweb-number\";\n",
    "  input.setAttribute(\"data-tinyweb-id\", id);\n",
    "  input.min = String(low);\n",
    "  input.max = String(high);\n",
    "  input.value = String(value);\n",
    "  return input;\n",
    "}\n",
    "\n",
    "// Whether a key press is the reader typing into a field, which the page\n",
    "// does not report as a key. Event -> Bool\n",
    "function typedInField(event) {\n",
    "  const target = event.target;\n",
    "  return !!target && typeof target.tagName === \"string\"\n",
    "    && (target.tagName === \"SELECT\"\n",
    "      || target.tagName === \"TEXTAREA\"\n",
    "      || (target.tagName === \"INPUT\" && (target.type === \"text\" || target.type === \"number\")));\n",
    "}\n",
    "\n",
    "// --- the engine: sound, the beat, timers and changing the page ---\n",
    "// What every `cmd` command does, the same for the page a program sends\n",
    "// commands to and for web, which calls it directly: makeEngine(host)\n",
    "// answers {command(cmd), reports(withSound), frozen(), held(cmd), close()}.\n",
    "// `host` is what the engine needs of the page:\n",
    "//   audio() -- the AudioContext once sound has started, or null\n",
    "//   startAudio() -- starts sound, where the reader has already done something\n",
    "//   clock() -- the page's clock, in seconds\n",
    "//   toAudio(t) -- a time on the page's clock as a time on the audio clock\n",
    "//   thaw(t) -- the clock goes on from `t` after a pause\n",
    "//   sample(id) -- a sample's loading, a Promise of its AudioBuffer (or null)\n",
    "//   addSample(id, loading) -- a sample loaded another way: a file the reader chose\n",
    "//   element(id) -- an element by its identifier; forget(id) when it is removed\n",
    "//   remember(id, element), place(element) -- a new element, put on the page\n",
    "//   canvas(id) -- a canvas's {element, width, height}\n",
    "//   send(event) -- reports an event to the program\n",
    "\n",
    "// How far ahead the beat is scheduled, and how often it is looked at.\n",
    "const LOOKAHEAD = 0.15;\n",
    "const TICK_MS = 25;\n",
    "\n",
    "// How long before an `sdelay` ends the page answers it, so that what the\n",
    "// program plays next reaches the page in time to start exactly there,\n",
    "// and how often the clock is looked at while one waits.\n",
    "const SDELAY_LEAD = 0.05;\n",
    "const SDELAY_TICK_MS = 5;\n",
    "\n",
    "// The numbers a command carries. String -> [Float]\n",
    "function engineNumbers(text) {\n",
    "  return text === \"\" || text === undefined ? [] : String(text).trim().split(/\\s+/).map(Number);\n",
    "}\n",
    "\n",
    "// A buffer played backwards, made once per buffer. AudioContext -> AudioBuffer -> AudioBuffer\n",
    "const reversedBuffers = new WeakMap();\n",
    "function reversedOf(context, buffer) {\n",
    "  let done = reversedBuffers.get(buffer);\n",
    "  if (done) return done;\n",
    "  done = context.createBuffer(buffer.numberOfChannels, buffer.length, buffer.sampleRate);\n",
    "  for (let k = 0; k < buffer.numberOfChannels; k++) {\n",
    "    const from = buffer.getChannelData(k);\n",
    "    const to = done.getChannelData(k);\n",
    "    for (let i = 0, n = from.length; i < n; i++) to[i] = from[n - 1 - i];\n",
    "  }\n",
    "  reversedBuffers.set(buffer, done);\n",
    "  return done;\n",
    "}\n",
    "\n",
    "// A reverb's impulse: two seconds of noise dying away. AudioContext -> AudioBuffer\n",
    "function impulseOf(context) {\n",
    "  const length = Math.round(context.sampleRate * 2);\n",
    "  const impulse = context.createBuffer(2, length, context.sampleRate);\n",
    "  // The same noise every time, so a render comes out the same.\n",
    "  let seed = 22222;\n",
    "  const random = () => {\n",
    "    seed = (seed * 1103515245 + 12345) % 2147483648;\n",
    "    return seed / 2147483648;\n",
    "  };\n",
    "  for (let k = 0; k < 2; k++) {\n",
    "    const data = impulse.getChannelData(k);\n",
    "    for (let i = 0; i < length; i++) data[i] = (random() * 2 - 1) * Math.pow(1 - i / length, 3);\n",
    "  }\n",
    "  return impulse;\n",
    "}\n",
    "\n",
    "// A channel's settings as `channel_style` gives them.\n",
    "const CHANNEL_DEFAULT = { volume: 1, pan: 0, echo: 0, echoTime: 0.3, feedback: 0.35, reverb: 0, lowPass: 0 };\n",
    "\n",
    "// The sound graph of one AudioContext: a master volume, an analyser on\n",
    "// it, and the channels each sound goes through: volume, pan, a low-pass\n",
    "// filter, and sends to an echo and a reverb. AudioContext -> {..}\n",
    "function soundGraph(context) {\n",
    "  const master = context.createGain();\n",
    "  const analyser = context.createAnalyser ? context.createAnalyser() : null;\n",
    "  if (analyser) {\n",
    "    master.connect(analyser);\n",
    "    analyser.connect(context.destination);\n",
    "  } else {\n",
    "    master.connect(context.destination);\n",
    "  }\n",
    "  const channels = new Map();\n",
    "  let impulse = null;\n",
    "  function channel(n) {\n",
    "    let ch = channels.get(n);\n",
    "    if (ch) return ch;\n",
    "    const input = context.createGain();\n",
    "    const panner = context.createStereoPanner ? context.createStereoPanner() : null;\n",
    "    const filter = context.createBiquadFilter();\n",
    "    filter.type = \"lowpass\";\n",
    "    filter.frequency.value = 22050;\n",
    "    const out = context.createGain();\n",
    "    if (panner) input.connect(panner).connect(filter);\n",
    "    else input.connect(filter);\n",
    "    filter.connect(out);\n",
    "    out.connect(master);\n",
    "    const delay = context.createDelay(5);\n",
    "    const feedback = context.createGain();\n",
    "    const echo = context.createGain();\n",
    "    echo.gain.value = 0;\n",
    "    out.connect(echo);\n",
    "    echo.connect(delay);\n",
    "    delay.connect(feedback);\n",
    "    feedback.connect(delay);\n",
    "    delay.connect(master);\n",
    "    const reverb = context.createGain();\n",
    "    reverb.gain.value = 0;\n",
    "    let convolver = null;\n",
    "    ch = { input, panner, filter, out, delay, feedback, echo, reverb, convolver };\n",
    "    channels.set(n, ch);\n",
    "    return ch;\n",
    "  }\n",
    "  function style(n, settings) {\n",
    "    const ch = channel(n);\n",
    "    ch.out.gain.value = settings.volume;\n",
    "    if (ch.panner) ch.panner.pan.value = Math.max(-1, Math.min(1, settings.pan));\n",
    "    ch.filter.frequency.value = settings.lowPass > 0 ? settings.lowPass : 22050;\n",
    "    ch.echo.gain.value = settings.echo;\n",
    "    ch.delay.delayTime.value = Math.max(0.001, Math.min(5, settings.echoTime));\n",
    "    ch.feedback.gain.value = Math.max(0, Math.min(0.95, settings.feedback));\n",
    "    if (settings.reverb > 0 && ch.convolver === null && context.createConvolver) {\n",
    "      if (impulse === null) impulse = impulseOf(context);\n",
    "      ch.convolver = context.createConvolver();\n",
    "      ch.convolver.buffer = impulse;\n",
    "      ch.out.connect(ch.reverb);\n",
    "      ch.reverb.connect(ch.convolver);\n",
    "      ch.convolver.connect(master);\n",
    "    }\n",
    "    ch.reverb.gain.value = settings.reverb;\n",
    "  }\n",
    "  return { context, master, analyser, channel, style };\n",
    "}\n",
    "\n",
    "// A WAV file of a rendered buffer, 16 bits, as bytes. AudioBuffer -> Uint8Array\n",
    "function wavBytes(buffer) {\n",
    "  const channels = buffer.numberOfChannels;\n",
    "  const frames = buffer.length;\n",
    "  const bytes = new Uint8Array(44 + frames * channels * 2);\n",
    "  const view = new DataView(bytes.buffer);\n",
    "  const text = (at, s) => { for (let i = 0; i < s.length; i++) bytes[at + i] = s.charCodeAt(i); };\n",
    "  text(0, \"RIFF\");\n",
    "  view.setUint32(4, 36 + frames * channels * 2, true);\n",
    "  text(8, \"WAVEfmt \");\n",
    "  view.setUint32(16, 16, true);\n",
    "  view.setUint16(20, 1, true);\n",
    "  view.setUint16(22, channels, true);\n",
    "  view.setUint32(24, buffer.sampleRate, true);\n",
    "  view.setUint32(28, buffer.sampleRate * channels * 2, true);\n",
    "  view.setUint16(32, channels * 2, true);\n",
    "  view.setUint16(34, 16, true);\n",
    "  text(36, \"data\");\n",
    "  view.setUint32(40, frames * channels * 2, true);\n",
    "  const data = [];\n",
    "  for (let k = 0; k < channels; k++) data.push(buffer.getChannelData(k));\n",
    "  let at = 44;\n",
    "  for (let i = 0; i < frames; i++) {\n",
    "    for (let k = 0; k < channels; k++) {\n",
    "      const v = Math.max(-1, Math.min(1, data[k][i]));\n",
    "      view.setInt16(at, v < 0 ? v * 0x8000 : v * 0x7fff, true);\n",
    "      at += 2;\n",
    "    }\n",
    "  }\n",
    "  return bytes;\n",
    "}\n",
    "\n",
    "// Offers `blob` to the reader as a file called `name`. Blob -> String -> ()\n",
    "function offerDownload(blob, name) {\n",
    "  const link = document.createElement(\"a\");\n",
    "  link.href = URL.createObjectURL(blob);\n",
    "  link.download = name;\n",
    "  link.style.display = \"none\";\n",
    "  document.body.appendChild(link);\n",
    "  link.click();\n",
    "  link.remove();\n",
    "  setTimeout(() => URL.revokeObjectURL(link.href), 10000);\n",
    "}\n",
    "\n",
    "function makeEngine(host) {\n",
    "  let graph = null;              // the live context's sound graph\n",
    "  const settings = new Map();    // channel -> its settings, for every graph\n",
    "  let masterVolume = 1;\n",
    "  const voices = new Map();      // voice -> {source, gain}\n",
    "  const sounding = new Set();    // every source started and not yet ended\n",
    "  // The beat: tempo and swing, and where the beat was at some time, so a\n",
    "  // change of tempo goes on from where the beat is.\n",
    "  let bpm = 120;\n",
    "  let swingAmount = 0;\n",
    "  let anchor = null;             // {time, beat}\n",
    "  const beats = new Map();       // watcher -> {steps, next}\n",
    "  const timers = new Map();      // timer -> {at, every}\n",
    "  let ticker = 0;\n",
    "  let frozen = null;             // the clock, while the program has paused it\n",
    "  let listening = null;          // {bins, smoothing}\n",
    "  let rendering = null;          // {id, name, seconds, commands}\n",
    "  let closed = false;\n",
    "\n",
    "  function live() {\n",
    "    const context = host.audio();\n",
    "    if (!context) return null;\n",
    "    if (graph === null || graph.context !== context) {\n",
    "      graph = soundGraph(context);\n",
    "      graph.master.gain.value = masterVolume;\n",
    "      for (const [n, s] of settings) graph.style(n, s);\n",
    "      if (listening) listen(listening.bins, listening.smoothing);\n",
    "    }\n",
    "    return graph;\n",
    "  }\n",
    "\n",
    "  function beatAt(t) {\n",
    "    return anchor === null ? 0 : anchor.beat + ((t - anchor.time) * bpm) / 60;\n",
    "  }\n",
    "\n",
    "  // When step `k` of a beat cut into `steps` steps sounds. Int -> Int -> Float\n",
    "  function stepTime(k, steps) {\n",
    "    const at = anchor.time + ((k / steps - anchor.beat) * 60) / bpm;\n",
    "    return k % 2 === 1 ? at + (swingAmount * 60) / bpm / steps : at;\n",
    "  }\n",
    "\n",
    "  function tick() {\n",
    "    if (closed) return;\n",
    "    const t = host.clock();\n",
    "    if (frozen !== null) return;\n",
    "    for (const [id, timer] of [...timers]) {\n",
    "      if (t + 0.0005 < timer.at) continue;\n",
    "      if (timer.every > 0) {\n",
    "        while (timer.at <= t + 0.0005) timer.at += timer.every;\n",
    "      } else {\n",
    "        timers.delete(id);\n",
    "      }\n",
    "      host.send({ ev: \"cb\", id, kind: \"timer\" });\n",
    "    }\n",
    "    for (const [id, watcher] of beats) {\n",
    "      for (let guard = 0; guard < 64; guard++) {\n",
    "        const at = stepTime(watcher.next, watcher.steps);\n",
    "        if (at > t + LOOKAHEAD) break;\n",
    "        host.send({ ev: \"cb\", id, kind: \"beat\",\n",
    "          reports: { beat: [watcher.next, Math.max(at, t), beatAt(t)] } });\n",
    "        watcher.next += 1;\n",
    "      }\n",
    "    }\n",
    "    if (timers.size === 0 && beats.size === 0) {\n",
    "      clearInterval(ticker);\n",
    "      ticker = 0;\n",
    "    }\n",
    "  }\n",
    "\n",
    "  function ticking() {\n",
    "    if (ticker === 0 && !closed) ticker = setInterval(tick, TICK_MS);\n",
    "  }\n",
    "\n",
    "  // Starts one sound on `g`'s context: a sample (`play` and `start`) or a\n",
    "  // tone, at `at` on that context's clock. Answers its source.\n",
    "  function sound(g, kind, sample, buffer, n, toTime) {\n",
    "    const context = g.context;\n",
    "    if (kind === \"tone\") {\n",
    "      const [frequency, at, duration, volume, pan, channel] = n;\n",
    "      const when = Math.max(context.currentTime, toTime(at));\n",
    "      const length = Math.max(0.02, duration);\n",
    "      const oscillator = context.createOscillator();\n",
    "      oscillator.type = [\"sine\", \"square\", \"triangle\", \"sawtooth\"].includes(sample) ? sample : \"sine\";\n",
    "      oscillator.frequency.value = frequency;\n",
    "      const gain = context.createGain();\n",
    "      const attack = Math.min(0.01, length / 4);\n",
    "      const release = Math.min(0.05, length / 4);\n",
    "      gain.gain.setValueAtTime(0, when);\n",
    "      gain.gain.linearRampToValueAtTime(volume, when + attack);\n",
    "      gain.gain.setValueAtTime(volume, when + length - release);\n",
    "      gain.gain.linearRampToValueAtTime(0, when + length);\n",
    "      const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;\n",
    "      if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));\n",
    "      oscillator.connect(gain);\n",
    "      (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);\n",
    "      oscillator.start(when);\n",
    "      oscillator.stop(when + length + 0.01);\n",
    "      return { source: oscillator, gain };\n",
    "    }\n",
    "    const [at, volume, rate, pan, channel, reverse, loop] = n;\n",
    "    const source = context.createBufferSource();\n",
    "    source.buffer = reverse ? reversedOf(context, buffer) : buffer;\n",
    "    source.playbackRate.value = rate > 0 ? rate : 1;\n",
    "    source.loop = !!loop;\n",
    "    const gain = context.createGain();\n",
    "    gain.gain.value = volume;\n",
    "    const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;\n",
    "    if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));\n",
    "    source.connect(gain);\n",
    "    (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);\n",
    "    source.start(Math.max(context.currentTime, toTime(at)));\n",
    "    return { source, gain };\n",
    "  }\n",
    "\n",
    "  // A sound command on the live context.\n",
    "  function playLive(cmd) {\n",
    "    const n = engineNumbers(cmd.numbers);\n",
    "    if (cmd.kind === \"tone\") {\n",
    "      host.startAudio();\n",
    "      const g = live();\n",
    "      if (!g) return;\n",
    "      const made = sound(g, \"tone\", cmd.text, null, n, host.toAudio);\n",
    "      sounding.add(made.source);\n",
    "      made.source.onended = () => sounding.delete(made.source);\n",
    "      return;\n",
    "    }\n",
    "    const sample = cmd.kind === \"play\" ? cmd.id : cmd.text;\n",
    "    host.startAudio();\n",
    "    const loading = host.sample(sample);\n",
    "    if (!loading) return;\n",
    "    const voice = cmd.kind === \"start\" ? cmd.id : null;\n",
    "    if (voice !== null) voices.set(voice, { source: null, gain: null, stopped: null });\n",
    "    loading.then((buffer) => {\n",
    "      const g = live();\n",
    "      if (buffer === null || closed || !g) return;\n",
    "      const entry = voice === null ? null : voices.get(voice);\n",
    "      if (entry && entry.stopped !== null && entry.stopped <= host.clock()) return;\n",
    "      const made = sound(g, \"sample\", sample, buffer, n, host.toAudio);\n",
    "      sounding.add(made.source);\n",
    "      made.source.onended = () => {\n",
    "        sounding.delete(made.source);\n",
    "        if (voice !== null && voices.get(voice)?.source === made.source) voices.delete(voice);\n",
    "      };\n",
    "      if (entry) {\n",
    "        entry.source = made.source;\n",
    "        entry.gain = made.gain;\n",
    "        if (entry.stopped !== null) made.source.stop(Math.max(g.context.currentTime, host.toAudio(entry.stopped)));\n",
    "        if (entry.fade) fadeVoice(entry, ...entry.fade);\n",
    "      }\n",
    "    });\n",
    "  }\n",
    "\n",
    "  function fadeVoice(entry, volume, over) {\n",
    "    const g = live();\n",
    "    if (!g || entry.gain === null) {\n",
    "      entry.fade = [volume, over];\n",
    "      return;\n",
    "    }\n",
    "    const now = g.context.currentTime;\n",
    "    const param = entry.gain.gain;\n",
    "    param.cancelScheduledValues(now);\n",
    "    param.setValueAtTime(param.value, now);\n",
    "    if (over > 0) param.linearRampToValueAtTime(volume, now + over);\n",
    "    else param.setValueAtTime(volume, now);\n",
    "  }\n",
    "\n",
    "  function stopAll() {\n",
    "    const g = live();\n",
    "    for (const source of sounding) {\n",
    "      try {\n",
    "        source.stop(g ? g.context.currentTime : 0);\n",
    "      } catch {\n",
    "        // already stopped\n",
    "      }\n",
    "    }\n",
    "    sounding.clear();\n",
    "    for (const entry of voices.values()) entry.stopped = -Infinity;\n",
    "    voices.clear();\n",
    "  }\n",
    "\n",
    "  function listen(bins, smoothing) {\n",
    "    listening = { bins, smoothing };\n",
    "    const g = graph;\n",
    "    if (!g || !g.analyser) return;\n",
    "    let size = 32;\n",
    "    while (size < bins * 2 && size < 32768) size *= 2;\n",
    "    g.analyser.fftSize = size;\n",
    "    g.analyser.smoothingTimeConstant = Math.max(0, Math.min(0.99, smoothing));\n",
    "  }\n",
    "\n",
    "  // What the page reports with an event: where the beat is, how late\n",
    "  // sound comes out, whether it is running; and with a frame, what the\n",
    "  // program listens to. Bool -> {..}\n",
    "  // The analyser's arrays, kept from frame to frame.\n",
    "  const scratch = { spectrum: new Uint8Array(0), samples: new Float32Array(0) };\n",
    "\n",
    "  function reports(withSound) {\n",
    "    const context = host.audio();\n",
    "    const t = host.clock();\n",
    "    const latency = context ? (context.outputLatency || 0) + (context.baseLatency || 0) : 0;\n",
    "    const out = { clock: [beatAt(t), latency, context && context.state === \"running\" ? 1 : 0] };\n",
    "    if (withSound && listening !== null) {\n",
    "      const g = live();\n",
    "      const bins = listening.bins;\n",
    "      const level = [0];\n",
    "      const band = new Array(bins).fill(0);\n",
    "      const wave = new Array(bins).fill(0);\n",
    "      if (g && g.analyser && g.analyser.getByteFrequencyData) {\n",
    "        const a = g.analyser;\n",
    "        if (scratch.spectrum.length !== a.frequencyBinCount) {\n",
    "          scratch.spectrum = new Uint8Array(a.frequencyBinCount);\n",
    "          scratch.samples = new Float32Array(a.fftSize);\n",
    "        }\n",
    "        const spectrum = scratch.spectrum;\n",
    "        a.getByteFrequencyData(spectrum);\n",
    "        const per = spectrum.length / bins;\n",
    "        for (let k = 0; k < bins; k++) {\n",
    "          let peak = 0;\n",
    "          for (let i = Math.floor(k * per); i < Math.max(Math.floor((k + 1) * per), Math.floor(k * per) + 1); i++) {\n",
    "            peak = Math.max(peak, spectrum[Math.min(i, spectrum.length - 1)]);\n",
    "          }\n",
    "          band[k] = Math.round((peak / 255) * 1000) / 1000;\n",
    "        }\n",
    "        const samples = scratch.samples;\n",
    "        a.getFloatTimeDomainData(samples);\n",
    "        let sum = 0;\n",
    "        for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];\n",
    "        level[0] = Math.round(Math.min(1, Math.sqrt(sum / samples.length) * Math.SQRT2) * 1000) / 1000;\n",
    "        const step = samples.length / bins;\n",
    "        for (let k = 0; k < bins; k++) wave[k] = Math.round(samples[Math.floor(k * step)] * 1000) / 1000;\n",
    "      }\n",
    "      out.level = level;\n",
    "      out.band = band;\n",
    "      out.wave = wave;\n",
    "    }\n",
    "    return out;\n",
    "  }\n",
    "\n",
    "  // Renders what was scheduled between `render` and `render_end` offline,\n",
    "  // offers it as a WAV file and reports how long that took and how loud\n",
    "  // its loudest sample is.\n",
    "  function finishRender(job) {\n",
    "    const Offline = globalThis.OfflineAudioContext;\n",
    "    const done = (took, peak) =>\n",
    "      host.send({ ev: \"cb\", id: job.id, kind: \"rendered\", reports: { rendered: [took, peak] } });\n",
    "    if (!Offline) {\n",
    "      done(0, 0);\n",
    "      return;\n",
    "    }\n",
    "    const rate = 44100;\n",
    "    const context = new Offline(2, Math.max(1, Math.ceil(job.seconds * rate)), rate);\n",
    "    const g = soundGraph(context);\n",
    "    g.master.gain.value = masterVolume;\n",
    "    for (const [n, s] of settings) g.style(n, s);\n",
    "    const wanted = job.commands.filter((c) => c.kind !== \"tone\")\n",
    "      .map((c) => host.sample(c.kind === \"play\" ? c.id : c.text) || Promise.resolve(null));\n",
    "    Promise.all(wanted).then((buffers) => {\n",
    "      let b = 0;\n",
    "      for (const c of job.commands) {\n",
    "        const n = engineNumbers(c.numbers);\n",
    "        if (c.kind === \"tone\") {\n",
    "          sound(g, \"tone\", c.text, null, n, (t) => t);\n",
    "        } else {\n",
    "          const buffer = buffers[b++];\n",
    "          if (buffer) sound(g, \"sample\", null, buffer, n, (t) => t);\n",
    "        }\n",
    "      }\n",
    "      const started = typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
    "      return context.startRendering().then((buffer) => {\n",
    "        const took = ((typeof performance !== \"undefined\" ? performance.now() : Date.now()) - started) / 1000;\n",
    "        let peak = 0;\n",
    "        for (let k = 0; k < buffer.numberOfChannels; k++) {\n",
    "          const data = buffer.getChannelData(k);\n",
    "          for (let i = 0; i < data.length; i++) peak = Math.max(peak, Math.abs(data[i]));\n",
    "        }\n",
    "        offerDownload(new Blob([wavBytes(buffer)], { type: \"audio/wav\" }), job.name);\n",
    "        done(Math.round(took * 1000) / 1000, Math.round(peak * 1000) / 1000);\n",
    "      });\n",
    "    }).catch((error) => {\n",
    "      console.error(`tinyweb: rendering ${job.name} failed: ${error.message}`);\n",
    "      done(0, 0);\n",
    "    });\n",
    "  }\n",
    "\n",
    "  // An element whose `display` the program sets: a slider's row, not\n",
    "  // its input.\n",
    "  function shown(element) {\n",
    "    return element.tagName === \"INPUT\" && element.type === \"range\" ? element.parentNode : element;\n",
    "  }\n",
    "\n",
    "  function value(id, text) {\n",
    "    host.send({ ev: \"report\", reports: { [\"value.\" + id]: String(text) } });\n",
    "  }\n",
    "\n",
    "  function command(cmd) {\n",
    "    const n = engineNumbers(cmd.numbers);\n",
    "    if (rendering !== null && [\"play\", \"start\", \"tone\"].includes(cmd.kind)) {\n",
    "      rendering.commands.push(cmd);\n",
    "      return;\n",
    "    }\n",
    "    switch (cmd.kind) {\n",
    "      // --- sound ---\n",
    "      case \"play\":\n",
    "      case \"start\":\n",
    "      case \"tone\":\n",
    "        playLive(cmd);\n",
    "        break;\n",
    "      case \"stop\": {\n",
    "        const entry = voices.get(cmd.id);\n",
    "        if (!entry) break;\n",
    "        const at = n[0] || 0;\n",
    "        entry.stopped = at;\n",
    "        const g = live();\n",
    "        if (entry.source && g) entry.source.stop(Math.max(g.context.currentTime, host.toAudio(at)));\n",
    "        break;\n",
    "      }\n",
    "      case \"fade\": {\n",
    "        const entry = voices.get(cmd.id);\n",
    "        if (entry) fadeVoice(entry, n[0] ?\? 0, n[1] ?\? 0);\n",
    "        break;\n",
    "      }\n",
    "      case \"stop_all\":\n",
    "        stopAll();\n",
    "        break;\n",
    "      case \"master\": {\n",
    "        masterVolume = n[0] ?\? 1;\n",
    "        const g = live();\n",
    "        if (g) g.master.gain.value = masterVolume;\n",
    "        break;\n",
    "      }\n",
    "      case \"channel\": {\n",
    "        const ch = Number(cmd.id) || 0;\n",
    "        const s = { volume: n[0] ?\? 1, pan: n[1] ?\? 0, echo: n[2] ?\? 0, echoTime: n[3] ?\? 0.3,\n",
    "          feedback: n[4] ?\? 0.35, reverb: n[5] ?\? 0, lowPass: n[6] ?\? 0 };\n",
    "        settings.set(ch, s);\n",
    "        const g = live();\n",
    "        if (g) g.style(ch, s);\n",
    "        break;\n",
    "      }\n",
    "      case \"listen\":\n",
    "        listen(Math.max(1, Math.min(1024, Math.round(n[0] || 32))), n[1] ?\? 0.8);\n",
    "        live();\n",
    "        break;\n",
    "      case \"tempo\": {\n",
    "        const t = host.clock();\n",
    "        anchor = anchor === null ? null : { time: t, beat: beatAt(t) };\n",
    "        bpm = Math.max(1, n[0] || 120);\n",
    "        break;\n",
    "      }\n",
    "      case \"swing\":\n",
    "        swingAmount = Math.max(0, Math.min(0.9, n[0] || 0));\n",
    "        break;\n",
    "      case \"beat\": {\n",
    "        const t = host.clock();\n",
    "        const steps = Math.max(1, Math.round(n[0] || 1));\n",
    "        if (anchor === null) anchor = { time: t + 0.05, beat: 0 };\n",
    "        // The first step not yet passed, from where the beat is.\n",
    "        // `+ 0` makes a -0 at the very start a 0: a step is a whole number.\n",
    "        let next = Math.ceil(beatAt(t) * steps - 1e-9) + 0;\n",
    "        while (stepTime(next, steps) < t) next += 1;\n",
    "        beats.set(cmd.id, { steps, next });\n",
    "        ticking();\n",
    "        break;\n",
    "      }\n",
    "      case \"beat_stop\":\n",
    "        beats.delete(cmd.id);\n",
    "        break;\n",
    "      case \"audio\": {\n",
    "        const context = host.audio();\n",
    "        if (cmd.text === \"pause\" && frozen === null) {\n",
    "          frozen = host.clock();\n",
    "          if (context && context.state === \"running\") context.suspend();\n",
    "        } else if (cmd.text === \"resume\" && frozen !== null) {\n",
    "          const at = frozen;\n",
    "          if (context) {\n",
    "            context.resume().then(() => {\n",
    "              host.thaw(at);\n",
    "              frozen = null;\n",
    "            });\n",
    "          } else {\n",
    "            host.thaw(at);\n",
    "            frozen = null;\n",
    "          }\n",
    "        }\n",
    "        break;\n",
    "      }\n",
    "      case \"render\":\n",
    "        rendering = { id: cmd.id, name: cmd.text, seconds: n[0] || 1, commands: [] };\n",
    "        break;\n",
    "      case \"render_end\":\n",
    "        if (rendering !== null) {\n",
    "          const job = rendering;\n",
    "          rendering = null;\n",
    "          finishRender(job);\n",
    "        }\n",
    "        break;\n",
    "      // --- timers ---\n",
    "      case \"after\":\n",
    "      case \"every\": {\n",
    "        const seconds = Math.max(0, n[0] || 0);\n",
    "        timers.set(cmd.id, { at: host.clock() + seconds, every: cmd.kind === \"every\" ? Math.max(0.001, seconds) : 0 });\n",
    "        ticking();\n",
    "        break;\n",
    "      }\n",
    "      case \"cancel\":\n",
    "        timers.delete(cmd.id);\n",
    "        beats.delete(cmd.id);\n",
    "        break;\n",
    "      // --- changing what is on the page ---\n",
    "      case \"set_text\": {\n",
    "        const element = host.element(cmd.id);\n",
    "        if (!element) break;\n",
    "        if (element.tagName === \"INPUT\" || element.tagName === \"TEXTAREA\") element.value = cmd.text;\n",
    "        else element.textContent = cmd.text;\n",
    "        break;\n",
    "      }\n",
    "      case \"visible\": {\n",
    "        const element = host.element(cmd.id);\n",
    "        if (element) shown(element).style.display = n[0] ? \"\" : \"none\";\n",
    "        break;\n",
    "      }\n",
    "      case \"enabled\": {\n",
    "        const element = host.element(cmd.id);\n",
    "        if (element) element.disabled = !n[0];\n",
    "        break;\n",
    "      }\n",
    "      case \"remove\": {\n",
    "        const element = host.element(cmd.id);\n",
    "        if (element) shown(element).remove();\n",
    "        host.forget(cmd.id);\n",
    "        break;\n",
    "      }\n",
    "      case \"text_area\": {\n",
    "        const area = document.createElement(\"textarea\");\n",
    "        area.setAttribute(\"data-tinyweb-id\", String(cmd.id));\n",
    "        area.value = cmd.text;\n",
    "        area.rows = Math.max(1, Math.round(n[0] || 4));\n",
    "        area.cols = Math.max(1, Math.round(n[1] || 40));\n",
    "        area.addEventListener(\"input\", () => {\n",
    "          host.send({ ev: \"cb\", id: cmd.id, kind: \"change\", reports: { [\"value.\" + cmd.id]: area.value } });\n",
    "        });\n",
    "        host.remember(cmd.id, area);\n",
    "        host.place(area);\n",
    "        break;\n",
    "      }\n",
    "      case \"file_button\": {\n",
    "        const button = document.createElement(\"button\");\n",
    "        button.setAttribute(\"data-tinyweb-id\", String(cmd.id));\n",
    "        button.textContent = cmd.text;\n",
    "        const input = document.createElement(\"input\");\n",
    "        input.type = \"file\";\n",
    "        input.style.display = \"none\";\n",
    "        button.addEventListener(\"click\", () => {\n",
    "          host.startAudio();\n",
    "          input.click();\n",
    "        });\n",
    "        // The input is inside the button: its own click is not the button's.\n",
    "        input.addEventListener(\"click\", (event) => event.stopPropagation());\n",
    "        input.addEventListener(\"change\", () => {\n",
    "          const file = input.files && input.files[0];\n",
    "          if (!file) return;\n",
    "          file.arrayBuffer().then((bytes) => {\n",
    "            if (/^audio\\//.test(file.type) || /\\.(wav|mp3|ogg|m4a|flac|aac)$/i.test(file.name)) {\n",
    "              const decoder = new OfflineAudioContext(1, 1, 44100);\n",
    "              const loading = decoder.decodeAudioData(bytes).catch(() => null);\n",
    "              host.addSample(cmd.id, loading);\n",
    "              loading.then(() => host.send({ ev: \"cb\", id: cmd.id, kind: \"loaded\",\n",
    "                reports: { file: file.name, [\"file.text\"]: \"\" } }));\n",
    "            } else {\n",
    "              const text = new TextDecoder().decode(bytes);\n",
    "              host.send({ ev: \"cb\", id: cmd.id, kind: \"loaded\", reports: { file: file.name, [\"file.text\"]: text } });\n",
    "            }\n",
    "          });\n",
    "        });\n",
    "        host.remember(cmd.id, button);\n",
    "        host.place(button);\n",
    "        button.appendChild(input);\n",
    "        break;\n",
    "      }\n",
    "      case \"cursor\": {\n",
    "        const target = cmd.id === \"\" ? document.body : host.canvas(cmd.id)?.element;\n",
    "        if (target) target.style.cursor = cmd.text || \"auto\";\n",
    "        break;\n",
    "      }\n",
    "      case \"save_canvas\": {\n",
    "        const entry = host.canvas(cmd.id);\n",
    "        if (!entry || !entry.element.toBlob) break;\n",
    "        const out = document.createElement(\"canvas\");\n",
    "        out.width = entry.width;\n",
    "        out.height = entry.height;\n",
    "        const g = out.getContext(\"2d\");\n",
    "        g.fillStyle = \"#ffffff\";\n",
    "        g.fillRect(0, 0, out.width, out.height);\n",
    "        g.drawImage(entry.element, 0, 0, out.width, out.height);\n",
    "        out.toBlob((blob) => { if (blob) offerDownload(blob, cmd.text); }, \"image/png\");\n",
    "        break;\n",
    "      }\n",
    "      case \"download\":\n",
    "        offerDownload(new Blob([cmd.text], { type: \"text/plain\" }), cmd.id);\n",
    "        break;\n",
    "    }\n",
    "  }\n",
    "\n",
    "  return {\n",
    "    command,\n",
    "    reports,\n",
    "    value,\n",
    "    // The clock while the program has paused it, or null.\n",
    "    frozen: () => frozen,\n",
    "    // Whether a command needs sound, which may need the splash screen first.\n",
    "    sounds: (cmd) => [\"play\", \"start\", \"tone\"].includes(cmd.kind),\n",
    "    close() {\n",
    "      closed = true;\n",
    "      clearInterval(ticker);\n",
    "      ticker = 0;\n",
    "      stopAll();\n",
    "    },\n",
    "  };\n",
    "}\n",
    "// END tinyweb style\n",
    "\n",
    "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n",
    "// `receive(commands)` carries out a batch of commands, and `send(event)`\n",
    "// is how the page reports one. `standalone` is true where the page is\n",
    "// the whole document, which is where a key press is listened for; a\n",
    "// page inside another (a notebook cell) listens on `element`, which\n",
    "// takes the focus when clicked. `activated` is true where the reader\n",
    "// started the program with a click or a key, as in the playground and\n",
    "// a notebook, and the page then never shows the splash screen.\n",
    "// `silent` is true where the page is only a picture of what a program\n",
    "// drew -- a notebook's result diff -- and never makes a sound.\n",
    "export function mountPage(element, sendEvent,\n",
    "                          { standalone = false, activated = false, silent = false } = {}) {\n",
    "  const box = document.createElement(\"div\");\n",
    "  box.className = \"tinyweb-page\";\n",
    "  box.style.cssText =\n",
    "    \"display:flex;flex-direction:column;align-items:flex-start;outline:none\";\n",
    "  element.appendChild(box);\n",
    "  const look = styled(element, box);\n",
    "\n",
    "  const canvases = new Map();\n",
    "  const labels = new Map();\n",
    "  const samples = new Map();\n",
    "  const pictures = new Map();\n",
    "  // What `set_checked` and `set_value` change, by identifier, and each\n",
    "  // group of radio buttons.\n",
    "  const checks = new Map();\n",
    "  const values = new Map();\n",
    "  const groups = new Map();\n",
    "  const bitmaps = new Map();\n",
    "  // Where an element made now goes: the page, or a row it was put inside.\n",
    "  const rows = new Map();\n",
    "  let parent = box;\n",
    "  // The keys held down, reported again as released when the page loses\n",
    "  // the focus.\n",
    "  const heldKeys = new Set();\n",
    "  let start = now();\n",
    "  let audio = null;\n",
    "  let offset = 0;\n",
    "  let frameWanted = false;\n",
    "  let frameWaiting = false;\n",
    "  let frameRequest = 0;\n",
    "  let closed = false;\n",
    "  // Sound, the beat, timers and page changes (the `cmd` commands).\n",
    "  let engine = null;\n",
    "  // Inside another page the keys go to the element the page is mounted\n",
    "  // in, which takes the focus when anything in it is clicked; that page\n",
    "  // shows the focus (:focus-within).\n",
    "  const keyTarget = standalone ? window : element;\n",
    "  let keysWanted = false;\n",
    "  // The splash screen: what it says, whether it has been shown (or is\n",
    "  // not needed), and while it is shown the element, the commands held\n",
    "  // until it is dismissed, and the clock where it stopped.\n",
    "  let splashText = SPLASH_TEXT;\n",
    "  let splashDone = activated;\n",
    "  let splash = null;\n",
    "  let held = null;\n",
    "  let heldClock = 0;\n",
    "  let heldAt = 0;\n",
    "  // The picture the held commands wait for, and the events the reader\n",
    "  // caused while they waited for it.\n",
    "  let waitingFor = null;\n",
    "  let deferred = [];\n",
    "  // tinyweb's `sdelay`: where the last one ends on the page's clock (null\n",
    "  // before the first), the one to answer and when, and once it is\n",
    "  // answered, what the program does next that is not a sound, held until\n",
    "  // the end -- a sound is started at the end instead (`timed`). The\n",
    "  // interval looks at the clock while one of them waits.\n",
    "  let sdelayEnd = null;\n",
    "  let answering = null;\n",
    "  let paced = null;\n",
    "  let pacer = 0;\n",
    "\n",
    "  let focusable = false;    // whether mounting made `element` focusable\n",
    "\n",
    "  function takeFocus(event) {\n",
    "    // A slider keeps the focus for its arrow keys.\n",
    "    if (!event.target.closest(\"input\")) element.focus({ preventScroll: true });\n",
    "  }\n",
    "\n",
    "  if (!standalone) {\n",
    "    focusable = element.tabIndex < 0;\n",
    "    if (focusable) element.tabIndex = 0;\n",
    "    element.addEventListener(\"click\", takeFocus);\n",
    "  }\n",
    "\n",
    "  // The page's clock: the audio clock once sound has started, and until\n",
    "  // then the seconds since the page was mounted. `offset` joins the two,\n",
    "  // so the clock never goes back.\n",
    "  function running() {\n",
    "    return audio !== null && audio.state === \"running\";\n",
    "  }\n",
    "\n",
    "  function clockNow() {\n",
    "    if (held !== null) return heldClock;\n",
    "    const paused = engine === null ? null : engine.frozen();\n",
    "    if (paused !== null) return paused;\n",
    "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
    "  }\n",
    "\n",
    "  // Every event carries where the beat is and how late sound comes out,\n",
    "  // and a frame what the program listens to.\n",
    "  function report(event) {\n",
    "    if (closed) return;\n",
    "    if (held !== null) {\n",
    "      if (splash === null) deferred.push(event);\n",
    "      return;\n",
    "    }\n",
    "    const reports = { ...engine.reports(event.ev === \"frame\"), ...(event.reports || {}) };\n",
    "    sendEvent({ ...event, t: clockNow(), running: running(), reports });\n",
    "  }\n",
    "\n",
    "  // Whether a sound now would need the splash screen first.\n",
    "  function splashWanted() {\n",
    "    return !splashDone && splashText !== \"\" && !running() && !readerActive();\n",
    "  }\n",
    "\n",
    "  // Shows the splash screen and holds what comes after it: the commands,\n",
    "  // the frames and the clock.\n",
    "  function showSplash() {\n",
    "    splashDone = true;\n",
    "    heldClock = clockNow();\n",
    "    heldAt = now();\n",
    "    held = [];\n",
    "    splash = splashScreen(splashText);\n",
    "    splash.addEventListener(\"click\", dismissSplash);\n",
    "    window.addEventListener(\"keydown\", dismissSplash, true);\n",
    "    document.body.appendChild(splash);\n",
    "  }\n",
    "\n",
    "  // The reader's click or key: the splash screen goes, sound starts, the\n",
    "  // clock goes on from where it stopped, and what was held is carried out.\n",
    "  function dismissSplash(event) {\n",
    "    if (splash === null) return;\n",
    "    event?.preventDefault?.();\n",
    "    event?.stopImmediatePropagation?.();\n",
    "    window.removeEventListener(\"keydown\", dismissSplash, true);\n",
    "    splash.remove();\n",
    "    splash = null;\n",
    "    startAudio();\n",
    "    release();\n",
    "  }\n",
    "\n",
    "  // Holds what comes after a picture still loading, until it has loaded\n",
    "  // or failed: the commands, the frames, the events and the clock.\n",
    "  // Picture -> ()\n",
    "  function waitFor(picture) {\n",
    "    if (held === null) {\n",
    "      heldClock = clockNow();\n",
    "      heldAt = now();\n",
    "      held = [];\n",
    "    }\n",
    "    waitingFor = picture;\n",
    "    picture.settled.push(() => {\n",
    "      waitingFor = null;\n",
    "      release();\n",
    "    });\n",
    "  }\n",
    "\n",
    "  // Carries out what was held once nothing holds it any more, then sends\n",
    "  // the events that waited with it. ()\n",
    "  function release() {\n",
    "    if (held === null || splash !== null || waitingFor !== null) return;\n",
    "    start += now() - heldAt;\n",
    "    const pending = held;\n",
    "    held = null;\n",
    "    for (const command of pending) take(command);\n",
    "    if (held !== null) return;\n",
    "    const events = deferred;\n",
    "    deferred = [];\n",
    "    for (const event of events) report(event);\n",
    "  }\n",
    "\n",
    "  // Carries out a command, or holds it while something holds the page,\n",
    "  // or until the `sdelay` before it has ended. Command -> ()\n",
    "  function take(command) {\n",
    "    if (held !== null) held.push(command);\n",
    "    else if (paced !== null && !sound(command)) paced.push(command);\n",
    "    else carryOut(paced !== null ? timed(command) : command);\n",
    "  }\n",
    "\n",
    "  // `sdelay seconds`, reached in the program's order: it ends `seconds`\n",
    "  // after the last one ended -- or after now, for the first, and where\n",
    "  // that end has passed already, so a program that fell behind starts\n",
    "  // again from now rather than catching up. The program waits until the\n",
    "  // page answers it. Command -> ()\n",
    "  function sdelay(command) {\n",
    "    const t = clockNow();\n",
    "    const seconds = Math.max(0, Number(command.seconds) || 0);\n",
    "    sdelayEnd = sdelayEnd === null ? t + seconds : Math.max(sdelayEnd + seconds, t);\n",
    "    answering = { id: command.id, at: sdelayEnd - SDELAY_LEAD };\n",
    "    pace();\n",
    "  }\n",
    "\n",
    "  // Looks at the clock for the `sdelay` waiting: answers it a little\n",
    "  // before its end, and carries out what was held after it once the end\n",
    "  // has come. ()\n",
    "  function pace() {\n",
    "    if (closed) return;\n",
    "    const t = clockNow();\n",
    "    if (answering !== null && t >= answering.at) {\n",
    "      const { id } = answering;\n",
    "      answering = null;\n",
    "      if (paced === null) paced = [];\n",
    "      report({ ev: \"sdelay\", id });\n",
    "    }\n",
    "    if (paced !== null && answering === null && t >= sdelayEnd) {\n",
    "      const pending = paced;\n",
    "      paced = null;\n",
    "      for (const command of pending) take(command);\n",
    "    }\n",
    "    const needed = answering !== null || paced !== null;\n",
    "    if (needed && pacer === 0) pacer = setInterval(pace, SDELAY_TICK_MS);\n",
    "    else if (!needed && pacer !== 0) {\n",
    "      clearInterval(pacer);\n",
    "      pacer = 0;\n",
    "    }\n",
    "  }\n",
    "\n",
    "  // Whether a command starts a sound. Command -> Bool\n",
    "  function sound(command) {\n",
    "    return command.op === \"cmd\" && engine.sounds(command);\n",
    "  }\n",
    "\n",
    "  // A sound the program starts after an `sdelay`, with no time of its\n",
    "  // own, starts where the `sdelay` ends, exactly. Command -> Command\n",
    "  function timed(command) {\n",
    "    if (sdelayEnd === null || !sound(command)) return command;\n",
    "    const n = String(command.numbers ?\? \"\").trim().split(/\\s+/);\n",
    "    const k = command.kind === \"tone\" ? 1 : 0;\n",
    "    if (n.length <= k || Number(n[k]) !== 0) return command;\n",
    "    n[k] = String(sdelayEnd);\n",
    "    return { ...command, numbers: n.join(\" \") };\n",
    "  }\n",
    "\n",
    "  // Sound may start only after the reader did something, so every\n",
    "  // gesture is a chance to start it.\n",
    "  function startAudio() {\n",
    "    if (silent) return;\n",
    "    if (audio === null) {\n",
    "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n",
    "      if (!Context) return;\n",
    "      const before = clockNow();\n",
    "      audio = new Context();\n",
    "      offset = before - audio.currentTime;\n",
    "      audio.onstatechange = () => {\n",
    "        if (audio.state !== \"running\") return;\n",
    "        const paused = engine.frozen();\n",
    "        offset = (paused !== null ? paused : (now() - start) / 1000) - audio.currentTime;\n",
    "      };\n",
    "    }\n",
    "    if (audio.state === \"suspended\") audio.resume();\n",
    "  }\n",
    "\n",
    "  box.addEventListener(\"pointerdown\", startAudio);\n",
    "\n",
    "  engine = makeEngine({\n",
    "    audio: () => audio,\n",
    "    startAudio,\n",
    "    clock: clockNow,\n",
    "    toAudio: (t) => t - offset,\n",
    "    thaw: (t) => {\n",
    "      start = now() - t * 1000;\n",
    "      if (running()) offset = t - audio.currentTime;\n",
    "    },\n",
    "    sample: (id) => samples.get(id),\n",
    "    addSample: (id, loading) => samples.set(id, loading),\n",
    "    element: (id) => look.elements.get(id),\n",
    "    forget: (id) => look.elements.delete(id),\n",
    "    remember: (id, made) => remember(look, id, made),\n",
    "    place: (made) => parent.appendChild(made),\n",
    "    canvas: (id) => canvases.get(id),\n",
    "    send: (event) => report(event),\n",
    "  });\n",
    "\n",
    "  function onKey(event) {\n",
    "    if (splash !== null) {\n",
    "      dismissSplash(event);\n",
    "      return;\n",
    "    }\n",
    "    startAudio();\n",
    "    if (!keysWanted || typedInField(event)) return;\n",
    "    // Arrows and the space bar move the program's world, not the page.\n",
    "    if (standalone && [\"ArrowUp\", \"ArrowDown\", \"ArrowLeft\", \"ArrowRight\", \" \"].includes(event.key)) {\n",
    "      event.preventDefault?.();\n",
    "    }\n",
    "    heldKeys.add(event.key);\n",
    "    report({ ev: \"key\", key: event.key });\n",
    "  }\n",
    "  keyTarget.addEventListener(\"keydown\", onKey);\n",
    "\n",
    "  function onKeyUp(event) {\n",
    "    if (!keysWanted) return;\n",
    "    if (heldKeys.delete(event.key)) report({ ev: \"key_up\", key: event.key });\n",
    "  }\n",
    "  keyTarget.addEventListener(\"keyup\", onKeyUp);\n",
    "\n",
    "  // A key released while the page did not have the focus is never\n",
    "  // reported, so leaving the page lets go of every key.\n",
    "  function onBlur() {\n",
    "    for (const key of heldKeys) report({ ev: \"key_up\", key });\n",
    "    heldKeys.clear();\n",
    "  }\n",
    "  window.addEventListener(\"blur\", onBlur);\n",
    "\n",
    "  function loadSample(name) {\n",
    "    const decoder = new OfflineAudioContext(1, 1, 44100);\n",
    "    const fetchArray = (url) =>\n",
    "      fetch(url).then((response) => {\n",
    "        if (!response.ok) throw new Error(`${name}: ${response.status}`);\n",
    "        return response.arrayBuffer();\n",
    "      });\n",
    "    return fetchArray(new URL(name, document.baseURI))\n",
    "      .catch(() => fetchArray(new URL(\"tinyweb_assets/\" + name, import.meta.url)))\n",
    "      .then((bytes) => decoder.decodeAudioData(bytes))\n",
    "      .catch((error) => {\n",
    "        console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);\n",
    "        return null;\n",
    "      });\n",
    "  }\n",
    "\n",
    "  function frame() {\n",
    "    if (closed) return;\n",
    "    if (!frameWaiting && held === null) {\n",
    "      frameWaiting = true;\n",
    "      report({ ev: \"frame\" });\n",
    "    }\n",
    "    if (answering !== null || paced !== null) pace();\n",
    "    frameRequest = requestAnimationFrame(frame);\n",
    "  }\n",
    "\n",
    "  function newCanvas({ id, width, height }) {\n",
    "    const element = document.createElement(\"canvas\");\n",
    "    element.setAttribute(\"data-tinyweb-id\", String(id));\n",
    "    const ratio = globalThis.devicePixelRatio || 1;\n",
    "    element.width = Math.round(width * ratio);\n",
    "    element.height = Math.round(height * ratio);\n",
    "    element.style.width = width + \"px\";\n",
    "    element.style.height = height + \"px\";\n",
    "    element.style.background = \"#ffffff\";\n",
    "    const context = element.getContext(\"2d\");\n",
    "    context.scale(ratio, ratio);\n",
    "    plainLines(context);\n",
    "    const entry = {\n",
    "      element, context, width, height, mouse: false, pointer: false, ratio, depth: 0,\n",
    "      gradients: new Map(),\n",
    "    };\n",
    "    canvases.set(id, entry);\n",
    "    remember(look, id, element);\n",
    "    const where = (event) => {\n",
    "      const bounds = element.getBoundingClientRect();\n",
    "      return {\n",
    "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
    "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
    "      };\n",
    "    };\n",
    "    element.addEventListener(\"click\", (event) => {\n",
    "      if (entry.mouse) report({ ev: \"mouse\", c: id, ...where(event) });\n",
    "    });\n",
    "    // A browser reports a move at most once a frame already.\n",
    "    element.addEventListener(\"pointerdown\", (event) => {\n",
    "      if (!entry.pointer) return;\n",
    "      capture(element, event);\n",
    "      startAudio();\n",
    "      report({ ev: \"press\", c: id, ...where(event) });\n",
    "    });\n",
    "    element.addEventListener(\"pointerup\", (event) => {\n",
    "      if (entry.pointer) report({ ev: \"release\", c: id, ...where(event) });\n",
    "    });\n",
    "    element.addEventListener(\"pointermove\", (event) => {\n",
    "      if (entry.pointer) report({ ev: \"move\", c: id, ...where(event) });\n",
    "    });\n",
    "    element.addEventListener(\"contextmenu\", (event) => {\n",
    "      if (entry.pointer) event.preventDefault?.();\n",
    "    });\n",
    "    element.style.touchAction = \"none\";\n",
    "    parent.appendChild(element);\n",
    "  }\n",
    "\n",
    "  function draw(c, paint) {\n",
    "    const entry = canvases.get(c);\n",
    "    if (entry) paint(entry.context, entry);\n",
    "  }\n",
    "\n",
    "  function carryOut(command) {\n",
    "    switch (command.op) {\n",
    "      case \"canvas\":\n",
    "        newCanvas(command);\n",
    "        break;\n",
    "      case \"clear\":\n",
    "        draw(command.c, (g, entry) => {\n",
    "          freshState(g, entry);\n",
    "          g.fillStyle = paint(g, entry, command.color);\n",
    "          g.fillRect(0, 0, entry.width, entry.height);\n",
    "        });\n",
    "        break;\n",
    "      case \"shape\":\n",
    "        draw(command.c, (g, entry) => drawShape(g, entry, command.kind, command.numbers,\n",
    "          command.color, command.outline, command.width, command.alpha));\n",
    "        break;\n",
    "      case \"text\":\n",
    "        draw(command.c, (g, entry) => drawText(g, entry, command.x, command.y, command.words,\n",
    "          command.color, command.size, command.font, command.align, command.baseline,\n",
    "          command.bold, command.outline, command.outline_width, command.alpha));\n",
    "        break;\n",
    "      case \"measure\": {\n",
    "        // Answered once the code that asked has finished, as any event is.\n",
    "        const width = textWidth(command.words, command.size, command.font, command.bold);\n",
    "        queueMicrotask(() => report({ ev: \"measured\", id: command.id, width }));\n",
    "        break;\n",
    "      }\n",
    "      case \"bitmap\": {\n",
    "        let surface = bitmaps.get(command.id);\n",
    "        if (!surface || surface.width !== command.width || surface.height !== command.height) {\n",
    "          surface = bitmapSurface(command.width, command.height);\n",
    "          bitmaps.set(command.id, surface);\n",
    "        }\n",
    "        const [rx, ry, rw, rh] = command.rect;\n",
    "        updateSurface(surface, rx, ry, rw, rh, command.data);\n",
    "        draw(command.c, (g) => drawSurface(g, surface, command.x, command.y, command.scale));\n",
    "        break;\n",
    "      }\n",
    "      case \"state\":\n",
    "        draw(command.c, (g, entry) => canvasState(g, entry, command.kind, command.value,\n",
    "          command.numbers));\n",
    "        break;\n",
    "      case \"image_load\":\n",
    "        pictures.set(command.id, loadPicture(command.name, import.meta.url));\n",
    "        break;\n",
    "      case \"image\": {\n",
    "        const picture = pictures.get(command.picture);\n",
    "        if (picture && picture.loading) {\n",
    "          waitFor(picture);\n",
    "          held.push(command);\n",
    "          break;\n",
    "        }\n",
    "        draw(command.c, (g) => drawPicture(g, picture, command.x,\n",
    "          command.y, command.width, command.height, command.alpha));\n",
    "        break;\n",
    "      }\n",
    "      case \"checkbox\": {\n",
    "        const { row, input } = choiceRow(\"checkbox\", command.id, command.title, command.checked);\n",
    "        input.addEventListener(\"change\", () => {\n",
    "          startAudio();\n",
    "          report({ ev: \"check\", id: command.id, checked: input.checked,\n",
    "            reports: { [\"value.\" + command.id]: String(input.checked) } });\n",
    "        });\n",
    "        checks.set(command.id, (on) => { input.checked = on; });\n",
    "        remember(look, command.id, input);\n",
    "        parent.appendChild(row);\n",
    "        break;\n",
    "      }\n",
    "      case \"radio\": {\n",
    "        const members = groups.get(command.group) || [];\n",
    "        groups.set(command.group, members);\n",
    "        const first = members.length === 0;\n",
    "        const { row, input } = choiceRow(\"radio\", command.id, command.title,\n",
    "          command.chosen || first);\n",
    "        input.name = `${look.name}:${command.group}`;\n",
    "        const choose = () => {\n",
    "          for (const other of members) other.checked = other === input;\n",
    "        };\n",
    "        if (command.chosen) choose();\n",
    "        members.push(input);\n",
    "        input.addEventListener(\"change\", () => {\n",
    "          startAudio();\n",
    "          choose();\n",
    "          report({ ev: \"pick\", id: command.id });\n",
    "        });\n",
    "        checks.set(command.id, (on) => {\n",
    "          if (on) choose();\n",
    "          else input.checked = false;\n",
    "        });\n",
    "        remember(look, command.id, input);\n",
    "        parent.appendChild(row);\n",
    "        break;\n",
    "      }\n",
    "      case \"choice\": {\n",
    "        const select = choiceElement(command.id, command.options, command.chosen);\n",
    "        select.addEventListener(\"change\", () => {\n",
    "          startAudio();\n",
    "          report({ ev: \"choose\", id: command.id, value: Number(select.value),\n",
    "            reports: { [\"value.\" + command.id]: select.value } });\n",
    "        });\n",
    "        values.set(command.id, (value) => { select.value = String(value); });\n",
    "        remember(look, command.id, select);\n",
    "        parent.appendChild(select);\n",
    "        break;\n",
    "      }\n",
    "      case \"text_input\": {\n",
    "        const input = textInputElement(command.id, command.placeholder);\n",
    "        input.addEventListener(\"input\", () => engine.value(command.id, input.value));\n",
    "        input.addEventListener(\"keydown\", (event) => {\n",
    "          if (event.key === \"Enter\") {\n",
    "            startAudio();\n",
    "            report({ ev: \"enter\", id: command.id, text: input.value });\n",
    "          }\n",
    "        });\n",
    "        remember(look, command.id, input);\n",
    "        parent.appendChild(input);\n",
    "        break;\n",
    "      }\n",
    "      case \"number\": {\n",
    "        const input = numberElement(command.id, command.low, command.high, command.value);\n",
    "        input.addEventListener(\"change\", () => {\n",
    "          startAudio();\n",
    "          report({ ev: \"slide\", id: command.id, value: Number(input.value),\n",
    "            reports: { [\"value.\" + command.id]: input.value } });\n",
    "        });\n",
    "        values.set(command.id, (value) => { input.value = String(value); });\n",
    "        remember(look, command.id, input);\n",
    "        parent.appendChild(input);\n",
    "        break;\n",
    "      }\n",
    "      case \"set_checked\":\n",
    "        if (checks.has(command.id)) checks.get(command.id)(command.checked);\n",
    "        break;\n",
    "      case \"set_value\":\n",
    "        if (values.has(command.id)) values.get(command.id)(command.value);\n",
    "        break;\n",
    "      case \"button\": {\n",
    "        const button = document.createElement(\"button\");\n",
    "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
    "        button.textContent = command.title;\n",
    "        button.addEventListener(\"click\", () => {\n",
    "          startAudio();\n",
    "          report({ ev: \"click\", id: command.id });\n",
    "        });\n",
    "        remember(look, command.id, button);\n",
    "        parent.appendChild(button);\n",
    "        break;\n",
    "      }\n",
    "      case \"label\": {\n",
    "        const text = document.createElement(\"div\");\n",
    "        text.className = \"tinyweb-label\";\n",
    "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
    "        text.textContent = command.text;\n",
    "        labels.set(command.id, text);\n",
    "        remember(look, command.id, text);\n",
    "        parent.appendChild(text);\n",
    "        break;\n",
    "      }\n",
    "      case \"row\":\n",
    "      case \"column\": {\n",
    "        const row = rowElement(command.id, command.op === \"row\");\n",
    "        rows.set(command.id, row);\n",
    "        remember(look, command.id, row);\n",
    "        parent.appendChild(row);\n",
    "        break;\n",
    "      }\n",
    "      case \"inside\":\n",
    "        parent = rows.get(command.id) || box;\n",
    "        break;\n",
    "      case \"outside\":\n",
    "        parent = box;\n",
    "        break;\n",
    "      case \"set_label\":\n",
    "        // A label's text, or a button's title.\n",
    "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
    "        else if (look.elements.get(command.id)?.tagName === \"BUTTON\") {\n",
    "          look.elements.get(command.id).textContent = command.text;\n",
    "        }\n",
    "        break;\n",
    "      case \"slider\": {\n",
    "        const row = document.createElement(\"label\");\n",
    "        row.className = \"tinyweb-slider\";\n",
    "        row.style.cssText = \"display:flex;align-items:center;gap:8px\";\n",
    "        const input = document.createElement(\"input\");\n",
    "        input.type = \"range\";\n",
    "        input.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
    "        input.min = String(command.low);\n",
    "        input.max = String(command.high);\n",
    "        input.value = String(command.value);\n",
    "        const shown = document.createElement(\"span\");\n",
    "        shown.textContent = input.value;\n",
    "        input.addEventListener(\"input\", () => {\n",
    "          shown.textContent = input.value;\n",
    "          report({ ev: \"slide\", id: command.id, value: Number(input.value),\n",
    "            reports: { [\"value.\" + command.id]: input.value } });\n",
    "        });\n",
    "        row.append(input, shown);\n",
    "        values.set(command.id, (value) => {\n",
    "          input.value = String(value);\n",
    "          shown.textContent = input.value;\n",
    "        });\n",
    "        remember(look, command.id, input);\n",
    "        parent.appendChild(row);\n",
    "        break;\n",
    "      }\n",
    "      case \"style\":\n",
    "        applyStyle(look, command.id, command.kind, command.prop, command.value);\n",
    "        break;\n",
    "      case \"load\":\n",
    "        samples.set(command.id, loadSample(command.name));\n",
    "        break;\n",
    "      case \"cmd\":\n",
    "        if (engine.sounds(command) && splashWanted()) {\n",
    "          showSplash();\n",
    "          held.push(command);\n",
    "        } else {\n",
    "          engine.command(command);\n",
    "        }\n",
    "        break;\n",
    "      case \"splash\":\n",
    "        if (splashWanted()) showSplash();\n",
    "        break;\n",
    "      case \"splash_text\":\n",
    "        splashText = command.text;\n",
    "        break;\n",
    "      case \"on_frame\":\n",
    "        if (!frameWanted) {\n",
    "          frameWanted = true;\n",
    "          frameRequest = requestAnimationFrame(frame);\n",
    "        }\n",
    "        break;\n",
    "      case \"frame_done\":\n",
    "        frameWaiting = false;\n",
    "        break;\n",
    "      case \"sdelay\":\n",
    "        sdelay(command);\n",
    "        break;\n",
    "      case \"on_mouse\": {\n",
    "        const entry = canvases.get(command.c);\n",
    "        if (entry) entry.mouse = true;\n",
    "        break;\n",
    "      }\n",
    "      case \"on_pointer\": {\n",
    "        const entry = canvases.get(command.c);\n",
    "        if (entry) entry.pointer = true;\n",
    "        break;\n",
    "      }\n",
    "      case \"on_key\":\n",
    "        keysWanted = true;\n",
    "        // Inside another page the keys go where the focus is, which is\n",
    "        // still the Run button that started the program; one typing in\n",
    "        // an editor keeps it.\n",
    "        if (!standalone && !typing()) element.focus({ preventScroll: true });\n",
    "        break;\n",
    "    }\n",
    "  }\n",
    "\n",
    "  function typing() {\n",
    "    const active = document.activeElement;\n",
    "    return !!active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));\n",
    "  }\n",
    "\n",
    "  function freeze() {\n",
    "    if (closed) return;\n",
    "    closed = true;\n",
    "    cancelAnimationFrame(frameRequest);\n",
    "    if (pacer !== 0) clearInterval(pacer);\n",
    "    if (splash !== null) {\n",
    "      window.removeEventListener(\"keydown\", dismissSplash, true);\n",
    "      splash.remove();\n",
    "    }\n",
    "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
    "    keyTarget.removeEventListener(\"keyup\", onKeyUp);\n",
    "    window.removeEventListener(\"blur\", onBlur);\n",
    "    if (!standalone) element.removeEventListener(\"click\", takeFocus);\n",
    "    engine.close();\n",
    "    if (audio !== null) audio.close();\n",
    "  }\n",
    "\n",
    "  return {\n",
    "    receive(commands) {\n",
    "      if (closed) return;\n",
    "      for (const command of commands) take(command);\n",
    "    },\n",
    "    // Stops: no more events, frames or sound, and what is shown stays.\n",
    "    freeze,\n",
    "    close() {\n",
    "      freeze();\n",
    "      box.remove();\n",
    "      unstyled(look);\n",
    "      if (focusable) {\n",
    "        element.removeAttribute(\"tabindex\");\n",
    "        element.blur();\n",
    "      }\n",
    "    },\n",
    "  };\n",
    "}\n",
    0
};
/* END tinyweb page */

/* --- text that grows --- */

typedef struct {
    char *text;
    size_t length;
    size_t room;
} tw_text;

static void tw_add(tw_text *out, const char *more, size_t length)
{
    if (out->length + length + 1 > out->room) {
        size_t room = out->room == 0 ? 256 : out->room;
        while (out->length + length + 1 > room) room *= 2;
        out->text = (char *) realloc(out->text, room);
        if (out->text == NULL) abort();
        out->room = room;
    }
    memcpy(out->text + out->length, more, length);
    out->length += length;
    out->text[out->length] = '\0';
}

static void tw_puts(tw_text *out, const char *more)
{
    tw_add(out, more, strlen(more));
}

static void tw_int(tw_text *out, int n)
{
    char digits[32];
    sprintf(digits, "%d", n);
    tw_puts(out, digits);
}

static char *tw_copy(const char *text)
{
    char *copy = (char *) malloc(strlen(text) + 1);
    if (copy == NULL) abort();
    strcpy(copy, text);
    return copy;
}

/* A string as JSON writes it, which is also how a log line quotes one. */
static void tw_quote(tw_text *out, const char *text)
{
    const unsigned char *c;
    char escape[8];
    tw_puts(out, "\"");
    for (c = (const unsigned char *) text; *c != '\0'; c++) {
        switch (*c) {
        case '"': tw_puts(out, "\\\""); break;
        case '\\': tw_puts(out, "\\\\"); break;
        case '\n': tw_puts(out, "\\n"); break;
        case '\r': tw_puts(out, "\\r"); break;
        case '\t': tw_puts(out, "\\t"); break;
        case '\b': tw_puts(out, "\\b"); break;
        case '\f': tw_puts(out, "\\f"); break;
        default:
            if (*c < 0x20) {
                sprintf(escape, "\\u%04x", (unsigned) *c);
                tw_puts(out, escape);
            } else {
                tw_add(out, (const char *) c, 1);
            }
        }
    }
    tw_puts(out, "\"");
}

/* --- commands --- */

/* One command: its JSON for the page, its line for the log, and what a
   later command can make invisible -- the canvas it draws on, the label
   it sets, a `cmd`'s kind and id (`key`, NULL for any other op), which
   `replacing` hides where earlier commands have the same. */
typedef struct {
    char *json;
    char *line;
    int drawing;
    const char *canvas;
    int setting;
    const char *id;
    char *key;
    int replacing;
} tw_command;

static const char *tw_log = NULL;
static const char *tw_events = NULL;
static int tw_checked = 0;
static int tw_listener = -1;
static const char **tw_names = NULL;
static size_t tw_name_count = 0;
static double tw_clock = 0.0;
/* Whether an event has been delivered: until one is, the program is in
   its top level, whose sound a page connecting later still plays. */
static int tw_delivered = 0;
/* tinyweb's `sdelay`: how many have been sent, and with no page, where
   the last one ended on the clock the events give (once there is one). */
static int tw_sdelays = 0;
static int tw_sdelay_ended = 0;
static double tw_sdelay_end = 0.0;

static tw_command *tw_history = NULL;
static size_t tw_history_count = 0;
static size_t tw_history_room = 0;
static tw_text tw_pending;
static int tw_batching = 0;
static int *tw_clients = NULL;
static size_t tw_client_count = 0;

typedef struct { const char *id; void (*f)(void); } tw_button;
typedef struct { const char *id; void (*f)(int); } tw_slider;
typedef struct { const char *id; void (*f)(bool); } tw_check;
typedef struct { const char *id; const char *title; void (*f)(const char *); } tw_radio;
typedef struct { const char *id; void (*f)(const char *); } tw_text_field;
typedef struct { const char *c; void (*f)(int, int); } tw_mouse;
static tw_button *tw_buttons = NULL;
static size_t tw_button_count = 0;
static tw_slider *tw_sliders = NULL;
static size_t tw_slider_count = 0;
static tw_check *tw_checks = NULL;
static size_t tw_check_count = 0;
static tw_radio *tw_radios = NULL;
static size_t tw_radio_count = 0;
static tw_slider *tw_choices = NULL;
static size_t tw_choice_count = 0;
static tw_text_field *tw_text_fields = NULL;
static size_t tw_text_field_count = 0;
static void (**tw_frames)(double) = NULL;
static size_t tw_frame_count = 0;
static tw_mouse *tw_mice = NULL;
static size_t tw_mouse_count = 0;
static void (**tw_keys)(const char *) = NULL;
static size_t tw_key_count = 0;
static void (**tw_key_ups)(const char *) = NULL;
static size_t tw_key_up_count = 0;
/* The keys held down now, from the key events delivered so far. */
static char **tw_down = NULL;
static size_t tw_down_count = 0;
static int tw_keys_on = 0;

/* Each canvas's pointer, where it was last seen, and the functions
   watching it, by kind. */
typedef struct { const char *c; int x; int y; int down; } tw_pointer_seen;
typedef struct { const char *c; char kind[8]; void (*f)(int, int); } tw_watcher;
static tw_pointer_seen *tw_pointers = NULL;
static size_t tw_pointer_count = 0;
static tw_watcher *tw_watchers = NULL;
static size_t tw_watcher_count = 0;

typedef struct { const char *id; void (*f)(double); int answered; } tw_measure;
static tw_measure *tw_measures = NULL;
static size_t tw_measure_count = 0;

/* A bitmap's pixels, four bytes each, and the rectangle that changed
   since it was last shown. */
typedef struct {
    const char *id;
    int width;
    int height;
    unsigned char *data;
    int x1, y1, x2, y2;
} tw_bitmap;
static tw_bitmap *tw_bitmaps = NULL;
static size_t tw_bitmap_count = 0;

static void *tw_grow(void *array, size_t count, size_t size)
{
    void *grown = realloc(array, (count + 1) * size);
    if (grown == NULL) abort();
    return grown;
}

static void tw_after_program(void);

/* Whether two identifiers are the same; NULL is none. */
static int tw_same(const char *a, const char *b)
{
    return a != NULL && b != NULL && strcmp(a, b) == 0;
}

/* Ends the program with `message`, and with status 1. */
static void tw_refuse(const char *message)
{
    fflush(stdout);
    fprintf(stderr, "%s\n", message);
    exit(1);
}

/* Reads the environment, the first time anything asks. */
static void tw_environment(void)
{
    if (!tw_checked) {
        tw_checked = 1;
        tw_log = getenv("PYKING_TINYWEB_LOG");
        tw_events = getenv("PYKING_TINYWEB_EVENTS");
        if (tw_log != NULL) atexit(tw_after_program);
    }
}

/* What every function but tinyweb_web_init needs first: a log to write
   to, or a page served. */
static void tw_ready(void)
{
    tw_environment();
    if (tw_log == NULL && tw_listener < 0) {
        tw_refuse("tinyweb: call tinyweb.web_init(port) before anything else, "
                  "or set PYKING_TINYWEB_LOG");
    }
}

static void tw_write_log(const char *line)
{
    FILE *log = fopen(tw_log, "a");
    if (log == NULL) return;
    fputs(line, log);
    fputc('\n', log);
    fclose(log);
}

/* Writes all of text to a socket, answering 0 where it has gone. */
static int tw_write_all(int socket, const char *text, size_t length)
{
    while (length > 0) {
        ssize_t written = write(socket, text, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        text += written;
        length -= (size_t) written;
    }
    return 1;
}

/* Sends a batch -- JSON objects joined by commas -- to every page. */
static void tw_broadcast(const char *batch)
{
    tw_text message = { NULL, 0, 0 };
    size_t i = 0;
    tw_puts(&message, "data: [");
    tw_puts(&message, batch);
    tw_puts(&message, "]\n\n");
    while (i < tw_client_count) {
        if (tw_write_all(tw_clients[i], message.text, message.length)) {
            i++;
        } else {
            close(tw_clients[i]);
            tw_clients[i] = tw_clients[tw_client_count - 1];
            tw_client_count--;
        }
    }
    free(message.text);
}

static void tw_flush(void)
{
    if (tw_pending.length > 0) {
        tw_broadcast(tw_pending.text);
        tw_pending.length = 0;
        tw_pending.text[0] = '\0';
    }
}

/* Keeps a command for a page connecting later, less what it makes
   invisible: everything drawn on a canvas it clears, a label's text it
   sets again. */
static void tw_keep(tw_command command)
{
    size_t i, kept = 0;
    for (i = 0; i < tw_history_count; i++) {
        tw_command *old = &tw_history[i];
        int hidden =
            (command.drawing == 2 && old->drawing && tw_same(old->canvas, command.canvas))
            || (command.setting && old->setting && tw_same(old->id, command.id))
            || (command.replacing && tw_same(old->key, command.key));
        if (hidden) {
            free(old->json);
            free(old->line);
            free(old->key);
        } else {
            tw_history[kept++] = *old;
        }
    }
    tw_history_count = kept;
    if (tw_history_count == tw_history_room) {
        tw_history_room = tw_history_room == 0 ? 64 : tw_history_room * 2;
        tw_history = (tw_command *) realloc(tw_history, tw_history_room * sizeof(tw_command));
        if (tw_history == NULL) abort();
    }
    tw_history[tw_history_count++] = command;
}

/* Sends one command: `json` its fields after "op", `line` its log line.
   `drawing` is 1 for a command drawing on canvas `canvas` and 2 for one
   clearing it, `setting` 1 for one setting label `id`, and `kept` 0 for
   one a late page is not sent. */
static void tw_send_keyed(const char *op, const char *fields, const char *line,
                          int drawing, const char *canvas, int setting, const char *id,
                          int kept, const char *key, int replacing)
{
    tw_text json = { NULL, 0, 0 };
    tw_ready();
    if (tw_log != NULL) {
        if (strcmp(op, "frame_done") != 0 && strcmp(op, "event_done") != 0) {
            tw_write_log(line);
        }
        return;
    }
    tw_puts(&json, "{\"op\":\"");
    tw_puts(&json, op);
    tw_puts(&json, "\"");
    tw_puts(&json, fields);
    tw_puts(&json, "}");
    if (kept) {
        tw_command command;
        command.json = tw_copy(json.text);
        command.line = tw_copy(line);
        command.drawing = drawing;
        command.canvas = canvas;
        command.setting = setting;
        command.id = id;
        command.key = key == NULL ? NULL : tw_copy(key);
        command.replacing = replacing;
        tw_keep(command);
    }
    if (tw_pending.length > 0) tw_puts(&tw_pending, ",");
    tw_puts(&tw_pending, json.text);
    free(json.text);
    if (!tw_batching) tw_flush();
}

static void tw_send(const char *op, const char *fields, const char *line,
                    int drawing, const char *canvas, int setting, const char *id, int kept)
{
    tw_send_keyed(op, fields, line, drawing, canvas, setting, id, kept, NULL, 0);
}

/* A field `,"name":value` of a command's JSON, and the same value as a
   word of its log line. */
static void tw_field_int(tw_text *json, tw_text *line, const char *name, int value)
{
    tw_puts(json, ",\"");
    tw_puts(json, name);
    tw_puts(json, "\":");
    tw_int(json, value);
    tw_puts(line, " ");
    tw_int(line, value);
}

static void tw_field_float(tw_text *json, tw_text *line, const char *name, double value)
{
    char number[64];
    tw_puts(json, ",\"");
    tw_puts(json, name);
    tw_puts(json, "\":");
    sprintf(number, "%.17g", value);
    tw_puts(json, number);
    sprintf(number, " %.3f", value);
    tw_puts(line, number);
}

/* A string field: `bare` writes it in the log line as it is (a color),
   and otherwise quoted. */
static void tw_field_string(tw_text *json, tw_text *line, const char *name,
                            const char *value, int bare)
{
    tw_puts(json, ",\"");
    tw_puts(json, name);
    tw_puts(json, "\":");
    tw_quote(json, value);
    tw_puts(line, " ");
    if (bare) tw_puts(line, value); else tw_quote(line, value);
}

static void tw_finish(const char *op, tw_text *json, tw_text *line,
                      int drawing, const char *canvas, int setting, const char *id, int kept)
{
    tw_send(op, json->text == NULL ? "" : json->text, line->text,
            drawing, canvas, setting, id, kept);
    free(json->text);
    free(line->text);
}

/* A field that is in a command's JSON and not its log line. */
static void tw_field_json(tw_text *json, const char *name, const char *value)
{
    tw_puts(json, ",\"");
    tw_puts(json, name);
    tw_puts(json, "\":");
    tw_quote(json, value);
}

/* An element's text after its identifier: in the log line only where
   the two differ. */
static void tw_field_text(tw_text *json, tw_text *line, const char *name,
                          const char *value, const char *id)
{
    if (strcmp(value, id) == 0) tw_field_json(json, name, value);
    else tw_field_string(json, line, name, value, 0);
}

/* A new element's identifier: `name`, or `name` with the first number
   from 1 that makes it one nothing on the page has. */
static const char *tw_fresh(const char *name)
{
    char *found;
    unsigned long n = 0;
    size_t i;
    /* An empty name would be the page's own identifier. */
    if (name[0] == '\0') name = "element";
    found = tw_copy(name);
    for (;;) {
        int taken = 0;
        for (i = 0; i < tw_name_count; i++) {
            if (strcmp(tw_names[i], found) == 0) taken = 1;
        }
        if (!taken) break;
        n++;
        free(found);
        found = (char *) malloc(strlen(name) + 24);
        if (found == NULL) abort();
        sprintf(found, "%s%lu", name, n);
    }
    tw_names = (const char **) tw_grow((void *) tw_names, tw_name_count, sizeof(const char *));
    tw_names[tw_name_count++] = found;
    return found;
}

/* --- the functions tinyweb_external.pyk declares --- */

const char *tinyweb_canvas(int width, int height)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("canvas");
    tw_puts(&line, "canvas");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "width", width);
    tw_field_int(&json, &line, "height", height);
    tw_finish("canvas", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

void tinyweb_fill_canvas(const char *c, const char *color)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "clear");
    tw_field_string(&json, &line, "c", c, 0);
    tw_field_string(&json, &line, "color", color, 1);
    tw_finish("clear", &json, &line, 2, c, 0, NULL, 1);
}

/* A Bool field: `,"name":true` in the JSON, and the word in the line. */
static void tw_field_bool(tw_text *json, tw_text *line, const char *name, bool value)
{
    tw_puts(json, ",\"");
    tw_puts(json, name);
    tw_puts(json, "\":");
    tw_puts(json, value ? "true" : "false");
    tw_puts(line, value ? " true" : " false");
}

void tinyweb_draw_shape(const char *c, const char *kind, const char *numbers, const char *color,
                        const char *outline, double width, double alpha)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, kind);
    tw_field_json(&json, "kind", kind);
    tw_field_string(&json, &line, "c", c, 0);
    tw_field_string(&json, &line, "numbers", numbers, 1);
    tw_field_string(&json, &line, "color", color, 0);
    tw_field_string(&json, &line, "outline", outline, 0);
    tw_field_float(&json, &line, "width", width);
    tw_field_float(&json, &line, "alpha", alpha);
    tw_finish("shape", &json, &line, 1, c, 0, NULL, 1);
}

void tinyweb_draw_text(const char *c, double x, double y, const char *words, const char *color,
                       int size, const char *font, const char *align, const char *baseline,
                       bool bold, const char *outline, double outline_width, double alpha)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "text");
    tw_field_string(&json, &line, "c", c, 0);
    tw_field_float(&json, &line, "x", x);
    tw_field_float(&json, &line, "y", y);
    tw_field_string(&json, &line, "color", color, 0);
    tw_field_int(&json, &line, "size", size);
    tw_field_string(&json, &line, "font", font, 0);
    tw_field_string(&json, &line, "align", align, 1);
    tw_field_string(&json, &line, "baseline", baseline, 1);
    tw_field_bool(&json, &line, "bold", bold);
    tw_field_string(&json, &line, "outline", outline, 0);
    tw_field_float(&json, &line, "outline_width", outline_width);
    tw_field_float(&json, &line, "alpha", alpha);
    tw_field_string(&json, &line, "words", words, 0);
    tw_finish("text", &json, &line, 1, c, 0, NULL, 1);
}

void tinyweb_measure(const char *words, int size, const char *font, bool bold,
                     void (*answer)(double))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("measure");
    tw_measures = (tw_measure *) tw_grow(tw_measures, tw_measure_count, sizeof(tw_measure));
    tw_measures[tw_measure_count].id = id;
    tw_measures[tw_measure_count].f = answer;
    tw_measures[tw_measure_count].answered = 0;
    tw_measure_count++;
    tw_puts(&line, "measure");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "size", size);
    tw_field_string(&json, &line, "font", font, 0);
    tw_field_bool(&json, &line, "bold", bold);
    tw_field_string(&json, &line, "words", words, 0);
    tw_finish("measure", &json, &line, 0, NULL, 0, NULL, 1);
}

/* The pointer of canvas `c` as last seen; NULL until something watches
   it. */
static tw_pointer_seen *tw_pointer_of(const char *c)
{
    size_t i;
    for (i = 0; i < tw_pointer_count; i++) {
        if (tw_same(tw_pointers[i].c, c)) return &tw_pointers[i];
    }
    return NULL;
}

void tinyweb_watch_pointer(const char *c, const char *kind, void (*f)(int, int))
{
    tw_ready();
    if (tw_pointer_of(c) == NULL) {
        tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
        tw_pointers = (tw_pointer_seen *) tw_grow(tw_pointers, tw_pointer_count,
                                                  sizeof(tw_pointer_seen));
        tw_pointers[tw_pointer_count].c = tw_copy(c);
        tw_pointers[tw_pointer_count].x = 0;
        tw_pointers[tw_pointer_count].y = 0;
        tw_pointers[tw_pointer_count].down = 0;
        tw_pointer_count++;
        tw_puts(&line, "on_pointer");
        tw_field_string(&json, &line, "c", c, 0);
        tw_finish("on_pointer", &json, &line, 0, NULL, 0, NULL, 1);
    }
    if (strcmp(kind, "press") == 0 || strcmp(kind, "release") == 0
        || strcmp(kind, "move") == 0 || strcmp(kind, "drag") == 0) {
        tw_watchers = (tw_watcher *) tw_grow(tw_watchers, tw_watcher_count, sizeof(tw_watcher));
        tw_watchers[tw_watcher_count].c = tw_copy(c);
        strcpy(tw_watchers[tw_watcher_count].kind, kind);
        tw_watchers[tw_watcher_count].f = f;
        tw_watcher_count++;
    }
}

int tinyweb_pointer(const char *c, const char *which)
{
    tw_pointer_seen *seen;
    tw_ready();
    seen = tw_pointer_of(c);
    if (seen == NULL) return 0;
    if (strcmp(which, "x") == 0) return seen->x;
    if (strcmp(which, "y") == 0) return seen->y;
    return seen->down ? 1 : 0;
}

void tinyweb_set_state(const char *c, const char *kind, const char *value, const char *numbers)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, kind);
    tw_field_json(&json, "kind", kind);
    tw_field_string(&json, &line, "c", c, 0);
    if (value[0] == '\0') tw_field_json(&json, "value", value);
    else tw_field_string(&json, &line, "value", value, 0);
    if (numbers[0] == '\0') tw_field_json(&json, "numbers", numbers);
    else tw_field_string(&json, &line, "numbers", numbers, 1);
    tw_finish("state", &json, &line, 1, c, 0, NULL, 1);
}

const char *tinyweb_load_image(const char *name)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(name);
    tw_puts(&line, "load_image");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "name", name, id);
    tw_finish("image_load", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

void tinyweb_draw_image(const char *c, const char *picture, int x, int y, int width, int height,
                        double alpha)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "image");
    tw_field_string(&json, &line, "c", c, 0);
    tw_field_string(&json, &line, "picture", picture, 0);
    tw_field_int(&json, &line, "x", x);
    tw_field_int(&json, &line, "y", y);
    tw_field_int(&json, &line, "width", width);
    tw_field_int(&json, &line, "height", height);
    tw_field_float(&json, &line, "alpha", alpha);
    tw_finish("image", &json, &line, 1, c, 0, NULL, 1);
}

/* --- bitmaps --- */

static tw_bitmap *tw_bitmap_named(const char *b)
{
    size_t i;
    for (i = tw_bitmap_count; i > 0; i--) {
        if (tw_same(tw_bitmaps[i - 1].id, b)) return &tw_bitmaps[i - 1];
    }
    return NULL;
}

const char *tinyweb_make_bitmap(int width, int height, int background)
{
    tw_bitmap *bitmap;
    size_t i, count;
    tw_ready();
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    tw_bitmaps = (tw_bitmap *) tw_grow(tw_bitmaps, tw_bitmap_count, sizeof(tw_bitmap));
    bitmap = &tw_bitmaps[tw_bitmap_count++];
    bitmap->id = tw_fresh("bitmap");
    bitmap->width = width;
    bitmap->height = height;
    count = (size_t) width * (size_t) height * 4;
    bitmap->data = (unsigned char *) malloc(count);
    if (bitmap->data == NULL) abort();
    for (i = 0; i < count; i += 4) {
        bitmap->data[i] = 0;
        bitmap->data[i + 1] = 0;
        bitmap->data[i + 2] = 0;
        bitmap->data[i + 3] = 255;
    }
    bitmap->x1 = 0;
    bitmap->y1 = 0;
    bitmap->x2 = width;
    bitmap->y2 = height;
    tinyweb_fill_bitmap(bitmap->id, background);
    return bitmap->id;
}

void tinyweb_set_pixel(const char *b, int x, int y, int color)
{
    tw_bitmap *bitmap = tw_bitmap_named(b);
    size_t at;
    if (bitmap == NULL || x < 0 || y < 0 || x >= bitmap->width || y >= bitmap->height) return;
    at = ((size_t) y * (size_t) bitmap->width + (size_t) x) * 4;
    bitmap->data[at] = (unsigned char) ((color >> 16) & 255);
    bitmap->data[at + 1] = (unsigned char) ((color >> 8) & 255);
    bitmap->data[at + 2] = (unsigned char) (color & 255);
    if (x < bitmap->x1) bitmap->x1 = x;
    if (y < bitmap->y1) bitmap->y1 = y;
    if (x + 1 > bitmap->x2) bitmap->x2 = x + 1;
    if (y + 1 > bitmap->y2) bitmap->y2 = y + 1;
}

int tinyweb_get_pixel(const char *b, int x, int y)
{
    tw_bitmap *bitmap = tw_bitmap_named(b);
    size_t at;
    if (bitmap == NULL || x < 0 || y < 0 || x >= bitmap->width || y >= bitmap->height) return 0;
    at = ((size_t) y * (size_t) bitmap->width + (size_t) x) * 4;
    return (bitmap->data[at] << 16) | (bitmap->data[at + 1] << 8) | bitmap->data[at + 2];
}

void tinyweb_fill_bitmap(const char *b, int color)
{
    tw_bitmap *bitmap = tw_bitmap_named(b);
    size_t i, count;
    if (bitmap == NULL) return;
    count = (size_t) bitmap->width * (size_t) bitmap->height * 4;
    for (i = 0; i < count; i += 4) {
        bitmap->data[i] = (unsigned char) ((color >> 16) & 255);
        bitmap->data[i + 1] = (unsigned char) ((color >> 8) & 255);
        bitmap->data[i + 2] = (unsigned char) (color & 255);
        bitmap->data[i + 3] = 255;
    }
    bitmap->x1 = 0;
    bitmap->y1 = 0;
    bitmap->x2 = bitmap->width;
    bitmap->y2 = bitmap->height;
}

/* Appends `length` bytes as base64. */
static void tw_base64(tw_text *out, const unsigned char *bytes, size_t length)
{
    static const char digits[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i;
    char four[4];
    for (i = 0; i + 2 < length; i += 3) {
        unsigned long n = ((unsigned long) bytes[i] << 16) | ((unsigned long) bytes[i + 1] << 8)
                          | bytes[i + 2];
        four[0] = digits[(n >> 18) & 63];
        four[1] = digits[(n >> 12) & 63];
        four[2] = digits[(n >> 6) & 63];
        four[3] = digits[n & 63];
        tw_add(out, four, 4);
    }
    if (length - i == 1) {
        unsigned long n = (unsigned long) bytes[i] << 16;
        four[0] = digits[(n >> 18) & 63];
        four[1] = digits[(n >> 12) & 63];
        four[2] = '=';
        four[3] = '=';
        tw_add(out, four, 4);
    } else if (length - i == 2) {
        unsigned long n = ((unsigned long) bytes[i] << 16) | ((unsigned long) bytes[i + 1] << 8);
        four[0] = digits[(n >> 18) & 63];
        four[1] = digits[(n >> 12) & 63];
        four[2] = digits[(n >> 6) & 63];
        four[3] = '=';
        tw_add(out, four, 4);
    }
}

void tinyweb_draw_bitmap(const char *c, const char *b, int x, int y, double scale)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_bitmap *bitmap = tw_bitmap_named(b);
    int rx = 0, ry = 0, rw = 0, rh = 0, row;
    unsigned char *rect;
    unsigned long hash = 2166136261UL;
    size_t i, size;
    char digest[16];
    if (bitmap == NULL) return;
    if (bitmap->x2 > bitmap->x1 && bitmap->y2 > bitmap->y1) {
        rx = bitmap->x1;
        ry = bitmap->y1;
        rw = bitmap->x2 - bitmap->x1;
        rh = bitmap->y2 - bitmap->y1;
    }
    size = (size_t) rw * (size_t) rh * 4;
    rect = (unsigned char *) malloc(size == 0 ? 1 : size);
    if (rect == NULL) abort();
    for (row = 0; row < rh; row++) {
        memcpy(rect + (size_t) row * (size_t) rw * 4,
               bitmap->data + (((size_t) (ry + row)) * (size_t) bitmap->width + (size_t) rx) * 4,
               (size_t) rw * 4);
    }
    for (i = 0; i < size; i++) {
        hash = ((hash ^ rect[i]) * 16777619UL) & 0xFFFFFFFFUL;
    }
    sprintf(digest, "%08lx", hash);
    bitmap->x1 = bitmap->width;
    bitmap->y1 = bitmap->height;
    bitmap->x2 = 0;
    bitmap->y2 = 0;
    tw_puts(&line, "bitmap");
    tw_field_string(&json, &line, "c", c, 0);
    tw_field_string(&json, &line, "id", b, 0);
    tw_field_int(&json, &line, "x", x);
    tw_field_int(&json, &line, "y", y);
    tw_field_float(&json, &line, "scale", scale);
    tw_field_int(&json, &line, "width", bitmap->width);
    tw_field_int(&json, &line, "height", bitmap->height);
    tw_puts(&json, ",\"rect\":[");
    tw_int(&json, rx);
    tw_puts(&json, ",");
    tw_int(&json, ry);
    tw_puts(&json, ",");
    tw_int(&json, rw);
    tw_puts(&json, ",");
    tw_int(&json, rh);
    tw_puts(&json, "]");
    tw_puts(&line, " ");
    tw_int(&line, rx);
    tw_puts(&line, " ");
    tw_int(&line, ry);
    tw_puts(&line, " ");
    tw_int(&line, rw);
    tw_puts(&line, " ");
    tw_int(&line, rh);
    tw_puts(&json, ",\"data\":\"");
    tw_base64(&json, rect, size);
    tw_puts(&json, "\"");
    free(rect);
    tw_field_string(&json, &line, "digest", digest, 1);
    tw_finish("bitmap", &json, &line, 1, c, 0, NULL, 1);
}

const char *tinyweb_make_checkbox(const char *title, bool checked, void (*on_change)(bool))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(title);
    tw_checks = (tw_check *) tw_grow(tw_checks, tw_check_count, sizeof(tw_check));
    tw_checks[tw_check_count].id = id;
    tw_checks[tw_check_count].f = on_change;
    tw_check_count++;
    tw_puts(&line, "checkbox");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "title", title, id);
    tw_field_bool(&json, &line, "checked", checked);
    tw_finish("checkbox", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_make_radio(const char *group, const char *title, bool chosen,
                               void (*on_pick)(const char *))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(title);
    tw_radios = (tw_radio *) tw_grow(tw_radios, tw_radio_count, sizeof(tw_radio));
    tw_radios[tw_radio_count].id = id;
    tw_radios[tw_radio_count].title = tw_copy(title);
    tw_radios[tw_radio_count].f = on_pick;
    tw_radio_count++;
    tw_puts(&line, "radio");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "title", title, id);
    tw_field_string(&json, &line, "group", group, 0);
    tw_field_bool(&json, &line, "chosen", chosen);
    tw_finish("radio", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_make_choice(const char *options, int chosen, void (*on_change)(int))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("choice");
    tw_choices = (tw_slider *) tw_grow(tw_choices, tw_choice_count, sizeof(tw_slider));
    tw_choices[tw_choice_count].id = id;
    tw_choices[tw_choice_count].f = on_change;
    tw_choice_count++;
    tw_puts(&line, "choice");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "chosen", chosen);
    tw_field_string(&json, &line, "options", options, 0);
    tw_finish("choice", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_make_text_input(const char *placeholder, void (*on_enter)(const char *))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(placeholder[0] == '\0' ? "text" : placeholder);
    tw_text_fields = (tw_text_field *) tw_grow(tw_text_fields, tw_text_field_count,
                                               sizeof(tw_text_field));
    tw_text_fields[tw_text_field_count].id = id;
    tw_text_fields[tw_text_field_count].f = on_enter;
    tw_text_field_count++;
    tw_puts(&line, "text_input");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "placeholder", placeholder, id);
    tw_finish("text_input", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_make_number_input(int low, int high, int value, void (*on_change)(int))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("number");
    tw_sliders = (tw_slider *) tw_grow(tw_sliders, tw_slider_count, sizeof(tw_slider));
    tw_sliders[tw_slider_count].id = id;
    tw_sliders[tw_slider_count].f = on_change;
    tw_slider_count++;
    tw_puts(&line, "number");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "low", low);
    tw_field_int(&json, &line, "high", high);
    tw_field_int(&json, &line, "value", value);
    tw_finish("number", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

void tinyweb_set_checked(const char *id, bool checked)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "set_checked");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_bool(&json, &line, "checked", checked);
    tw_finish("set_checked", &json, &line, 0, NULL, 1, id, 1);
}

void tinyweb_set_value(const char *id, int value)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "set_value");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "value", value);
    tw_finish("set_value", &json, &line, 0, NULL, 1, id, 1);
}

const char *tinyweb_make_button(const char *title, void (*on_click)(void))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(title);
    tw_buttons = (tw_button *) tw_grow(tw_buttons, tw_button_count, sizeof(tw_button));
    tw_buttons[tw_button_count].id = id;
    tw_buttons[tw_button_count].f = on_click;
    tw_button_count++;
    tw_puts(&line, "button");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "title", title, id);
    tw_finish("button", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_label(const char *text)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(text);
    tw_puts(&line, "label");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "text", text, id);
    tw_finish("label", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_row(void)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("row");
    tw_puts(&line, "row");
    tw_field_string(&json, &line, "id", id, 0);
    tw_finish("row", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_column(void)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("column");
    tw_puts(&line, "column");
    tw_field_string(&json, &line, "id", id, 0);
    tw_finish("column", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

void tinyweb_inside(const char *id)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "inside");
    tw_field_string(&json, &line, "id", id, 0);
    tw_finish("inside", &json, &line, 0, NULL, 0, NULL, 1);
}

void tinyweb_outside(void)
{
    tw_ready();
    tw_send("outside", "", "outside", 0, NULL, 0, NULL, 1);
}

void tinyweb_set_label(const char *id, const char *text)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "set_label");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_string(&json, &line, "text", text, 0);
    tw_finish("set_label", &json, &line, 0, NULL, 1, id, 1);
}

void tinyweb_apply_style(const char *id, const char *kind, const char *property, const char *value)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_puts(&line, "style");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_string(&json, &line, "kind", kind, 1);
    tw_field_string(&json, &line, "prop", property, 1);
    tw_field_string(&json, &line, "value", value, 0);
    tw_finish("style", &json, &line, 0, NULL, 0, NULL, 1);
}

const char *tinyweb_make_slider(int low, int high, int value, void (*on_change)(int))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh("slider");
    tw_sliders = (tw_slider *) tw_grow(tw_sliders, tw_slider_count, sizeof(tw_slider));
    tw_sliders[tw_slider_count].id = id;
    tw_sliders[tw_slider_count].f = on_change;
    tw_slider_count++;
    tw_puts(&line, "slider");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_int(&json, &line, "low", low);
    tw_field_int(&json, &line, "high", high);
    tw_field_int(&json, &line, "value", value);
    tw_finish("slider", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_load_sample(const char *name)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    const char *id;
    tw_ready();
    id = tw_fresh(name);
    tw_puts(&line, "load");
    tw_field_string(&json, &line, "id", id, 0);
    tw_field_text(&json, &line, "name", name, id);
    tw_finish("load", &json, &line, 0, NULL, 0, NULL, 1);
    return id;
}

const char *tinyweb_fresh_id(const char *name)
{
    tw_ready();
    return tw_fresh(name);
}

/* `mode` says what a page connecting later is sent again: 0 the command,
   1 the command in place of the last of its kind and id, 2 the command
   while no event has been delivered, 3 nothing. */
void tinyweb_command(const char *kind, const char *id, const char *text, const char *numbers,
                     int mode)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 }, key = { NULL, 0, 0 };
    tw_field_json(&json, "kind", kind);
    tw_field_json(&json, "id", id);
    tw_field_json(&json, "text", text);
    tw_field_json(&json, "numbers", numbers);
    tw_puts(&json, ",\"mode\":");
    tw_int(&json, mode);
    tw_puts(&line, kind);
    tw_puts(&line, " ");
    tw_quote(&line, id);
    if (text[0] != '\0') {
        tw_puts(&line, " ");
        tw_quote(&line, text);
    }
    if (numbers[0] != '\0') {
        tw_puts(&line, " ");
        tw_puts(&line, numbers);
    }
    tw_puts(&key, kind);
    tw_add(&key, "\n", 1);
    tw_puts(&key, id);
    tw_send_keyed("cmd", json.text, line.text, 0, NULL, 0, NULL,
                  mode == 3 ? 0 : mode == 2 ? !tw_delivered : 1, key.text, mode == 1);
    free(json.text);
    free(line.text);
    free(key.text);
}

/* The functions `watch` and its kin handed over, by element and kind:
   `f`, or one called with the text reported under `name` (`text`), or
   with the first two numbers reported under `kind` (`step`, `pair`). */
typedef struct {
    char *id;
    char *kind;
    void (*f)(void);
    char *name;
    void (*text)(const char *);
    void (*step)(int, double);
    void (*pair)(double, double);
} tw_callback;
static tw_callback *tw_callbacks = NULL;
static size_t tw_callback_count = 0;

/* Adds a watcher of `kind` for `id`, calling nothing yet; answers it. */
static tw_callback *tw_watching(const char *id, const char *kind)
{
    tw_callback *added;
    tw_ready();
    tw_callbacks = (tw_callback *) tw_grow(tw_callbacks, tw_callback_count, sizeof(tw_callback));
    added = &tw_callbacks[tw_callback_count++];
    added->id = tw_copy(id);
    added->kind = tw_copy(kind);
    added->f = NULL;
    added->name = NULL;
    added->text = NULL;
    added->step = NULL;
    added->pair = NULL;
    return added;
}

void tinyweb_watch(const char *id, const char *kind, void (*f)(void))
{
    tw_watching(id, kind)->f = f;
}

void tinyweb_watch_text(const char *id, const char *kind, const char *name, void (*f)(const char *))
{
    tw_callback *added = tw_watching(id, kind);
    added->name = tw_copy(name);
    added->text = f;
}

void tinyweb_watch_step(const char *id, const char *kind, void (*f)(int, double))
{
    tw_watching(id, kind)->step = f;
}

void tinyweb_watch_pair(const char *id, const char *kind, void (*f)(double, double))
{
    tw_watching(id, kind)->pair = f;
}

/* What the page last reported, by name: numbers, or a text where `text`
   is not NULL. */
typedef struct { char *name; char *text; double *numbers; size_t count; } tw_report;
static tw_report *tw_reports = NULL;
static size_t tw_report_count = 0;

static tw_report *tw_report_named(const char *name)
{
    size_t i;
    for (i = 0; i < tw_report_count; i++) {
        if (strcmp(tw_reports[i].name, name) == 0) return &tw_reports[i];
    }
    return NULL;
}

double tinyweb_report_number(const char *name, int k)
{
    tw_report *found = tw_report_named(name);
    if (found == NULL || found->text != NULL || k < 0 || (size_t) k >= found->count) return 0.0;
    return found->numbers[k];
}

const char *tinyweb_report_text(const char *name)
{
    tw_report *found = tw_report_named(name);
    return found == NULL || found->text == NULL ? "" : found->text;
}

int tinyweb_report_count(const char *name)
{
    tw_report *found = tw_report_named(name);
    return found == NULL || found->text != NULL ? 0 : (int) found->count;
}

void tinyweb_splash(void)
{
    tw_ready();
    tw_send("splash", "", "splash", 0, NULL, 0, NULL, 1);
}

void tinyweb_set_splash(const char *message)
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_ready();
    tw_puts(&line, "splash_text");
    tw_field_string(&json, &line, "text", message, 0);
    tw_finish("splash_text", &json, &line, 0, NULL, 0, NULL, 1);
}

double tinyweb_time(void)
{
    tw_ready();
    return tw_clock;
}

void tinyweb_on_frame(void (*draw)(double))
{
    tw_ready();
    tw_frames = (void (**)(double)) tw_grow((void *) tw_frames, tw_frame_count,
                                            sizeof(void (*)(double)));
    tw_frames[tw_frame_count++] = draw;
    tw_send("on_frame", "", "on_frame", 0, NULL, 0, NULL, 1);
}

void tinyweb_on_mouse(const char *c, void (*click)(int, int))
{
    tw_text json = { NULL, 0, 0 }, line = { NULL, 0, 0 };
    tw_ready();
    tw_mice = (tw_mouse *) tw_grow(tw_mice, tw_mouse_count, sizeof(tw_mouse));
    tw_mice[tw_mouse_count].c = c;
    tw_mice[tw_mouse_count].f = click;
    tw_mouse_count++;
    tw_puts(&line, "on_mouse");
    tw_field_string(&json, &line, "c", c, 0);
    tw_finish("on_mouse", &json, &line, 0, NULL, 0, NULL, 1);
}

void tinyweb_on_key(void (*pressed)(const char *))
{
    tw_ready();
    tw_keys = (void (**)(const char *)) tw_grow((void *) tw_keys, tw_key_count,
                                                sizeof(void (*)(const char *)));
    tw_keys[tw_key_count++] = pressed;
    tw_send("on_key", "", "on_key", 0, NULL, 0, NULL, 1);
}

void tinyweb_on_key_up(void (*released)(const char *))
{
    tw_ready();
    tw_key_ups = (void (**)(const char *)) tw_grow((void *) tw_key_ups, tw_key_up_count,
                                                   sizeof(void (*)(const char *)));
    tw_key_ups[tw_key_up_count++] = released;
    tw_send("on_key", "", "on_key", 0, NULL, 0, NULL, 1);
}

/* Where `key` is among the keys held down, or -1. */
static long tw_held(const char *key)
{
    size_t i;
    for (i = 0; i < tw_down_count; i++) {
        if (strcmp(tw_down[i], key) == 0) return (long) i;
    }
    return -1;
}

bool tinyweb_key_down(const char *key)
{
    tw_ready();
    if (!tw_keys_on && tw_key_count == 0 && tw_key_up_count == 0) {
        tw_keys_on = 1;
        tw_send("on_key", "", "on_key", 0, NULL, 0, NULL, 1);
    }
    return tw_held(key) >= 0 ? true : false;
}

/* --- events --- */

/* One event, as the page posts it or an events file lists it. */
typedef struct {
    char ev[16];
    int has_t;
    double t;
    char *id;
    int value;
    char *c;
    int x;
    int y;
    char *key;
    int checked;
    char *text;
    double width;
    char *kind;
    char *reports;
} tw_event;

static tw_event *tw_queue = NULL;
static size_t tw_queued = 0;

/* Frees what an event holds. */
static void tw_free_event(tw_event *event)
{
    if (event->c != event->id) free(event->c);
    free(event->id);
    free(event->key);
    free(event->text);
    free(event->kind);
    free(event->reports);
}

/* Skips spaces and any of `also`. */
static const char *tw_skip(const char *at, const char *also)
{
    while (*at != '\0' && (strchr(" \t\r\n", *at) != NULL || strchr(also, *at) != NULL)) at++;
    return at;
}

/* Where the object or array starting at `at` ends: just past its closing
   bracket, strings inside it skipped. */
static const char *tw_nested_end(const char *at)
{
    int depth = 0, in_string = 0;
    for (; *at != '\0'; at++) {
        if (in_string) {
            if (*at == '\\' && at[1] != '\0') at++;
            else if (*at == '"') in_string = 0;
        } else if (*at == '"') {
            in_string = 1;
        } else if (*at == '{' || *at == '[') {
            depth++;
        } else if (*at == '}' || *at == ']') {
            if (--depth == 0) return at + 1;
        }
    }
    return at;
}

static const char *tw_string(const char *at, tw_text *out);

/* Replaces what is reported under `name`: a text, or numbers. */
static void tw_set_report(const char *name, char *text, double *numbers, size_t count)
{
    tw_report *found = tw_report_named(name);
    if (found == NULL) {
        tw_reports = (tw_report *) tw_grow(tw_reports, tw_report_count, sizeof(tw_report));
        found = &tw_reports[tw_report_count++];
        found->name = tw_copy(name);
    } else {
        free(found->text);
        free(found->numbers);
    }
    found->text = text;
    found->numbers = numbers;
    found->count = count;
}

/* The entries of a `reports` object, as the page sends them: each name
   with an array of numbers, a number, or a string. */
static void tw_merge_reports(const char *text)
{
    const char *at = text;
    for (;;) {
        tw_text name = { NULL, 0, 0 };
        at = tw_skip(at, ",:{");
        if (*at != '"') return;
        at = tw_string(at + 1, &name);
        if (name.text == NULL) tw_puts(&name, "");
        at = tw_skip(at, ":");
        if (*at == '"') {
            tw_text value = { NULL, 0, 0 };
            at = tw_string(at + 1, &value);
            tw_set_report(name.text, value.text == NULL ? tw_copy("") : value.text, NULL, 0);
        } else if (*at == '[') {
            double *numbers = NULL;
            size_t count = 0;
            at++;
            for (;;) {
                char *end;
                double number;
                at = tw_skip(at, ",");
                if (*at == '\0' || *at == ']') break;
                number = strtod(at, &end);
                if (end == at) {
                    while (*at != '\0' && *at != ',' && *at != ']') at++;
                } else {
                    numbers = (double *) tw_grow(numbers, count, sizeof(double));
                    numbers[count++] = number;
                    at = end;
                }
            }
            if (*at == ']') at++;
            if (numbers == NULL) numbers = (double *) tw_grow(NULL, 0, sizeof(double));
            tw_set_report(name.text, NULL, numbers, count);
        } else {
            char *end;
            double number = strtod(at, &end);
            if (end != at) {
                double *numbers = (double *) tw_grow(NULL, 0, sizeof(double));
                numbers[0] = number;
                tw_set_report(name.text, NULL, numbers, 1);
                at = end;
            }
            while (*at != '\0' && *at != ',' && *at != '}') at++;
        }
        free(name.text);
    }
}

/* Calls what the program handed over for one event, in the order it was
   handed over. */
static void tw_deliver(const tw_event *event)
{
    size_t i;
    tw_delivered = 1;
    if (event->has_t) tw_clock = event->t;
    if (event->reports != NULL) tw_merge_reports(event->reports);
    if (strcmp(event->ev, "cb") == 0) {
        size_t count = tw_callback_count;
        for (i = 0; i < count; i++) {
            if (tw_same(tw_callbacks[i].id, event->id) && tw_same(tw_callbacks[i].kind, event->kind)) {
                /* Copied first: a callback may add watchers, moving the table. */
                tw_callback called = tw_callbacks[i];
                if (called.f != NULL) {
                    called.f();
                } else if (called.text != NULL) {
                    called.text(tinyweb_report_text(called.name));
                } else if (called.step != NULL) {
                    called.step((int) tinyweb_report_number(called.kind, 0),
                                tinyweb_report_number(called.kind, 1));
                } else if (called.pair != NULL) {
                    called.pair(tinyweb_report_number(called.kind, 0),
                                tinyweb_report_number(called.kind, 1));
                }
            }
        }
    } else if (strcmp(event->ev, "click") == 0) {
        for (i = 0; i < tw_button_count; i++) {
            if (tw_same(tw_buttons[i].id, event->id)) tw_buttons[i].f();
        }
    } else if (strcmp(event->ev, "slide") == 0) {
        for (i = 0; i < tw_slider_count; i++) {
            if (tw_same(tw_sliders[i].id, event->id)) tw_sliders[i].f(event->value);
        }
    } else if (strcmp(event->ev, "check") == 0) {
        for (i = 0; i < tw_check_count; i++) {
            if (tw_same(tw_checks[i].id, event->id)) tw_checks[i].f(event->checked ? true : false);
        }
    } else if (strcmp(event->ev, "pick") == 0) {
        for (i = 0; i < tw_radio_count; i++) {
            if (tw_same(tw_radios[i].id, event->id)) tw_radios[i].f(tw_radios[i].title);
        }
    } else if (strcmp(event->ev, "choose") == 0) {
        for (i = 0; i < tw_choice_count; i++) {
            if (tw_same(tw_choices[i].id, event->id)) tw_choices[i].f(event->value);
        }
    } else if (strcmp(event->ev, "enter") == 0) {
        for (i = 0; i < tw_text_field_count; i++) {
            if (tw_same(tw_text_fields[i].id, event->id)) {
                tw_text_fields[i].f(event->text == NULL ? "" : event->text);
            }
        }
    } else if (strcmp(event->ev, "frame") == 0) {
        for (i = 0; i < tw_frame_count; i++) tw_frames[i](tw_clock);
        tw_send("frame_done", "", "frame_done", 0, NULL, 0, NULL, 0);
    } else if (strcmp(event->ev, "mouse") == 0) {
        for (i = 0; i < tw_mouse_count; i++) {
            if (tw_same(tw_mice[i].c, event->c)) tw_mice[i].f(event->x, event->y);
        }
    } else if (strcmp(event->ev, "key") == 0) {
        const char *key = event->key == NULL ? "" : event->key;
        if (tw_held(key) < 0) {
            tw_down = (char **) tw_grow((void *) tw_down, tw_down_count, sizeof(char *));
            tw_down[tw_down_count++] = tw_copy(key);
        }
        for (i = 0; i < tw_key_count; i++) tw_keys[i](key);
    } else if (strcmp(event->ev, "key_up") == 0) {
        const char *key = event->key == NULL ? "" : event->key;
        long at = tw_held(key);
        if (at >= 0) {
            free(tw_down[at]);
            tw_down[at] = tw_down[tw_down_count - 1];
            tw_down_count--;
        }
        for (i = 0; i < tw_key_up_count; i++) tw_key_ups[i](key);
    } else if (strcmp(event->ev, "press") == 0 || strcmp(event->ev, "release") == 0
               || strcmp(event->ev, "move") == 0) {
        tw_pointer_seen *seen = tw_pointer_of(event->c);
        if (seen != NULL) {
            int x, y, drag;
            seen->x = event->x;
            seen->y = event->y;
            if (strcmp(event->ev, "press") == 0) seen->down = 1;
            else if (strcmp(event->ev, "release") == 0) seen->down = 0;
            x = seen->x;
            y = seen->y;
            drag = strcmp(event->ev, "move") == 0 && seen->down;
            for (i = 0; i < tw_watcher_count; i++) {
                if (tw_same(tw_watchers[i].c, event->c)
                    && strcmp(tw_watchers[i].kind, event->ev) == 0) {
                    tw_watchers[i].f(x, y);
                }
            }
            if (drag) {
                for (i = 0; i < tw_watcher_count; i++) {
                    if (tw_same(tw_watchers[i].c, event->c)
                        && strcmp(tw_watchers[i].kind, "drag") == 0) {
                        tw_watchers[i].f(x, y);
                    }
                }
            }
        }
    } else if (strcmp(event->ev, "measured") == 0) {
        for (i = 0; i < tw_measure_count; i++) {
            if (!tw_measures[i].answered && tw_same(tw_measures[i].id, event->id)) {
                tw_measures[i].answered = 1;
                tw_measures[i].f(event->width);
                break;
            }
        }
    }
}

/* Appends the UTF-8 for one code point. */
static void tw_utf8(tw_text *out, unsigned long code)
{
    char bytes[4];
    if (code < 0x80) {
        bytes[0] = (char) code;
        tw_add(out, bytes, 1);
    } else if (code < 0x800) {
        bytes[0] = (char) (0xC0 | (code >> 6));
        bytes[1] = (char) (0x80 | (code & 0x3F));
        tw_add(out, bytes, 2);
    } else {
        bytes[0] = (char) (0xE0 | (code >> 12));
        bytes[1] = (char) (0x80 | ((code >> 6) & 0x3F));
        bytes[2] = (char) (0x80 | (code & 0x3F));
        tw_add(out, bytes, 3);
    }
}

/* Reads a JSON string starting just after its opening quote, answering
   where it ends. */
static const char *tw_string(const char *at, tw_text *out)
{
    while (*at != '\0' && *at != '"') {
        if (*at == '\\' && at[1] != '\0') {
            at++;
            switch (*at) {
            case 'n': tw_puts(out, "\n"); break;
            case 't': tw_puts(out, "\t"); break;
            case 'r': tw_puts(out, "\r"); break;
            case 'b': tw_puts(out, "\b"); break;
            case 'f': tw_puts(out, "\f"); break;
            case 'u': {
                char hex[5];
                if (strlen(at) < 5) return at + strlen(at);
                memcpy(hex, at + 1, 4);
                hex[4] = '\0';
                tw_utf8(out, strtoul(hex, NULL, 16));
                at += 4;
                break;
            }
            default: tw_add(out, at, 1);
            }
            at++;
        } else {
            tw_add(out, at, 1);
            at++;
        }
    }
    return *at == '"' ? at + 1 : at;
}

/* The event a page posted: one JSON object, of strings, numbers and
   `reports`. */
static tw_event tw_parse_event(const char *text)
{
    tw_event event;
    const char *at = text;
    memset(&event, 0, sizeof event);
    while (*at != '\0') {
        tw_text key = { NULL, 0, 0 };
        while (*at != '\0' && *at != '"') at++;
        if (*at == '\0') break;
        at = tw_string(at + 1, &key);
        while (*at == ' ' || *at == ':' || *at == '\t' || *at == '\n' || *at == '\r') at++;
        if (*at == '"') {
            tw_text value = { NULL, 0, 0 };
            at = tw_string(at + 1, &value);
            if (key.text != NULL && strcmp(key.text, "ev") == 0 && value.text != NULL) {
                strncpy(event.ev, value.text, sizeof event.ev - 1);
            } else if (key.text != NULL && (strcmp(key.text, "key") == 0
                                            || strcmp(key.text, "id") == 0
                                            || strcmp(key.text, "text") == 0
                                            || strcmp(key.text, "kind") == 0
                                            || strcmp(key.text, "c") == 0)) {
                char *text = value.text == NULL ? tw_copy("") : value.text;
                char **field = strcmp(key.text, "key") == 0 ? &event.key
                    : strcmp(key.text, "id") == 0 ? &event.id
                    : strcmp(key.text, "text") == 0 ? &event.text
                    : strcmp(key.text, "kind") == 0 ? &event.kind : &event.c;
                free(*field);
                *field = text;
                value.text = NULL;
            }
            free(value.text);
        } else if (*at == '{' || *at == '[') {
            const char *end = tw_nested_end(at);
            if (key.text != NULL && strcmp(key.text, "reports") == 0) {
                tw_text value = { NULL, 0, 0 };
                tw_add(&value, at, (size_t) (end - at));
                free(event.reports);
                event.reports = value.text;
            }
            at = end;
        } else if (key.text != NULL && strcmp(key.text, "checked") == 0) {
            event.checked = strncmp(at, "true", 4) == 0;
            while (*at != '\0' && *at != ',' && *at != '}') at++;
        } else {
            char *end;
            double number = strtod(at, &end);
            if (end != at && key.text != NULL) {
                if (strcmp(key.text, "t") == 0) {
                    event.has_t = 1;
                    event.t = number;
                } else if (strcmp(key.text, "value") == 0) event.value = (int) number;
                else if (strcmp(key.text, "x") == 0) event.x = (int) number;
                else if (strcmp(key.text, "y") == 0) event.y = (int) number;
                else if (strcmp(key.text, "width") == 0) event.width = number;
                else if (strcmp(key.text, "id") == 0) {
                    /* An `sdelay` answer's number. */
                    char digits[32];
                    sprintf(digits, "%d", (int) number);
                    free(event.id);
                    event.id = tw_copy(digits);
                }
            }
            while (*at != '\0' && *at != ',' && *at != '}') at++;
        }
        free(key.text);
    }
    return event;
}

/* A `cb`, `report` or `report_text` line of an events file after its
   first word: quoted strings, then numbers for a report. */
static int tw_parse_generic(const char *word, const char *at, tw_event *event)
{
    tw_text first = { NULL, 0, 0 }, reports = { NULL, 0, 0 };
    int ok = 1;
    if (*at != '"') return 0;
    at = tw_string(at + 1, &first);
    if (first.text == NULL) tw_puts(&first, "");
    at = tw_skip(at, "");
    if (strcmp(word, "report") == 0) {
        int count = 0;
        strcpy(event->ev, "report");
        tw_puts(&reports, "{");
        tw_quote(&reports, first.text);
        tw_puts(&reports, ":[");
        while (*at != '\0') {
            char *end;
            size_t length = strcspn(at, " \t\r\n");
            strtod(at, &end);
            if (end != at + length) {
                ok = 0;
                break;
            }
            if (count++ > 0) tw_puts(&reports, ",");
            tw_add(&reports, at, length);
            at = tw_skip(end, "");
        }
        tw_puts(&reports, "]}");
    } else {
        tw_text second = { NULL, 0, 0 };
        if (*at != '"') {
            free(first.text);
            return 0;
        }
        at = tw_string(at + 1, &second);
        if (second.text == NULL) tw_puts(&second, "");
        if (*tw_skip(at, "") != '\0') ok = 0;
        if (strcmp(word, "cb") == 0) {
            strcpy(event->ev, "cb");
            event->id = first.text;
            event->kind = second.text;
            return ok;
        }
        strcpy(event->ev, "report");
        tw_puts(&reports, "{");
        tw_quote(&reports, first.text);
        tw_puts(&reports, ":");
        tw_quote(&reports, second.text);
        tw_puts(&reports, "}");
        free(second.text);
    }
    free(first.text);
    event->reports = reports.text;
    return ok;
}

/* One line of an events file as the event the page would send; 0 where
   it names none. The element an event is on is a quoted string, which
   may hold spaces, and the numbers it takes follow it. */
static int tw_parse_line(const char *line, tw_event *event)
{
    char word[16];
    double numbers[3];
    int n = 0, wanted;
    const char *at = line;
    size_t length;
    memset(event, 0, sizeof *event);
    if (strncmp(line, "key ", 4) == 0) {
        strcpy(event->ev, "key");
        event->key = tw_copy(line + 4);
        return 1;
    }
    if (strncmp(line, "key_up ", 7) == 0) {
        strcpy(event->ev, "key_up");
        event->key = tw_copy(line + 7);
        return 1;
    }
    while (*at == ' ') at++;
    length = strcspn(at, " ");
    if (length == 0 || length >= sizeof word) return 0;
    memcpy(word, at, length);
    word[length] = '\0';
    at += length;
    strcpy(event->ev, word);
    while (*at == ' ') at++;
    if (strcmp(word, "cb") == 0 || strcmp(word, "report") == 0
        || strcmp(word, "report_text") == 0) {
        return tw_parse_generic(word, at, event);
    }
    if (strcmp(word, "frame") == 0) {
        wanted = 1;
    } else {
        tw_text id = { NULL, 0, 0 };
        if (strcmp(word, "click") == 0 || strcmp(word, "pick") == 0) wanted = 0;
        else if (strcmp(word, "slide") == 0 || strcmp(word, "choose") == 0) wanted = 1;
        else if (strcmp(word, "mouse") == 0 || strcmp(word, "press") == 0
                 || strcmp(word, "release") == 0 || strcmp(word, "move") == 0) wanted = 2;
        else if (strcmp(word, "measured") == 0) wanted = 1;
        else if (strcmp(word, "check") == 0 || strcmp(word, "enter") == 0) wanted = -1;
        else return 0;
        if (*at != '"') return 0;
        at = tw_string(at + 1, &id);
        event->id = id.text == NULL ? tw_copy("") : id.text;
        event->c = event->id;
        while (*at == ' ') at++;
        if (strcmp(word, "check") == 0) {
            if (strncmp(at, "true", 4) == 0) { event->checked = 1; at += 4; }
            else if (strncmp(at, "false", 5) == 0) { event->checked = 0; at += 5; }
            else return 0;
            while (*at == ' ' || *at == '\r') at++;
            return *at == '\0';
        }
        if (strcmp(word, "enter") == 0) {
            tw_text typed = { NULL, 0, 0 };
            if (*at != '"') return 0;
            at = tw_string(at + 1, &typed);
            event->text = typed.text == NULL ? tw_copy("") : typed.text;
            while (*at == ' ' || *at == '\r') at++;
            return *at == '\0';
        }
    }
    /* The numbers, and nothing after them. */
    for (;;) {
        char *end;
        double number;
        while (*at == ' ' || *at == '\r') at++;
        if (*at == '\0') break;
        number = strtod(at, &end);
        if (end == at || n == 3) return 0;
        numbers[n++] = number;
        at = end;
    }
    if (n != wanted) return 0;
    if (strcmp(word, "frame") == 0) {
        event->has_t = 1;
        event->t = numbers[0];
    } else if (strcmp(word, "slide") == 0 || strcmp(word, "choose") == 0) {
        event->value = (int) numbers[0];
    } else if (strcmp(word, "measured") == 0) {
        event->width = numbers[0];
    } else if (strcmp(word, "mouse") == 0 || strcmp(word, "press") == 0
               || strcmp(word, "release") == 0 || strcmp(word, "move") == 0) {
        event->x = (int) numbers[0];
        event->y = (int) numbers[1];
    }
    return 1;
}

/* The events file, once the top level has ended: each line logged as it
   is delivered. */
static void tw_deliver_file(void)
{
    FILE *file;
    tw_text all = { NULL, 0, 0 };
    char chunk[4096];
    size_t got;
    char *line;
    if (tw_events == NULL) return;
    file = fopen(tw_events, "r");
    if (file == NULL) return;
    while ((got = fread(chunk, 1, sizeof chunk, file)) > 0) tw_add(&all, chunk, got);
    fclose(file);
    if (all.text == NULL) return;
    line = all.text;
    while (line != NULL) {
        char *end = strchr(line, '\n');
        const char *at;
        int blank = 1;
        if (end != NULL) *end = '\0';
        for (at = line; *at != '\0'; at++) {
            if (*at != ' ' && *at != '\t' && *at != '\r') blank = 0;
        }
        if (!blank) {
            tw_event event;
            tw_text logged = { NULL, 0, 0 };
            tw_puts(&logged, "> ");
            tw_puts(&logged, line);
            tw_write_log(logged.text);
            free(logged.text);
            if (tw_parse_line(line, &event)) {
                tw_deliver(&event);
                tw_free_event(&event);
            } else {
                tw_text unknown = { NULL, 0, 0 };
                tw_free_event(&event);
                tw_puts(&unknown, "! unknown event: ");
                tw_puts(&unknown, line);
                tw_write_log(unknown.text);
                free(unknown.text);
            }
        }
        line = end == NULL ? NULL : end + 1;
    }
    free(all.text);
}

/* --- the server --- */

static void tw_close(int socket)
{
    close(socket);
}

static void tw_reply(int socket, int status, const char *kind, const char *body, size_t length)
{
    char head[512];
    const char *reason = status == 200 ? "OK" : status == 204 ? "No Content" : "Not Found";
    sprintf(head,
            "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %lu\r\n"
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
            status, reason, kind, (unsigned long) length);
    if (tw_write_all(socket, head, strlen(head))) tw_write_all(socket, body, length);
    tw_close(socket);
}

static void tw_reply_lines(int socket, const char *kind, const char *const *lines)
{
    tw_text body = { NULL, 0, 0 };
    size_t i;
    for (i = 0; lines[i] != NULL; i++) tw_puts(&body, lines[i]);
    tw_reply(socket, 200, kind, body.text == NULL ? "" : body.text, body.length);
    free(body.text);
}

static const char *tw_content_type(const char *path)
{
    const char *dot = strrchr(path, '.');
    if (dot == NULL) return "application/octet-stream";
    if (strcmp(dot, ".html") == 0) return "text/html; charset=utf-8";
    if (strcmp(dot, ".js") == 0) return "text/javascript; charset=utf-8";
    if (strcmp(dot, ".css") == 0) return "text/css; charset=utf-8";
    if (strcmp(dot, ".json") == 0) return "application/json";
    if (strcmp(dot, ".wav") == 0) return "audio/wav";
    if (strcmp(dot, ".mp3") == 0) return "audio/mpeg";
    if (strcmp(dot, ".ogg") == 0) return "audio/ogg";
    if (strcmp(dot, ".png") == 0) return "image/png";
    if (strcmp(dot, ".jpg") == 0) return "image/jpeg";
    if (strcmp(dot, ".svg") == 0) return "image/svg+xml";
    return "application/octet-stream";
}

/* Answers a file beside where the program runs -- a sample beside the
   program, or one of tinyweb_assets/ the compiler copied there, or into
   the build/ there, where `pyk compile` leaves them when it puts the
   executable outside. */
static void tw_static(int socket, const char *path)
{
    const char *at = path;
    struct stat info;
    FILE *file = NULL;
    tw_text body = { NULL, 0, 0 };
    tw_text built = { NULL, 0, 0 };
    char chunk[4096];
    size_t got;
    while (*at == '/') at++;
    if (*at != '\0' && strstr(at, "..") == NULL) {
        if (stat(at, &info) == 0 && S_ISREG(info.st_mode)) {
            file = fopen(at, "rb");
        } else {
            tw_add(&built, "build/", 6);
            tw_add(&built, at, strlen(at));
            tw_add(&built, "", 1);
            if (stat(built.text, &info) == 0 && S_ISREG(info.st_mode)) file = fopen(built.text, "rb");
        }
    }
    free(built.text);
    if (file == NULL) {
        tw_reply(socket, 404, "text/plain", "not found\n", 10);
        return;
    }
    while ((got = fread(chunk, 1, sizeof chunk, file)) > 0) tw_add(&body, chunk, got);
    fclose(file);
    tw_reply(socket, 200, tw_content_type(at), body.text == NULL ? "" : body.text, body.length);
    free(body.text);
}

/* One request on a socket just accepted: read whole, then answered. */
static void tw_serve(int socket)
{
    tw_text request = { NULL, 0, 0 };
    char chunk[4096];
    char *end = NULL;
    char method[8], target[1024];
    long length = 0;
    const char *found;
    ssize_t got;
    while (end == NULL) {
        got = read(socket, chunk, sizeof chunk);
        if (got <= 0) {
            free(request.text);
            tw_close(socket);
            return;
        }
        tw_add(&request, chunk, (size_t) got);
        end = strstr(request.text, "\r\n\r\n");
    }
    found = strstr(request.text, "Content-Length:");
    if (found == NULL) found = strstr(request.text, "content-length:");
    if (found != NULL && found < end) length = strtol(found + 15, NULL, 10);
    while ((long) (request.length - (size_t) (end - request.text) - 4) < length) {
        size_t offset = (size_t) (end - request.text);
        got = read(socket, chunk, sizeof chunk);
        if (got <= 0) break;
        tw_add(&request, chunk, (size_t) got);
        end = request.text + offset;
    }
    if (sscanf(request.text, "%7s %1023s", method, target) != 2) {
        free(request.text);
        tw_close(socket);
        return;
    }
    {
        char *query = strchr(target, '?');
        if (query != NULL) *query = '\0';
    }
    if (strcmp(method, "POST") == 0 && strcmp(target, "/events") == 0) {
        const char *answer = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        tw_queue = (tw_event *) tw_grow(tw_queue, tw_queued, sizeof(tw_event));
        tw_queue[tw_queued++] = tw_parse_event(end + 4);
        tw_write_all(socket, answer, strlen(answer));
        tw_close(socket);
    } else if (strcmp(method, "GET") != 0) {
        tw_reply(socket, 404, "text/plain", "not found\n", 10);
    } else if (strcmp(target, "/") == 0 || strcmp(target, "/index.html") == 0) {
        tw_reply_lines(socket, "text/html; charset=utf-8", tinyweb_page_html);
    } else if (strcmp(target, "/tinyweb_page.js") == 0) {
        tw_reply_lines(socket, "text/javascript; charset=utf-8", tinyweb_page_js);
    } else if (strcmp(target, "/commands") == 0) {
        const char *head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                           "Cache-Control: no-store\r\n\r\n: tinyweb\n\n";
        if (tw_write_all(socket, head, strlen(head))) {
            int sent = 1;
            if (tw_history_count > 0) {
                tw_text batch = { NULL, 0, 0 };
                size_t i;
                tw_puts(&batch, "data: [");
                for (i = 0; i < tw_history_count; i++) {
                    if (i > 0) tw_puts(&batch, ",");
                    tw_puts(&batch, tw_history[i].json);
                }
                tw_puts(&batch, "]\n\n");
                sent = tw_write_all(socket, batch.text, batch.length);
                free(batch.text);
            }
            if (sent) {
                tw_clients = (int *) tw_grow(tw_clients, tw_client_count, sizeof(int));
                tw_clients[tw_client_count++] = socket;
            } else {
                tw_close(socket);
            }
        } else {
            tw_close(socket);
        }
    } else {
        tw_static(socket, target);
    }
    free(request.text);
}

/* Answers whatever is waiting on the server's sockets, waiting for
   something to be. */
static void tw_poll(void)
{
    fd_set ready;
    int highest = tw_listener;
    size_t i;
    FD_ZERO(&ready);
    FD_SET(tw_listener, &ready);
    for (i = 0; i < tw_client_count; i++) {
        FD_SET(tw_clients[i], &ready);
        if (tw_clients[i] > highest) highest = tw_clients[i];
    }
    if (select(highest + 1, &ready, NULL, NULL, NULL) < 0) return;
    i = 0;
    while (i < tw_client_count) {
        /* A page's stream has nothing to say: readable means it has
           gone. */
        if (FD_ISSET(tw_clients[i], &ready)) {
            char scratch[64];
            if (read(tw_clients[i], scratch, sizeof scratch) <= 0) {
                tw_close(tw_clients[i]);
                tw_clients[i] = tw_clients[tw_client_count - 1];
                tw_client_count--;
                continue;
            }
        }
        i++;
    }
    if (FD_ISSET(tw_listener, &ready)) {
        int client = accept(tw_listener, NULL, NULL);
        if (client >= 0) {
            struct timeval wait;
            wait.tv_sec = 5;
            wait.tv_usec = 0;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const void *) &wait, sizeof wait);
            tw_serve(client);
        }
    }
}

/* Takes the first event the page posted off the queue, answering 0
   where there is none. One at a time, so an `sdelay` in what an event
   calls can take the ones after it. */
static int tw_next_event(tw_event *event)
{
    if (tw_queued == 0) return 0;
    *event = tw_queue[0];
    tw_queued--;
    memmove(tw_queue, tw_queue + 1, tw_queued * sizeof(tw_event));
    return 1;
}

/* Delivers one event the page posted, then says it is done. */
static void tw_answer_event(tw_event *event)
{
    tw_deliver(event);
    tw_send("event_done", "", "event_done", 0, NULL, 0, NULL, 0);
    fflush(stdout);
    tw_flush();
    tw_free_event(event);
}

/* What runs once main has returned: the events file's events, or the
   page's, until the program is stopped. */
static void tw_after_program(void)
{
    static int running = 0;
    tw_event event;
    if (running) return;
    running = 1;
    if (tw_log != NULL) {
        tw_deliver_file();
        return;
    }
    if (tw_listener < 0) return;
    /* What the top level printed is out before the page is served, which
       goes on until the program is stopped. */
    fflush(stdout);
    tw_batching = 1;
    for (;;) {
        tw_poll();
        while (tw_next_event(&event)) tw_answer_event(&event);
    }
}

/* Forgets the `sdelay` the page has answered: a page connecting later
   is sent only one still waiting. */
static void tw_forget(const char *key)
{
    size_t i, kept = 0;
    for (i = 0; i < tw_history_count; i++) {
        tw_command *old = &tw_history[i];
        if (tw_same(old->key, key)) {
            free(old->json);
            free(old->line);
            free(old->key);
        } else {
            tw_history[kept++] = *old;
        }
    }
    tw_history_count = kept;
}

/* Sends `sdelay` and waits for the page to answer it, serving the page
   and delivering its other events meanwhile. With no page, moves the
   clock on to where it ends instead. */
void tinyweb_sdelay(double time)
{
    double seconds = time > 0.0 ? time : 0.0;
    tw_text json = { NULL, 0, 0 };
    tw_text line = { NULL, 0, 0 };
    char key[48];
    char digits[32];
    int id, was, answered = 0;
    tw_event event;
    tw_ready();
    id = ++tw_sdelays;
    tw_puts(&line, "sdelay");
    tw_puts(&json, ",\"id\":");
    tw_int(&json, id);
    tw_field_float(&json, &line, "seconds", seconds);
    sprintf(key, "sdelay %d", id);
    sprintf(digits, "%d", id);
    tw_send_keyed("sdelay", json.text, line.text, 0, NULL, 0, NULL, 1, key, 0);
    free(json.text);
    free(line.text);
    if (tw_log != NULL) {
        if (!tw_sdelay_ended) tw_sdelay_end = tw_clock + seconds;
        else tw_sdelay_end = tw_sdelay_end + seconds > tw_clock ? tw_sdelay_end + seconds : tw_clock;
        tw_sdelay_ended = 1;
        tw_clock = tw_sdelay_end;
        return;
    }
    /* Sound played after the first `sdelay` is live: a page connecting
       later is not sent it, as it is not sent a callback's. */
    tw_delivered = 1;
    fflush(stdout);
    tw_flush();
    was = tw_batching;
    while (!answered) {
        if (tw_queued == 0) tw_poll();
        while (!answered && tw_next_event(&event)) {
            if (strcmp(event.ev, "sdelay") == 0) {
                if (tw_same(event.id, digits)) {
                    tw_deliver(&event);
                    tw_forget(key);
                    answered = 1;
                }
                tw_free_event(&event);
            } else {
                tw_batching = 1;
                tw_answer_event(&event);
                tw_batching = was;
            }
        }
    }
    tw_batching = was;
}

void tinyweb_web_start(int port)
{
    struct sockaddr_in address;
    socklen_t size = sizeof address;
    int yes = 1;
    char message[160];
    tw_environment();
    if (tw_log != NULL || tw_listener >= 0) return;
    if (port < 0 || port > 65535) {
        sprintf(message, "tinyweb: cannot serve the page on port %d: "
                "a port is a number from 0 to 65535", port);
        tw_refuse(message);
    }
    signal(SIGPIPE, SIG_IGN);
    tw_listener = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(tw_listener, SOL_SOCKET, SO_REUSEADDR, (const void *) &yes, sizeof yes);
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short) port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (tw_listener < 0 || bind(tw_listener, (struct sockaddr *) &address, sizeof address) != 0
        || listen(tw_listener, 16) != 0) {
        sprintf(message, "tinyweb: cannot serve the page on port %d: %.80s", port,
                strerror(errno));
        tw_refuse(message);
    }
    getsockname(tw_listener, (struct sockaddr *) &address, &size);
    printf("tinyweb: http://127.0.0.1:%d/\n", (int) ntohs(address.sin_port));
    fflush(stdout);
    atexit(tw_after_program);
}
