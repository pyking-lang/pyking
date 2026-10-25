# The Python implementation of the names declared in
# tinyweb_external.pyk, for python.
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
import base64 as _base64
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

_names = set()
_clock = 0.0
# Whether an event has been delivered: until one is, the program is in
# its top level, whose sound a page connecting later still plays.
_delivered = False
_buttons = {}
_sliders = {}
_checks = {}
_radios = {}
_choices = {}
_texts = {}
_mice = {}
_frames = []
_keys = []
_key_ups = []
# The keys held down now, from the key events delivered so far.
_down = set()
_keys_on = False
# Each canvas's pointer: the functions watching it, by kind, and where it
# was last seen.
_pointers = {}
_measures = {}
_bitmaps = {}
# The functions `watch` handed over, by element and kind, and what the
# page last reported, by name: a list of numbers or a text.
_watchers = {}
_reports = {}
_after = False
_hub = None


# --- commands ---

def _quote(text):
    return _json.dumps(text, ensure_ascii=False)


def _seconds(x):
    return f"{x:.3f}"


def _log_line(command):
    """A command as the one line every headless implementation writes:
    each identifier quoted, and an element's text after it only where the
    two differ."""
    op = command["op"]
    c = command.get
    q = lambda name: _quote(c(name))  # noqa: E731
    flag = lambda name: "true" if c(name) else "false"  # noqa: E731

    def named(id_field, text_field):
        return q(id_field) + ("" if c(id_field) == c(text_field) else " " + q(text_field))

    if op == "canvas":
        return f"canvas {q('id')} {c('width')} {c('height')}"
    if op == "clear":
        return f"clear {q('c')} {c('color')}"
    if op == "shape":
        numbers = c("numbers")
        if not isinstance(numbers, str):
            numbers = " ".join(_seconds(x) for x in numbers)
        return (f"{c('kind')} {q('c')} {numbers} {q('color')} {q('outline')} "
                f"{_seconds(c('width'))} {_seconds(c('alpha'))}")
    if op == "text":
        return (f"text {q('c')} {_seconds(c('x'))} {_seconds(c('y'))} {q('color')} {c('size')} "
                f"{q('font')} {c('align')} {c('baseline')} {flag('bold')} {q('outline')} "
                f"{_seconds(c('outline_width'))} {_seconds(c('alpha'))} {q('words')}")
    if op == "measure":
        return f"measure {q('id')} {c('size')} {q('font')} {flag('bold')} {q('words')}"
    if op == "on_pointer":
        return f"on_pointer {q('c')}"
    if op in ("row", "column", "inside"):
        return f"{op} {q('id')}"
    if op == "bitmap":
        rx, ry, rw, rh = c("rect")
        return (f"bitmap {q('c')} {q('id')} {c('x')} {c('y')} {_seconds(c('scale'))} "
                f"{c('width')} {c('height')} {rx} {ry} {rw} {rh} {c('digest')}")
    if op == "state":
        words = [c("kind"), q("c")]
        if c("value") != "":
            words.append(q("value"))
        if c("numbers") != "":
            words.append(c("numbers"))
        return " ".join(words)
    if op == "image_load":
        return f"load_image {named('id', 'name')}"
    if op == "image":
        return (f"image {q('c')} {q('picture')} {c('x')} {c('y')} {c('width')} {c('height')} "
                f"{_seconds(c('alpha'))}")
    if op == "button":
        return f"button {named('id', 'title')}"
    if op == "label":
        return f"label {named('id', 'text')}"
    if op == "set_label":
        return f"set_label {q('id')} {q('text')}"
    if op == "slider":
        return f"slider {q('id')} {c('low')} {c('high')} {c('value')}"
    if op == "checkbox":
        return f"checkbox {named('id', 'title')} {flag('checked')}"
    if op == "radio":
        return f"radio {named('id', 'title')} {q('group')} {flag('chosen')}"
    if op == "choice":
        return f"choice {q('id')} {c('chosen')} {q('options')}"
    if op == "text_input":
        return f"text_input {named('id', 'placeholder')}"
    if op == "number":
        return f"number {q('id')} {c('low')} {c('high')} {c('value')}"
    if op == "set_checked":
        return f"set_checked {q('id')} {flag('checked')}"
    if op == "set_value":
        return f"set_value {q('id')} {c('value')}"
    if op == "load":
        return f"load {named('id', 'name')}"
    if op == "cmd":
        return (f"{c('kind')} {q('id')}" + ("" if c("text") == "" else " " + q("text"))
                + ("" if c("numbers") == "" else " " + c("numbers")))
    if op == "on_mouse":
        return f"on_mouse {q('c')}"
    if op == "style":
        return f"style {q('id')} {c('kind')} {c('prop')} {q('value')}"
    if op == "splash_text":
        return f"splash_text {q('text')}"
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


