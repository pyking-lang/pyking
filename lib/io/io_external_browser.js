// The JavaScript implementation of the names declared in
// io_external.pyk, for web24 and iweb24 -- the browser environment,
// where `print` writes through `write_line` below. A page has a console
// and nothing else: standard output goes to console.log a line at a
// time, and standard input is not supported, so each read says so on
// the console and answers as the end of the input would.
//
// console.log always ends a line, so `write` holds text back until a
// newline completes it; `flush` writes what is left, and the page calls
// it when the program stops. A page embedding the program -- the
// playground, a notebook -- supplies an implementation of its own
// instead of this one.

let partial = "";

export function write(text) {
  const lines = (partial + text).split("\n");
  partial = lines.pop();
  for (const line of lines) {
    console.log(line);
  }
}

export function write_line(text) {
  write(text + "\n");
}

export function flush() {
  if (partial !== "") {
    console.log(partial);
    partial = "";
  }
}

function unsupported(name) {
  console.log(`io.${name}: standard input is not supported in a browser`);
}

export function prompt_line(prompt) {
  write(prompt);
  flush();
  unsupported("read_line");
  return "";
}

export function read() {
  flush();
  unsupported("read");
  return "";
}

export function is_eof() {
  flush();
  unsupported("is_eof");
  return true;
}
