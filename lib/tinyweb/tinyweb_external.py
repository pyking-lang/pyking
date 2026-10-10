# The Python implementation of the names declared in
# tinyweb_external.pyk, for python14.
#
# A program talks to its page in commands and the page answers in
# events (docs/libraries.md, "tinyweb"). Where the program runs decides
# where they go:
#
#   - $PYKING_TINYWEB_LOG set: no page. Each command is a line in that
#     file, and once the top level has ended the events
#     $PYKING_TINYWEB_EVENTS lists are delivered -- how a program is
#     tested.
#   - otherwise `web_init(port)` serves the page, tinyweb_page.html and
#     tinyweb_page.js (copied into this file below), from a server on a
#     thread of its own: GET /commands is a stream of command batches
#     (server-sent events) and POST /events one event each. Once the top
#     level has ended, the events are delivered in the order they came,
#     each answered with `event_done` once what it caused has been sent,
#     until the program is stopped.
#   - neither: the first call says `web_init` is missing, and the
#     program ends with status 1.
#
# Callbacks run on the main thread, after the top level, from an atexit
# handler; a `sys.exit` in one ends the program with its status.

import atexit as _atexit
import json as _json
import os as _os
import queue as _queue
import sys as _sys
import threading as _threading
import traceback as _traceback
from http.server import BaseHTTPRequestHandler as _Handler
from http.server import ThreadingHTTPServer as _Server

_LOG = _os.environ.get("PYKING_TINYWEB_LOG")
_EVENTS = _os.environ.get("PYKING_TINYWEB_EVENTS")

_last = 0
_clock = 0.0
_buttons = {}
_sliders = {}
_mice = {}
_frames = []
_keys = []
_after = False
_hub = None


# --- commands ---

def _quote(text):
    return _json.dumps(text, ensure_ascii=False)


def _seconds(x):
    return f"{x:.3f}"


def _log_line(command):
    """A command as the one line every headless implementation writes."""
    op = command["op"]
    c = command.get
    if op == "canvas":
        return f"canvas {c('id')} {c('width')} {c('height')}"
    if op == "clear":
        return f"clear {c('c')} {c('color')}"
    if op == "circle":
        return f"circle {c('c')} {c('x')} {c('y')} {c('radius')} {c('color')}"
    if op == "rect":
        return f"rect {c('c')} {c('x')} {c('y')} {c('width')} {c('height')} {c('color')}"
    if op == "line":
        return f"line {c('c')} {c('x1')} {c('y1')} {c('x2')} {c('y2')} {c('color')} {c('width')}"
    if op == "text":
        return f"text {c('c')} {c('x')} {c('y')} {c('color')} {c('size')} {_quote(c('words'))}"
    if op == "button":
        return f"button {c('id')} {_quote(c('title'))}"
    if op == "label":
        return f"label {c('id')} {_quote(c('text'))}"
    if op == "set_label":
        return f"set_label {c('id')} {_quote(c('text'))}"
    if op == "slider":
        return f"slider {c('id')} {c('low')} {c('high')} {c('value')}"
    if op == "load":
        return f"load {c('id')} {_quote(c('name'))}"
    if op == "play":
        return f"play {c('sample')} {_seconds(c('at'))} {_seconds(c('volume'))} {_seconds(c('rate'))}"
    if op == "on_mouse":
        return f"on_mouse {c('c')}"
    return op


def _write_log(line):
    with open(_LOG, "a", encoding="utf-8") as log:
        log.write(line + "\n")


def _ready():
    """Says what every function but `web_init` needs first: a log to
    write to, or a page served."""
    global _after
    if _LOG is not None:
        if not _after:
            _after = True
            _atexit.register(_after_program)
        return
    if _hub is None:
        _refuse("tinyweb: call tinyweb.web_init(port) before anything else, "
                "or set PYKING_TINYWEB_LOG")


def _refuse(message):
    """Ends the program with `message`, and with status 1."""
    _sys.stdout.flush()
    _sys.stderr.write(message + "\n")
    _sys.stderr.flush()
    _os._exit(1)


def _send(command):
    _ready()
    if _LOG is not None:
        if command["op"] not in ("frame_done", "event_done"):
            _write_log(_log_line(command))
    else:
        _hub.send(command)


def _fresh():
    global _last
    _last += 1
    return _last


# --- the functions tinyweb_external.pyk declares ---

