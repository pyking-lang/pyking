# Changelog

All notable changes to Pyking are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Added

- Tab completes in the REPL, `pyk repl` and the playground's REPL tab
  alike: one name that fits is completed, several as far as they agree,
  and otherwise they are listed with their types -- what the session
  has bound, the modules it imported (`math.` offers what `math`
  exports), the builtins, the keywords, and the meta-commands after a
  `:`. Tab at the start of a line still indents.
- `pyk <file> -t <target>` compiles the program for that target, builds
  it in `build/` and runs it from there.
- A datatype's constructors may share a line, separated by commas, and
  the first of them may follow the datatype's `:`: `datatype Color:
  Red, Green, Blue`.
- `tinyweb.web_init()`: the port defaults to 0, any free one.
- The playground's Compiled code tab has a Download button: the compiled
  files, each library's implementation and the assets the program names,
  with a Makefile (`make`, `make run`, `make clean`), as one .zip.
- `pyk serve <file>` serves the file's directory and prints a link to
  the file itself.

- A `math` library, on every target: `sin`, `cos`, `tan`, `asin`,
  `acos`, `atan` and `atan2` in degrees, each with a `_rad` twin in
  radians, and `radians`/`degrees`; `sinh`, `cosh`, `tanh`, `exp`,
  `log`, `log2`, `log10`, `sqrt`, `cbrt`, `pow`, `hypot` and
  `distance`; `floor`, `ceil`, `trunc` and `round` answering an Int;
  `abs`, `min`, `max`, `clamp`, `sign` and a floored `mod` for Ints and
  Floats alike; `gcd`, `lcm`, `lerp` and `map_range`; and `pi`, `tau`,
  `e`, `inf`, `nan`, `is_nan` and `is_finite`.
- Algebraic data types: `datatype Tree(a):` with one constructor per
  line, fields that are positional, named or defaulted, constructors
  applied with a call's rules, and `x.field` to read a named field.
  Datatypes cross modules with `public datatype`. Supported on every
  target; C refuses one that holds itself.
- Patterns: constructor patterns with fields by position or by name,
  or-patterns (`case 1 | 2:`), `as` patterns, and guards
  (`case n if n > 0:`).
- design/plan-bootstrap.md: what Pyking still lacks for the compiler to
  be written in it.
- Every target but C compiles everything the type checker accepts.
  Java does it in three shapes -- plain classes for java8, records and
  `instanceof` patterns for java17, records and a pattern `switch` for
  java21 -- with generics, `java.util.List`, closures and a
  `PykRuntime.java` written beside every program. C compiles everything
  that needs no garbage collector: tuples, datatypes that do not hold
  themselves, polymorphic functions (once per type, across modules
  too), nested functions, lambdas and function values handed down, and
  `for x in range(...)`; a list, a datatype holding itself and a closure
  that would outlive its stack frame are refused with the reason.
  JavaScript gains `range`, `len` and `x = if ...`/`x = match ...`;
  OCaml takes a polymorphic parameter, as a record with a polymorphic
  field.
- `sys` on Java answers `args`, `env`, `prog_name` and `prog_path`;
  `time` has Java and C implementations.
- The playground compiles a program that imports, the standard library
  included, showing every module's file.
- `make test` runs every test program on every target. A case leaves a
  target out only through `excluded`, with the reason, and the summary
  lists them; a page's `exited with status N` is read as its exit
  status.
- tinyweb shows a splash screen, `Click to Start` over the dimmed page,
  before the first sound on a page opened from a link: the page a
  program serves, and a `web24` or `iweb24` page. The page waits there
  until the reader clicks or presses a key, and the sound plays then.
  `tinyweb.splash()` shows it, `tinyweb.set_splash(message)` changes what
  it says (`""` turns it off), and a program that can play a sound calls
  `splash()` at the end of its top level without writing it. The
  playground and the notebook never show it.
- tinyweb draws more (step 1 of the plan): `ellipse`, `arc`, `polygon`,
  `path` and `curve`; an outline, its width and transparency on every
  shape, and rounded corners on `rect`; text with a font, an alignment
  and bold; `translate`, `rotate`, `scale`, `push`, `pop` and `reset`;
  pictures with `load_image` and `image` (`ball.png`, `star.png` and
  `tile.png` ship with it); `shadow` and `blend`. Colors come from the
  submodule `tinyweb.colors`: `rgb`, `rgba`, `hsl` and `palette`.
- tinyweb widgets: `checkbox`, `radio`, `choice` (a dropdown),
  `text_input` and `number_input`, with `set_checked` and `set_value`.
- tinyweb draws between pixels: the submodule `tinyweb.smooth` holds the
  shapes with Float coordinates and widths, and `smooth.lines` and
  `smooth.circles` draw thousands in one command.
- tinyweb: `lines`, `bezier`, `erase`, `line_style` (ends, corners and
  dashes), `clip_rect`, `clip_circle` and `clip_polygon`; text with a
  baseline and an outline, and `measure_text`; gradients,
  `colors.linear_gradient`, `colors.radial_gradient` and
  `colors.conic_gradient`, with `colors.stop`.
- tinyweb's mouse and keyboard: `on_press`, `on_release`, `on_move`,
  `on_drag`, `mouse_x`, `mouse_y`, `mouse_down`, `on_key_up` and
  `key_down`.
- tinyweb bitmaps: `bitmap`, `set_pixel`, `get_pixel`, `fill_bitmap`,
  `show_bitmap`, `pixel_color`, `red`, `green` and `blue`.
- tinyweb layout: `row`, `column`, `inside` and `outside`;
  `page_style(align = ...)`, `set_style(weight = ..., height = ...)`,
  and `set_label` changing a button's title.
- `time.local_now()`: the date and the time of day where the program
  runs.
- A `random` library, written in Pyking: `random`, `randint`, `uniform`,
  `choice`, `shuffle` and `seed`, the same numbers on every target for a
  seed.
- Submodules: a definition with a dotted name, `public def
  mymod.foo(x: Int) -> Int`, is `foo` in the submodule `mymod` of its
  file -- deeper ones too, `mymod.another.foo` -- for a `def`, an `=`
  binding, a datatype (its constructors written `shapes.Circle`) and a
  declaration. Another module reaches it as `hello.mymod.foo`, or with
  `from hello import mymod`, `import hello.mymod [as m]` or `from
  hello.mymod import foo`.
- `pyk --tinyweb-log` (and `pyk repl --tinyweb-log`) prints what a
  program sends its tinyweb page, and what the page answers, on stderr
  while the page runs; the playground's Web output tab has the same as a
  "tinyweb log" switch.
- `make quicktest`: a random sample of `make test` (`PERCENT=`, 5 by
  default; `SEED=` repeats a run). Both print a per-target summary at the
  end.

### Changed

- Named arguments may be written in any order: `box(depth = 6, width =
  4)`. They are evaluated in the order written, then the defaults of the
  parameters left out.
- `pyk compile` writes everything it generates into `build/`, with a
  Makefile (`make`, `make run`, `make clean`), builds it with the
  target's own tools, and puts only the executable beside `build/` --
  the binary for C and OCaml, a launcher script for Python, Node and
  Java, nothing for a page. `--output` names the executable. A `build/`
  an earlier compile made is replaced, and any other refused.
  `--no-build` writes `build/` and builds nothing. `-t pyking` writes
  its one file as before.
- `--run` on `web24` and `iweb24` prints a link straight to the page.
- The install instructions run `brew update` before `brew install
  pyking-lang/tap/pyking`.

- Every name a program binds -- with `=`, `var` or `def`, a parameter, a
  loop variable, a pattern or an import alias -- starts with a lowercase
  letter or `_`; an uppercase name is always a type or a constructor, so
  `PI = 3.14` is now refused and written `pi = 3.14`.
- The time library's format constants are `time.iso8601_format`,
  `time.date_format`, `time.time_format`, `time.datetime_format` and
  `time.compact_format` (were `ISO8601`, `DATE`, `TIME`, `DATETIME` and
  `COMPACT`).
- A `var` may hold a value of any type -- a String, a tuple, a list, a
  datatype's value or a function -- not only an Int, a Float or a Bool.
- tinyweb names a canvas, button, label, slider and sample by a String
  rather than an Int: its text -- a button's title, a label's text, a
  sample's file name -- or "canvas" or "slider", with a number added
  where the name is taken. The log and `.events` files quote them.
- The playground's Web output tab is empty whenever no program runs.
- A page a program serves plays the sounds the top level played when it
  connects, rather than leaving them out.

- Every `match` must match every value, whether its value is taken or
  not, and every case must be reachable. A refusal names a value no
  case matches. A statement `match` with nothing to do for the rest
  needs `case _: ()`.
- A Python reserved word used as a name is renamed `word_` rather than
  `word2`, so that a public one is imported under the same name.
- `tests/test_cases.toml` has no `targets` lists: a case runs on every
  target unless `excluded` names one with the reason, and `also` adds
  the targets that turn a pass off.

### Fixed

- On a phone, the website's header shows the five sections as a second
  row; before, they were hidden and only the current section's pages
  were reachable.
- In the playground, compiling a program that imports `math` for
  `node24` or `web24` exported its overloaded names unrenamed
  (`int::abs`), and an `iweb24` page of a program importing anything
  but `io` printed nothing.

- In the browser, a NaN or an infinity answered by a module implemented
  in JavaScript reached the interpreter as `()`, and -0.0 as 0.0.
- A C program is linked with `-lm` by `pyk compile --run`.
- The library pages list an overloaded export (`int::abs`).
- The type checker recorded some types inside a polymorphic definition
  at another definition's types -- `[]` in `collect` read `[Int]` --
  since its re-check's metavariables were later solved under the same
  numbers; and a polymorphic def nested in another kept the enclosing
  one's variables unsolved. Both now read back in the definition's own
  variables, and a printed nested type still shows `?` where Pyking
  cannot write one.
- On `ocaml5.5`, a tuple binding with two `_`, `(_, x, _) = t`, compiled
  to OCaml binding `__` twice, which OCaml refuses.
- On `ocaml5.5`, a `return` inside an `if` that was itself inside an
  `if` with no `else`, with statements after it, did not leave the
  function; and a public `def` with a parameter it did not read made a
  warning.
- On `node24` and `web24`, a Float whose shortest digits end exactly
  halfway printed its last digit one higher (`168799237148104.63` for
  `168799237148104.62`), and formatting a Float was slow.
- In the browser -- iweb24, the playground, the notebook -- text with a
  character beyond the first 256, an em dash say, was garbled on its
  way into the interpreter and out of it.
- tinyweb's log rounds a Float that is exactly halfway the same way on
  every host.
- On the C targets, clang (by default on a Mac) fused a multiply and an
  add into one rounding, so a Float could differ from every other
  target in its last digit; generated C now turns that off.
- On `ocaml5.5`, a program using tinyweb failed to build in a directory
  where a program importing `sys` had been compiled before: tinyweb's
  implementation now names OCaml's own `Stdlib.Sys`.
- A submodule's import is found by its row, so a qualified name after
  a comma (`f(a, colors.rgb(...))`) is rewritten too, and the rewrite
  no longer overflows the browser's stack on a long module.

## [0.1.3] - 2026-10-16

### Added

- tinyweb pages have a look of their own, the same in the playground,
  the notebook, the help and on every target: the light look the
  playground's Web output window had. `tw.theme(name)` switches the
  whole page to `"light"`, `"dark"`, `"plain"`, `"paper"` or `"retro"`;
  `page_style`, `button_style`, `label_style`, `slider_style` and
  `canvas_style` change every element of a kind; `set_style` and
  `set_colors` change one element. A new page, Getting started ›
  Styling tinyweb, shows each of them with examples to run.
- Pyking as a Docker image, for x86_64 and arm64:
  `docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking
  hello.pyk`. `ghcr.io/pyking-lang/pyking:full` also holds Python, node,
  gcc, a JDK and OCaml, so `pyk compile --run` runs every target. The
  playground, the notebook and the help can be opened from outside the
  container with `-p 8000:8000 ... playground --port 8000`.
- Pyking as a Nix flake, on Linux and macOS: `nix run
  github:pyking-lang/pyking-releases`, or `nix profile install
  github:pyking-lang/pyking-releases`.
- `make website-release` publishes the website at https://pyking.org/,
  from the GitHub Pages repository `pyking-lang/pyking-lang.github.io`.
- The website's start page has a picture at its top, a python wearing a
  crown, and its example beside the title, dark in both themes, with a
  "Try in playground" button in its corner.
- A playground link may hold a program: `…/playground/#code=…` opens the
  playground with that program in the editor, without running it, and
  **Copy code as link** makes one from what is in the editor.
