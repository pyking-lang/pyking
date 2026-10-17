# Growing tinyweb

A plan for what tinyweb could offer next, in five steps, each usable on
its own, and two for later: sprites, and sessions with a storage
library. Nothing here is built. The aim is the one tinyweb started with:
an API a beginner can use from the first line, which still takes a
program all the way to every example in `web_examples/` -- the canvas,
animation, input, particles, physics, pixels, a complete game, samples,
sequencers, effects and the six ways of keeping music and pictures in
step -- and to the small web applications and games people write after
those.

Where this plan and the code disagree once work starts, the code is
right and this file is stale.

## What tinyweb has today

| Area | Functions |
|---|---|
| Page | `web_init`, `theme`, `page_style` |
| Canvas | `canvas`, `clear`, `circle`, `rect`, `line`, `text`, `canvas_style` |
| Widgets | `button`, `label`, `set_label`, `slider`, `button_style`, `label_style`, `slider_style`, `set_style`, `set_colors` |
| Sound | `load_sample`, `play`, `play_file`, `time` |
| Events | `on_frame`, `on_mouse` (a click on a canvas), `on_key` (a key pressed) |

## Rules every addition keeps

These are what make tinyweb both simple and portable, and each step
below is held to them.

1. **Every function works on every target**: the interpreter, the
   playground, the notebook, web24, iweb24, and every compiled target
   that serves its page. A function some target cannot offer is not
   added.
2. **A function sends commands, and the page answers with events.**
   Nothing asks the page a question and waits: on a native target the
   page is in another process, reached over HTTP. Whatever a program
   wants to *read* -- where the mouse is, which keys are held, how loud
   the music is -- the page reports by event, and tinyweb keeps the
   last report, exactly as `time()` already does. Such a function
   answers "as of the last event", and its documentation says so.
3. **Only `Int`, `Float`, `String`, `Bool` and a callback cross into
   the host.** C and Java carry no list or tuple across the boundary, so
   a function taking a list -- a polygon's points, a dropdown's choices
   -- is written in `tinyweb.pyk`, which turns it into calls of a
   primitive or into one string. A callback is one of the shapes C and
   Java can carry; a new shape is a new typedef in `target_c.ml` and a
   new interface in `target_java.ml`, and is called out where a step
   needs one.
4. **Everything is named by a `String`.** A canvas, a button, a sample,
   a sound that is playing, a bitmap, a timer: each is the identifier its
   function answered, and that identifier is what changes, moves, stops
   or removes it. It is the thing's own text where it has one -- a
   button's title, a label's text, a file's name -- and otherwise its
   kind (`"canvas"`, `"voice"`, `"timer"`), with the first number from 1
   added where the page has that name already (`"canvas1"`). The same
   string is in the commands, on the page and in the log.
5. **Defaults for everything but the essentials.** `tw.circle(c, x, y,
   r)` draws; the color, the outline and the transparency are named
   arguments with defaults. Named arguments are written in parameter
   order, so each function lists the parameters a beginner reaches for
   first.
6. **Colors are CSS strings.** Helpers that build them (`rgb`, `hsl`)
   are Pyking functions answering a string, with no command behind them.
7. **One renderer.** A command is carried out by `tinyweb_page.js` and,
   for web24, by `tinyweb_external_browser.js`. Where a feature is more
   than a few lines, it goes in a block of the page script that
   `embed_page.py` copies into the web24 file, as the style block is.
8. **Tested as everything else is**: a `lib_tinyweb_*` case per step,
   with its `.events` and `.page`, on every target, and the web24 and
   command pages compared under node and in Chromium. Every public
   function gets a runnable example in its `##` block.

## Decisions

| | Decision |
|---|---|
| 1 | `math` and `random` are libraries of their own, not part of tinyweb |
| 2 | Angles are in degrees by default; `math` converts to and from radians |
| 3 | `play` stays as it is; a new `start` answers a voice that can be stopped and faded (step 3) |
| 4 | Drawing everything again each frame is the model; sprites are step 6, near the end, with their pros and cons below, and are built without measuring first |
| 5 | Saving data is not tinyweb's: a storage library of its own, in the last phase (step 7) |
| 6 | Sessions are opt-in: a program without `on_session` has today's one shared page. They come in the last phase, with storage |
| 7 | `fetch_text` is in (step 5) |
| 8 | Sound (step 3) comes before games (step 4) |
| 9 | Pyking gains hexadecimal and binary integer literals, with `_` allowed between digits for readability, before step 5 |

## What tinyweb needs from outside it

Two libraries most of the examples need, which belong beside tinyweb
rather than inside it, since programs without a page need them too:

- **`math`**: `sin`, `cos`, `tan`, `atan2`, `sqrt`, `pow`, `abs`,
  `floor`, `ceil`, `round`, `min`, `max`, `clamp`, `pi`. Rotation,
  orbits, a clock face, physics, noise and every wave need these.