def web_init(port):
    global _hub
    if _LOG is not None or _hub is not None:
        return
    if not 0 <= port <= 65535:
        _refuse(f"tinyweb: cannot serve the page on port {port}: "
                "a port is a number from 0 to 65535")
    _hub = _Hub(port)
    print(f"tinyweb: http://127.0.0.1:{_hub.port}/", flush=True)
    _atexit.register(_after_program)


def canvas(width, height):
    _ready()
    id = _fresh()
    _send({"op": "canvas", "id": id, "width": width, "height": height})
    return id


def fill_canvas(c, color):
    _send({"op": "clear", "c": c, "color": color})


def draw_circle(c, x, y, radius, color):
    _send({"op": "circle", "c": c, "x": x, "y": y, "radius": radius, "color": color})


def draw_rect(c, x, y, width, height, color):
    _send({"op": "rect", "c": c, "x": x, "y": y, "width": width, "height": height,
           "color": color})


def draw_line(c, x1, y1, x2, y2, color, width):
    _send({"op": "line", "c": c, "x1": x1, "y1": y1, "x2": x2, "y2": y2,
           "color": color, "width": width})


def draw_text(c, x, y, words, color, size):
    _send({"op": "text", "c": c, "x": x, "y": y, "color": color, "size": size,
           "words": words})


def make_button(title, on_click):
    _ready()
    id = _fresh()
    _buttons[id] = on_click
    _send({"op": "button", "id": id, "title": title})
    return id


def label(text):
    _ready()
    id = _fresh()
    _send({"op": "label", "id": id, "text": text})
    return id


def set_label(id, text):
    _send({"op": "set_label", "id": id, "text": text})


def make_slider(low, high, value, on_change):
    _ready()
    id = _fresh()
    _sliders[id] = on_change
    _send({"op": "slider", "id": id, "low": low, "high": high, "value": value})
    return id


def load_sample(name):
    _ready()
    id = _fresh()
    _send({"op": "load", "id": id, "name": name})
    return id


def play_sample(sample, at, volume, rate):
    _send({"op": "play", "sample": sample, "at": at, "volume": volume, "rate": rate})


def time():
    _ready()
    return _clock


def on_frame(draw):
    _ready()
    _frames.append(draw)
    _send({"op": "on_frame"})


def on_mouse(c, click):
    _ready()
    _mice.setdefault(c, []).append(click)
    _send({"op": "on_mouse", "c": c})


def on_key(pressed):
    _ready()
    _keys.append(pressed)
    _send({"op": "on_key"})


# --- events ---

def _deliver(event):
    """Calls what the program handed over for one event, in the order it
    was handed over."""
    global _clock
    t = event.get("t")
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        _clock = float(t)
    kind = event.get("ev")
    if kind == "click":
        if event.get("id") in _buttons:
            _buttons[event["id"]]()
    elif kind == "slide":
        if event.get("id") in _sliders:
            _sliders[event["id"]](int(event["value"]))
    elif kind == "frame":
        for draw in list(_frames):
            draw(_clock)
        _send({"op": "frame_done"})
    elif kind == "mouse":
        for click in list(_mice.get(event.get("c"), [])):
            click(int(event["x"]), int(event["y"]))
    elif kind == "key":
        for pressed in list(_keys):
            pressed(str(event["key"]))


def _parse_event(line):
    """One line of an events file as the event the page would send, or
    None."""
    if line.startswith("key "):
        return {"ev": "key", "key": line[4:]}
    words = line.split()
    try:
        if words[0] == "click" and len(words) == 2:
            return {"ev": "click", "id": int(words[1])}
        if words[0] == "slide" and len(words) == 3:
            return {"ev": "slide", "id": int(words[1]), "value": int(words[2])}
        if words[0] == "frame" and len(words) == 2:
            return {"ev": "frame", "t": float(words[1])}
        if words[0] == "mouse" and len(words) == 4:
            return {"ev": "mouse", "c": int(words[1]), "x": int(words[2]),
                    "y": int(words[3])}
    except ValueError:
        return None
    return None


def _after_program():
    """What runs once the top level has ended: the events file's events,
    or the page's, until the program is stopped."""
    try:
        if _LOG is not None:
            if _EVENTS and _os.path.exists(_EVENTS):
                with open(_EVENTS, encoding="utf-8") as events:
                    lines = events.read().split("\n")
                for line in lines:
                    if line.strip() == "":
                        continue
                    _write_log("> " + line)
                    event = _parse_event(line)
                    if event is None:
                        _write_log("! unknown event: " + line)
                    else:
                        _deliver(event)
        elif _hub is not None:
            _hub.batching = True
            while True:
                _deliver(_hub.events.get())
                _send({"op": "event_done"})
                _hub.flush()
                _sys.stdout.flush()
    except KeyboardInterrupt:
        _finish(130)
    except SystemExit as stop:
        _finish(stop.code if isinstance(stop.code, int) else 1)
    except BaseException:
        _traceback.print_exc()
        _finish(1)


