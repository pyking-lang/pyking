// The keys of every command the playground adds -- Run, Copy for slides,
// the debugger's actions and the REPL's -- which the settings can
// change: what each command is called, the keys it has until the
// settings say otherwise, and how a key is written, read, shown and
// matched against what the keyboard sent. Monaco's own editing keys are
// Monaco's, and not here.
//
// A key is written as a spec, "Mod+Shift+;": `Mod` is Cmd on a Mac and
// Ctrl elsewhere, `Ctrl` the Mac's Control key (elsewhere the same as
// Mod), `Alt` Option on a Mac, and the key itself the physical key --
// so `;` is the same key with Shift held, where it types `:`. The
// settings keep, per command, the keys only where they differ from the
// defaults: `settings.keys = {"debug.next": ["F10"]}`.
//
//   import { COMMANDS, keysOf, matchesKey, parseKey } from "./keys.js";

/** Whether the page is on a Mac, where Mod is Cmd and Alt is Option.
 *  () -> Bool */
export function onMac() {
  const platform = globalThis.navigator?.userAgentData?.platform
    ?? globalThis.navigator?.platform ?? "";
  return /mac|iphone|ipad/i.test(platform);
}

/** Every command whose keys the settings change, in the order the
 *  settings list them: its id, the area it belongs to, what it is called
 *  there and in a tooltip, and its default keys -- a list, or a function
 *  of whether this is a Mac. Run has Cmd+Enter and Ctrl+Enter on a Mac,
 *  where the two are different keys, and Ctrl+Enter elsewhere.
 *
 *  Copy for slides is Alt+Shift+C (Option+Shift+C): a browser opens its
 *  inspector on Ctrl+Shift+C and Cmd+Option+C, Monaco has no Alt+Shift+C,
 *  and on a Mac Option+Shift+C types Ç, which is no dead key. */
export const COMMANDS = [
  { id: "run", area: "Editor", label: "Run, or stop what runs",
    defaults: (mac) => (mac ? ["Shift+Enter", "Mod+Enter", "Ctrl+Enter"]
                            : ["Shift+Enter", "Mod+Enter"]) },
  { id: "copySlides", area: "Editor", label: "Copy for slides", defaults: ["Alt+Shift+C"] },
  { id: "debug.start", area: "Debugger", label: "Start debugging, or start again",
    defaults: ["Alt+D"] },
  { id: "debug.continue", area: "Debugger", label: "Continue", defaults: ["F8", "Alt+C"] },
  { id: "debug.next", area: "Debugger", label: "Step over", defaults: ["F10", "Alt+O"] },
  { id: "debug.in", area: "Debugger", label: "Step into", defaults: ["F11", "Alt+I"] },
  { id: "debug.out", area: "Debugger", label: "Step out", defaults: ["Shift+F11", "Alt+T"] },
  { id: "debug.stop", area: "Debugger", label: "Stop debugging", defaults: ["Alt+S"] },
  { id: "debug.breakpoint", area: "Debugger",
    label: "Set or remove a breakpoint on the cursor's line", defaults: ["Alt+B"] },
  { id: "repl.submit", area: "REPL", label: "Submit the entry, or open the next line",
    defaults: ["Enter"] },
  { id: "repl.newline", area: "REPL", label: "Open a new line", defaults: ["Shift+Enter"] },
  { id: "repl.previous", area: "REPL", label: "The entry before", defaults: ["Up"] },
  { id: "repl.next", area: "REPL", label: "The entry after", defaults: ["Down"] },
  { id: "repl.complete", area: "REPL", label: "Complete the word, or indent",
    defaults: ["Tab"] },
];

/** The areas, in the settings' order. */
export const AREAS = ["Editor", "Debugger", "REPL"];

/** The command an id names. String -> Object? */
export function command(id) {
  return COMMANDS.find((c) => c.id === id) ?? null;
}

