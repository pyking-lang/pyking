// Where a program's page is shown, in a page that runs programs on a
// worker: the playground and the notebook. A library that needs a page
// sends it what to show as {type: "page", module, data} from the
// worker; a PageHost mounts that library's own renderer -- `mountPage`,
// exported by lib/<name>/<name>_page.js -- in an element the page
// chose, hands it each batch, and sends back
// what the renderer reports. Nothing here knows any one library: see
// docs/libraries.md, "A library that needs a page".
//
// The page this runs in may be out of sight while its program goes on:
// the website keeps each of its sections open and shows one
// (tools/site/public/site/shell.js), and tells a section's window when it
// is hidden or shown again with a `pyking:visibility` event, whose
// `detail.hidden` says which. A host that is not silent hands that to
// each renderer's `setHidden`, which holds the page -- its clock, its
// frames, its sound -- until it is shown again.

/** The name of the event that says a page is hidden or shown again. */
export const VISIBILITY_EVENT = "pyking:visibility";

export class PageHost {
  /** element: where the pages go. libURL: the standard library's URL.
   *  send(module, event): how a renderer's event reaches the program.
   *  silent: the pages are only pictures, and play no sound. */
  constructor(element, { libURL, send, silent = false }) {
    this.element = element;
    this.silent = silent;
    this.libURL = libURL.endsWith("/") ? libURL : libURL + "/";
    this.send = send;
    this.pages = new Map();
    this.hidden = false;
    if (!silent) {
      this.onVisibility = (event) => this.setHidden(!!event.detail?.hidden);
      window.addEventListener(VISIBILITY_EVENT, this.onVisibility);
    }
  }

  /** Holds every page while it is out of sight, and lets each go on when
   *  it is shown again; a page mounted meanwhile starts held. Bool -> () */
  setHidden(hidden) {
    this.hidden = hidden;
    for (const page of this.pages.values()) page.then((p) => p?.setHidden?.(hidden));
  }

  /** Whether any library has shown anything here. () -> Bool */
  get used() {
    return this.pages.size > 0;
  }

  /** Carries out a batch of `module`'s commands, mounting its renderer
   *  first if this is the first. Batches are carried out in the order
   *  they arrive. String -> [Object] -> () */
  receive(module, data) {
    if (!this.pages.has(module)) {
      const url = `${this.libURL}${module}/${module}_page.js`;
      this.pages.set(module, import(url)
        // `activated`: the reader started the program with a click or
        // a key, so a page may play sound without asking for one.
        .then((library) => library.mountPage(
          this.element, (event) => this.send(module, event),
          { activated: true, silent: this.silent }))
        .then((page) => {
          if (this.hidden) page?.setHidden?.(true);
          return page;
        })
        .catch((error) => {
          console.error(`cannot show ${module}'s page: ${error.message}`);
          return null;
        }));
    }
    this.pages.get(module).then((page) => page?.receive(data));
  }

  /** Stops every page asking for events, and leaves what it shows.
   *  () -> () */
  freeze() {
    for (const page of this.pages.values()) page.then((p) => p?.freeze());
  }

  /** Removes every page. () -> () */
  close() {
    for (const page of this.pages.values()) page.then((p) => p?.close());
    this.pages.clear();
    if (this.onVisibility) window.removeEventListener(VISIBILITY_EVENT, this.onVisibility);
    this.onVisibility = null;
  }
}
