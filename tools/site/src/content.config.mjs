// The site's pages: the docs collection, the pages under the staging directory's
// content/, which site.py fills from sitesrc/ and from lib/ (see
// README.md). Starlight's own docsLoader reads src/content/docs/ only,
// so this is the same glob pointed at the staging directory. The i18n
// collection is Starlight's own, src/content/i18n/: its UI strings, which
// Starlight asks for on every page and warns about when there is none.
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { i18nLoader } from "@astrojs/starlight/loaders";
import { docsSchema, i18nSchema } from "@astrojs/starlight/schema";
import { STAGE } from "./stage.mjs";

export const collections = {
  docs: defineCollection({
    loader: glob({ base: STAGE + "/content", pattern: "**/[^_]*.{md,mdx}" }),
    schema: docsSchema(),
  }),
  i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