- `PYKING_WEB_HOST` names the address `pyk notebook`, `pyk playground`,
  `pyk pykhelp` and `pyk serve` listen on, 127.0.0.1 without it;
  `0.0.0.0` listens on every interface.

## [0.1.2] - 2026-10-12

### Added

- `pyk pykhelp` serves the help -- getting started, the language reference
  and the library reference -- with every example runnable, and `make
  pykhelp` opens it (`make help` lists the make targets, as before). The
  playground has it as a fifth tab, Help, with a button copying an
  example into the editor. The website, the Help tab
  and `pyk pykhelp` show the same pages, which `make` generates.
- A function implemented in a target language may be declared with its
  parameters named, `def write(text: String) -> ()`, in place of `def
  write : (String) -> ()`; the standard library now is.
- A REPL in the playground: `pyk repl`'s own session, with its commands
  (`:help`, `:ls`, `:type`, `:edit`, `:ast`, `:tokens`, `:reset`), the
  standard library, a Stop button, Copy from editor (the text marked in
  the editor into the prompt), and the environment as a table below,
  updated after every entry.
- The playground has a light and a dark theme, following the system's
  by default, with a switch in the header and a choice in the settings.
  On the website it follows the site's own switch.
- `pyk example` lists example programs, one per line, and `pyk example
  NAME` saves one in the current directory. The playground's menu,
  now called Examples, offers the same ones, in a checkout and an
  install alike.
