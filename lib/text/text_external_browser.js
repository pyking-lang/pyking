// The JavaScript implementation of the names declared in
// text_external.pyk, for web and iweb. text_external_node.js beside
// it is the same code for node: a string is the same in every
// JavaScript runtime.
//
// A JavaScript string is UTF-16, so a character past the first 65536
// is two units there and one code point in Pyking: every position is
// converted from code points to units on the way in and back on the
// way out.

// The unit position of code point `k`, counting from unit `from`.
function units(s, from, k) {
  let i = from;
  while (k > 0 && i < s.length) {
    const c = s.charCodeAt(i);
    i += c >= 0xd800 && c <= 0xdbff && i + 1 < s.length ? 2 : 1;
    k -= 1;
  }
  return i;
}

// The number of code points in the units before `end`.
function points(s, end) {
  let n = 0;
  let i = 0;
  while (i < end) {
    const c = s.charCodeAt(i);
    i += c >= 0xd800 && c <= 0xdbff && i + 1 < s.length ? 2 : 1;
    n += 1;
  }
  return n;
}

export function host_length(s) { return points(s, s.length); }

export function host_slice(s, start, stop) {
  const i = units(s, 0, start);
  return s.slice(i, units(s, i, stop - start));
}

export function host_find(s, part, start) {
  const i = s.indexOf(part, units(s, 0, start));
  return i < 0 ? -1 : points(s, i);
}

export function host_code(s, k) { return s.codePointAt(units(s, 0, k)); }
export function host_from_code(n) { return String.fromCodePoint(n); }
export function host_replace(s, old, by) { return s.split(old).join(by); }
export function host_upper(s) { return s.replace(/[a-z]+/g, (w) => w.toUpperCase()); }
export function host_lower(s) { return s.replace(/[A-Z]+/g, (w) => w.toLowerCase()); }
