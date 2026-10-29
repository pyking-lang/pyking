// The playground's keys (tools/playground/assets/keys.js), under node:
// every command and its defaults, how a key spec is read, matched
// against a key event, written from one and shown -- as a Mac and as
// another computer -- and the settings: a command's keys over its
// defaults, set and reset, and an earlier version's `debugKeys` moved
// into `keys`. The page's own use of them, keys pressed for real, is
// tests/lsp/playground.mjs.
//
//   node keys.mjs
//
// The answer, one JSON line on stdout, is {checks, failures: [String]}.

import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const keys = await import(path.join(repo, "tools", "playground", "assets", "keys.js"));
const debug = await import(path.join(repo, "tools", "playground", "assets", "debugger.js"));

let checks = 0;
const failures = [];
const check = (label, ok, detail = "") => {
  checks += 1;
  if (!ok) failures.push(`keys: ${label}${detail === "" ? "" : ": " + JSON.stringify(detail)}`);
};

/** Runs `body` as a computer whose platform is `platform`. */
const as = (platform, body) => {
  const saved = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { platform } });
  try {
    return body();
  } finally {
    if (saved) Object.defineProperty(globalThis, "navigator", saved);
    else delete globalThis.navigator;
  }
};
const mac = (body) => as("MacIntel", body);
const linux = (body) => as("Linux x86_64", body);
const event = (code, mods = {}, key = undefined) => ({
  code, key: key ?? code, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods,
});

// The commands.
const ids = keys.COMMANDS.map((c) => c.id);
check("every command the playground adds", ids.join() === ["run", "copySlides", "debug.start",
  "debug.continue", "debug.next", "debug.in", "debug.out", "debug.stop", "debug.breakpoint",
  "repl.submit", "repl.newline", "repl.previous", "repl.next", "repl.complete"].join(), ids);
check("each in an area the settings group by", keys.COMMANDS.every((c) => keys.AREAS.includes(c.area))
  && keys.AREAS.join() === "Editor,Debugger,REPL");
check("each with a label", keys.COMMANDS.every((c) => typeof c.label === "string" && c.label !== ""));
check("Run: Shift+Enter and Ctrl+Enter off a Mac",
  linux(() => keys.defaultKeys("run")).join() === "Shift+Enter,Mod+Enter", linux(() => keys.defaultKeys("run")));
check("Run: Shift+Enter, Cmd+Enter and Ctrl+Enter on a Mac",
  mac(() => keys.defaultKeys("run")).join() === "Shift+Enter,Mod+Enter,Ctrl+Enter", mac(() => keys.defaultKeys("run")));
check("Copy for slides: Alt+Shift+C", keys.defaultKeys("copySlides").join() === "Alt+Shift+C");
check("the REPL's: Enter, Shift+Enter, Up, Down, Tab",
  ["submit", "newline", "previous", "next", "complete"].map((a) => keys.defaultKeys("repl." + a).join()).join()
  === "Enter,Shift+Enter,Up,Down,Tab");
check("the debugger's, as debugger.js has them", JSON.stringify(debug.DEFAULT_KEYS) === JSON.stringify({
  start: ["Alt+D"], continue: ["F8", "Alt+C"], next: ["F10", "Alt+O"], in: ["F11", "Alt+I"],
  out: ["Shift+F11", "Alt+T"], stop: ["Alt+S"], breakpoint: ["Alt+B"] }), debug.DEFAULT_KEYS);
check("and its actions' names", debug.ACTIONS.map(([a]) => a).join() === "start,continue,next,in,out,stop,breakpoint");
check("an unknown command has no keys", keys.defaultKeys("nope").length === 0);

// No default is a browser's: neither the inspector's Ctrl+Shift+C or
// Cmd+Option+C, nor Ctrl/Cmd+Shift+I or J.
const reserved = ["Mod+Shift+C", "Mod+Alt+C", "Mod+Shift+I", "Mod+Alt+I", "Mod+Shift+J", "Mod+Alt+J",
                  "Mod+R", "Mod+W", "Mod+T", "Mod+N", "Mod+L", "Mod+P", "Mod+S", "Mod+F", "F12", "F5"];