- A language server, `pyk lsp`, for every editor that speaks LSP: errors
  as you type, the inferred type on hover, go to definition (into
  imported modules and the standard library), an outline and
  completion. It is part of `pyk`, so nothing else is installed.
  Options `--stdio`, `-L`, `--log FILE`; settings `libPath` and
  `diagnostics` (`change` or `save`).
- A VS Code and Cursor extension, `pyking-<version>.vsix`, attached to
  every release, and setup for Neovim, Vim, Emacs, Sublime Text,
  PyCharm and Helix on the website's Editors page. The Emacs mode
  registers the server with eglot and ships in every package.
- `pyk serve [--port N] [DIR]` serves a directory's files, such as a
  page compiled for `web24` or `iweb24`, and lists a directory with no
  `index.html`.

### Changed

- `make test SUITE=tinyweb` runs one test suite, `SUITE=repl,lsp`
  several; `make help` says so.
- The playground's right side is five tabs: Run output, Compiled code
  (the target list and Compile are there now), Web output (a tinyweb
  page, in a browser-window frame with a Refresh button), REPL and Help.
- The playground's header shows the version of the `pyk` serving it.
- The website: the sections are on the left of the header and the
  search on the right; the menu on the left lists only the section being
  read, with the page's headings under it, and there is no menu on the
  right. A new section, Documentation, holds the language reference,
  Editors (from Getting started) and tinyweb without Pyking (from
  Libraries). The playground fills the window under the header. The
  logo is a python wearing a crown.