- **`random`**: `random()` (a Float in [0, 1)), `randint(low, high)`,
  `choice(list)`, `shuffle(list)`, and `seed(n)` for art that comes out
  the same each time.

Both are small external modules, one implementation per host, written
before step 1 or with it. They are not counted among the five steps.

**Hexadecimal and binary literals**, a language change rather than a
library one, needed before step 5 so a pixel's color can be written
`0xff8800`:

- `0xff8800`, `0XFF8800`: hexadecimal, either case for `x` and the digits.
- `0b0001_0101`, `0B101`: binary.
- `_` may stand between two digits of either, for readability only:
  `0b0001_0101` is `0b00010101` is 21. Not first, not last, not two in a
  row, and not right after `0x` or `0b`.
- Both are `Int` literals, held to `lexer.max_int_literal` like a
  decimal one, so the native and browser builds accept the same
  programs.

It follows CLAUDE.md's five places: the lexer (`TokInt` as today, read
from the new spellings), PYKING.md's literal section and grammar, tests
(`int_literals_hex_binary` with its `.out`, and `fail_*` cases for a
misplaced `_` and a literal past the bound), `docs/` (nothing for any
backend, since every literal reaches them as an ordinary `Int`), and
the Emacs mode's number highlighting. Whether a decimal literal may use
`_` too (`1_000_000`) is an open question below.

**Saving data** -- a high score, a to-do list, a user's settings -- is
not tinyweb's either. A program on a native target has `fs` already. A
storage library with one meaning everywhere -- a file beside the
program natively, the browser's own storage on a page -- is the last
phase, step 7, together with tinyweb's sessions, which give it a key to
save a viewer's data under.

## The five steps

| Step | Theme | Reaches |
|---|---|---|
| 1 | Drawing | graphics1, 2, 3, 4, 5, 11 |
| 2 | Input, time and widgets | graphics6, 7; forms, quizzes, tools |
| 3 | Sound and music | sound1-5, graphicsmusic1-6 |
| 4 | Games, drawn every frame | graphics8, 9, 12; arcade and puzzle games |
| 5 | Bitmaps, layout and web applications | graphics10, 11; dashboards, editors, data apps |
| 6 (later) | Sprites | the same games, cheaper on native targets |
| 7 (last) | Sessions, and a storage library | chat, classroom quizzes, two-player games, saved progress |

The order is the order a learner meets the ideas in `web_examples/`, and
each step ends with some of those examples rewritten in Pyking as
programs in `src/examples.toml`, so the playground offers them.

---

## Step 1: Drawing

Everything `web_examples/graphics1` to `graphics5` draws, and the
static half of `graphics11`.

**Shapes**, each with an outline as well as a fill:

| Function | What it does |
|---|---|
| `ellipse(c, x, y, rx, ry, color, outline, width)` | an ellipse; `circle` stays the simple case |
| `arc(c, x, y, r, start, end, color, outline, width)` | a slice of a circle, angles in degrees |
| `polygon(c, points, color, outline, width)` | a closed shape through `[(x, y), ...]`; a star is a polygon |
| `path(c, points, color, width)` | an open line through the points |
| `curve(c, x1, y1, cx, cy, x2, y2, color, width)` | a quadratic Bézier curve |
| `rect(..., radius)` | the existing `rect` gains rounded corners |

Every filled shape gains `outline: String = ""` and `width: Int = 1`
(no outline by default) and `alpha: Float = 1.0`. `color = ""` with an
outline draws only the outline.

**Text**: `text(..., font, align, bold)`, with `align` one of `"left"`,
`"center"` and `"right"`. Measuring text needs the page, so it is not
offered here; centring is what `align` is for.

**Transformations**, as `graphics5` teaches them:

| Function | What it does |
|---|---|
| `translate(c, x, y)` | moves the origin |
| `rotate(c, degrees)` | turns everything drawn after it |
| `scale(c, sx, sy)` | stretches it |
| `push(c)` / `pop(c)` | saves and restores the transformation and the alpha |
| `reset(c)` | back to no transformation |

**Images**: `load_image(name) -> String`, found as samples are (beside the
page, then in `tinyweb_assets/`), and `image(c, picture, x, y, width,
height)`. A program draws one before it has loaded and nothing appears;
the next frame draws it. tinyweb ships a few small CC0 images, as it
ships samples.

**Colors**, Pyking functions with no command: `rgb(r, g, b)`,
`rgba(r, g, b, a)`, `hsl(h, s, l)`, and a few named palettes as lists of
strings for generative art.

**Shadows and blending**: `shadow(c, color, blur, dx, dy)` and
`blend(c, mode)` with `"normal"` and `"add"` (additive light, for the
particles of step 4 and the glow of `graphicsmusic`).

