---
title: Styling a tinyweb page
description: The themes a tinyweb page can have, and how to change its buttons, labels, sliders and canvases.
sidebar:
  label: Styling tinyweb
  order: 2
---

A tinyweb page has a look of its own: the same colors, fonts and buttons
wherever it is shown, whether that is the playground, this page, or the
page a compiled program serves. A program can change that look in three
ways, from the broadest to the narrowest:

- `theme` picks one of tinyweb's ready-made looks for the whole page.
- `page_style`, `button_style`, `label_style`, `slider_style` and
  `canvas_style` change one kind of element, all of them at once.
- `set_style` and `set_colors` change one element.

The narrower one wins: a button given its own colors with `set_colors`
keeps them whatever `button_style` says. Every example below is a whole
program. Press **▶** to run it, and change it to try your own.

## Themes

A page starts in `"light"`. This program shows everything a page can
hold, in that theme:

```pyking
import tinyweb as tw
tw.web_init(0)
tw.label("The light theme")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "orange")
tw.rect(c, 70, 15, 130, 30, "#4caf50")
tw.button("Press me")
tw.slider(0, 100, 40)
```

The same program in each of the other four themes. Call `theme` first,
before anything else changes the look, since a theme replaces what the
`_style` functions changed.

```pyking
import tinyweb as tw
tw.web_init(0)
tw.theme("dark")
tw.label("The dark theme")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "orange")
tw.rect(c, 70, 15, 130, 30, "#4caf50")
tw.button("Press me")
tw.slider(0, 100, 40)
```

`"plain"` uses the browser's own buttons and sliders, on white:

```pyking
import tinyweb as tw
tw.web_init(0)
tw.theme("plain")
tw.label("The plain theme")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "orange")
tw.rect(c, 70, 15, 130, 30, "#4caf50")
tw.button("Press me")
tw.slider(0, 100, 40)
```

`"paper"` is ink on warm paper, with a serif font:

```pyking
import tinyweb as tw
tw.web_init(0)
tw.theme("paper")
tw.label("The paper theme")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "orange")
tw.rect(c, 70, 15, 130, 30, "#4caf50")
tw.button("Press me")
tw.slider(0, 100, 40)
```

`"retro"` is green on black, in a typewriter font:

```pyking
import tinyweb as tw
tw.web_init(0)
tw.theme("retro")
tw.label("The retro theme")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "orange")
tw.rect(c, 70, 15, 130, 30, "#4caf50")
tw.button("Press me")
tw.slider(0, 100, 40)
```

## One kind of element

Each `_style` function changes every element of one kind: those already
on the page and those made after it. Only what is named changes, and
everything else stays as the theme has it.

A color is any CSS color, such as `"red"`, `"#336699"` or
`"rgb(40, 120, 200)"`. A border is a CSS border, such as `"2px solid
navy"`, `"1px dashed gray"` or `"none"`. Sizes, corners, padding and gaps
are whole numbers of pixels. A font is a font name, such as `"Georgia"`,
or one of `"serif"`, `"sans-serif"` and `"monospace"`.

Named arguments are written in the order the function lists its
parameters, and any of them can be left out. The order for each function
is on its own entry in [the tinyweb reference](/libraries/tinyweb/).

```pyking
import tinyweb as tw
tw.web_init(0)
tw.page_style(background = "#fdf6e3", color = "#586e75", font = "Georgia", size = 17, padding = 16, gap = 14)
tw.button_style(background = "#268bd2", color = "white", border = "none", radius = 16, padding = 9)
tw.label_style(background = "#eee8d5", radius = 6, padding = 8)
tw.slider_style(accent = "#cb4b16", width = 260)
tw.canvas_style(border = "2px solid #93a1a1", radius = 8)
tw.label("Every label looks like this one.")
tw.label("And this one.")
c = tw.canvas(220, 60)
tw.circle(c, 30, 30, 20, "#b58900")
tw.button("Start")
tw.button("Stop")
tw.slider(0, 100, 60)
```

## One element

`set_colors` and `set_style` change one button, label, slider or canvas,
named by the number the function that made it answered. They win over
the theme and over the `_style` functions.

```pyking
import tinyweb as tw
tw.web_init(0)
tw.button_style(radius = 8, padding = 8)
yes = tw.button("Yes")
no = tw.button("No")
maybe = tw.button("Maybe")
tw.set_colors(yes, color = "white", background = "seagreen")
tw.set_colors(no, color = "white", background = "firebrick")
tw.set_style(maybe, border = "2px dashed orange", font = "monospace")
title = tw.label("A big title")
tw.set_style(title, color = "purple", font = "Georgia", size = 30)
```

A style can change while the page is showing, as anything else on it
can. Press the buttons:

```pyking
import tinyweb as tw
tw.web_init(0)
status = tw.label("Choose a theme")

def to_light():
    tw.theme("light")
    tw.set_label(status, "light")

def to_dark():
    tw.theme("dark")
    tw.set_label(status, "dark")

def to_retro():
    tw.theme("retro")
    tw.set_label(status, "retro")

tw.button("Light", on_click = to_light)
tw.button("Dark", on_click = to_dark)
tw.button("Retro", on_click = to_retro)
tw.slider(0, 10, 5)
```
