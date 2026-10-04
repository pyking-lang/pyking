// The JavaScript implementation of the names declared in
// io_external.pyk, for node24. io_external_browser.js beside it is the
// browser's, which has no standard input.
//
// Standard input is read synchronously, a chunk at a time, into a byte
// buffer that a line is cut from -- node's own readers are all
// asynchronous, and a Pyking program waits for its answer. Bytes are
// decoded only once a whole line is in hand, so a character split
// across two chunks is decoded whole.
import { readSync } from "node:fs";

let pending = Buffer.alloc(0);
let ended = false;

// Reads one more chunk into `pending`, or marks the input ended. A
// descriptor with nothing ready yet answers EAGAIN, which means "ask
// again", not "the end".
function fill() {
  const chunk = Buffer.alloc(65536);
  for (;;) {
    try {
      const count = readSync(0, chunk, 0, chunk.length, null);
      if (count === 0) {
        ended = true;
      } else {
        pending = Buffer.concat([pending, chunk.subarray(0, count)]);
      }
      return;
    } catch (error) {
      if (error.code === "EAGAIN") {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      } else if (error.code === "EOF") {
        ended = true;
        return;
      } else {
        throw error;
      }
    }
  }
}

export function write(text) {
  process.stdout.write(text);
}

export function write_line(text) {
  process.stdout.write(text + "\n");
}

export function prompt_line(prompt) {
  process.stdout.write(prompt);
  for (;;) {
    const at = pending.indexOf(10);
    if (at >= 0) {
      let line = pending.subarray(0, at);
      pending = pending.subarray(at + 1);
      if (line.length > 0 && line[line.length - 1] === 13) {
        line = line.subarray(0, line.length - 1);
      }
      return line.toString("utf8");
    }
    if (ended) {
      const line = pending.toString("utf8");
      pending = Buffer.alloc(0);
      return line;
    }
    fill();
  }
}

export function read() {
  while (!ended) {
    fill();
  }
  const text = pending.toString("utf8");
  pending = Buffer.alloc(0);
  return text;
}

export function is_eof() {
  while (pending.length === 0 && !ended) {
    fill();
  }
  return pending.length === 0;
}