def _fresh(name):
    """A new element's identifier: `name`, or `name` with the first number
    from 1 that makes it one nothing on the page has."""
    # An empty name would be the page's own identifier.
    name = name or "element"
    found, n = name, 0
    while found in _names:
        n += 1
        found = f"{name}{n}"
    _names.add(found)
    return found


# --- the functions tinyweb_external.pyk declares ---

def web_start(port):
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
    id = _fresh("canvas")
    _send({"op": "canvas", "id": id, "width": width, "height": height})
    return id


def fill_canvas(c, color):
    _send({"op": "clear", "c": c, "color": color})


def draw_shape(c, kind, numbers, color, outline, width, alpha):
    _send({"op": "shape", "c": c, "kind": kind, "numbers": numbers, "color": color,
           "outline": outline, "width": width, "alpha": alpha})


def draw_pairs(c, kind, items, color, outline, width, alpha):
    draw_shape(c, kind, [float(x) for item in items for x in item], color, outline, width, alpha)


def draw_triples(c, kind, items, color, outline, width, alpha):
    draw_shape(c, kind, [float(x) for item in items for x in item], color, outline, width, alpha)


def draw_quads(c, kind, items, color, outline, width, alpha):
    draw_shape(c, kind, [float(x) for item in items for x in item], color, outline, width, alpha)


def draw_text(c, x, y, words, color, size, font, align, baseline, bold, outline, outline_width,
              alpha):
    _send({"op": "text", "c": c, "x": x, "y": y, "words": words, "color": color,
           "size": size, "font": font, "align": align, "baseline": baseline, "bold": bold,
           "outline": outline, "outline_width": outline_width, "alpha": alpha})


def measure(words, size, font, bold, answer):
    _ready()
    id = _fresh("measure")
    _measures[id] = answer
    _send({"op": "measure", "id": id, "words": words, "size": size, "font": font, "bold": bold})


def watch_pointer(c, kind, f):
    _ready()
    if c not in _pointers:
        _pointers[c] = {"press": [], "release": [], "move": [], "drag": [],
                        "x": 0, "y": 0, "down": False}
        _send({"op": "on_pointer", "c": c})
    if kind in ("press", "release", "move", "drag"):
        _pointers[c][kind].append(f)


def pointer(c, which):
    _ready()
    seen = _pointers.get(c)
    if seen is None:
        return 0
    if which == "x":
        return seen["x"]
    if which == "y":
        return seen["y"]
    return 1 if seen["down"] else 0


# --- bitmaps ---

def _digest(data):
    """FNV-1a, 32 bits, of the bytes: what the log says of a bitmap's
    pixels."""
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return f"{h:08x}"


class _Bitmap:
    """A bitmap's pixels, four bytes each, and the rectangle that changed
    since it was last shown."""

    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.data = bytearray(b"\x00\x00\x00\xff" * (width * height))
        self.x1, self.y1, self.x2, self.y2 = 0, 0, width, height

    def touch(self, x, y):
        self.x1 = min(self.x1, x)
        self.y1 = min(self.y1, y)
        self.x2 = max(self.x2, x + 1)
        self.y2 = max(self.y2, y + 1)


def make_bitmap(width, height, background):
    _ready()
    id = _fresh("bitmap")
    _bitmaps[id] = _Bitmap(max(1, width), max(1, height))
    fill_bitmap(id, background)
    return id


def set_pixel(b, x, y, color):
    bm = _bitmaps.get(b)
    if bm is None or not (0 <= x < bm.width and 0 <= y < bm.height):
        return
    at = (y * bm.width + x) * 4
    bm.data[at] = (color >> 16) & 255
    bm.data[at + 1] = (color >> 8) & 255
    bm.data[at + 2] = color & 255
    bm.touch(x, y)


def get_pixel(b, x, y):
    bm = _bitmaps.get(b)
    if bm is None or not (0 <= x < bm.width and 0 <= y < bm.height):
        return 0
    at = (y * bm.width + x) * 4
    return (bm.data[at] << 16) | (bm.data[at + 1] << 8) | bm.data[at + 2]


def fill_bitmap(b, color):
    bm = _bitmaps.get(b)
    if bm is None:
        return
    bm.data[:] = bytes(((color >> 16) & 255, (color >> 8) & 255, color & 255, 255)) \
        * (bm.width * bm.height)
    bm.x1, bm.y1, bm.x2, bm.y2 = 0, 0, bm.width, bm.height


