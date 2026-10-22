// The help: the pages tools/help/help.py generated -- getting started,
// the language reference and the libraries -- with a menu above the page
// being read. The playground's Help tab mounts it, and so does the page
// `pyk pykhelp` serves (index.html beside this file).
//
//   import { mountHelp } from "./help/help.js";
//   const help = await mountHelp(element, { onCopy: (code) => ... });
//
// A page is Markdown, rendered by the notebook's own renderer: each
// ```pyking block is a cell that runs in the page, on one compiler worker
// shared by every page. A link to another help page opens it here.
//
// Data structures:
//   Help -- one mounted help: the index, the page shown, its cells.
//
// Functions:
//   mountHelp(host, options) -- mounts the help in host, answers a Help.

const HERE = new URL(".", import.meta.url);

const DEFAULTS = {
  pagesURL: new URL("pages/", HERE).href,       // share/help/, as served
  notebookURL: new URL("../notebook/", HERE).href,
  webrunURL: new URL("../webrun/", HERE).href,
  vendorURL: new URL("../vendor/", HERE).href,
  pykingURL: new URL("../pyking/", HERE).href,
  theme: "dark",           // "light" or "dark"
  start: null,             // the slug of the first page; default: the first
  onCopy: null,            // (code) -> (): adds "Copy to editor" to each cell
  onTheme: null,           // (theme) -> (): adds a light/dark switch to the menu
  fontSize: 13,
};

/** Mounts the help in `host` and shows its first page.
 *  Element -> {...} -> Promise<Help> */
export async function mountHelp(host, options = {}) {
  const help = new Help(host, { ...DEFAULTS, ...options });
  await help.init();
  return help;
}

class Help {
  constructor(host, cfg) {
    this.host = host;
    this.cfg = cfg;
    this.index = null;
    this.slug = null;
    this.cells = null;          // the notebook's Cells for the page shown
    this.runtime = null;        // one compiler worker for every page
    this.notebook = null;       // the notebook's module
  }

  async init() {
    const style = document.createElement("link");
    style.rel = "stylesheet";
    style.href = new URL("help.css", HERE).href;
    document.head.append(style);
    this.host.classList.add("pyk-help");
    this.host.innerHTML = `
      <nav class="pyk-help-menu" aria-label="Help pages"><div class="pyk-help-column">
        <div class="pyk-help-sections"></div>
        <div class="pyk-help-headings"></div>
      </div></nav>
      <article class="pyk-help-page pkn-notebook pkn-embedded">
        <div class="pyk-help-column"></div>
      </article>`;
    this.menu = this.host.querySelector(".pyk-help-menu");
    this.sections = this.host.querySelector(".pyk-help-sections");
    this.headings = this.host.querySelector(".pyk-help-headings");
    this.page = this.host.querySelector(".pyk-help-page");
    this.body = this.page.querySelector(".pyk-help-column");
    if (this.cfg.onTheme) {
      const button = document.createElement("button");
      button.className = "pyk-help-theme";
      button.addEventListener("click", () => {
        this.setTheme(this.theme === "dark" ? "light" : "dark");
        this.cfg.onTheme(this.theme);
      });
      this.menu.append(button);
      this.themeButton = button;
    }
    this.setTheme(this.cfg.theme);
    this.index = await (await fetch(this.cfg.pagesURL + "index.json")).json();
    this.pages = this.index.sections.flatMap((section) => section.pages
      .filter((page) => section.help.includes(page.slug))
      .map((page) => ({ ...page, section: section.label })));
    this.page.addEventListener("click", (event) => this.follow(event));
    this.menu.addEventListener("click", (event) => this.follow(event));
    await this.show(this.cfg.start ?? this.pages[0]?.slug);
  }

  /** The slug a link names, if it is a help page, and its anchor.
   *  String -> {slug, anchor}? */
  target(href) {
    if (!href) return null;
    if (href.startsWith("#")) return { slug: this.slug, anchor: href.slice(1) };
    const url = new URL(href, `https://help.invalid/${this.slug}/`);
    if (url.host !== "help.invalid") return null;
    const slug = url.pathname.replace(/^\/+|\/+$/g, "").replace(/\.md$/, "");
    return this.pages.some((page) => page.slug === slug)
      ? { slug, anchor: url.hash.slice(1) } : null;
  }