Implementation: one command per call. A polygon's points cross as one
string, `"x,y x,y ..."`, built by the Pyking half. Degrees rather than
radians, since a beginner thinks in degrees, and `math` offers both.

Tests: `lib_tinyweb_shapes`, `lib_tinyweb_transform`, `lib_tinyweb_image`.

Examples ported: graphics1 (hello canvas), graphics2 (stars, curves),
graphics4 (a bouncing ball), graphics5 (solar system, analog clock).

---

## Step 2: Input, time and widgets

What `graphics6` and `graphics7` need, and what a quiz, a form or a
small tool needs.

**The mouse**, on a canvas, beside today's `on_mouse` (a click):

| Function | What it does |
|---|---|
| `on_press(c, f(x, y))` | the button goes down |
| `on_release(c, f(x, y))` | the button comes up |
| `on_move(c, f(x, y))` | the pointer moves over the canvas, at most once a frame |
| `on_drag(c, f(x, y))` | it moves with the button held |
| `mouse_x(c)`, `mouse_y(c)`, `mouse_down(c)` | the last reported position and state |

The pointer events cover a mouse, a pen and a finger, so a phone works
too.

**The keyboard**: `on_key_up(f(key))` beside `on_key`, and
`key_down(key) -> Bool`, the held-key state `graphics7` is built on,
kept by tinyweb from both events. Arrow keys and the space bar stop
scrolling the page while it has the focus.

**Time**:

| Function | What it does |
|---|---|
| `after(seconds, f) -> String` | calls `f` once, `seconds` from now on the page's clock |
| `every(seconds, f) -> String` | calls `f` again and again |
| `cancel(timer)` | stops either |

`on_frame` stays the way to animate; these are for "in three seconds"
and "once a second".

**More widgets**, each named by an `Int` like the ones there are:

| Function | What it does |
|---|---|
| `text_input(placeholder, on_enter) -> String` | a line of text; `on_enter(text)` when Enter is pressed |
| `checkbox(title, checked, on_change) -> String` | `on_change(checked)` |
| `choice(options, chosen, on_change) -> String` | a dropdown over a list of strings; `on_change(index)` |
| `number_input(low, high, value, on_change) -> String` | a number field |

**Changing what is on the page**:

| Function | What it does |
|---|---|
| `set_text(id, text)` | the text of a label, a button or an input; `set_label` stays |
| `set_value(id, value)` | where a slider, checkbox or choice stands |
| `show(id)`, `hide(id)` | without removing it |
| `enable(id)`, `disable(id)` | a button that cannot be pressed yet |
| `remove(id)` | gone for good |
| `value_of(id)` | what an input holds, as last reported |

Implementation: the held-key and mouse state are kept in each
implementation from events, as `time` is. A timer runs on the page,
which reports `{ev: "timer", id}`, so it keeps the page's clock and
works the same on every target. `on_enter` needs a `(String) -> ()`
callback and `checkbox` a `(Bool) -> ()`; the first is `on_key`'s
shape, and the second is a new one for C and Java.

Tests: `lib_tinyweb_pointer`, `lib_tinyweb_keys_held`,
`lib_tinyweb_timers`, `lib_tinyweb_widgets`.

Examples ported: graphics6 (a paint program, drag and drop), graphics7
(a ship steered with held keys), a multiplication quiz, a unit
converter.

---

## Step 3: Sound and music

`sound1` to `sound5` and the six synchronisation strategies of
`graphicsmusic1` to `graphicsmusic6`. tinyweb already has the hard part
-- one clock, and `play(at = t)` on it -- so this step is about what is
played and how it is scheduled.

**Two ways to make a sound: `play` and `start`.** Most sounds are
*fired and forgotten*: a drum hit, a click, a note of a melody. It
plays to its end, and the program never needs to talk about it again.
That is `play`, which stays exactly as it is, answering `()`, and only
gains `pan`:

| Function | What it does |
|---|---|
| `play(sample, at, volume, rate, pan)` | plays the sample once, to its end; `pan` from -1.0 (left) to 1.0 (right) |

Some sounds have to be *controlled* while they play: background music
that loops until the level ends, an engine that hums while a key is
held, a note held as long as a piano key is down, music that fades out
on "game over". Such a sound is a **voice**: one playing of a sample,
named by a `String`, the way a button is. `start` begins one and answers
its identifier, and that identifier is what stops or fades it:

| Function | What it does |
|---|---|
| `start(sample, at, volume, rate, pan, loop) -> String` | starts the sample and answers the voice; with `loop = true` it plays again and again until stopped |
| `stop(voice, at)` | stops it, now or at a time on the clock |
| `fade(voice, volume, over)` | changes its volume smoothly, over `over` seconds; a fade to 0.0 and then a stop is a fade-out |
| `master_volume(volume)` | everything at once |

