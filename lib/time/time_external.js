// The JavaScript implementation of the names declared in
// time.external.pyk. One file serves node24, web24 and iweb24: a clock
// and a calendar are the parts of the host every JavaScript runtime
// has.
//
// Decomposition is UTC, so every `getUTC*` here is deliberate -- a
// `getMonth` would format differently per machine. JavaScript counts
// months from 0 and Pyking reports them as a reader writes them, which
// is the one field that is not a plain forward.
//
// A Pyking tuple is an array here, and unlike a list it carries no
// marker: the value formatter reads an unmarked array as a tuple
// (docs/modules.md, "What may cross the boundary").

function parts(t) {
  return new Date(t * 1000);
}

export function instant() {
  return Math.floor(Date.now() / 1000);
}

export function now() {
  const at = parts(Math.floor(Date.now() / 1000));
  return [
    at.getUTCFullYear(),
    at.getUTCMonth() + 1,
    at.getUTCDate(),
    at.getUTCHours(),
    at.getUTCMinutes(),
    at.getUTCSeconds(),
  ];
}

export function year_of(t) {
  return parts(t).getUTCFullYear();
}

export function month_of(t) {
  return parts(t).getUTCMonth() + 1;
}

export function day_of(t) {
  return parts(t).getUTCDate();
}

export function hour_of(t) {
  return parts(t).getUTCHours();
}

export function minute_of(t) {
  return parts(t).getUTCMinutes();
}

export function second_of(t) {
  return parts(t).getUTCSeconds();
}
