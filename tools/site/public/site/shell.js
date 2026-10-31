// Keeps each section of the website as the reader left it. The header's
// sections -- Install, Getting started, Documentation, Libraries, the
// Playground, and the start page -- are each a page of their own, and
// going to one would throw away the page before: the playground's
// program running, its REPL, its debugger stopped on a line, the library
// page and where it was scrolled to. So the window the reader opened
// becomes a shell holding one frame per section, each opened the first
// time its section is, and a section's tab shows its frame again exactly
// as it was. See tools/site/README.md, "Every section kept open".
//
// Loaded by every page, first in its head, as a classic script, so it
// decides what the page is before anything is drawn:
//
//   the shell     the page the reader opened, in a window of its own.
//                 Its own content is never shown and its own scripts
//                 leave it be (`html.pyking-shell`); it shows the frames.
//   a section     a page in one of the shell's frames
//                 (`html.pyking-framed`). A link to another section is
//                 handed to the shell, a section's tab in the header
//                 included, which shows that section as it was left;
//                 any other link is followed in the frame as usual.
//   a plain page  anything else: a page in someone else's frame, a page
//                 that is no section's (404), or one opened with
//                 `?noshell`, which is how to look at a page on its own.
//
// The address bar, the title and Back follow the section shown: each
// section shown is an entry of the shell's history, which remembers
// which section it was, and each page a frame goes to is an entry of
// that frame's, as with any link. A frame that is hidden is told so with
// a `pyking:visibility` event on its window (`detail.hidden`), which the
// tinyweb pages a program shows there take to hold their clock and
// sound (tools/webrun/assets/pages.js). Theirs is the only state a
// hidden section stops: everything else runs on.
//
// The script's own attributes say where the site is: `data-base` is the
// path it is served under ("" at a domain's root), and `data-sections`
// is [{key, label, prefix}], each prefix a path below the base that the
// pages of that section start with.