def draw_bitmap(c, b, x, y, scale):
    bm = _bitmaps.get(b)
    if bm is None:
        return
    if bm.x2 > bm.x1 and bm.y2 > bm.y1:
        rx, ry, rw, rh = bm.x1, bm.y1, bm.x2 - bm.x1, bm.y2 - bm.y1
    else:
        rx, ry, rw, rh = 0, 0, 0, 0
    rows = [bytes(bm.data[((ry + r) * bm.width + rx) * 4:((ry + r) * bm.width + rx + rw) * 4])
            for r in range(rh)]
    data = b"".join(rows)
    bm.x1, bm.y1, bm.x2, bm.y2 = bm.width, bm.height, 0, 0
    _send({"op": "bitmap", "c": c, "id": b, "width": bm.width, "height": bm.height,
           "x": x, "y": y, "scale": scale, "rect": [rx, ry, rw, rh],
           "data": _base64.b64encode(data).decode("ascii"), "digest": _digest(data)})


def set_state(c, kind, value, numbers):
    _send({"op": "state", "c": c, "kind": kind, "value": value, "numbers": numbers})


def load_image(name):
    _ready()
    id = _fresh(name)
    _send({"op": "image_load", "id": id, "name": name})
    return id


def draw_image(c, picture, x, y, width, height, alpha):
    _send({"op": "image", "c": c, "picture": picture, "x": x, "y": y, "width": width,
           "height": height, "alpha": alpha})


def make_checkbox(title, checked, on_change):
    _ready()
    id = _fresh(title)
    _checks[id] = on_change
    _send({"op": "checkbox", "id": id, "title": title, "checked": checked})
    return id


def make_radio(group, title, chosen, on_pick):
    _ready()
    id = _fresh(title)
    _radios[id] = (title, on_pick)
    _send({"op": "radio", "id": id, "group": group, "title": title, "chosen": chosen})
    return id


def make_choice(options, chosen, on_change):
    _ready()
    id = _fresh("choice")
    _choices[id] = on_change
    _send({"op": "choice", "id": id, "options": options, "chosen": chosen})
    return id


def make_text_input(placeholder, on_enter):
    _ready()
    id = _fresh(placeholder if placeholder != "" else "text")
    _texts[id] = on_enter
    _send({"op": "text_input", "id": id, "placeholder": placeholder})
    return id


def make_number_input(low, high, value, on_change):
    _ready()
    id = _fresh("number")
    _sliders[id] = on_change
    _send({"op": "number", "id": id, "low": low, "high": high, "value": value})
    return id


def set_checked(id, checked):
    _send({"op": "set_checked", "id": id, "checked": checked})


def set_value(id, value):
    _send({"op": "set_value", "id": id, "value": value})


def make_button(title, on_click):
    _ready()
    id = _fresh(title)
    _buttons[id] = on_click
    _send({"op": "button", "id": id, "title": title})
    return id


def label(text):
    _ready()
    id = _fresh(text)
    _send({"op": "label", "id": id, "text": text})
    return id


def row():
    _ready()
    id = _fresh("row")
    _send({"op": "row", "id": id})
    return id


def column():
    _ready()
    id = _fresh("column")
    _send({"op": "column", "id": id})
    return id


def inside(id):
    _send({"op": "inside", "id": id})


def outside():
    _send({"op": "outside"})


def set_label(id, text):
    _send({"op": "set_label", "id": id, "text": text})


def apply_style(id, kind, property, value):
    _send({"op": "style", "id": id, "kind": kind, "prop": property, "value": value})


def make_slider(low, high, value, on_change):
    _ready()
    id = _fresh("slider")
    _sliders[id] = on_change
    _send({"op": "slider", "id": id, "low": low, "high": high, "value": value})
    return id


def load_sample(name):
    _ready()
    id = _fresh(name)
    _send({"op": "load", "id": id, "name": name})
    return id


def fresh_id(name):
    _ready()
    return _fresh(name)


def command(kind, id, text, numbers, mode):
    _send({"op": "cmd", "kind": kind, "id": id, "text": text, "numbers": numbers, "mode": mode})


def watch(id, kind, f):
    _ready()
    _watchers.setdefault((id, kind), []).append(f)


def report_number(name, k):
    value = _reports.get(name)
    if not isinstance(value, list) or k < 0 or k >= len(value):
        return 0.0
    return value[k]


def report_text(name):
    value = _reports.get(name)
    return value if isinstance(value, str) else ""


def report_count(name):
    value = _reports.get(name)
    return len(value) if isinstance(value, list) else 0


def watch_text(id, kind, name, f):
    watch(id, kind, lambda: f(report_text(name)))


