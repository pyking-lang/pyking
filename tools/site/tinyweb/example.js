// A canvas, two circles, two samples and buttons that play them, written
// in JavaScript against tinyweb.js, for node. Run it with
// `node example.js` and open the address it prints.

import * as tw from "./tinyweb.js";

tw.web_init(0);

const kick = tw.load_sample("kick1.wav");
const snare = tw.load_sample("snare1.wav");

const canvas = tw.canvas(400, 200);
tw.draw_shape(canvas, "circle", "100 50 30", "#ff0000", "", 1.0, 1.0);
tw.draw_shape(canvas, "circle", "100 50 20", "#000000", "", 1.0, 1.0);

let presses = 0;

tw.make_button("Play kick", () => tw.play_sample(kick, 0.0, 1.0, 1.0));
tw.make_button("Play snare", () => {
  presses += 1;
  console.log(`snare, press ${presses}`);
  tw.play_sample(snare, 0.0, 0.5, 1.0);
});
tw.make_button("Does nothing", () => {});
tw.splash();

console.log("built the page");
