// Where site.py stages what the build reads: content/ (the pages),
// public/ (the static files and the runtime) and the Pyking grammar.
import { fileURLToPath } from "node:url";

export const STAGE = process.env.PYKING_SITE_STAGE
  ?? fileURLToPath(new URL("../build", import.meta.url));