```
music = tw.start(song, loop = true, volume = 0.6)
...
def game_over():
    tw.fade(music, 0.0, over = 2.0)
    tw.stop(music, at = tw.time() + 2.0)
```

So a beginner meets `play` first and never needs a voice; `start` is
the second thing to learn, for the sounds that need it. Keeping them
apart also keeps every existing program's types as they are.

**Tones without a sample**: `tone(frequency, at, duration, wave, volume)`,
fired and forgotten like `play`, with `wave` one of `"sine"`, `"square"`, `"triangle"` and
`"sawtooth"`, and a short attack and release so it does not click.
`note(name) -> Float` gives a frequency from a name (`"A4"`, `"C#3"`),
and `rate_of(name, base)` the `rate` that plays a sample at that pitch,
which is `sound4`'s melodies from one sample.

**A beat, scheduled ahead**: the lookahead scheduler `sound3` explains
(the "two clocks"), built into the page so a beginner never writes it:

| Function | What it does |
|---|---|
| `tempo(bpm)` | the beats per minute; 120 by default |
| `on_beat(f(beat, t), steps)` | calls `f` a little ahead of each step with its number and its exact time on the clock, `steps` to a beat (4 is sixteenths) |
| `beat()` | which beat the clock is on now, as a Float, for drawing |
| `swing(amount)` | delays every other step |

A step sequencer is then a list of booleans and an `on_beat` that plays
`at = t`. A frame that draws from `beat()` is `graphicsmusic2`, and a
note's time kept in a list until the frame reaches it is
`graphicsmusic3`, with no new function.

**Mixing and effects**, by channel, as `sound5` mixes:

| Function | What it does |
|---|---|
| `play(..., channel)`, `start(..., channel)`, `tone(..., channel)` | which channel a sound goes through; 0 by default |
| `channel_style(channel, volume, pan, echo, reverb, low_pass)` | each one 0.0 (off) to 1.0, or a frequency for `low_pass` |

**Listening**, for `graphicsmusic4`: `level() -> Float` (how loud, 0.0
to 1.0) and `band(n, of) -> Float` (one of `of` frequency bands), each as
of the last frame, which the page reports with the frame.

Implementation: the scheduler runs on the page, so its timing does not
depend on how far away the program is. On a native target `on_beat`'s
callbacks arrive late in wall time but carry the right `t`, and `play(at
= t)` lands on time, which is the whole point of the design. `on_beat`
needs an `(Int, Float) -> ()` callback, new for C and Java.

Tests: `lib_tinyweb_voices` (`start`, `stop`, `fade`), `lib_tinyweb_tone`, `lib_tinyweb_beat`,
`lib_tinyweb_mixer`. A test cannot hear, so the `.page` file holds what
was scheduled and when, as `play` lines do today.

Examples ported: sound3 (a step sequencer), sound4 (an on-screen piano,
an arpeggiator), graphicsmusic1, 2, 3 and 4.

---

## Step 4: Games, drawn every frame

`graphics8` (particles), `graphics9` (physics) and `graphics12`
(Breakout), and the games beyond them: Snake, Pong, Asteroids, Flappy
Bird, memory, Tetris. A game here does what the examples do: it keeps
its world in its own variables and draws all of it again each frame.

**Collisions**, as pure Pyking functions with no command behind them:

| Function | What it does |
|---|---|
| `rects_overlap(x1, y1, w1, h1, x2, y2, w2, h2) -> Bool` | two rectangles touch |
| `circles_overlap(x1, y1, r1, x2, y2, r2) -> Bool` | two circles touch |
| `circle_rect_overlap(cx, cy, r, x, y, w, h) -> Bool` | a ball and a brick |
| `inside_rect(px, py, x, y, w, h) -> Bool` | a click on a button drawn on the canvas |

**Particles**: `burst(c, x, y, count, color, speed, life)`, an emitter
the page runs entirely, for the fireworks of `graphics8` without a
command per spark. It is fire-and-forget, like `play`: nothing about it
is kept to change later, so it does not bring in sprites.

**A game's frame**:

| Function | What it does |
|---|---|
| `on_frame(draw)` | unchanged; `draw(t)` |
| `fixed_step(update, rate)` | calls `update(dt)` `rate` times a second of clock, however frames fall, for `graphics9`'s stable physics |
| `pause()`, `resume()`, `paused()` | stops frames and timers, and pauses the sound |
| `on_blur(f)`, `on_focus(f)` | the page lost or got the keyboard, so a game can pause itself |

**The screen**: `canvas(..., fit)` with `fit = true` filling the space
it is in and keeping its proportions; `fullscreen()`; `cursor(c, name)`
including `"none"`.