(() => {
  "use strict";
  const script = document.currentScript;
  const base = (script?.dataset.base ?? "").replace(/\/$/, "");
  const sections = JSON.parse(script?.dataset.sections || "[]");
  const root = document.documentElement;
  const EVENT = "pyking:visibility";

  // The section a URL is a page of: a section's key, "home" for the
  // start page, or null for anything else. String -> String?
  function sectionOf(href) {
    let url;
    try {
      url = new URL(href, location.href);
    } catch {
      return null;
    }
    if (url.origin !== location.origin || !url.pathname.startsWith(base + "/")) return null;
    const path = url.pathname.slice(base.length);
    if (path === "/" || path === "/index.html") return "home";
    return sections.find((s) => path.startsWith(s.prefix))?.key ?? null;
  }

  let shell = null;
  try {
    if (window.parent !== window) shell = window.parent.pykingShell ?? null;
  } catch {
    shell = null;    // someone else's frame, from another origin
  }
  if (shell) {
    framed(shell);
    return;
  }
  if (window.top !== window) return;
  if (new URLSearchParams(location.search).has("noshell")) return;
  if (sectionOf(location.href) === null) return;
  window.pykingShell = makeShell();

  // --- the shell ---

  function makeShell() {
    root.classList.add("pyking-shell");
    const style = document.createElement("style");
    style.textContent = `
      html.pyking-shell, html.pyking-shell body { overflow: hidden !important; }
      html.pyking-shell body > :not(#pyking-shell) { display: none !important; }
      #pyking-shell { position: fixed; inset: 0; background: var(--sl-color-bg, Canvas); }
      #pyking-shell > iframe {
        position: absolute; inset: 0; width: 100%; height: 100%; border: 0; display: block;
      }
      #pyking-shell > iframe[data-hidden] { visibility: hidden; }
    `;
    document.head.append(style);

    const frames = new Map();    // section -> its iframe
    let current = null;          // the section shown
    let box = null;

    // Where a frame is: where it was last sent, until it gets there,
    // then where it is. Iframe -> String?
    function whereIs(frame) {
      if (frame.pykingGoing) return frame.pykingGoing;
      try {
        const href = frame.contentWindow.location.href;
        return href === "about:blank" ? null : href;
      } catch {
        return null;
      }
    }

    // The shell's address and title follow the section shown. ()
    function follow() {
      const frame = frames.get(current);
      const href = frame && whereIs(frame);
      if (!href) return;
      history.replaceState({ pykingSection: current }, "", href);
      try {
        const title = frame.contentDocument?.title;
        if (title) document.title = title;
      } catch {
        // a page from another origin keeps its title to itself
      }
    }

    // A section's frame, made and sent to `href` if there is none yet.
    // String -> String -> Iframe
    function frameFor(key, href) {
      let frame = frames.get(key);
      if (frame) return frame;
      frame = document.createElement("iframe");
      frame.dataset.section = key;
      frame.title = key === "home" ? "Pyking" : sections.find((s) => s.key === key)?.label ?? key;
      frame.pykingGoing = href;
      frame.addEventListener("load", () => arrived(frame));
      frame.src = href;
      box.append(frame);
      frames.set(key, frame);
      if (key !== current) hide(frame);
      return frame;
    }

    // A frame has a page: what it shows from now on is followed, and a
    // page that is another section's -- one a script went to -- makes
    // the frame that section's. Iframe -> ()
    function arrived(frame) {
      frame.pykingGoing = null;
      let page;
      try {
        page = frame.contentWindow;
        page.location.href;
      } catch {
        return;
      }
      const followIt = () => {
        frame.pykingGoing = null;
        if (frame.dataset.section === current) follow();
      };
      page.addEventListener("hashchange", followIt);
      page.addEventListener("popstate", followIt);
      for (const name of ["pushState", "replaceState"]) {
        const original = page.history[name];
        page.history[name] = function (...args) {
          const answer = original.apply(this, args);
          followIt();
          return answer;
        };
      }
      const key = sectionOf(page.location.href);
      if (key !== null && key !== frame.dataset.section) rekey(frame, key);
      if (frame.dataset.hidden !== undefined) tell(frame, true);
      followIt();
    }

    // A frame that went to another section's page becomes that
    // section's; a frame the section had is let go. Iframe -> String -> ()
    function rekey(frame, key) {
      const was = frame.dataset.section;
      const other = frames.get(key);
      if (other) {
        frames.delete(key);
        other.remove();
      }
      frames.delete(was);
      frames.set(key, frame);
      frame.dataset.section = key;
      if (current === was) current = key;
    }

    // Tells a frame's page whether it is out of sight. Iframe -> Bool -> ()
    function tell(frame, hidden) {
      try {
        const page = frame.contentWindow;
        page.dispatchEvent(new page.CustomEvent(EVENT, { detail: { hidden } }));
      } catch {
        // not a page of the site
      }
    }

    function hide(frame) {
      frame.dataset.hidden = "";
      frame.inert = true;
      tell(frame, true);
    }

    // Shows a section's frame, and hides the one that was shown. String -> ()
    function select(key) {
      if (key === current) return;
      const before = frames.get(current);
      current = key;
      if (before) hide(before);
      const frame = frames.get(key);
      delete frame.dataset.hidden;
      frame.inert = false;
      tell(frame, false);
      follow();
      try {
        frame.contentWindow.focus();
      } catch {
        // nothing to focus yet
      }
    }

    // A link to another section, from a section's page. A section's tab
    // shows the section as it was left; any other link shows that page
    // of it. Either is an entry of the shell's history.
    // String -> {tab: Bool} -> ()
    function open(href, { tab = false } = {}) {
      const key = sectionOf(href);
      if (key === null) {
        location.assign(href);
        return;
      }
      const frame = frames.get(key);
      if (!frame) {
        if (key !== current) history.pushState({ pykingSection: key }, "", href);
        frameFor(key, href);
        select(key);
        return;
      }
      if (!tab) {
        frame.pykingGoing = href;
        // Replaced, so that Back goes to the section the link was on
        // rather than to this section's page before.
        if (key === current) frame.contentWindow.location.assign(href);
        else frame.contentWindow.location.replace(href);
      }
      if (key !== current) {
        history.pushState({ pykingSection: key }, "", whereIs(frame) ?? href);
        select(key);
      }
    }

    // Back and Forward between sections. Event -> ()
    function back(event) {
      const key = event.state?.pykingSection ?? sectionOf(location.href);
      if (key === null || key === undefined) return;
      if (!frames.has(key)) frameFor(key, location.href);
      select(key);
    }

    function start() {
      box = document.createElement("div");
      box.id = "pyking-shell";
      document.body.append(box);
      const key = sectionOf(location.href);
      history.replaceState({ pykingSection: key }, "", location.href);
      current = key;
      frameFor(key, location.href);
      addEventListener("popstate", back);
    }

    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
    else start();

    // What a section's page and a test see of the shell.
    return {
      open,
      sectionOf,
      get current() {
        return current;
      },
      frame: (key) => frames.get(key) ?? null,
      get sections() {
        return [...frames.keys()];
      },
    };
  }

  // --- a section, in one of the shell's frames ---

  // `shell` is the shell's handle. Object -> ()
  function framed(shell) {
    root.classList.add("pyking-framed");

    // Whether a link is one of the header's: a section's tab, or the
    // logo, which is the start page's. Element -> Bool
    const isTab = (link) => link.closest(".pyking-nav, .site-title") !== null;

    // After the page's own listeners, so that one that takes a click
    // keeps it.
    addEventListener("click", (event) => {
      if (event.defaultPrevented || event.button !== 0
          || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.composedPath().find((node) => node instanceof Element
        && node.localName === "a" && node.hasAttribute("href"));
      if (!link || link.hasAttribute("download")) return;
      const target = link.getAttribute("target");
      if (target && target !== "_self") return;
      const url = new URL(link.href, location.href);
      if (url.origin !== location.origin) {
        // Another site replaces the whole window, as it would without
        // the shell, rather than only this frame.
        event.preventDefault();
        window.top.location.assign(url.href);
        return;
      }
      const key = sectionOf(url.href);
      if (key === null || key === sectionOf(location.href)) return;
      event.preventDefault();
      // A search's results, say, are not left open behind the section.
      for (const dialog of document.querySelectorAll("dialog[open]")) dialog.close();
      shell.open(url.href, { tab: isTab(link) });
    });

    // The theme the reader picks in one section is every section's:
    // Starlight stores it, and the other frames hear of it.
    addEventListener("storage", (event) => {
      if (event.key !== "starlight-theme") return;
      const theme = event.newValue || "auto";
      root.dataset.theme = theme !== "auto" ? theme
        : matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
      window.StarlightThemeProvider?.updatePickers?.(theme);
    });
  }
})();
