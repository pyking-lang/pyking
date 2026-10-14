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
    "display:flex;flex-direction:column;align-items:flex-start;gap:8px;" +
    "font-family:system-ui,sans-serif;outline:none";
  element.appendChild(box);

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
    element.style.border = "1px solid #8884";
    element.style.background = "#ffffff";
    const context = element.getContext("2d");
    context.scale(ratio, ratio);
    canvases.set(id, { element, context, width, height, mouse: false });
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
        box.appendChild(button);
        break;
      }
      case "label": {
        const text = document.createElement("div");
        text.setAttribute("data-tinyweb-id", String(command.id));
        text.textContent = command.text;
        labels.set(command.id, text);
        box.appendChild(text);
        break;
      }
      case "set_label":
        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;
        break;
      case "slider": {
        const row = document.createElement("label");
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
        box.appendChild(row);
        break;
      }
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
      if (focusable) {
        element.removeAttribute("tabindex");
        element.blur();
      }
    },
  };
}
