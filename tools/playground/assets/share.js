// A program in a playground link: `<playground>#code=<text>`, where the
// text is the program's UTF-8 bytes in URL-safe base64 without padding.
// It is in the fragment, so a link opens the program without its code
// ever reaching a server. Needs nothing but TextEncoder and btoa, so the
// website's build (under node) writes the same links the page reads.
//
// Functions:
//   encodeSource(text) -- a program as the text of a link.
//   decodeSource(code) -- the program a link's text holds, or null.
//   sourceFromHash(hash) -- the program in a URL's fragment, or null.
//   linkTo(playground, text) -- a link opening the playground with a program.

const KEY = "code=";

/** A program as the text of a link. String -> String */
export function encodeSource(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The program a link's text holds, or null when it is not one.
 *  String -> String? */
export function decodeSource(code) {
  try {
    const base64 = code.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/** The program in a URL's fragment (`#code=...`, among other `&`-joined
 *  fields), or null when it holds none. String -> String? */
export function sourceFromHash(hash) {
  const field = (hash ?? "").replace(/^#/, "").split("&").find((f) => f.startsWith(KEY));
  return field === undefined ? null : decodeSource(field.slice(KEY.length));
}

/** A link opening the playground at `playground` with a program in its
 *  editor. String -> String -> String */
export function linkTo(playground, text) {
  return playground.replace(/#.*$/, "") + "#" + KEY + encodeSource(text);
}
