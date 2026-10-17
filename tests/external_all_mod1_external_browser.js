// The implementation of external_all_mod1_external.pyk that the
// `web` and `iweb` targets use. It answers what the node one does:
// nothing in it needs node.

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
