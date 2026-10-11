// Makes the Pyking cells on a page runnable, with the notebook's own
// cells (notebook.js, mountCells) -- and its exercises and quizzes, which
// arrive as fragments of a notebook -- and keeps their theme the site's.
// Loaded on every page; does nothing on a page with no cell. The
// runtime -- notebook/, webrun/, vendor/, pyking/, lib/ -- is served
// under runtime/ beside this directory (tools/site/README.md).

const placeholders = document.querySelectorAll(
  ".pkn-embedded .pkn-cell, .pkn-embedded .pkn-fragment");

if (placeholders.length) {
  const runtime = new URL("../runtime/", import.meta.url);
  const { mountCells } = await import(new URL("notebook/notebook.js", runtime).href);
  const theme = () => (document.documentElement.dataset.theme === "dark" ? "dark" : "light");
  const cells = await mountCells(placeholders, { theme: theme(), fontSize: 14 });
  new MutationObserver(() => cells.setTheme(theme(), false))
    .observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  // A handle for the console and for tests driving the page.
  window.pykingCells = cells;
}