**What drawing every frame costs.** Every shape is a command, and on a
native target the commands of a frame travel to the page over HTTP. A
frame of Breakout is a few hundred small commands, which is well within
what a local connection carries at 60 frames a second; the page already
asks for the next frame only once the last one's commands have arrived,
so a slow program drops frames rather than falling behind. Two things in
this plan keep the cost down without changing the model: `burst` for
many short-lived dots, and the bitmaps of step 5 for a dense picture.
Step 6 is the answer if that is not enough.

Tests: `lib_tinyweb_collide`, `lib_tinyweb_burst`,
`lib_tinyweb_fixed_step`, `lib_tinyweb_pause`.

Examples ported: graphics8 (fireworks), graphics9 (balls with gravity),
graphics12 (Breakout), graphicsmusic5 (physics that plays music), and
two new games, Snake and Pong.

---

## Step 5: Bitmaps, layout and web applications

`graphics10` and the rest of `graphics11`, and what turns tinyweb from
a canvas library into a way to write small web applications.

**Bitmaps: a picture the program builds, sent in one go.** Sending a
picture pixel by pixel would be one command per pixel -- 64 000 for a
small 320 by 200 picture -- which no target could keep up with. A
bitmap is instead a block of pixels the *program* owns: setting a pixel
changes the program's own memory and sends nothing, and the whole
bitmap goes to the page in one command when the program says so.

| Function | What it does |
|---|---|
| `bitmap(width, height) -> String` | a new bitmap, all black, kept by the program |
| `set_pixel(b, x, y, color)` | one pixel; sends nothing |
| `get_pixel(b, x, y) -> Int` | what a pixel holds, answered at once, since the program owns it |
| `fill_bitmap(b, color)` | every pixel |
| `show_bitmap(c, b, x, y, scale)` | draws the bitmap on the canvas, in one command; `scale` makes each pixel a sharp square, for pixel art and for a small bitmap filling a big canvas |
| `pixel_color(r, g, b) -> Int` | a pixel's color from red, green and blue, 0 to 255 |
| `red(color)`, `green(color)`, `blue(color)` | the parts of one, for filters |

A pixel's color is an `Int`, written in hexadecimal as `0xff8800`
(orange) with the literals this plan adds to the language, rather than
a CSS string, since a string per pixel would be slower to make and to
read, and an `Int` crosses into every host. `pixel_color` builds one
from numbers a program computed, and it and the three parts are plain
Pyking arithmetic.

Fire from `graphics10`:

```
b = tw.bitmap(160, 100)
def draw(t: Float):
    ... set_pixel for each pixel, from the row below it ...
    tw.show_bitmap(c, b, 0, 0, scale = 4)
tw.on_frame(draw)
```

How each host keeps a bitmap, so that `set_pixel` is a store in memory:

| Host | The bitmap | `show_bitmap` |
|---|---|---|
| web24 | an `ImageData` on the page itself | `putImageData`; nothing is copied |
| the playground, the notebook, iweb24 | a byte array in the worker running the program | the bytes posted to the page in one message, without copying |
| Python, node, OCaml, C, Java, the interpreter | a byte array in the program | the bytes as one base64 string in one command |

Only what changed is sent: each bitmap remembers the rectangle that
changed since it was last shown, and `show_bitmap` sends that rectangle,
or nothing. A 320 by 200 bitmap changing completely is 256 KB, about
340 KB in base64; over a local connection that is comfortably 30 frames
a second. On web24 and the playground the limit is how fast the program
can compute its pixels, and under the interpreter that is the real
limit: 64 000 calls of `set_pixel` a frame is a lot for any interpreter.
The documentation says so, and suggests a small bitmap with a `scale`.

Beside bitmaps, for what is not a picture computed pixel by pixel:

| Function | What it does |
|---|---|
| `grid(c, cols, rows, cell, colors)` | a grid of square cells from a list of CSS colors, for Life, a maze, a board game |
| `filter(c, name)` | `"grayscale"`, `"blur"`, `"invert"`, `"sepia"` on what is drawn |
| `gradient(c, x1, y1, x2, y2, from, to) -> String` | a color that is a gradient, usable wherever a color is |

**Layout**, which the styling step left out:

| Function | What it does |
|---|---|
| `row() -> String` | a box whose elements go side by side |
| `column() -> String` | a box whose elements go one below another |
| `panel(title) -> String` | a column with a frame and a heading |
| `inside(box)` | elements made after this go into the box |
| `outside()` | back to the page |
| `box_style(box, ...)` | like `set_style`, for a box |

`inside`/`outside` rather than a `parent =` argument on every function
keeps every existing call as it is.

**Showing data**:

| Function | What it does |
|---|---|
| `table(headings, rows) -> String` | a table from lists of strings, `set_rows` to change it |
| `list_view(items, on_pick) -> String` | a list a reader picks from |
| `text_area(text, on_change) -> String` | several lines of text to edit |
| `markdown(text) -> String` | a label that renders headings, bold, lists and links |
| `link(title, url)` | a link that opens in a new tab |
| `progress(value, high) -> String` | a progress bar |
| `chart(kind, values, labels) -> String` | `"bar"`, `"line"` or `"pie"`, for a dashboard |

**The world outside the page**:

| Function | What it does |
|---|---|
| `fetch_text(url, on_answer)` | `on_answer(text)` when it arrives, or `""` with a message |
| `download(name, text)` | offers the reader a file |
| `upload(on_file)` | asks the reader for a file and hands over its text |
| `clipboard(text)` | copies text |
| `title(text)` | the page's title in the browser tab |

`fetch_text` is made from the page on every target, so a browser's
rules about other sites apply everywhere alike and a native program
behaves as a web page does.

Tests: `lib_tinyweb_bitmap` (the log holds a digest of each bitmap
shown, rather than its bytes), `lib_tinyweb_layout`, `lib_tinyweb_table`,
and a `fetch_text` case served from the test's own directory.

Examples ported: graphics10 (fire, plasma, an image filter), graphics11
(a Mandelbrot explorer, a fractal tree), and three applications: a
to-do list, a quiz built from a file, and a dashboard reading a CSV.

---

## Step 6 (later): Sprites

Steps 1 to 5 keep tinyweb's one model: the program owns everything it
shows, and draws it again each frame. Sprites are the other model, and
are left for later so the first one is learned well before a second
arrives.

A sprite is a shape or picture the *page* remembers. The program makes
it once and then only says what changes:

| Function | What it does |
|---|---|
| `sprite_circle(c, x, y, r, color) -> String` | a circle the page keeps drawing |
| `sprite_rect(c, x, y, w, h, color) -> String` | a rectangle |
| `sprite_image(c, picture, x, y, w, h) -> String` | a picture |
| `sprite_text(c, x, y, words, color, size) -> String` | text, such as a score |
| `move(s, x, y)`, `turn(s, degrees)` | where it is, which way it faces |
| `glide(s, x, y, seconds)` | moves it there smoothly, on the page |
| `velocity(s, vx, vy)` | keeps it moving with no command a frame |
| `on_click_sprite(s, f)` | a click on the sprite itself |
| `touching(a, b) -> Bool`, `on_touch(a, b, f)` | two sprites meet |
| `remove(s)` | gone |

A canvas with sprites draws them after whatever `on_frame` drew: a
background drawn each frame, sprites on top.

**For sprites:**

- **Far fewer commands.** Breakout's two hundred bricks are made once;
  a frame then moves a ball and a paddle, two small commands instead of
  two hundred. On a native target that is the difference that matters.
- **Smooth motion from a slow program.** `glide` and `velocity` are
  animated by the page, so a sprite moves at 60 frames a second even
  when the program answers ten times a second, as a native program on a
  busy machine may.
- **Objects, as a beginner thinks of them.** "The ball", "the paddle",
  each with a name, is how Scratch works, and clicking a sprite is
  easier than working out what was under the mouse.

**Against sprites:**

- **Two models to learn, and how they mix.** `clear` wipes what was
  drawn but not the sprites; the order things appear in depends on which
  model drew them. Every beginner meets that question.
- **State in two places.** A sprite with a `velocity` is somewhere only
  the page knows, so its position has to be reported back by event, and
  the program sees it a frame late. A game that checks collisions in its
  own code against positions the page moved is easy to get subtly wrong.
- **A program computed from the clock does not want them.** The timeline
  demos of `graphicsmusic6`, and anything seekable, are simplest as "draw
  the world at time `t`", which is drawing every frame.
- **More renderer, in two places.** A sprite list, hit testing and
  motion on the page are code in `tinyweb_page.js` and the web24 file
  alike, and motion that depends on frames is harder to test exactly
  than a log of commands.

It is built as planned, without first measuring whether native targets
need it: clickable objects and page-side motion are reasons of their
own.

---

## Step 7 (last): Sessions, and a storage library

The last phase is the two things that let a tinyweb program serve more
than one person and remember them: sessions, in tinyweb, and a storage
library beside it.

### Sessions

**Today there is one session.** A native program -- or `pyk program.pyk`
-- serves one page. Every browser tab that opens its address sees the
same page: the commands go to all of them, a tab that connects late is
sent everything so far, and an event from any tab reaches the one
program. In the playground, the notebook, web24 and iweb24 there is only
ever one viewer.

