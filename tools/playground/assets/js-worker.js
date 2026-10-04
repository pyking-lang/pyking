// Runs generated JavaScript on a thread of its own, for the same reason the
// Python one exists: so a program that never returns can be stopped.
// Served by tools/playground/playground.py.
//
// A sandboxed iframe was the obvious alternative and is not good enough: a
// same-process frame shares the main thread, so an endless loop inside one
// can still lock the page. A worker is guaranteed to be a separate thread
// and `terminate()` is guaranteed to end it.
//
// What arrives is a whole compiled program: the module the user is
// looking at, plus the files the compiler wrote beside it (the shared
// `pyk-runtime.js`, and one module per Pyking module). Nothing is
// rewritten except the import specifiers, which have to become blob URLs
// -- a module loaded from a blob has no base to resolve `./x.js` against.

const send = (type, data) => self.postMessage({ type, data });

// A generated program prints through `console.log`, which is redirected
// below -- but `pykFormat` is still needed here, because the shared
// runtime module the program imports is one of the files being wired up
// and this worker is what supplies its formatting. It arrives with each
// program, read out of the compiler (PykingRuntime.words(), which asks
// src/target_js_packaging.ml), so it cannot drift from what the compiler
// generates. A hand-copy did drift, which is why it no longer is one.
let formatInstalled = false;

/** Blob URLs for a whole program, with every relative import rewritten
 *  to point at them. Files are wired up in dependency order by resolving
 *  lazily: a specifier is replaced only once its target has a URL, and
 *  the compiler emits no cycles. */
function link(files, main) {
  const urls = {};
  const remaining = Object.keys(files);
  const specifier = /(\bfrom\s*|\bimport\s*)(["'])\.\/([^"']+)\2/g;
  // Repeat until nothing more can be resolved: each pass links the files
  // whose own imports are all already linked.
  for (let pass = 0; pass < remaining.length + 1 && remaining.length; pass++) {
    for (let i = remaining.length - 1; i >= 0; i--) {
      const name = remaining[i];
      const needs = [];
      files[name].replace(specifier, (_, __, ___, target) => needs.push(target));
      if (needs.some((n) => files[n] !== undefined && urls[n] === undefined)) continue;
      const text = files[name].replace(
        specifier,
        (whole, keyword, quote, target) =>
          urls[target] ? keyword + quote + urls[target] + quote : whole);
      urls[name] = URL.createObjectURL(
        new Blob([text], { type: "text/javascript" }));
      remaining.splice(i, 1);
    }
  }
  return urls;
}

self.onmessage = async (event) => {
  const { code, files, main, formatHelper } = event.data;
  if (!formatInstalled && formatHelper) {
    // Indirect eval, so the helper's declarations land in global scope.
    (0, eval)(formatHelper);
    formatInstalled = true;
  }
  console.log = (...args) => send("stdout", args.join(" ") + "\n");
  // `debug` writes with console.error, and the page shows it apart.
  console.error = (...args) => send("debug", args.join(" ") + "\n");
  let urls = {};
  try {
    // The pane's text wins: the user may have edited what is displayed.
    const program = { ...files, [main]: code };
    urls = link(program, main);
    if (!urls[main]) throw new Error("could not resolve the program's imports");
    await import(urls[main]);
    // What the page loader does when a `web` program stops: write out a
    // line `io.write` left unfinished.
    if (urls["io_external.js"]) (await import(urls["io_external.js"])).flush?.();
    send("done");
  } catch (err) {
    send("failed", err && err.message ? err.message : String(err));
  } finally {
    for (const url of Object.values(urls)) URL.revokeObjectURL(url);
  }
};
