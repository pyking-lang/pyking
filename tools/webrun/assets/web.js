// What the Pyking web tools share in the browser: loading Ace with the
// Pyking mode, loading KaTeX, and booting the compiler. The playground
// (tools/playground/assets/playground.js) and the notebook
// (tools/notebook/assets/notebook.js) both import this, and neither keeps
// a copy of any of it. See tools/webrun/README.md.
//
// Every URL is resolved against this module's own location by default,
// so a page that serves webrun/, vendor/ and pyking/ side by side -- the
// layout tools/webrun/server.py serves -- needs no configuration.

import { PykingRuntime } from "./pyking-runtime.js";

export { PykingRuntime };
export { JsRunner } from "./pyking-runtime.js";

const HERE = new URL(".", import.meta.url);

/** The default locations, beside this module: this directory, the
 *  vendored libraries, and the compiler bundle. */
export const DEFAULT_URLS = {
  webrun: HERE.href,
  vendor: new URL("../vendor/", HERE).href,
  pyking: new URL("../pyking/", HERE).href,
};

/** A directory URL, absolute and ending in `/`. String -> String */
export function directoryURL(url) {
  const absolute = new URL(url, document.baseURI).href;
  return absolute.endsWith("/") ? absolute : absolute + "/";
}

/** A compiler worker, not yet booted. {webrun, pyking} -> PykingRuntime */
export function createRuntime(urls = {}) {
  const { webrun, pyking } = { ...DEFAULT_URLS, ...urls };
  return new PykingRuntime({
    pykingURL: directoryURL(pyking),
    workerURL: directoryURL(webrun) + "pyking-worker.js",
  });
}

/** Boots the compiler and loads Ace with the Pyking mode, whose word
 *  lists come from that compiler. Answers the compiler's words.
 *  PykingRuntime -> {webrun, vendor} -> (String -> ()) -> {...} */
export async function ensureEditor(runtime, urls = {}, onStatus = () => {}) {
  const { webrun, vendor } = { ...DEFAULT_URLS, ...urls };
  const [words] = await Promise.all([
    runtime.ready(onStatus).then(() => runtime.words()),
    ensureAce(vendor),
  ]);
  if (!globalThis.pykingWords) {
    const types = words.keywords.filter((w) => /^[A-Z]/.test(w));
    const constants = ["true", "false"].filter((w) => words.keywords.includes(w));
    globalThis.pykingWords = {
      keywords: words.keywords.filter(
        (w) => !types.includes(w) && !constants.includes(w)),
      types,
      constants,
      builtins: words.builtins,
    };
  }
  if (!ace.config.$modes?.["ace/mode/pyking"]) {
    await loadScript(directoryURL(webrun) + "pyking-mode.js");
  }
  return words;
}

/** Ace itself, with its basePath pointed at the vendored copy so modes
 *  and themes load from there. String -> Promise */
export async function ensureAce(vendor = DEFAULT_URLS.vendor) {
  const base = directoryURL(vendor) + "ace";
  if (!globalThis.ace) await loadScript(base + "/ace.js");
  ace.config.set("basePath", base);
}

/** KaTeX and its stylesheet, loaded once. String -> Promise */
export async function ensureKatex(vendor = DEFAULT_URLS.vendor) {
  const base = directoryURL(vendor) + "katex";
  loadStyle(base + "/katex.min.css");
  if (!globalThis.katex) await loadScript(base + "/katex.min.js");
  return globalThis.katex;
}

/** A classic script, appended to the document once per URL.
 *  String -> Promise */
export function loadScript(src) {
  const existing = document.querySelector(`script[data-pyk-src="${src}"]`);
  if (existing) return existing.pykLoaded;
  const script = document.createElement("script");
  script.dataset.pykSrc = src;
  script.pykLoaded = new Promise((resolve, reject) => {
    script.onload = resolve;
    script.onerror = () => reject(new Error("could not load " + src));
  });
  script.src = src;
  document.head.appendChild(script);
  return script.pykLoaded;
}

/** A stylesheet, linked once per URL. String -> () */
export function loadStyle(href) {
  if (document.querySelector(`link[data-pyk-href="${href}"]`)) return;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = href;
  link.dataset.pykHref = href;
  document.head.appendChild(link);
}

/** A JSON document; throws with the URL on anything but 200.
 *  String -> Promise<Any> */
export async function fetchJSON(url) {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
  return response.json();
}

/** A text document; throws with the URL on anything but 200.
 *  String -> Promise<String> */
export async function fetchText(url) {
  const response = await fetch(url, { cache: "no-store" });
  if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
  return response.text();
}
