// The JavaScript implementation of the names declared in
// fs_external.pyk, for web24 and iweb24 -- the browser environment. A
// page has no filesystem, so each name says on the console that it is
// not supported and answers as a missing file would: nothing to read,
// nothing written, and nothing there.

function unsupported(name) {
  console.log(`fs.${name}: the filesystem is not supported in a browser`);
}

export function read_text(filename) {
  unsupported("read_text");
  return "";
}

export function write_text(filename, text) {
  unsupported("write_text");
}

export function exists(filename) {
  unsupported("exists");
  return false;
}