def _finish(code):
    _sys.stdout.flush()
    _sys.stderr.flush()
    _os._exit(code)


# --- the server ---

class _Hub:
    """The page's server: the commands sent so far, every page connected,
    and the events they have posted."""

    def __init__(self, port):
        self.lock = _threading.Lock()
        self.history = []
        self.pending = []
        self.clients = []
        self.events = _queue.Queue()
        self.batching = False
        hub = self

        class Handler(_PageHandler):
            pass

        Handler.hub = hub
        try:
            self.server = _Server(("127.0.0.1", port), Handler)
        except OSError as error:
            _refuse(f"tinyweb: cannot serve the page on port {port}: "
                    f"{error.strerror or error}")
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        _threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def send(self, command):
        """Keeps a command for every page connected later, and sends it to
        every page connected now -- at once from the top level, and with
        the rest of its batch from a callback."""
        with self.lock:
            self.history = _kept(self.history, command)
            self.pending.append(command)
        if not self.batching:
            self.flush()

    def flush(self):
        with self.lock:
            batch, self.pending = self.pending, []
            clients = list(self.clients)
        if batch:
            for client in clients:
                client.put(batch)

    def connect(self):
        client = _queue.Queue()
        with self.lock:
            history = list(self.history)
            self.clients.append(client)
        if history:
            client.put(history)
        return client

    def disconnect(self, client):
        with self.lock:
            if client in self.clients:
                self.clients.remove(client)


def _kept(history, command):
    """The commands a page connecting now has to be sent, once `command`
    has been: everything but sound and frame bookkeeping, less what a
    later command has made invisible -- a canvas's drawing before it was
    cleared, a label's text before it was set again."""
    op = command["op"]
    if op in ("play", "frame_done", "event_done"):
        return history
    if op == "clear":
        drawing = ("clear", "circle", "rect", "line", "text")
        history = [h for h in history if not (h["op"] in drawing and h.get("c") == command["c"])]
    elif op == "set_label":
        history = [h for h in history
                   if not (h["op"] == "set_label" and h["id"] == command["id"])]
    return history + [command]


_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
          ".css": "text/css; charset=utf-8", ".json": "application/json",
          ".wav": "audio/wav", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
          ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml"}


class _PageHandler(_Handler):
    hub = None
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def _reply(self, status, body, kind):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return self._reply(200, _PAGE_HTML.encode(), _TYPES[".html"])
        if path == "/tinyweb_page.js":
            return self._reply(200, _PAGE_JS.encode(), _TYPES[".js"])
        if path == "/commands":
            return self._stream()
        found = _static(path)
        if found is None:
            return self._reply(404, b"not found\n", "text/plain")
        with open(found, "rb") as f:
            body = f.read()
        self._reply(200, body, _TYPES.get(_os.path.splitext(found)[1], "application/octet-stream"))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if self.path.split("?", 1)[0] != "/events":
            return self._reply(404, b"not found\n", "text/plain")
        try:
            event = _json.loads(body.decode("utf-8"))
        except ValueError:
            return self._reply(400, b"bad event\n", "text/plain")
        if isinstance(event, dict):
            self.hub.events.put(event)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        client = self.hub.connect()
        try:
            self.wfile.write(b": tinyweb\n\n")
            self.wfile.flush()
            while True:
                batch = client.get()
                text = _json.dumps(batch, ensure_ascii=False, separators=(",", ":"))
                self.wfile.write(("data: " + text + "\n\n").encode("utf-8"))
                self.wfile.flush()
        except OSError:
            pass
        finally:
            self.hub.disconnect(client)
            self.close_connection = True