- The library reference shows each function in a box, with its full
  signature, its parameters, what it returns and a runnable example,
  for every function of the standard library.
- `:reset` in `pyk repl` keeps the library path (`-L`) the session was
  started with.
- The playground's editor is Monaco, in the source pane and in every
  output pane, and the source pane is a client of the Pyking language
  server: errors are underlined as you type, and it has hover, go to
  definition, an outline and completion. `make vendor` downloads Monaco.
  The notebook keeps Ace.
- `pyk notebook` and `pyk playground` are served by `pyk` itself, so
  Python is no longer needed to use them, and no package ships or
  recommends it. Only `pyk notebook --mode test` needs node.
- `pyk compile --run` serves a `web24` or `iweb24` page with `pyk serve`
  rather than `python3 -m http.server`.

### Fixed

- A tinyweb program's sounds play in the website's playground and cells:
  the samples were not copied into the site.
- A page with many cells no longer freezes the browser while it loads:
  the language reference made 124 editors at once, and a click on the
  menu went unanswered for half a minute. A cell's editor is now made
  when the cell comes near the screen.
- The Help tab shows the end of a long page, keeps a cell's run button in
  view at every width, and lines its menu -- the sections on the left,
  the page's headings on the right -- and its title up with the text.
  `pyk pykhelp` has one scroll bar and a light/dark switch.
- An example's stdout shown under it is replaced by its own output when
  it is run, rather than a second box appearing, and stands in line with
  its code.
- An example that does not run in a browser (`sys.prog_name`,
  `sys.prog_path`) follows the website's dark theme instead of showing
  white.
- `pyk` given a file that does not exist says so as a usage error rather
  than ending with an uncaught exception.