/** A command's keys until the settings say otherwise. String -> [String] */
export function defaultKeys(id) {
  const found = command(id);
  if (!found) return [];
  return typeof found.defaults === "function" ? found.defaults(onMac()) : [...found.defaults];
}

/** An action's keys as the settings hold them -- a list, or one spec
 *  as earlier settings saved it -- as a list. Any -> [String] */
export function keyList(held) {
  if (Array.isArray(held)) return held.filter((k) => typeof k === "string" && k !== "");
  return typeof held === "string" && held !== "" ? [held] : [];
}

/** A command's keys: the settings' (`settings.keys`) over its defaults.
 *  Object -> String -> [String] */
export function keysOf(settings, id) {
  const saved = settings?.keys;
  return saved && Object.prototype.hasOwnProperty.call(saved, id)
    ? keyList(saved[id]) : defaultKeys(id);
}

/** Whether a command's keys are its defaults. Object -> String -> Bool */
export function isDefault(settings, id) {
  return !(settings?.keys && Object.prototype.hasOwnProperty.call(settings.keys, id));
}

/** Settings with a command's keys set: dropped from `keys` where they
 *  are its defaults. Object -> String -> [String] -> Object */
export function withKeys(settings, id, specs) {
  const keys = { ...(settings.keys ?? {}) };
  if (specs.join("\n") === defaultKeys(id).join("\n")) delete keys[id];
  else keys[id] = [...specs];
  return { ...settings, keys };
}

/** Saved settings as this version reads them: the debugger's keys that
 *  earlier versions saved as `debugKeys` ({next: ["F10"]}) moved into
 *  `keys` ("debug.next"), where `keys` has none for that action yet.
 *  Object -> Object */
export function migrateSettings(saved) {
  if (!saved || typeof saved !== "object") return {};
  const out = { ...saved };
  const keys = out.keys && typeof out.keys === "object" && !Array.isArray(out.keys)
    ? { ...out.keys } : {};
  const old = out.debugKeys;
  if (old && typeof old === "object" && !Array.isArray(old)) {
    for (const [action, held] of Object.entries(old)) {
      const id = "debug." + action;
      if (command(id) && !(id in keys)) keys[id] = keyList(held);
    }
  }
  delete out.debugKeys;
  out.keys = keys;
  return out;
}

/** Several key specs as this computer's keyboard writes them, "F10 or
 *  Option+O". [String] -> String */
export function showKeys(specs) {
  return specs.length === 0 ? "no key" : specs.map(showKey).join(" or ");
}

/** The physical key a written character stands for, so a key means the
 *  same with Shift held: `;` is Semicolon whether or not it types `:`. */
const CODES = {
  ";": "Semicolon", "'": "Quote", "\\": "Backslash", ",": "Comma", ".": "Period",
  "/": "Slash", "[": "BracketLeft", "]": "BracketRight", "-": "Minus", "=": "Equal",
  "`": "Backquote", Enter: "Enter", Space: "Space", Tab: "Tab", Backspace: "Backspace",
  Up: "ArrowUp", Down: "ArrowDown", Left: "ArrowLeft", Right: "ArrowRight",
};

/** A key spec, "Mod+Shift+;", as {mod, ctrl, alt, shift, code}. Off a
 *  Mac, Ctrl is Mod. String -> Object? */
export function parseKey(spec) {
  if (typeof spec !== "string" || spec === "") return null;
  const parts = spec.split("+");
  // "Mod++" is the key `+` itself.
  let key = parts.pop();
  if (key === "" && parts.length > 0 && parts[parts.length - 1] === "") {
    parts.pop();
    key = "+";
  }
  const has = (name) => parts.includes(name);
  let code = CODES[key];
  if (!code && /^[A-Za-z]$/.test(key)) code = "Key" + key.toUpperCase();
  if (!code && /^[0-9]$/.test(key)) code = "Digit" + key;
  if (!code && /^F[0-9]{1,2}$/.test(key)) code = key;
  if (!code && key === "+") code = "Equal";
  if (!code) return null;
  const mac = onMac();
  return { mod: has("Mod") || (!mac && has("Ctrl")), ctrl: mac && has("Ctrl"),
           alt: has("Alt"), shift: has("Shift"), code };
}

