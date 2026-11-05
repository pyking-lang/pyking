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
//
// A new build. `data-build` is the build the page is (site.py), and
// version.json, at the base, names the one the site serves now. The top
// window -- the shell, or a plain page of the site -- reads it again when
// it starts, when it is shown or focused, and every CHECK_EVERY; when it
// names another build, the window is reloaded onto it, silently, at the
// first moment that loses nothing: when the window is hidden, or when no
// page in it is busy and the reader has not typed, clicked or scrolled
// for IDLE. A page says it is busy, and keeps what it can, through
// `window.pykingUpdate` = {busy() -> Bool, save() -> ()}: the playground
// while a program runs, is debugged or a REPL session has defined names,
// cells while one runs. The shell keeps which page each section was at,
// and where it was scrolled, and opens them there again. `data-update`,
// "CHECK IDLE RETRY" in milliseconds, replaces the times, for tests.

(() => {
  "use strict";
  const script = document.currentScript;
  const base = (script?.dataset.base ?? "").replace(/\/$/, "");
  const sections = JSON.parse(script?.dataset.sections || "[]");
  const build = script?.dataset.build ?? null;
  const root = document.documentElement;
  const EVENT = "pyking:visibility";
  // How often version.json is read again, how long the reader must have
  // left the page alone before it is reloaded under them, and how often a
  // busy page is asked again, in milliseconds.
  const timing = (script?.dataset.update ?? "").split(/\s+/).map(Number);
  const [CHECK_EVERY, IDLE, RETRY] = [5 * 60000, 2 * 60000, 15000]
    .map((otherwise, k) => (timing[k] > 0 ? timing[k] : otherwise));
  // The build a reload was made for: one that came back as the build
  // before -- a cache not yet past it -- is not reloaded for again.
  const TRIED_KEY = "pyking-site.reloaded-for";
  // Where the shell keeps its sections across a reload onto a new build.
  const RESTORE_KEY = "pyking-shell.restore";

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
  if (new URLSearchParams(location.search).has("noshell") || sectionOf(location.href) === null) {
    // A plain page is a window of its own, and is reloaded onto a new
    // build as the shell is.
    const update = watchBuild(() => [window], () => {});
    if (update) addEventListener("load", () => update.check());
    return;
  }
  window.pykingShell = makeShell();

  // --- a new build ---

  // Watches version.json for a build other than this page's, and reloads
  // the window onto it when that loses nothing. `pages` answers the
  // windows whose pages may be busy; `keep` saves what the window itself
  // wants back. Answers {check, touched, pending}, or null where the page
  // names no build. (() -> [Window]) -> (() -> ()) -> Object?
  function watchBuild(pages, keep) {
    if (!build) return null;
    let lastInput = null;     // none since the page loaded: idle already
    let newer = null;         // the build version.json names, when not ours
    let retry = null;
    let checked = 0;
    let reloading = false;    // the page going away fires visibilitychange

    const touched = () => {
      lastInput = Date.now();
    };
    for (const type of ["keydown", "pointerdown", "wheel", "touchstart"]) {
      addEventListener(type, touched, { capture: true, passive: true });
    }

    async function check() {
      checked = Date.now();
      let named = null;
      try {
        const response = await fetch(base + "/version.json", { cache: "no-store" });
        if (response.ok) named = (await response.json()).build ?? null;
      } catch {
        return;     // offline, or the site is being replaced: ask again later
      }
      if (!named || named === build) return;
      try {
        if (sessionStorage.getItem(TRIED_KEY) === named) return;
      } catch {
        // no storage: try it
      }
      newer = named;
      settle();
    }

    const busy = () => pages().some((page) => {
      try {
        return !!page.pykingUpdate?.busy();
      } catch {
        return false;
      }
    });

    // Reloads now if nothing is lost by it, or asks again in RETRY.
    function settle() {
      clearTimeout(retry);
      retry = null;
      if (newer === null) return;
      const idle = lastInput === null || Date.now() - lastInput >= IDLE;
      if (document.visibilityState === "hidden" || (idle && !busy())) {
        reload();
        return;
      }
      retry = setTimeout(settle, RETRY);
    }

    function reload() {
      if (reloading) return;
      reloading = true;
      for (const page of pages()) {
        try {
          page.pykingUpdate?.save();
        } catch {
          // a page that cannot keep anything starts afresh
        }
      }
      keep();
      try {
        sessionStorage.setItem(TRIED_KEY, newer);
      } catch {
        // reloaded all the same
      }
      location.reload();
    }

    setInterval(check, CHECK_EVERY);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") settle();
      else check();
    });
    addEventListener("focus", () => {
      if (Date.now() - checked > 10000) check();
    });
    return {
      check,
      touched,
      get pending() {
        return newer;
      },
    };
  }

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
    // Where each section was before a reload onto a new build: key ->
    // {href, x, y}. A section is opened there again the first time it is.
    let restoring = {};
    try {
      restoring = JSON.parse(sessionStorage.getItem(RESTORE_KEY)) ?? {};
      sessionStorage.removeItem(RESTORE_KEY);
    } catch {
      restoring = {};
    }

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
      const kept = restoring[key];
      delete restoring[key];
      frame = document.createElement("iframe");
      if (kept && kept.href === href) frame.pykingScroll = kept;
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
      if (frame.pykingScroll) {
        page.scrollTo(frame.pykingScroll.x, frame.pykingScroll.y);
        frame.pykingScroll = null;
      }
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
        // A section's tab opens it where it was before a reload.
        if (tab && restoring[key]?.href) href = restoring[key].href;
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
      update?.check();
    }

    // Each section's page and scroll, for the shell reloaded onto a new
    // build to open them there again. () -> ()
    function keep() {
      const kept = {};
      for (const [key, frame] of frames) {
        try {
          const page = frame.contentWindow;
          kept[key] = { href: page.location.href, x: page.scrollX, y: page.scrollY };
        } catch {
          // not a page of the site: opened afresh
        }
      }
      try {
        sessionStorage.setItem(RESTORE_KEY, JSON.stringify(kept));
      } catch {
        // every section starts afresh
      }
    }

    const update = watchBuild(() => [...frames.values()].map((frame) => frame.contentWindow)
      .filter(Boolean), keep);

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
      // The reader did something in a section (`framed`). () -> ()
      touched: () => update?.touched(),
      // The build this page is, and the newer one waiting for a moment
      // to reload onto, if any; `checkBuild` reads version.json now.
      build,
      get newerBuild() {
        return update?.pending ?? null;
      },
      checkBuild: () => update?.check(),
    };
  }

  // --- a section, in one of the shell's frames ---

  // `shell` is the shell's handle. Object -> ()
  function framed(shell) {
    root.classList.add("pyking-framed");

    // Whether a link is one of the header's: a section's tab, or the
    // logo, which is the start page's. Element -> Bool
    const isTab = (link) => link.closest(".pyking-nav, .site-title") !== null;

    // What the reader does here counts as being in the window, which is
    // not reloaded onto a new build under them.
    for (const type of ["keydown", "pointerdown", "wheel", "touchstart"]) {
      addEventListener(type, () => shell.touched?.(), { capture: true, passive: true });
    }

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
