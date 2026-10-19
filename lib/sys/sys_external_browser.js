// The JavaScript implementation of the names declared in
// sys_external.pyk, for web and iweb -- the browser environment. A
// page has no arguments, no environment and no program file, so each of
// those says on the console that it is not supported and answers as an
// empty one would. `exit` does work: it stops the program, and the page
// running it reports the status.
//
// A Pyking list is an array carrying the `pykList` marker
// (docs/modules.md, "What may cross the boundary").
function asList(items) {
  items.pykList = true;
  return items;
}

function unsupported(name) {
  console.log(`sys.${name}: not supported in a browser`);
}

export function args() {
  unsupported("args");
  return asList([]);
}

export function env() {
  unsupported("env");
  return asList([]);
}

export function prog_name() {
  unsupported("prog_name");
  return "";
}

export function prog_path() {
  unsupported("prog_path");
  return "";
}

// Stops the program by throwing: nothing in Pyking catches, so it
// unwinds to whatever started the program, which reads `pykExit` and
// writes out what `io.write` left unfinished.
export function exit(code) {
  const stop = new Error(`exit ${code}`);
  stop.pykExit = code;
  throw stop;
}