- A tinyweb page that listens for keys (`on_key`) takes the keyboard
  when the program starts, in the playground, the notebook and the help,
  unless an editor has it. Before, a key press went to the Run button.
  In the playground the whole Web output window takes the keyboard when
  clicked anywhere, its buttons included, keeps it until something
  outside is clicked, and outlines its frame while it has it.
- In the playground, the Web output window's three buttons are grey
  while it does not have the keyboard, as on a Mac. Running a tinyweb
  program with Run or its keys gives the window the keyboard, and Stop
  gives it back to the editor.
- In the playground, Ctrl+Enter (Cmd+Enter on a Mac) runs the program,
  as Shift+Enter does, and both stop a program that is running;
  compiling no longer has a key.
- In the playground, a run while you type no longer asks for the
  program's standard input or arguments: it uses the last ones given.
- tinyweb's `play` documentation says that `at` is a time on the page's
  clock, not a delay: two seconds from now is `tw.time() + 2.0`.
- `make website-dev` no longer warns about the grammar's `ebnf` blocks
  or a missing `i18n` collection.
- The Homebrew package ships the digest beside each library plugin, so
  a program importing `sys`, `tinyweb` or any other library implemented
  in OCaml runs without OCaml installed. 0.1.1 tried to compile the
  plugin and failed.

## [0.1.1] - 2026-10-11

### Added

- The `io` library: `write`, `write_line`, `read_line` (with an optional
  prompt), `read` and `is_eof`, on every target.
- `sys.exit`, ending a program with a status, on every target.
- The builtin `debug`, which prints like `print` but to standard error.
  `pyk compile --release` removes every call to it.
- The `tinyweb` library: a web page a program draws on and listens to,
  with canvases, buttons, labels, sliders, sound, and the mouse and keys.
  - It runs on every target. `tinyweb.web_init(port)` makes a program
    serve its own page and print its address (port 0 picks a free one).
  - The playground and the notebook show the page under the program.
  - The REPL keeps serving the page while it waits at the prompt.
  - `PYKING_TINYWEB_LOG` and `PYKING_TINYWEB_EVENTS` run a program
    without a page, logging what it would show and replaying events.
  - Each language's implementation is also a library of its own, usable
    with no Pyking: `tinyweb.py`, `tinyweb.js`, `tinyweb.ml`, `tinyweb.c`
    and `Tinyweb.java`, documented on the website with examples.
- The C and Java targets: what the top level binds is visible inside
  functions, and a top-level function can be passed as a value, such as a
  callback to a library.
- The website, built with `make website`: getting started, the library
  reference, and the playground, with runnable examples on every page.
- Notebook exercises and quizzes.
  - A notebook can hold rules with a maximum and a passing score,
    exercises checked against a solution or expected output, and
    single- and multiple-choice quizzes, with attempts, points and
    penalties.
  - `pyk notebook --mode student` (the default) hides solutions and
    answers, `--mode teacher` shows them, and `--mode test` checks a
    notebook instead of serving it.
  - Progress is kept in the browser, and `results()` reports it to a page
    embedding the notebook.
  - Exercises and quizzes also work on the website.
- A cell's standard input and arguments can be written on its header:
  ```` ```pyking stdin = "…" args = "…" ````.
- Programs in the playground and the notebook can read standard input and
  their arguments, which the page asks for, and can end with `sys.exit`.
- `CHANGELOG.md`, shipped in every package and shown on each release.

### Changed

- An external module's files are named `<module>_external.pyk` (was
  `<module>.external.pyk`), and its JavaScript implementation is split
  into `<module>_external_node.js` and `<module>_external_browser.js`.
- A runtime error raised by a library implemented in OCaml is reported
  where the program called it.
- `make test` needs node 22.7 or later (was 24).

### Fixed

- Building a library's interpreter plugin no longer fails when the
  current directory holds a compiled OCaml module of the same name.
- The playground's editor shows an unterminated string correctly.

## [0.1.0] - 2026-09-27

### Added

- The initial packaged release of Pyking: the `pyk` compiler and
  interpreter, the REPL, the standard library (`fs`, `sys`, `time`), the
  notebook and the playground, as a Homebrew package for macOS and as
  tarballs and `.deb` packages for Linux and WSL.

[0.1.1]: https://github.com/pyking-lang/pyking-releases/releases/tag/v0.1.1
[0.1.0]: https://github.com/pyking-lang/pyking-releases/releases/tag/v0.1.0