for (const id of ids) {
  for (const platform of [mac, linux]) {
    const clash = platform(() => keys.defaultKeys(id)).find((k) => reserved.includes(k));
    check(`${id}'s keys are none a browser keeps`, !clash, clash);
  }
}
// No two commands of one area share a key, nor Run and Copy for slides
// a debugger key that acts in the editor.
for (const platform of [mac, linux]) {
  const editorAndDebugger = platform(() => keys.COMMANDS.filter((c) => c.area !== "REPL")
    .flatMap((c) => keys.defaultKeys(c.id)));
  check("no key is two commands'", new Set(editorAndDebugger).size === editorAndDebugger.length,
    editorAndDebugger);
}

// Reading a spec.
check("a spec read", JSON.stringify(linux(() => keys.parseKey("Mod+Shift+;")))
  === JSON.stringify({ mod: true, ctrl: false, alt: false, shift: true, code: "Semicolon" }));
check("Ctrl is Mod off a Mac", JSON.stringify(linux(() => keys.parseKey("Ctrl+Enter")))
  === JSON.stringify(linux(() => keys.parseKey("Mod+Enter"))));
check("and a key of its own on one", mac(() => keys.parseKey("Ctrl+Enter")).ctrl === true
  && mac(() => keys.parseKey("Ctrl+Enter")).mod === false);
check("Mod++ is the key +", keys.parseKey("Mod++")?.code === "Equal");
check("letters, digits, function keys, arrows",
  ["A", "7", "F11", "Up", "Down", "Tab", "Space"].map((k) => keys.parseKey(k)?.code).join()
  === "KeyA,Digit7,F11,ArrowUp,ArrowDown,Tab,Space");
check("nonsense is no key", keys.parseKey("Alt+Nope") === null && keys.parseKey("") === null
  && keys.parseKey(null) === null);

// Matching an event.
check("Alt+Shift+C is Alt+Shift+C", linux(() =>
  keys.matchesKey(keys.parseKey("Alt+Shift+C"), event("KeyC", { altKey: true, shiftKey: true }, "Ç"))));
check("and not Alt+C", !linux(() =>
  keys.matchesKey(keys.parseKey("Alt+Shift+C"), event("KeyC", { altKey: true }, "ç"))));
check("a Mac's Option key with the character it types",
  mac(() => keys.matchesKey(keys.parseKey("Alt+I"), event("KeyI", { altKey: true }, "Dead"))));
check("Mod is Cmd on a Mac", mac(() => keys.matchesKey(keys.parseKey("Mod+Enter"), event("Enter", { metaKey: true })))
  && !mac(() => keys.matchesKey(keys.parseKey("Mod+Enter"), event("Enter", { ctrlKey: true }))));
check("and Ctrl elsewhere", linux(() => keys.matchesKey(keys.parseKey("Mod+Enter"), event("Enter", { ctrlKey: true })))
  && !linux(() => keys.matchesKey(keys.parseKey("Mod+Enter"), event("Enter", { metaKey: true }))));
check("an event with no code is matched by the key it typed",
  linux(() => keys.matchesKey(keys.parseKey("Enter"), { code: "", key: "Enter", ctrlKey: false,
    metaKey: false, altKey: false, shiftKey: false }))
  && linux(() => keys.matchesKey(keys.parseKey("Up"), { code: "", key: "ArrowUp", ctrlKey: false,
    metaKey: false, altKey: false, shiftKey: false })));
check("a command's keys, from the settings", linux(() => keys.isKey({}, "repl.newline", event("Enter", { shiftKey: true })))
  && !linux(() => keys.isKey({ keys: { "repl.newline": ["F2"] } }, "repl.newline", event("Enter", { shiftKey: true })))
  && linux(() => keys.isKey({ keys: { "repl.newline": ["F2"] } }, "repl.newline", event("F2"))));

