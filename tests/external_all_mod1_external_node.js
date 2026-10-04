// The JavaScript implementation of the Pyking module declared in
// external_all_mod1_external.pyk. An ES module: `esm` imports it
// directly, and `nodejs` is emitted as ES modules when a program
// reaches one. An Int is a number, and nothing here narrows a result:
// past the signed 32-bit range Pyking leaves the answer undefined.

export function shout(s) {
  return s + "!";
}

export function twice(n) {
  return n * 2;
}

export function flip(b) {
  return !b;
}

export const origin = 0;
export const greeting = "hello";
