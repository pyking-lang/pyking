// A Pyking tuple is a JavaScript array. So is a list -- the two are
// told apart at run time by a marker the list carries, because the
// formatter walks values rather than reading types: an array with
// `pykList === true` prints as [a, b], and one without as (a, b).
// See docs/modules.md, "What may cross the boundary".

export function split(s) {
  return [s, s.length > 1];
}

export function counts(n) {
  const list = [n, n + 1];
  list.pykList = true;
  return list;
}
