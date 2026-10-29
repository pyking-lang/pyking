---
title: Code on slides
description: Colour Pyking code for a slide with pyk highlight, so it keeps its colours and stays text a reader can copy.
sidebar:
  order: 3
---

`pyk highlight` writes Pyking code coloured the way the playground
colours it, as text a slide program such as Keynote pastes and keeps as
**text**: the colours stay, and a reader of the slides exported to PDF
can still select the code and copy it.

```sh
pyk highlight prog.pyk                  # HTML, on standard output
pyk highlight prog.pyk --rtf -o prog.rtf
pyk highlight prog.pyk --theme dark --background theme --size 28
```

Open the HTML in a browser, or the RTF in TextEdit, select the code,
copy it and paste it on the slide.

## From the playground

In the playground, **Copy for slides** does the same for the code in
the editor -- the selection, or the whole program when nothing is
selected -- and puts it on the clipboard ready to paste on a slide. It
is in the editor's right-click menu and on Alt+Shift+C (Option+Shift+C
on a Mac). Its options -- the colours, font, size, background and
spaces -- are under Settings, Copy for slides, with a preview, and so
are a switch that puts a Copy for slides button above the editor and,
under Keys, its key.

## Indentation that survives a PDF

Exporting to PDF and copying the code back out tends to lose the spaces
at the start of each line, and with them Pyking's blocks. So
`pyk highlight` writes indentation with non-breaking spaces, which a PDF
keeps. Pyking reads a non-breaking space as a space, so code copied out
of the PDF runs as it is.

`--spaces all` writes every space as a non-breaking one, except those
inside a string, which are part of what the program prints, and
`--spaces none` writes ordinary spaces only. Keynote's "Paste and Match
Style" pastes the plain text, which keeps the non-breaking spaces too.

## The options

| Option | What it does | Default |
|---|---|---|
| `--html`, `--rtf`, `--text` | the format: an HTML `<pre>` with every style inline, an RTF document, or plain text | `--html` |
| `--theme light` or `dark` | the playground's light or dark colours | `light` |
| `--font NAME` | the font | `Menlo` |
| `--size PT` | the size in points | the application's |
| `--background none`, `theme` or `#rrggbb` | what is behind the text | `none` |
| `--spaces indent`, `all` or `none` | which spaces are non-breaking | `indent` |
| `-o FILE` | write to a file | standard output |

## A notebook's code

Given a notebook (`.md`, or `.json` as `pyk notebook --to-json` writes
it), `pyk highlight` colours every ```` ```pyking ```` block -- cells,
fragments, tasks and solutions -- numbered from 1 in the order they are
written:

```sh
pyk highlight book.md                    # book-1.html, book-2.html, ... beside it
pyk highlight book.md --block 3          # block 3 alone, on standard output
pyk highlight book.md --notebook page    # every block, without the text
pyk highlight book.md --notebook whole -o book.html
```

`--notebook whole` writes the whole notebook, its text rendered as the
notebook's page renders it (which needs `node`), and each block
coloured; the blocks a program reads or prints are shown as they are.
`--output-dir DIR` says where `split` writes its files.