**A session would be one viewer's page.** With sessions, each tab that
opens the address gets a page of its own, built by the program for that
viewer, and the program can tell which viewer an event came from. That
is what a web server does for each user, and it opens up programs
tinyweb cannot write today: a chat room, a quiz where a teacher's page
shows every student's answer, a two-player game played from two tabs or
two computers, a page per player with a shared scoreboard.

**The functions**, opt-in -- decided -- so a program without
`on_session` is exactly today's one shared page:

| Function | What it does |
|---|---|
| `on_session(start)` | calls `start(s)` for each new viewer; what `start` builds is that viewer's page alone |
| `session() -> Int` | the session whose event is being handled; 0 at the top level |
| `on_leave(f)` | `f(s)` when a viewer closes the page, or has not been seen for a while |
| `to_session(s, f)` | runs `f` with what it draws and changes going to session `s` -- to update another player's page |
| `to_everyone(f)` | runs `f` with what it changes going to every session -- a chat message |
| `sessions() -> [Int]` | the sessions open now |

Inside an event's callback, commands go to the session the event came
from, which is what makes the common case need no session numbers at
all: a button's `on_click` changes the page of whoever pressed it.

```
def start(s: Int):
    shown = tw.label("Welcome, visitor " ++ string(s))
    def pressed():
        tw.set_label(shown, "You pressed it")   # only this viewer's page
    tw.button("Press", on_click = pressed)
tw.on_session(start)
```

**Sessions and saving.** Saving stays outside tinyweb, in the storage
library below, but a session gives a program a key to save under. If the page keeps a token of its
own in the browser, a reload continues the same session rather than
starting a new one, and `session_key() -> String` -- that token -- is
what a program would store a viewer's data by, with whatever storage
library it uses. A viewer who comes back tomorrow is then recognised.

**What it costs.**

- Each implementation keeps a page's state, its history for a late
  connection and its event queue per session, instead of once.
- Element identifiers stay unique across sessions (one set of names), so
  an id always names exactly one element on exactly one page.
- Every target is held to the same behaviour: the browser targets have
  one viewer, so `on_session` calls `start(1)` once there, and the same
  program runs everywhere -- rule 1.
- Tests need several connections at once, with events from each, in
  the `.events` file (`session 2: click 4`).
- Reaching another computer means listening beyond 127.0.0.1, which a
  program would have to ask for (`web_init(port, shared = true)`), since
  it lets anyone on the network in.

---

### A storage library

Its own module, say `store`, usable with or without tinyweb:

| Function | What it does |
|---|---|
| `store.put(key, value)` | keeps a string under a key |
| `store.get(key, default) -> String` | what is kept, or `default` |
| `store.remove(key)` | forgets it |
| `store.keys() -> [String]` | everything kept |

Natively it is a file beside the program (or under the user's data
directory); in a browser it is the page's own storage. With sessions, a
program keeps a viewer's data under `tw.session_key() ++ "/score"`. On a
browser page `get` answers at once, since the storage is right there;
natively it reads the file. Its design -- values beyond strings, what
happens when two sessions write at once -- is a plan of its own when this
phase comes.

Tests: `lib_tinyweb_sessions` (two connections, events from each, and
what each page received), `lib_store_*` on every target.

---

## Open questions

1. **Sessions**: should a reload continue its session (a token kept in
   the browser), and should a program be able to ask to listen beyond
   its own machine (`web_init(port, shared = true)`)?
2. **`_` in decimal literals**: allowed too (`1_000_000`), as in Python,
   or only in hexadecimal and binary?

---

## Organising tinyweb: submodules

### Why it needs organising

tinyweb has about 30 public functions today. The seven steps above add
around 120 more. As one module that means:

- one name space of 150 functions behind `tw.`, where completion in the
  editor offers `tone`, `table` and `turn` side by side;
- one library page of 150 entries in the help;
- one Pyking file of a few thousand lines, and one declaration file
  every host implements in full.

A beginner's first program should still be `import tinyweb as tw` and
nothing else, and what the first steps teach should be reached that
way. What a program needs later should be found by subject.

### Three ways to do it, and the one recommended

**Prefixed names in one module** (`tw.sound_start`, `tw.ui_table`) need
no language change, but keep every problem above and make every name
longer. Not recommended.

**Separate libraries** (`tinysound`, `tinygame`) need no language change
either, but the parts are not independent: they share one page, one
connection to it, one clock, one naming of elements and one event
loop. Separate libraries would each have their own host implementation
in seven languages, and those would have to find each other's state in
every host. Not recommended.

**Submodules: names inside the library**, recommended, and built.
`tinyweb` stays the module a beginner imports, and the subjects that
come later are submodules of it, named with a dot:

```
import tinyweb as tw              # the page, canvases, drawing, widgets, events
import tinyweb.sound as sound     # voices, tones, the beat, channels
from tinyweb.game import circles_overlap
```

### What the language offers

