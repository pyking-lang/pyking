// The Compiled code tab's Download: everything a compile wrote, with what
// `pyk compile` puts beside it -- each library's implementation for the
// target, the browser's `io`, the samples and pictures a program names --
// and a Makefile, packed as one .zip. Pure, so node can test it: the files
// a library holds are reached through a function the caller supplies.
//
// Functions:
//   crc32(bytes) -- the CRC-32 a zip entry carries.
//   zip(entries, date) -- a .zip of stored (uncompressed) entries.
//   familyOf(target) -- the backend family a target belongs to.
//   makefile(target, stem, names) -- the Makefile for a compile's files.
//   packFiles(options) -- every file of the download, Makefile included.

const encoder = new TextEncoder();

/** A string or bytes, as bytes. (String | Uint8Array) -> Uint8Array */
function bytesOf(data) {
  return typeof data === "string" ? encoder.encode(data) : data;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

/** The CRC-32 of some bytes, as a zip entry carries it. Uint8Array -> Int */
export function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i += 1) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A .zip holding each entry stored as it is, every name in UTF-8, each
 *  file readable by everyone and the Makefile's recipes' tools.
 *  [{name, data}] -> Date -> Uint8Array */
export function zip(entries, date = new Date()) {
  const time = (date.getHours() << 11) | (date.getMinutes() << 5) | (date.getSeconds() >> 1);
  const day = ((Math.max(date.getFullYear(), 1980) - 1980) << 9)
    | ((date.getMonth() + 1) << 5) | date.getDate();
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const data = bytesOf(entry.data);
    const crc = crc32(data);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true);
    local.setUint16(8, 0, true);
    local.setUint16(10, time, true);
    local.setUint16(12, day, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, data.length, true);
    local.setUint32(22, data.length, true);
    local.setUint16(26, name.length, true);
    local.setUint16(28, 0, true);
    const central = new DataView(new ArrayBuffer(46));
    central.setUint32(0, 0x02014b50, true);
    central.setUint16(4, (3 << 8) | 20, true);
    central.setUint16(6, 20, true);
    central.setUint16(8, 0x0800, true);
    central.setUint16(10, 0, true);
    central.setUint16(12, time, true);
    central.setUint16(14, day, true);
    central.setUint32(16, crc, true);
    central.setUint32(20, data.length, true);
    central.setUint32(24, data.length, true);
    central.setUint16(28, name.length, true);
    central.setUint32(38, (0o100644 << 16) >>> 0, true);
    central.setUint32(42, offset, true);
    locals.push(new Uint8Array(local.buffer), name, data);
    centrals.push(new Uint8Array(central.buffer), name);
    offset += 30 + name.length + data.length;
  }
  const size = centrals.reduce((n, part) => n + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  const parts = [...locals, ...centrals, new Uint8Array(end.buffer)];
  const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/** The family a target belongs to: "python", "node", "web", "iweb", "c",
 *  "java", "ocaml" or "pyking". String -> String */
export function familyOf(target) {
  for (const family of ["python", "node", "iweb", "web", "java", "ocaml", "pyking"]) {
    if (target.startsWith(family)) return family;
  }
  return /^c\d/.test(target) ? "c" : target;
}

/** A module's Java class name: its words capitalised and joined, as
 *  `tinyweb_external` is `TinywebExternal`. String -> String */
function className(name) {
  return name.split("_").filter(Boolean)
    .map((word) => word[0].toUpperCase() + word.slice(1)).join("");
}

/** Where a module's implementation is read from in lib/ for a family, in
 *  the order to try them, and what it is called beside the program.
 *  String -> String -> {from: [String], to: String}? */
function implementation(module, family) {
  const base = `${module}/${module}_external`;
  switch (family) {
    case "python": return { from: [`${base}.py`], to: `${module}_external.py` };
    case "node": return { from: [`${base}_node.js`], to: `${module}_external.js` };
    case "web": return { from: [`${base}_browser.js`], to: `${module}_external.js` };
    case "iweb": return { from: [`${base}_interpreter.js`, `${base}_browser.js`], to: `${module}_external.js` };
    case "c": return { from: [`${base}.c`], to: `${module}_external.c` };
    case "java": {
      const file = className(`${module}_external`) + ".java";
      return { from: [`${module}/${file}`], to: file };
    }
    case "ocaml": return { from: [`${base}.ml`], to: `${module}_external.ml` };
    default: return null;
  }
}

/** The files a native build names, in the order its compiler needs them:
 *  each module after what it imports, a module's implementation in its
 *  host language before the module's own file, an OCaml interface before
 *  its implementation, the program's own file last.
 *  String -> String -> [String] -> [String] */
function linkOrder(family, stem, names) {
  const suffix = family === "c" ? ".c" : ".ml";
  const own = stem + suffix;
  const generated = names.filter((n) => n.endsWith(suffix) && !n.endsWith("_external" + suffix) && n !== own);
  const implemented = names.filter((n) => n.endsWith("_external" + suffix));
  const order = [];
  const take = (name) => { if (names.includes(name) && !order.includes(name)) order.push(name); };
  // A module with no Pyking half has nothing generated: its
  // implementation goes first, since it imports nothing.
  for (const name of implemented) {
    const module = name.slice(0, -("_external" + suffix).length);
    if (!generated.includes(module + suffix)) take(name);
  }
  for (const name of generated) {
    const module = name.slice(0, -suffix.length);
    take(module + "_external" + suffix);
    if (family === "ocaml") take(module + ".mli");
    take(name);
  }
  take(own);
  return order;
}

/** The Makefile for one compile: `make` builds what the target builds,
 *  `make run` builds and runs it, `make clean` removes what make made.
 *  `names` is every file of the download. String -> String -> [String] -> String */
export function makefile(target, stem, names) {
  const family = familyOf(target);
  const lines = [
    `# Builds and runs the program the Pyking playground compiled for ${target}.`,
    "#",
    "#   make        build it",
    "#   make run    build it and run it",
    "#   make clean  remove what make built",
    "",
  ];
  const rules = (vars, build, run, clean) => lines.concat(
    vars, vars.length ? [""] : [],
    [".PHONY: all run clean", "", ...build, "", "run:" + (run.deps ?? ""), ...run.recipe.map((r) => "\t" + r),
      "", "clean:", ...clean.map((c) => "\t" + c), ""]).join("\n");
  switch (family) {
    case "c": {
      const sources = linkOrder("c", stem, names);
      return rules(
        ["CC ?= cc", `SOURCES = ${sources.join(" ")}`],
        [`all: ${stem}`, "", `${stem}: $(SOURCES) $(wildcard *.h)`, `\t$(CC) -std=${target} -o ${stem} $(SOURCES) -lm`],
        { deps: ` ${stem}`, recipe: [`./${stem}`] },
        [`rm -f ${stem}`]);
    }
    case "ocaml": {
      const sources = linkOrder("ocaml", stem, names);
      return rules(
        ["OCAMLOPT ?= ocamlopt", `SOURCES = ${sources.join(" ")}`],
        [`all: ${stem}`, "", `${stem}: $(SOURCES)`, `\t$(OCAMLOPT) -I +unix unix.cmxa -I . -o ${stem} $(SOURCES)`],
        { deps: ` ${stem}`, recipe: [`./${stem}`] },
        [`rm -f ${stem} *.cmi *.cmx *.cmo *.o`]);
    }
    case "java": {
      const main = className(stem);
      const sources = names.filter((n) => n.endsWith(".java"));
      const release = target.replace(/^java/, "");
      return rules(
        ["JAVAC ?= javac", "JAVA ?= java", `SOURCES = ${sources.join(" ")}`],
        [`all: ${main}.class`, "", `${main}.class: $(SOURCES)`, `\t$(JAVAC) --release ${release} -d . $(SOURCES)`],
        { deps: ` ${main}.class`, recipe: [`$(JAVA) -cp . ${main}`] },
        ["rm -f *.class"]);
    }
    case "python":
      return rules(["PYTHON ?= python3"], ["all:", "\t@echo 'nothing to build: make run runs it'"],
        { recipe: [`$(PYTHON) ${stem}.py`] }, ["rm -rf __pycache__"]);
    case "node":
      return rules(["NODE ?= node"], ["all:", "\t@echo 'nothing to build: make run runs it'"],
        { recipe: [`$(NODE) ${stem}.js`] }, ["@true"]);
    case "web":
    case "iweb":
      // A page of modules must be served: a browser refuses a module
      // fetched over file://.
      return rules(["PYK ?= pyk", "PORT ?= 8000"], ["all:", "\t@echo 'nothing to build: make run serves the page'"],
        { recipe: [`@echo "open http://localhost:$(PORT)/${stem}.html"`, "$(PYK) serve --port $(PORT) ."] },
        ["@true"]);
    default:
      return rules(["PYK ?= pyk"], ["all:", "\t@echo 'nothing to build: make run runs it'"],
        { recipe: [`$(PYK) ${names.find((n) => n.endsWith(".pyk")) ?? stem + ".pyk"}`] }, ["@true"]);
  }
}

/** The quoted file names in a program that name a sample or a picture,
 *  which a library finds in its `<name>_assets/` directory. String -> [String] */
function assetsNamed(source) {
  const found = new Set();
  for (const m of source.matchAll(/"([A-Za-z0-9_.-]+\.(?:wav|mp3|ogg|png|jpg|jpeg|gif))"/g)) found.add(m[1]);
  return [...found];
}

/** Every file a download holds, as [{name, data}]: the compile's own
 *  files, what `pyk compile` writes beside them for the target, and a
 *  Makefile. `get(path)` answers a file of the standard library (a path
 *  under lib/) as bytes, or null; `bundle()` the compiler as JavaScript,
 *  which an iweb page runs. `externals` are the program's modules
 *  implemented in a host language, as `pykAnalyze` names them.
 *  {target, files, externals, source, name, get, bundle} -> Promise<[{name, data}]> */
export async function packFiles({ target, files, externals = [], source, name = "playground.pyk", get, bundle }) {
  const family = familyOf(target);
  const stem = name.replace(/\.pyk$/, "");
  const out = Object.entries(files).map(([file, text]) => ({ name: file, data: text }));
  const has = (file) => out.some((entry) => entry.name === file);
  const first = async (paths) => {
    for (const path of paths) {
      const data = await get(path);
      if (data !== null) return data;
    }
    return null;
  };
  const add = async (from, to) => {
    if (has(to)) return;
    const data = await first(from);
    if (data !== null) out.push({ name: to, data });
  };
  let modules = [...externals];
  if (family === "iweb") {
    // The page names everything it loads: each module's Pyking source,
    // and each module implemented in JavaScript.
    const page = files[stem + ".html"] ?? "";
    modules = [...page.matchAll(/import \* as pykExt_(\w+) from/g)].map((m) => m[1]);
    for (const m of page.matchAll(/fetch\('\.\/([^']+)'\)/g)) {
      const file = m[1];
      if (file === name) out.push({ name: file, data: source });
      else await add([`${file.replace(/(_external)?\.pyk$/, "")}/${file}`], file);
    }
    for (const module of modules) await add([`${module}/${module}_page.js`], `${module}_page.js`);
    if (bundle) out.push({ name: "pyking.js", data: await bundle() });
  }
  if ((family === "web" || family === "iweb") && !modules.includes("io")) {
    // A page's `print` writes through the `io` library, imported or not.
    modules.push("io");
  }
  for (const module of modules) {
    const where = implementation(module, family);
    if (where) await add(where.from, where.to);
  }
  if (family !== "pyking") {
    for (const module of modules) {
      for (const asset of assetsNamed(source)) {
        await add([`${module}/${module}_assets/${asset}`], `${module}_assets/${asset}`);
      }
    }
  }
  out.push({ name: "Makefile", data: makefile(target, stem, out.map((e) => e.name)) });
  return out;
}