  /** A click on a link: a help page opens here, anything else in a new
   *  tab. MouseEvent -> () */
  follow(event) {
    const link = event.target.closest("a[href]");
    if (!link) return;
    const where = this.target(link.getAttribute("href"));
    event.preventDefault();
    if (!where) {
      window.open(link.href, "_blank", "noopener");
      return;
    }
    if (where.slug === this.slug) this.reveal(where.anchor);
    else this.show(where.slug, where.anchor);
  }

  /** Scrolls the page to a heading, or to its top. String? -> () */
  reveal(anchor) {
    const heading = anchor && this.page.querySelector(`[id="${CSS.escape(anchor)}"]`);
    if (heading) heading.scrollIntoView({ block: "start" });
    else this.page.scrollTop = 0;
  }

  /** Shows one page, by its slug: the menu marks it, and its cells run.
   *  String -> String? -> Promise<()> */
  async show(slug, anchor = null) {
    const page = this.pages.find((p) => p.slug === slug) ?? this.pages[0];
    if (!page) return;
    this.slug = page.slug;
    this.drawMenu();
    const text = await (await fetch(this.cfg.pagesURL + page.file)).text();
    const body = text.replace(/^---\n[\s\S]*?\n---\n/, "");
    this.body.innerHTML = `<h1 class="pyk-help-title"></h1>`
      + `<div class="pkn-fragment"></div>`;
    this.body.querySelector("h1").textContent = page.title;
    const fragment = this.body.querySelector(".pkn-fragment");
    fragment.dataset.markdown = body;
    this.notebook ??= await import(new URL("notebook.js", this.cfg.notebookURL).href);
    const web = await import(new URL("web.js", this.cfg.webrunURL).href);
    this.runtime ??= web.createRuntime({ webrun: this.cfg.webrunURL, pyking: this.cfg.pykingURL });
    // A cell still running on the page being left is stopped; stopping
    // restarts the worker, so only then.
    if (this.cells?.running) this.cells.stop();
    this.cells = await this.notebook.mountCells([fragment], {
      webrunURL: this.cfg.webrunURL,
      vendorURL: this.cfg.vendorURL,
      pykingURL: this.cfg.pykingURL,
      runtime: this.runtime,
      theme: this.theme,
      fontSize: this.cfg.fontSize,
      storageKey: `pyking-help#${page.slug}`,
      cellActions: this.cfg.onCopy ? [{
        label: "Copy to editor",
        title: "Put this example in the playground's editor",
        run: (code) => this.cfg.onCopy(code),
      }] : [],
    });
    this.reveal(anchor);
  }

  /** The menu: each section's pages on the left, the one shown marked,
   *  and that page's headings on the right. () -> () */
  drawMenu() {
    const groups = new Map();
    for (const page of this.pages) {
      if (!groups.has(page.section)) groups.set(page.section, []);
      groups.get(page.section).push(page);
    }
    const link = (href, text, current, sub = false) =>
      `<a href="${href}"${sub ? ' class="pyk-help-sub"' : ""}${current ? ' aria-current="page"' : ""}>${escape(text)}</a>`;
    const current = this.pages.find((p) => p.slug === this.slug);
    this.sections.innerHTML = [...groups].map(([label, pages]) => `
      <div class="pyk-help-group">
        <p class="pyk-help-label">${escape(label)}</p>
        ${pages.map((p) => link(`/${p.slug}/`, p.label, p.slug === this.slug, !!p.parent)).join("")}
      </div>`).join("");
    this.headings.innerHTML = current?.headings.length ? `
      <div class="pyk-help-group">
        <p class="pyk-help-label">On this page</p>
        ${current.headings.map((h) => link(`#${h.anchor}`, h.text, false)).join("")}
      </div>` : "";
  }

  /** Shows the help, and its cells, in "light" or "dark".
   *  String -> () */
  setTheme(theme) {
    this.theme = theme === "light" ? "light" : "dark";
    this.host.dataset.theme = this.theme;
    if (this.themeButton) {
      const other = this.theme === "dark" ? "light" : "dark";
      this.themeButton.textContent = other === "dark" ? "☾" : "☀";
      this.themeButton.title = `Switch to the ${other} theme`;
      this.themeButton.setAttribute("aria-label", this.themeButton.title);
    }
    this.cells?.setTheme?.(this.theme, false);
  }
}

function escape(text) {
  return String(text).replace(/[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}
