// What the page does with tinyweb's `sdelay`, against the page in
// dom.mjs with its clock moved by hand: when each one ends and is
// answered, that a sound after one starts exactly at its end, that what
// is drawn after one waits until then, and that a program that fell
// behind starts again from now. tests/test_tinyweb.py runs it; it
// prints what went wrong, one line each, and ends with status 1 if
// anything did.
//
// Usage: node sdelay.mjs <tinyweb_page.js copied as a .mjs file>

import { pathToFileURL } from "node:url";
import { install } from "./dom.mjs";

const page = install();
const { mountPage } = await import(pathToFileURL(process.argv[2]).href);

const answered = [];
const view = mountPage(document.body, (event) => {
  if (event.ev === "sdelay") answered.push({ id: event.id, t: event.t });
  // Each frame is answered at once, as a program with nothing to draw does.
  if (event.ev === "frame") view.receive([{ op: "frame_done" }]);
}, { activated: true });

const problems = [];
const expect = (what, ok) => { if (!ok) problems.push(what); };
const at = (seconds) => page.deliver(`frame ${seconds}`);
const tone = { op: "cmd", kind: "tone", id: "", text: "sine", numbers: "440 0 0.25 1 0 0", mode: 2 };
const dot = (x) => ({ op: "shape", c: "c", kind: "circle", numbers: `${x} 20 8`,
  color: "#ffa500", outline: "", width: 1, alpha: 1 });
const drawn = (x) => page.record.some((line) => line.includes(`arc(${x}, 20, 8`));
const played = (when) => page.record.some((line) => line === `audio: tone sine 440 at ${when}`);

view.receive([{ op: "canvas", id: "c", width: 200, height: 40 }, { op: "on_frame" }]);

// The first counts from now: it ends at 0.5, and is answered a little
// before, not long before.
view.receive([{ op: "sdelay", id: 1, seconds: 0.5 }]);
at(0.4);
expect("the first sdelay was answered at 0.4, before it was due", answered.length === 0);
at(0.46);
expect("the first sdelay was not answered at 0.46, just before its end at 0.5",
  answered.length === 1 && answered[0].id === 1);

// What the program does next: the tone starts exactly at the end, and
// the dot is drawn only once the end has come.
view.receive([tone, dot(10)]);
expect("a tone after the first sdelay did not start at its end, 0.500", played("0.500"));
expect("a dot drawn after the first sdelay was drawn before its end", !drawn(10));
at(0.5);
expect("a dot drawn after the first sdelay was not drawn at its end", drawn(10));

// The next counts from where the last ended, not from when it came:
// sent at 0.5 + a little, it ends at 1.0.
at(0.52);
view.receive([{ op: "sdelay", id: 2, seconds: 0.5 }]);
at(0.9);
expect("the second sdelay was answered before it was due", answered.length === 1);
at(0.96);
expect("the second sdelay was not answered just before its end at 1.0",
  answered.length === 2 && answered[1].id === 2);
view.receive([tone, dot(30)]);
expect("a tone after the second sdelay did not start at its end, 1.000", played("1.000"));
at(1.0);
expect("a dot drawn after the second sdelay was not drawn at its end", drawn(30));

// A program that fell behind: the third would end at 1.25, which has
// passed at 3.0, so it ends now and is answered at once.
at(3.0);
view.receive([{ op: "sdelay", id: 3, seconds: 0.25 }]);
expect("an sdelay whose end had passed was not answered at once",
  answered.length === 3 && answered[2].id === 3);
view.receive([tone, dot(50)]);
expect("a tone after a late sdelay did not start now, 3.000", played("3.000"));
expect("a dot drawn after a late sdelay was not drawn at once", drawn(50));

// And the next counts from then: 3.0 + 0.25.
view.receive([{ op: "sdelay", id: 4, seconds: 0.25 }]);
at(3.19);
expect("the sdelay after a late one was answered before it was due", answered.length === 3);
at(3.21);
expect("the sdelay after a late one was not answered just before 3.25", answered.length === 4);

view.freeze();
for (const problem of problems) console.log(problem);
process.exit(problems.length === 0 ? 0 : 1);
