// The implementation of external_float_mod1_external.pyk that the
// `web` and `iweb` targets use. It answers what the node one does:
// nothing in it needs node.

export function halve(x) {
  return x / 2.0;
}

export function hypot_sq(a, b) {
  return a * a + b * b;
}

export function widen(n) {
  return n;
}

export const epsilon = 0.5;
