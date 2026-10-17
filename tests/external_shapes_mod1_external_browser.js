// The implementation of external_shapes_mod1_external.pyk that the
// `web` and `iweb` targets use. It answers what the node one does:
// nothing in it needs node.

export function split(s) {
  return [s, s.length > 1];
}

export function counts(n) {
  const list = [n, n + 1];
  list.pykList = true;
  return list;
}
