# A canvas, two circles, two samples and buttons that play them, written
# in Python against tinyweb.py. Run it with `python3 example.py` and open
# the address it prints.

import tinyweb as tw

tw.web_init(0)

kick = tw.load_sample("kick1.wav")
snare = tw.load_sample("snare1.wav")

canvas = tw.canvas(400, 200)
tw.draw_shape(canvas, "circle", "100 50 30", "#ff0000", "", 1.0, 1.0)
tw.draw_shape(canvas, "circle", "100 50 20", "#000000", "", 1.0, 1.0)

presses = 0


def play_kick():
    tw.play_sample(kick, 0.0, 1.0, 1.0)


def play_snare():
    global presses
    presses += 1
    print(f"snare, press {presses}")
    tw.play_sample(snare, 0.0, 0.5, 1.0)


tw.make_button("Play kick", play_kick)
tw.make_button("Play snare", play_snare)
tw.make_button("Does nothing", lambda: None)
tw.splash()

print("built the page")
