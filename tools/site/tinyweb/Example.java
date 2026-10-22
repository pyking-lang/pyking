// A canvas, two circles, two samples and buttons that play them, written
// in Java against Tinyweb.java. Build it with
//   javac Tinyweb.java Example.java
// then run `java Example` and open the address it prints.

public final class Example {

    private static int presses = 0;

    public static void main(String[] args) {
        Tinyweb.web_init(0);
        String kick = Tinyweb.load_sample("kick1.wav");
        String snare = Tinyweb.load_sample("snare1.wav");
        String canvas = Tinyweb.canvas(400, 200);
        Tinyweb.draw_shape(canvas, "circle", "100 50 30", "#ff0000", "", 1.0, 1.0);
        Tinyweb.draw_shape(canvas, "circle", "100 50 20", "#000000", "", 1.0, 1.0);
        Tinyweb.make_button("Play kick", () -> Tinyweb.command("play", kick, "", "0.0 1.0 1.0 0.0 0 0", 2));
        Tinyweb.make_button("Play snare", () -> {
            presses += 1;
            System.out.println("snare, press " + presses);
            Tinyweb.command("play", snare, "", "0.0 0.5 1.0 0.0 0 0", 2);
        });
        Tinyweb.make_button("Does nothing", () -> { });
        Tinyweb.splash();
        System.out.println("built the page");
    }
}