Submodules are in the language (PYKING.md, "Submodules"; the
implementation is `src/submodules.ml`, described in docs/modules.md,
"Submodules"). What tinyweb needs of them:

**A submodule is dotted names in one file.** `tinyweb.pyk` defines
`public def sound.start(...)`, `public def sound.tone(...)`, and so on;
`tinyweb.sound` is nothing but those names. There is no folder and no
file per submodule, so finding a module is unchanged: `import
tinyweb.sound` finds `tinyweb` as today. Deeper paths work too
(`sound.channel.mute`), though tinyweb would use one level.

**What an import binds.** `import tinyweb.sound` binds `sound`, the last
part, and `as` renames it; `from tinyweb import sound` does the same.
`from tinyweb.sound import start` takes one name, and
`tw.sound.start(...)` reaches it through `import tinyweb as tw`. This
departs from Python, where `import a.b` binds `a`; `sound.start(...)` is
what a beginner would rather read than `tinyweb.sound.start(...)`.

**Inside tinyweb**, a submodule's names are always written with their
whole path -- `sound.start(...)`, even from `sound.tone` -- and nothing
else in `tinyweb.pyk` may be called `sound`.

**Privacy needs nothing new.** Every submodule is in tinyweb's own two
files, so it sees tinyweb's private declarations as the rest of
`tinyweb.pyk` does today, and a program still cannot reach
`make_button` or `apply_style`. A helper a submodule shares with
another without offering it is a private name, `def sound.mix(...)`,
which another module is refused.

**Host functions of a submodule** are dotted declarations in
`tinyweb_external.pyk`, `def sound.start_voice(...) -> String`, public
or private as any declaration. Each host implements it under the plain
name the dotted one compiles to: `sound__start_voice` in Python,
JavaScript, OCaml and Java, and `tinyweb_sound__start_voice` in C. So
the host implementations stay one per language, holding the page, the
connection and every command, as now; a submodule adds functions to
them and no files.

**What it costs.** `tinyweb.pyk` and `tinyweb_external.pyk` grow with
every step instead of being split across files, so each is organised by
`##` headings per submodule. The help still shows one page per
submodule (below).

**What is left to build** for tinyweb to use it:

| Place | What changes |
|---|---|
| `tools/help/libdoc.py`, the website | one library page per submodule, under the library in the menu, from the dotted names' `##` blocks |
| the playground and the notebook | completion and the outline grouping a library's names by submodule (the language server lists the plain names today) |
| `PYKING.md`, the library docs | an example of `import tinyweb.sound as sound` once `sound` exists |

### How tinyweb would be divided

The rule: **what the first two steps teach stays in `tinyweb`**, so
`import tinyweb as tw` reaches a beginner's first programs; each later
subject is a submodule named for it. Everything tinyweb has today stays
where it is, so no program changes.

| Module | What it holds | From |
|---|---|---|
| `tinyweb` | `web_init`, canvases and drawing (shapes, text, transformations, images), buttons, labels, sliders and the step 2 widgets, the mouse, the keyboard, `on_frame`, timers, `play`, `load_sample`, `play_file`, `time`, `theme` and the `_style` functions | today, steps 1 and 2 |
| `tinyweb.color` | `rgb`, `rgba`, `hsl`, palettes, `pixel_color` and its parts | step 1 |
| `tinyweb.sound` | `start`, `stop`, `fade`, `master_volume`, `tone`, `note`, `rate_of`, `tempo`, `on_beat`, `beat`, `swing`, channels, `level`, `band` | step 3 |
| `tinyweb.game` | the collision functions, `burst`, `fixed_step`, `pause`, `resume`, `on_blur`, `on_focus`, `fullscreen`, `cursor` | step 4 |
| `tinyweb.bitmap` | `bitmap`, `set_pixel`, `get_pixel`, `fill_bitmap`, `show_bitmap`, `grid`, `filter`, `gradient` | step 5 |
| `tinyweb.layout` | `row`, `column`, `panel`, `inside`, `outside`, `box_style`, `table`, `list_view`, `text_area`, `markdown`, `link`, `progress`, `chart` | step 5 |
| `tinyweb.net` | `fetch_text`, `download`, `upload`, `clipboard`, `title` | step 5 |
| `tinyweb.sprite` | sprites | step 6 |
| `tinyweb.session` | sessions | step 7 |

A submodule's functions take the identifiers `tinyweb`'s functions
answer (`bitmap.show_bitmap(c, b, ...)` draws on a canvas from
`tw.canvas`), since every element of a page shares one set of names.

`math`, `random` and `store` stay libraries of their own, as decided:
they are not about a page.

### When

The language change is made. What is left for submodules -- the help's
page per submodule, above -- is done before step 3, the first step whose
functions go into one. Steps 1 and 2 add to `tinyweb` itself, so the
order of the steps does not change.