/** The physical key an event was, from `code`, or where a keyboard
 *  leaves that empty -- some on a phone do -- from the key it typed.
 *  KeyboardEvent -> String */
export function codeOf(event) {
  if (event.code) return event.code;
  const key = event.key ?? "";
  if (key === " ") return "Space";
  if (/^[A-Za-z]$/.test(key)) return "Key" + key.toUpperCase();
  if (/^[0-9]$/.test(key)) return "Digit" + key;
  if (CODES[key]) return CODES[key];
  if (Object.values(CODES).includes(key) || /^F[0-9]{1,2}$/.test(key)) return key;
  return "";
}

/** Whether a key event is the key a spec names. Object -> KeyboardEvent -> Bool */
export function matchesKey(parsed, event) {
  if (!parsed || codeOf(event) !== parsed.code) return false;
  const mac = onMac();
  const mod = mac ? event.metaKey : event.ctrlKey;
  const ctrl = mac ? event.ctrlKey : false;
  if (!mac && event.metaKey) return false;
  return mod === parsed.mod && ctrl === parsed.ctrl && event.altKey === parsed.alt
    && event.shiftKey === parsed.shift;
}

/** Whether a key event is one of a command's keys, as the settings have
 *  them. Object -> String -> KeyboardEvent -> Bool */
export function isKey(settings, id, event) {
  return keysOf(settings, id).some((spec) => matchesKey(parseKey(spec), event));
}

/** The spec a key event writes, for the settings' key fields, or null
 *  for a modifier pressed on its own. KeyboardEvent -> String? */
export function specOf(event) {
  if (["Shift", "Control", "Alt", "Meta"].includes(event.key)) return null;
  const code = codeOf(event);
  const named = Object.entries(CODES).find(([, c]) => c === code)?.[0];
  let key = named;
  if (!key && /^Key[A-Z]$/.test(code)) key = code.slice(3);
  if (!key && /^Digit[0-9]$/.test(code)) key = code.slice(5);
  if (!key && /^F[0-9]{1,2}$/.test(code)) key = code;
  if (!key) return null;
  const mac = onMac();
  const parts = [];
  if (mac ? event.metaKey : event.ctrlKey) parts.push("Mod");
  if (mac && event.ctrlKey) parts.push("Ctrl");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  parts.push(key);
  return parts.join("+");
}

/** A key spec as this computer's keyboard writes it: Cmd and Option on
 *  a Mac. String -> String */
export function showKey(spec) {
  if (!spec) return "no key";
  const mac = onMac();
  const parts = spec.split("+");
  if (spec.endsWith("++")) parts.splice(-2, 2, "+");
  return parts.map((part) => part === "Mod" ? (mac ? "Cmd" : "Ctrl")
    : part === "Alt" && mac ? "Option" : part).join("+");
}

/** The Monaco keybinding a spec stands for, so an editor's action and its
 *  right-click menu name the key; null where Monaco has no such key.
 *  Monaco -> String -> Int? */
export function monacoKey(monaco, spec) {
  const parsed = parseKey(spec);
  if (!parsed) return null;
  const { KeyMod, KeyCode } = monaco;
  const named = {
    ArrowUp: "UpArrow", ArrowDown: "DownArrow", ArrowLeft: "LeftArrow", ArrowRight: "RightArrow",
  };
  const code = KeyCode[named[parsed.code] ?? parsed.code];
  if (code === undefined) return null;
  return (parsed.mod ? KeyMod.CtrlCmd : 0) | (parsed.ctrl ? KeyMod.WinCtrl : 0)
    | (parsed.alt ? KeyMod.Alt : 0) | (parsed.shift ? KeyMod.Shift : 0) | code;
}
