// The site's one collection: the pages under the staging directory's
// content/, which site.py fills from sitesrc/ and from lib/ (see
// README.md). Starlight's own docsLoader reads src/content/docs/ only,
// so this is the same glob pointed at the staging directory.
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { docsSchema } from "@astrojs/starlight/schema";
import { STAGE } from "./stage.mjs";

export const collections = {
  docs: defineCollection({
    loader: glob({ base: STAGE + "/content", pattern: "**/[^_]*.{md,mdx}" }),
    schema: docsSchema(),
  }),
};