def watch_step(id, kind, f):
    watch(id, kind, lambda: f(int(report_number(kind, 0)), report_number(kind, 1)))


def watch_pair(id, kind, f):
    watch(id, kind, lambda: f(report_number(kind, 0), report_number(kind, 1)))


def splash():
    _ready()
    _send({"op": "splash"})


def set_splash(message):
    _ready()
    _send({"op": "splash_text", "text": message})


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


def on_key_up(released):
    _ready()
    _key_ups.append(released)
    _send({"op": "on_key"})


def key_down(key):
    global _keys_on
    _ready()
    if not _keys_on and not _keys and not _key_ups:
        _keys_on = True
        _send({"op": "on_key"})
    return key in _down


# --- events ---

def _deliver(event):
    """Calls what the program handed over for one event, in the order it
    was handed over."""
    global _clock, _delivered
    _delivered = True
    t = event.get("t")
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        _clock = float(t)
    reports = event.get("reports")
    if isinstance(reports, dict):
        for name, value in reports.items():
            _merge_report(name, value)
    kind = event.get("ev")
    if kind == "cb":
        for f in list(_watchers.get((event.get("id"), event.get("kind")), [])):
            f()
    elif kind == "click":
        if event.get("id") in _buttons:
            _buttons[event["id"]]()
    elif kind == "slide":
        if event.get("id") in _sliders:
            _sliders[event["id"]](int(event["value"]))
    elif kind == "check":
        if event.get("id") in _checks:
            _checks[event["id"]](event.get("checked") is True)
    elif kind == "pick":
        if event.get("id") in _radios:
            title, on_pick = _radios[event["id"]]
            on_pick(title)
    elif kind == "choose":
        if event.get("id") in _choices:
            _choices[event["id"]](int(event["value"]))
    elif kind == "enter":
        if event.get("id") in _texts:
            _texts[event["id"]](str(event.get("text", "")))
    elif kind == "frame":
        for draw in list(_frames):
            draw(_clock)
        _send({"op": "frame_done"})
    elif kind == "mouse":
        for click in list(_mice.get(event.get("c"), [])):
            click(int(event["x"]), int(event["y"]))
    elif kind == "key":
        _down.add(str(event["key"]))
        for pressed in list(_keys):
            pressed(str(event["key"]))
    elif kind == "key_up":
        _down.discard(str(event["key"]))
        for released in list(_key_ups):
            released(str(event["key"]))
    elif kind in ("press", "release", "move"):
        seen = _pointers.get(event.get("c"))
        if seen is not None:
            seen["x"], seen["y"] = int(event["x"]), int(event["y"])
            if kind == "press":
                seen["down"] = True
            elif kind == "release":
                seen["down"] = False
            kinds = [kind] + (["drag"] if kind == "move" and seen["down"] else [])
            for k in kinds:
                for f in list(seen[k]):
                    f(seen["x"], seen["y"])
    elif kind == "measured":
        answer = _measures.pop(event.get("id"), None)
        if answer is not None:
            answer(float(event.get("width", 0)))


def _number(value):
    """A reported number as a Float: 0.0 where it is not one."""
    try:
        x = float(value)
    except (TypeError, ValueError):
        return 0.0
    # x - x is NaN for an infinity and for NaN; `math` may be the program's.
    return x if x - x == 0.0 else 0.0


def _merge_report(name, value):
    """Keeps what the page reported under `name`: a text, or numbers."""
    if isinstance(value, str):
        _reports[name] = value
    elif isinstance(value, list):
        _reports[name] = [_number(x) for x in value]
    else:
        _reports[name] = [_number(value)]


def _generic_event(kind, line):
    """A `cb`, `report` or `report_text` line of an events file: quoted
    strings, then numbers for a report."""
    rest = line.strip()[len(kind):]
    strings = []
    decoder = _json.JSONDecoder()
    while rest.lstrip().startswith('"'):
        rest = rest.lstrip()
        try:
            text, end = decoder.raw_decode(rest)
        except ValueError:
            return None
        if not isinstance(text, str):
            return None
        strings.append(text)
        rest = rest[end:]
    words = rest.split()
    if kind in ("cb", "report_text"):
        if len(strings) != 2 or words:
            return None
        if kind == "cb":
            return {"ev": "cb", "id": strings[0], "kind": strings[1]}
        return {"ev": "report", "reports": {strings[0]: strings[1]}}
    if len(strings) != 1:
        return None
    try:
        numbers = [float(w) for w in words]
    except ValueError:
        return None
    return {"ev": "report", "reports": {strings[0]: numbers}}


