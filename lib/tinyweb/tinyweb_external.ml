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

let log_file = Sys.getenv_opt "PYKING_TINYWEB_LOG"
let events_file = Sys.getenv_opt "PYKING_TINYWEB_EVENTS"

(* Set by the interpreter's plugin, which runs `after_program` itself. *)
let hosted = ref false

(* Where a library sample is looked for, after beside the program. *)
let assets =
  ref [ Filename.concat (Filename.dirname Sys.executable_name) "tinyweb_assets" ]

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
  "  body { margin: 16px; font-family: system-ui, sans-serif; background: #ffffff; color: #111111; }\n";
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
  "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n";
  "// `receive(commands)` carries out a batch of commands, and `send(event)`\n";
  "// is how the page reports one. `standalone` is true where the page is\n";
  "// the whole document, which is where a key press is listened for; a\n";
  "// page inside another (a notebook cell) takes the focus when clicked.\n";
  "export function mountPage(element, sendEvent, { standalone = false } = {}) {\n";
  "  const box = document.createElement(\"div\");\n";
  "  box.className = \"tinyweb-page\";\n";
  "  box.style.cssText =\n";
  "    \"display:flex;flex-direction:column;align-items:flex-start;gap:8px;\" +\n";
  "    \"font-family:system-ui,sans-serif;outline:none\";\n";
  "  element.appendChild(box);\n";
  "\n";
  "  const canvases = new Map();\n";
  "  const labels = new Map();\n";
  "  const samples = new Map();\n";
  "  const start = now();\n";
  "  let audio = null;\n";
  "  let offset = 0;\n";
  "  let frameWanted = false;\n";
  "  let frameWaiting = false;\n";
  "  let frameRequest = 0;\n";
  "  let closed = false;\n";
  "  const keyTarget = standalone ? window : box;\n";
  "  let keysWanted = false;\n";
  "\n";
  "  if (!standalone) box.tabIndex = 0;\n";
  "\n";
  "  // The page's clock: the audio clock once sound has started, and until\n";
  "  // then the seconds since the page was mounted. `offset` joins the two,\n";
  "  // so the clock never goes back.\n";
  "  function running() {\n";
  "    return audio !== null && audio.state === \"running\";\n";
  "  }\n";
  "\n";
  "  function clockNow() {\n";
  "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n";
  "  }\n";
  "\n";
  "  function report(event) {\n";
  "    if (!closed) sendEvent({ ...event, t: clockNow(), running: running() });\n";
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
  "    startAudio();\n";
  "    if (keysWanted) report({ ev: \"key\", key: event.key });\n";
  "  }\n";
  "  keyTarget.addEventListener(\"keydown\", onKey);\n";
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
  "    if (!frameWaiting) {\n";
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
  "    element.style.border = \"1px solid #8884\";\n";
  "    element.style.background = \"#ffffff\";\n";
  "    const context = element.getContext(\"2d\");\n";
  "    context.scale(ratio, ratio);\n";
  "    canvases.set(id, { element, context, width, height, mouse: false });\n";
  "    element.addEventListener(\"click\", (event) => {\n";
  "      const entry = canvases.get(id);\n";
  "      if (!entry.mouse) return;\n";
  "      const bounds = element.getBoundingClientRect();\n";
  "      report({\n";
  "        ev: \"mouse\",\n";
  "        c: id,\n";
  "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n";
  "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n";
  "      });\n";
  "    });\n";
  "    box.appendChild(element);\n";
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
  "          g.fillStyle = command.color;\n";
  "          g.fillRect(0, 0, entry.width, entry.height);\n";
  "        });\n";
  "        break;\n";
  "      case \"circle\":\n";
  "        draw(command.c, (g) => {\n";
  "          g.fillStyle = command.color;\n";
  "          g.beginPath();\n";
  "          g.arc(command.x, command.y, Math.max(0, command.radius), 0, 2 * Math.PI);\n";
  "          g.fill();\n";
  "        });\n";
  "        break;\n";
  "      case \"rect\":\n";
  "        draw(command.c, (g) => {\n";
  "          g.fillStyle = command.color;\n";
  "          g.fillRect(command.x, command.y, command.width, command.height);\n";
  "        });\n";
  "        break;\n";
  "      case \"line\":\n";
  "        draw(command.c, (g) => {\n";
  "          g.strokeStyle = command.color;\n";
  "          g.lineWidth = command.width;\n";
  "          g.lineCap = \"round\";\n";
  "          g.beginPath();\n";
  "          g.moveTo(command.x1, command.y1);\n";
  "          g.lineTo(command.x2, command.y2);\n";
  "          g.stroke();\n";
  "        });\n";
  "        break;\n";
  "      case \"text\":\n";
  "        draw(command.c, (g) => {\n";
  "          g.fillStyle = command.color;\n";
  "          g.font = `${command.size}px system-ui, sans-serif`;\n";
  "          g.textBaseline = \"top\";\n";
  "          g.fillText(command.words, command.x, command.y);\n";
  "        });\n";
  "        break;\n";
  "      case \"button\": {\n";
  "        const button = document.createElement(\"button\");\n";
  "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n";
  "        button.textContent = command.title;\n";
  "        button.addEventListener(\"click\", () => {\n";
  "          startAudio();\n";
  "          report({ ev: \"click\", id: command.id });\n";
  "        });\n";
  "        box.appendChild(button);\n";
  "        break;\n";
  "      }\n";
  "      case \"label\": {\n";
  "        const text = document.createElement(\"div\");\n";
  "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n";
  "        text.textContent = command.text;\n";
  "        labels.set(command.id, text);\n";
  "        box.appendChild(text);\n";
  "        break;\n";
  "      }\n";
  "      case \"set_label\":\n";
  "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n";
  "        break;\n";
  "      case \"slider\": {\n";
  "        const row = document.createElement(\"label\");\n";
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
  "        box.appendChild(row);\n";
  "        break;\n";
  "      }\n";
  "      case \"load\":\n";
  "        samples.set(command.id, loadSample(command.name));\n";
  "        break;\n";
  "      case \"play\":\n";
  "        play(command);\n";
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
  "      case \"on_key\":\n";
  "        keysWanted = true;\n";
  "        break;\n";
  "    }\n";
  "  }\n";
  "\n";
  "  function freeze() {\n";
  "    if (closed) return;\n";
  "    closed = true;\n";
  "    cancelAnimationFrame(frameRequest);\n";
  "    keyTarget.removeEventListener(\"keydown\", onKey);\n";
  "    if (audio !== null) audio.close();\n";
  "  }\n";
  "\n";
  "  return {\n";
  "    receive(commands) {\n";
  "      if (!closed) for (const command of commands) carryOut(command);\n";
  "    },\n";
  "    // Stops: no more events, frames or sound, and what is shown stays.\n";
  "    freeze,\n";
  "    close() {\n";
  "      freeze();\n";
  "      box.remove();\n";
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

type value = I of int | F of float | S of string

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

let json_of_value v =
  match v with
  | I n -> string_of_int n
  | F x ->
      let text = Printf.sprintf "%.17g" x in
      if Float.is_integer x && not (String.contains text 'e') then text ^ ".0" else text
  | S s -> quote s

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
  | None -> ""

let quoted command name =
  match List.assoc_opt name command.fields with
  | Some (S s) -> quote s
  | Some (I _) | Some (F _) | None -> "\"\""

(* A command as the one line every headless implementation writes. *)
let log_line command =
  let f = field command in
  let words =
    match command.op with
    | "canvas" -> [ "canvas"; f "id"; f "width"; f "height" ]
    | "clear" -> [ "clear"; f "c"; f "color" ]
    | "circle" -> [ "circle"; f "c"; f "x"; f "y"; f "radius"; f "color" ]
    | "rect" -> [ "rect"; f "c"; f "x"; f "y"; f "width"; f "height"; f "color" ]
    | "line" -> [ "line"; f "c"; f "x1"; f "y1"; f "x2"; f "y2"; f "color"; f "width" ]
    | "text" -> [ "text"; f "c"; f "x"; f "y"; f "color"; f "size"; quoted command "words" ]
    | "button" -> [ "button"; f "id"; quoted command "title" ]
    | "label" -> [ "label"; f "id"; quoted command "text" ]
    | "set_label" -> [ "set_label"; f "id"; quoted command "text" ]
    | "slider" -> [ "slider"; f "id"; f "low"; f "high"; f "value" ]
    | "load" -> [ "load"; f "id"; quoted command "name" ]
    | "play" -> [ "play"; f "sample"; f "at"; f "volume"; f "rate" ]
    | "on_mouse" -> [ "on_mouse"; f "c" ]
    | op -> [ op ]
  in
  String.concat " " words

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

(* The commands a page connecting now has to be sent, once `command` has
   been: everything but sound and frame bookkeeping, less what a later
   command has made invisible. *)
let kept history command =
  let drawing = [ "clear"; "circle"; "rect"; "line"; "text" ] in
  let same name h = List.assoc_opt name h.fields = List.assoc_opt name command.fields in
  match command.op with
  | "play" | "frame_done" | "event_done" -> history
  | "clear" ->
      List.filter (fun h -> not (List.mem h.op drawing && same "c" h)) history @ [ command ]
  | "set_label" ->
      List.filter (fun h -> not (h.op = "set_label" && same "id" h)) history @ [ command ]
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
      Sys.getcwd ()
      :: (if List.hd parts = "tinyweb_assets" then List.map Filename.dirname !assets else [])
    in
    List.find_map
      (fun place ->
        let candidate = Filename.concat place relative in
        if Sys.file_exists candidate && not (Sys.is_directory candidate) then Some candidate
        else None)
      places

(* --- events, as the page writes them --- *)

(* The fields of one flat JSON object, each as its text: a string
   decoded, anything else as written. *)
let parse_object text =
  let n = String.length text in
  let rec space i = if i < n && String.contains " \t\r\n" text.[i] then space (i + 1) else i in
  let string_at i =
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
  in
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

let last = ref 0
let clock = ref 0.0
let buttons : (int * (unit -> unit)) list ref = ref []
let sliders : (int * (int -> unit)) list ref = ref []
let frames : (float -> unit) list ref = ref []
let mice : (int * (int -> int -> unit)) list ref = ref []
let keys : (string -> unit) list ref = ref []
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
  let number name = Option.bind (List.assoc_opt name event) float_of_string_opt in
  let int name = Option.value ~default:0 (Option.map int_of_float (number name)) in
  (match number "t" with Some t -> clock := t | None -> ());
  let each table id f = List.iter (fun (key, g) -> if key = id then f g) table in
  match List.assoc_opt "ev" event with
  | Some "click" -> each !buttons (int "id") (fun f -> f ())
  | Some "slide" -> each !sliders (int "id") (fun f -> f (int "value"))
  | Some "frame" ->
      List.iter (fun f -> f !clock) !frames;
      send { op = "frame_done"; fields = [] }
  | Some "mouse" -> each !mice (int "c") (fun f -> f (int "x") (int "y"))
  | Some "key" ->
      let key = Option.value ~default:"" (List.assoc_opt "key" event) in
      List.iter (fun f -> f key) !keys
  | _ -> ()

(* The events file, once the top level has ended: each line logged as
   it is delivered. *)
and deliver_file () =
  match events_file with
  | Some path when Sys.file_exists path ->
      let lines = String.split_on_char '\n' (read_file path) in
      List.iter
        (fun line ->
          let words = List.filter (fun w -> w <> "") (String.split_on_char ' ' line) in
          if String.trim line <> "" then (
            write_log ("> " ^ line);
            let event =
              if String.length line > 4 && String.sub line 0 4 = "key " then
                Some [ ("ev", "key"); ("key", String.sub line 4 (String.length line - 4)) ]
              else
                match words with
                | [ "click"; id ] -> Some [ ("ev", "click"); ("id", id) ]
                | [ "slide"; id; value ] -> Some [ ("ev", "slide"); ("id", id); ("value", value) ]
                | [ "frame"; t ] -> Some [ ("ev", "frame"); ("t", t) ]
                | [ "mouse"; c; x; y ] -> Some [ ("ev", "mouse"); ("c", c); ("x", x); ("y", y) ]
                | _ -> None
            in
            match event with
            | Some event -> deliver event
            | None -> write_log ("! unknown event: " ^ line)))
        lines
  | _ -> ()

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
  match log_file with
  | Some _ -> if command.op <> "frame_done" && command.op <> "event_done" then write_log (log_line command)
  | None ->
      history := kept !history command;
      pending := !pending @ [ command ];
      if not !batching then flush_pending ()


(* --- the functions tinyweb_external.pyk declares --- *)

let web_init port =
  if log_file = None && !listener = None then (
    if port < 0 || port > 65535 then
      refuse
        (Printf.sprintf
           "tinyweb: cannot serve the page on port %d: a port is a number from 0 to 65535"
           port);
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
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

let fresh () =
  incr last;
  !last

let canvas width height =
  ready ();
  let id = fresh () in
  send { op = "canvas"; fields = [ ("id", I id); ("width", I width); ("height", I height) ] };
  id

let fill_canvas c color = send { op = "clear"; fields = [ ("c", I c); ("color", S color) ] }

let draw_circle c x y radius color =
  send
    {
      op = "circle";
      fields = [ ("c", I c); ("x", I x); ("y", I y); ("radius", I radius); ("color", S color) ];
    }

let draw_rect c x y width height color =
  send
    {
      op = "rect";
      fields =
        [ ("c", I c); ("x", I x); ("y", I y); ("width", I width); ("height", I height);
          ("color", S color) ];
    }

let draw_line c x1 y1 x2 y2 color width =
  send
    {
      op = "line";
      fields =
        [ ("c", I c); ("x1", I x1); ("y1", I y1); ("x2", I x2); ("y2", I y2);
          ("color", S color); ("width", I width) ];
    }

let draw_text c x y words color size =
  send
    {
      op = "text";
      fields =
        [ ("c", I c); ("x", I x); ("y", I y); ("color", S color); ("size", I size);
          ("words", S words) ];
    }

let make_button title on_click =
  ready ();
  let id = fresh () in
  buttons := !buttons @ [ (id, on_click) ];
  send { op = "button"; fields = [ ("id", I id); ("title", S title) ] };
  id

let label text =
  ready ();
  let id = fresh () in
  send { op = "label"; fields = [ ("id", I id); ("text", S text) ] };
  id

let set_label id text = send { op = "set_label"; fields = [ ("id", I id); ("text", S text) ] }

let make_slider low high value on_change =
  ready ();
  let id = fresh () in
  sliders := !sliders @ [ (id, on_change) ];
  send
    {
      op = "slider";
      fields = [ ("id", I id); ("low", I low); ("high", I high); ("value", I value) ];
    };
  id

let load_sample name =
  ready ();
  let id = fresh () in
  send { op = "load"; fields = [ ("id", I id); ("name", S name) ] };
  id

let play_sample sample at volume rate =
  send
    {
      op = "play";
      fields = [ ("sample", I sample); ("at", F at); ("volume", F volume); ("rate", F rate) ];
    }

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
  send { op = "on_mouse"; fields = [ ("c", I c) ] }

let on_key pressed =
  ready ();
  keys := !keys @ [ pressed ];
  send { op = "on_key"; fields = [] }

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

