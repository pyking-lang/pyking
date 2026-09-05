// The JavaScript implementation of the Pyking module declared in
// external_all_mod1.external.pyk. An ES module: `esm` imports it
// directly, and `nodejs` is emitted as ES modules when a program
// reaches one. An Int is a number held to 32 bits with `| 0`.

export function shout(s) {
  return s + "!";
}

export function twice(n) {
  return (n * 2) | 0;
}

export function flip(b) {
  return !b;
}

export const origin = 0;
export const greeting = "hello";
