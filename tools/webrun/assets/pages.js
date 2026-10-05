// Where a program's page is shown, in a page that runs programs on a
// worker: the playground and the notebook. A library that needs a page
// (lib/<name>/<name>.page) sends it what to show as {type: "page",
// module, data} from the worker; a PageHost mounts that library's own
// renderer -- `mountPage`, exported by lib/<name>/<name>_external_browser.js
// -- in an element the page chose, hands it each batch, and sends back
// what the renderer reports. Nothing here knows any one library: see
// docs/libraries.md, "A library that needs a page".

export class PageHost {
  /** element: where the pages go. libURL: the standard library's URL.
   *  send(module, event): how a renderer's event reaches the program. */
  constructor(element, { libURL, send }) {
    this.element = element;
    this.libURL = libURL.endsWith("/") ? libURL : libURL + "/";
    this.send = send;
    this.pages = new Map();
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
      const url = `${this.libURL}${module}/${module}_external_browser.js`;
      this.pages.set(module, import(url)
        .then((library) => library.mountPage(
          this.element, (event) => this.send(module, event)))
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
  }
}
