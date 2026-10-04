// The JavaScript implementation of the Pyking module declared in
// external_float_mod1_external.pyk. A JavaScript number is already a
// double, so a Pyking Float and a Pyking Int are the same
// representation here -- which is why `widen` has nothing to do.

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
