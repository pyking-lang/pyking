// The Pyking website: Astro with Starlight. Built by `make website`, which
// runs site.py; that stages the pages and the runtime first, so this file
// is not run on its own. See README.md.
import fs from "node:fs";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import { unified } from "@astrojs/markdown-remark";
import remarkPykingCells from "./src/remark-pyking-cells.mjs";
import { SECTIONS } from "./src/sections.mjs";
import { STAGE } from "./src/stage.mjs";

const base = process.env.PYKING_SITE_BASE ?? "/";
const prefix = base.replace(/\/$/, "");
const grammar = JSON.parse(fs.readFileSync(STAGE + "/pyking.tmLanguage.json", "utf8"));

export default defineConfig({
  base,
  site: process.env.PYKING_SITE_URL,
  outDir: process.env.PYKING_SITE_OUT ?? "../../website",
  publicDir: STAGE + "/public",
  cacheDir: STAGE + "/cache",
  trailingSlash: "always",
  markdown: { processor: unified({ remarkPlugins: [remarkPykingCells] }) },
  integrations: [
    starlight({
      title: "Pyking",
      description: "A small, statically typed, Python-like language that compiles to Python, JavaScript, C, Java and OCaml.",
      favicon: "/site/favicon.svg",
      logo: { src: "./src/assets/logo.svg", alt: "Pyking" },
      customCss: ["./src/styles/site.css"],
      head: [{ tag: "script", attrs: { type: "module", src: prefix + "/site/cells.js" } }],
      // The header puts the sections beside the logo and the search on
      // the right; the left menu is each section's own pages, the one
      // shown opened at its headings (site.py writes sidebar.json). No
      // page has a table of contents on the right.
      components: {
        Header: "./src/components/Header.astro",
        Sidebar: "./src/components/Sidebar.astro",
      },
      tableOfContents: false,
      expressiveCode: { shiki: { langs: [grammar] } },
      sidebar: SECTIONS.map(({ label, path }) => ({ label, link: path })),
    }),
  ],
});
