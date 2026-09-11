// The JavaScript implementation of the Pyking module declared in
// time_ext.external.pyk. One file serves node24, web24 and iweb24: a
// clock and a calendar are the parts of the host every JavaScript
// runtime has. Decomposition is UTC, so every `getUTC*` here is
// deliberate -- a `getMonth` would format differently per machine.

export function instant() {
  return Math.floor(Date.now() / 1000);
}

function parts(t) {
  return new Date(t * 1000);
}

export function year_of(t) {
  return parts(t).getUTCFullYear();
}

// JavaScript counts months from 0 and Pyking reports them as a reader
// writes them, so this is the one field that is not a plain forward.
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
