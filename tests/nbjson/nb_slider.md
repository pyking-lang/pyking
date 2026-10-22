# A slider and a label

`tw.slider(low, high, value, on_change = f)` puts a slider on the page,
and `f` is called with the new value whenever the reader moves it.
`tw.label(text)` shows a line of text and answers its id, which
`tw.set_text` takes to change it.

## Exercise

Show a label reading `volume 5` and a slider from 0 to 10 starting at
5. Whenever the slider moves to n, the label should read `volume n`,
or `volume n (loud)` when n is 8 or more. The program prints nothing;
what is checked is what it does to the page.

```pyking exercise
print("Add your code here")
```

```pyking solution
import tinyweb as tw

shown = tw.label("volume 5")

def moved(n: Int):
    words = "volume " ++ string(n)
    tw.set_text(shown, if n >= 8 then words ++ " (loud)" else words)

tw.slider(0, 10, 5, on_change = moved)
```

```events visible = true
slide "slider" 3
```

```events
slide "slider" 8
slide "slider" 10
slide "slider" 7
```

```events
slide "slider" 0
```