def _parse_event(line):
    """One line of an events file as the event the page would send, or
    None."""
    if line.startswith("key "):
        return {"ev": "key", "key": line[4:]}
    if line.startswith("key_up "):
        return {"ev": "key_up", "key": line[7:]}
    words = line.split(None, 1)
    if words and words[0] in ("cb", "report", "report_text"):
        return _generic_event(words[0], line)
    try:
        if words[0] == "frame" and len(words) == 2:
            return {"ev": "frame", "t": float(words[1])}
        if words[0] not in ("click", "slide", "mouse", "check", "pick", "choose", "enter",
                            "press", "release", "move", "measured") \
                or len(words) < 2:
            return None
        # The element is a quoted string, which may hold spaces; so is the
        # text an `enter` carries.
        id, end = _json.JSONDecoder().raw_decode(words[1].lstrip())
        after = words[1].lstrip()[end:].strip()
        if not isinstance(id, str):
            return None
        if words[0] == "enter":
            text, stop = _json.JSONDecoder().raw_decode(after)
            if not isinstance(text, str) or after[stop:].strip() != "":
                return None
            return {"ev": "enter", "id": id, "text": text}
        rest = after.split()
        if words[0] == "check" and len(rest) == 1 and rest[0] in ("true", "false"):
            return {"ev": "check", "id": id, "checked": rest[0] == "true"}
        if words[0] == "pick" and len(rest) == 0:
            return {"ev": "pick", "id": id}
        if words[0] == "choose" and len(rest) == 1:
            return {"ev": "choose", "id": id, "value": int(rest[0])}
        if words[0] == "click" and len(rest) == 0:
            return {"ev": "click", "id": id}
        if words[0] == "slide" and len(rest) == 1:
            return {"ev": "slide", "id": id, "value": int(rest[0])}
        if words[0] in ("mouse", "press", "release", "move") and len(rest) == 2:
            return {"ev": words[0], "c": id, "x": int(rest[0]), "y": int(rest[1])}
        if words[0] == "measured" and len(rest) == 1:
            return {"ev": "measured", "id": id, "width": float(rest[0])}
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
                _sys.stdout.flush()
                _hub.flush()
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
    has been: everything but sound a callback played and frame
    bookkeeping, less what a later command has made invisible -- a
    canvas's drawing before it was cleared, a label's text before it was
    set again."""
    op = command["op"]
    if op in ("frame_done", "event_done"):
        return history
    if op == "cmd":
        mode = command["mode"]
        if mode == 3 or (mode == 2 and _delivered):
            return history
        if mode == 1:
            history = [h for h in history
                       if not (h["op"] == "cmd" and h["kind"] == command["kind"]
                               and h["id"] == command["id"])]
        return history + [command]
    if op == "clear":
        drawing = ("clear", "shape", "text", "state", "image", "bitmap")
        history = [h for h in history if not (h["op"] in drawing and h.get("c") == command["c"])]
    elif op in ("set_label", "set_checked", "set_value"):
        history = [h for h in history
                   if not (h["op"] == op and h["id"] == command["id"])]
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
])
_PAGE_JS = "".join([
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
    "        if (entry) fadeVoice(entry, n[0] ?? 0, n[1] ?? 0);\n",
    "        break;\n",
    "      }\n",
    "      case \"stop_all\":\n",
    "        stopAll();\n",
    "        break;\n",
    "      case \"master\": {\n",
    "        masterVolume = n[0] ?? 1;\n",
    "        const g = live();\n",
    "        if (g) g.master.gain.value = masterVolume;\n",
    "        break;\n",
    "      }\n",
    "      case \"channel\": {\n",
    "        const ch = Number(cmd.id) || 0;\n",
    "        const s = { volume: n[0] ?? 1, pan: n[1] ?? 0, echo: n[2] ?? 0, echoTime: n[3] ?? 0.3,\n",
    "          feedback: n[4] ?? 0.35, reverb: n[5] ?? 0, lowPass: n[6] ?? 0 };\n",
    "        settings.set(ch, s);\n",
    "        const g = live();\n",
    "        if (g) g.style(ch, s);\n",
    "        break;\n",
    "      }\n",
    "      case \"listen\":\n",
    "        listen(Math.max(1, Math.min(1024, Math.round(n[0] || 32))), n[1] ?? 0.8);\n",
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
    "export function mountPage(element, sendEvent, { standalone = false, activated = false } = {}) {\n",
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
    "  // Carries out a command, or holds it while something holds the page.\n",
    "  // Command -> ()\n",
    "  function take(command) {\n",
    "    if (held !== null) held.push(command);\n",
    "    else carryOut(command);\n",
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
])
# END tinyweb page