// Writing one from an event, and showing it.
check("an event's spec", linux(() => keys.specOf(event("KeyO", { altKey: true }, "ø"))) === "Alt+O"
  && linux(() => keys.specOf(event("Enter", { ctrlKey: true }))) === "Mod+Enter"
  && mac(() => keys.specOf(event("Enter", { ctrlKey: true }))) === "Ctrl+Enter"
  && mac(() => keys.specOf(event("Semicolon", { metaKey: true, shiftKey: true }, ":"))) === "Mod+Shift+;"
  && linux(() => keys.specOf(event("ArrowUp", { altKey: true }))) === "Alt+Up");
check("a modifier on its own writes none", keys.specOf(event("ShiftLeft", { shiftKey: true }, "Shift")) === null);
check("shown as a Mac's keyboard names them", mac(() => keys.showKeys(["Mod+Enter", "Alt+Shift+C"]))
  === "Cmd+Enter or Option+Shift+C", mac(() => keys.showKeys(["Mod+Enter", "Alt+Shift+C"])));
check("and as another's", linux(() => keys.showKeys(["Mod+Enter", "Alt+Shift+C"]))
  === "Ctrl+Enter or Alt+Shift+C");
check("no keys", keys.showKeys([]) === "no key");
check("Mod++ shown", linux(() => keys.showKey("Mod++")) === "Ctrl++", linux(() => keys.showKey("Mod++")));

// The settings.
check("a command's keys are its defaults until set", keys.keysOf({}, "debug.next").join() === "F10,Alt+O"
  && keys.isDefault({}, "debug.next"));
const set = keys.withKeys({ fontSize: 15 }, "debug.next", ["F7"]);
check("set, they are the settings'", keys.keysOf(set, "debug.next").join() === "F7"
  && !keys.isDefault(set, "debug.next") && set.fontSize === 15, set);
const none = keys.withKeys({}, "debug.stop", []);
check("none is kept as none", keys.keysOf(none, "debug.stop").length === 0
  && JSON.stringify(none.keys) === '{"debug.stop":[]}', none);
check("set back to the defaults, they are dropped",
  JSON.stringify(keys.withKeys(set, "debug.next", ["F10", "Alt+O"]).keys) === "{}");
const migrated = keys.migrateSettings({ fontSize: 15, debugKeys: { next: "F7", start: ["Alt+G"],
  stop: [], nope: ["F1"] } });
check("an earlier version's debugKeys move into keys", JSON.stringify(migrated)
  === JSON.stringify({ fontSize: 15, keys: { "debug.next": ["F7"], "debug.start": ["Alt+G"], "debug.stop": [] } }),
  migrated);
check("keys already set win", keys.migrateSettings({ keys: { "debug.next": ["F6"] },
  debugKeys: { next: ["F7"] } }).keys["debug.next"].join() === "F6");
check("nothing saved is nothing", JSON.stringify(keys.migrateSettings(null)) === "{}"
  && JSON.stringify(keys.migrateSettings({ theme: "dark" })) === JSON.stringify({ theme: "dark", keys: {} }));

// Monaco's keybinding for a spec, with Monaco's own numbers.
const monaco = { KeyMod: { CtrlCmd: 2048, Shift: 1024, Alt: 512, WinCtrl: 256 },
                 KeyCode: { KeyC: 33, Enter: 3, F8: 66, UpArrow: 16 } };
check("Monaco's keybinding", linux(() => keys.monacoKey(monaco, "Alt+Shift+C")) === (512 | 1024 | 33)
  && mac(() => keys.monacoKey(monaco, "Ctrl+Enter")) === (256 | 3)
  && linux(() => keys.monacoKey(monaco, "Mod+Enter")) === (2048 | 3)
  && keys.monacoKey(monaco, "Up") === 16 && keys.monacoKey(monaco, "Alt+;") === null);

process.stdout.write(JSON.stringify({ checks, failures }) + "\n");
