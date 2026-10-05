// A Pyking function is a JavaScript function; `later` runs its callback
// once the program's own code has finished.

export function each(f, n) {
  for (let i = 0; i < n; i += 1) {
    f(i);
  }
}

export function with_float(f, x) {
  f(x * 2);
}

export function with_pair(f, n, s) {
  f(n + 1, s + "!");
}

export function later(f) {
  setTimeout(f, 0);
}