def _static(path):
    """The file a page asks for by `path`: beside where the program runs,
    and a library sample from tinyweb_assets/ beside this file."""
    parts = [p for p in path.split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        return None
    relative = _os.path.join(*parts)
    places = [_os.getcwd()]
    if parts[0] == "tinyweb_assets":
        places.append(_os.path.dirname(_os.path.abspath(__file__)))
    for place in places:
        candidate = _os.path.join(place, relative)
        if _os.path.isfile(candidate):
            return candidate
    return None


# BEGIN tinyweb page
# written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit
_PAGE_HTML = "".join([
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
    "  body { margin: 16px; font-family: system-ui, sans-serif; background: #ffffff; color: #111111; }\n",
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
])
_PAGE_JS = "".join([
    "// tinyweb's page: the renderer that carries out the commands a program\n",
    "// sends and reports the events its reader causes. It is the one copy of\n",
    "// that code, used wherever a program talks to its page in commands:\n",
    "//\n",
    "//   - on an iweb24 page, where tinyweb_external_interpreter.js mounts it\n",
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
    "// docs/libraries.md, \"tinyweb\". The web24 implementation,\n",
    "// tinyweb_external_browser.js, does what this file does without the\n",
    "// commands in between. Keep the file ASCII: it is embedded in C.\n",
    "\n",
    "function now() {\n",
    "  return typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
    "}\n",
    "\n",
    "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n",
    "// `receive(commands)` carries out a batch of commands, and `send(event)`\n",
    "// is how the page reports one. `standalone` is true where the page is\n",
    "// the whole document, which is where a key press is listened for; a\n",
    "// page inside another (a notebook cell) takes the focus when clicked.\n",
    "export function mountPage(element, sendEvent, { standalone = false } = {}) {\n",
    "  const box = document.createElement(\"div\");\n",
    "  box.className = \"tinyweb-page\";\n",
    "  box.style.cssText =\n",
    "    \"display:flex;flex-direction:column;align-items:flex-start;gap:8px;\" +\n",
    "    \"font-family:system-ui,sans-serif;outline:none\";\n",
    "  element.appendChild(box);\n",
    "\n",
    "  const canvases = new Map();\n",
    "  const labels = new Map();\n",
    "  const samples = new Map();\n",
    "  const start = now();\n",
    "  let audio = null;\n",
    "  let offset = 0;\n",
    "  let frameWanted = false;\n",
    "  let frameWaiting = false;\n",
    "  let frameRequest = 0;\n",
    "  let closed = false;\n",
    "  const keyTarget = standalone ? window : box;\n",
    "  let keysWanted = false;\n",
    "\n",
    "  if (!standalone) box.tabIndex = 0;\n",
    "\n",
    "  // The page's clock: the audio clock once sound has started, and until\n",
    "  // then the seconds since the page was mounted. `offset` joins the two,\n",
    "  // so the clock never goes back.\n",
    "  function running() {\n",
    "    return audio !== null && audio.state === \"running\";\n",
    "  }\n",
    "\n",
    "  function clockNow() {\n",
    "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
    "  }\n",
    "\n",
    "  function report(event) {\n",
    "    if (!closed) sendEvent({ ...event, t: clockNow(), running: running() });\n",
    "  }\n",
    "\n",
    "  // Sound may start only after the reader did something, so every\n",
    "  // gesture is a chance to start it.\n",
    "  function startAudio() {\n",
    "    if (audio === null) {\n",
    "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n",
    "      if (!Context) return;\n",
    "      const before = clockNow();\n",
    "      audio = new Context();\n",
    "      offset = before - audio.currentTime;\n",
    "      audio.onstatechange = () => {\n",
    "        if (audio.state === \"running\") offset = (now() - start) / 1000 - audio.currentTime;\n",
    "      };\n",
    "    }\n",
    "    if (audio.state === \"suspended\") audio.resume();\n",
    "  }\n",
    "\n",
    "  box.addEventListener(\"pointerdown\", startAudio);\n",
    "\n",
    "  function onKey(event) {\n",
    "    startAudio();\n",
    "    if (keysWanted) report({ ev: \"key\", key: event.key });\n",
    "  }\n",
    "  keyTarget.addEventListener(\"keydown\", onKey);\n",
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
    "  function play({ sample, at, volume, rate }) {\n",
    "    startAudio();\n",
    "    const loading = samples.get(sample);\n",
    "    if (!loading || audio === null) return;\n",
    "    loading.then((buffer) => {\n",
    "      if (buffer === null || closed) return;\n",
    "      const source = audio.createBufferSource();\n",
    "      source.buffer = buffer;\n",
    "      source.playbackRate.value = rate;\n",
    "      const gain = audio.createGain();\n",
    "      gain.gain.value = volume;\n",
    "      source.connect(gain).connect(audio.destination);\n",
    "      source.start(Math.max(audio.currentTime, at - offset));\n",
    "    });\n",
    "  }\n",
    "\n",
    "  function frame() {\n",
    "    if (closed) return;\n",
    "    if (!frameWaiting) {\n",
    "      frameWaiting = true;\n",
    "      report({ ev: \"frame\" });\n",
    "    }\n",
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
    "    element.style.border = \"1px solid #8884\";\n",
    "    element.style.background = \"#ffffff\";\n",
    "    const context = element.getContext(\"2d\");\n",
    "    context.scale(ratio, ratio);\n",
    "    canvases.set(id, { element, context, width, height, mouse: false });\n",
    "    element.addEventListener(\"click\", (event) => {\n",
    "      const entry = canvases.get(id);\n",
    "      if (!entry.mouse) return;\n",
    "      const bounds = element.getBoundingClientRect();\n",
    "      report({\n",
    "        ev: \"mouse\",\n",
    "        c: id,\n",
    "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
    "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
    "      });\n",
    "    });\n",
    "    box.appendChild(element);\n",
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
    "          g.fillStyle = command.color;\n",
    "          g.fillRect(0, 0, entry.width, entry.height);\n",
    "        });\n",
    "        break;\n",
    "      case \"circle\":\n",
    "        draw(command.c, (g) => {\n",
    "          g.fillStyle = command.color;\n",
    "          g.beginPath();\n",
    "          g.arc(command.x, command.y, Math.max(0, command.radius), 0, 2 * Math.PI);\n",
    "          g.fill();\n",
    "        });\n",
    "        break;\n",
    "      case \"rect\":\n",
    "        draw(command.c, (g) => {\n",
    "          g.fillStyle = command.color;\n",
    "          g.fillRect(command.x, command.y, command.width, command.height);\n",
    "        });\n",
    "        break;\n",
    "      case \"line\":\n",
    "        draw(command.c, (g) => {\n",
    "          g.strokeStyle = command.color;\n",
    "          g.lineWidth = command.width;\n",
    "          g.lineCap = \"round\";\n",
    "          g.beginPath();\n",
    "          g.moveTo(command.x1, command.y1);\n",
    "          g.lineTo(command.x2, command.y2);\n",
    "          g.stroke();\n",
    "        });\n",
    "        break;\n",
    "      case \"text\":\n",
    "        draw(command.c, (g) => {\n",
    "          g.fillStyle = command.color;\n",
    "          g.font = `${command.size}px system-ui, sans-serif`;\n",
    "          g.textBaseline = \"top\";\n",
    "          g.fillText(command.words, command.x, command.y);\n",
    "        });\n",
    "        break;\n",
    "      case \"button\": {\n",
    "        const button = document.createElement(\"button\");\n",
    "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
    "        button.textContent = command.title;\n",
    "        button.addEventListener(\"click\", () => {\n",
    "          startAudio();\n",
    "          report({ ev: \"click\", id: command.id });\n",
    "        });\n",
    "        box.appendChild(button);\n",
    "        break;\n",
    "      }\n",
    "      case \"label\": {\n",
    "        const text = document.createElement(\"div\");\n",
    "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
    "        text.textContent = command.text;\n",
    "        labels.set(command.id, text);\n",
    "        box.appendChild(text);\n",
    "        break;\n",
    "      }\n",
    "      case \"set_label\":\n",
    "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
    "        break;\n",
    "      case \"slider\": {\n",
    "        const row = document.createElement(\"label\");\n",
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
    "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n",
    "        });\n",
    "        row.append(input, shown);\n",
    "        box.appendChild(row);\n",
    "        break;\n",
    "      }\n",
    "      case \"load\":\n",
    "        samples.set(command.id, loadSample(command.name));\n",
    "        break;\n",
    "      case \"play\":\n",
    "        play(command);\n",
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
    "      case \"on_mouse\": {\n",
    "        const entry = canvases.get(command.c);\n",
    "        if (entry) entry.mouse = true;\n",
    "        break;\n",
    "      }\n",
    "      case \"on_key\":\n",
    "        keysWanted = true;\n",
    "        break;\n",
    "    }\n",
    "  }\n",
    "\n",
    "  function freeze() {\n",
    "    if (closed) return;\n",
    "    closed = true;\n",
    "    cancelAnimationFrame(frameRequest);\n",
    "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
    "    if (audio !== null) audio.close();\n",
    "  }\n",
    "\n",
    "  return {\n",
    "    receive(commands) {\n",
    "      if (!closed) for (const command of commands) carryOut(command);\n",
    "    },\n",
    "    // Stops: no more events, frames or sound, and what is shown stays.\n",
    "    freeze,\n",
    "    close() {\n",
    "      freeze();\n",
    "      box.remove();\n",
    "    },\n",
    "  };\n",
    "}\n",
])
# END tinyweb page
