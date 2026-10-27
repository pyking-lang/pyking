// The Java implementation of the names declared in tinyweb_external.pyk,
// for java8, java17 and java21. Java requires the file name and the
// public class to match, so this one file is capitalised where its
// siblings are not: the generated program calls TinywebExternal.canvas.
// A Pyking function is the java.util.function interface of its shape --
// Runnable, Consumer, BiConsumer -- so a Java caller hands one a lambda.
//
// A program talks to its page in commands and the page answers in
// events (docs/libraries.md, "tinyweb"). Where they go:
//
//   - $PYKING_TINYWEB_LOG set: no page. Each command is a line in that
//     file, and once the top level has ended the events
//     $PYKING_TINYWEB_EVENTS lists are delivered -- how a program is
//     tested.
//   - otherwise web_init(port) serves the page, tinyweb_page.html and
//     tinyweb_page.js (copied into this file below), with the JDK's own
//     HTTP server: GET /commands is a stream of command batches
//     (server-sent events) and POST /events one event each. Once main
//     has returned, the events are delivered in the order they came, on
//     a thread of their own, each answered with `event_done` once what
//     it caused has been sent.
//   - neither: the first call says web_init is missing, and the program
//     ends with status 1.

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

public final class TinywebExternal {

    private TinywebExternal() {
    }

    private static final String LOG = System.getenv("PYKING_TINYWEB_LOG");
    private static final String EVENTS = System.getenv("PYKING_TINYWEB_EVENTS");

    private static double clock = 0.0;
    // tinyweb's `sdelay`: how many have been sent, and with no page,
    // where the last one ended on the clock the events give (NaN before
    // the first).
    private static int sdelays = 0;
    private static double sdelayEnd = Double.NaN;
    // Whether an event has been delivered: until one is, the program is
    // in its top level, whose sound a page connecting later still plays.
    private static volatile boolean delivered = false;
    private static final Map<String, Runnable> buttons = new HashMap<String, Runnable>();
    private static final Map<String, Consumer<Integer>> sliders =
        new HashMap<String, Consumer<Integer>>();
    private static final Map<String, Consumer<Boolean>> checks =
        new HashMap<String, Consumer<Boolean>>();
    private static final Map<String, Runnable> radios = new HashMap<String, Runnable>();
    private static final Map<String, Consumer<Integer>> choices =
        new HashMap<String, Consumer<Integer>>();
    private static final Map<String, Consumer<String>> texts =
        new HashMap<String, Consumer<String>>();
    // Every identifier given out so far.
    private static final java.util.Set<String> names = new java.util.HashSet<String>();
    private static final List<Consumer<Double>> frames = new ArrayList<Consumer<Double>>();
    private static final List<Object[]> mice = new ArrayList<Object[]>();
    private static final List<Consumer<String>> keys = new ArrayList<Consumer<String>>();
    private static final List<Consumer<String>> keyUps = new ArrayList<Consumer<String>>();
    // The keys held down now, from the key events delivered so far.
    private static final java.util.Set<String> down = new java.util.HashSet<String>();
    private static boolean keysOn = false;
    // Each canvas's pointer: the functions watching it, by kind, and where
    // it was last seen.
    private static final Map<String, Pointer> pointers = new HashMap<String, Pointer>();
    private static final Map<String, Consumer<Double>> measures =
        new HashMap<String, Consumer<Double>>();
    private static final Map<String, Bitmap> bitmaps = new HashMap<String, Bitmap>();
    // The functions `watch` handed over, by element and kind, and what the
    // page last reported, by name: a double[] of numbers or a String.
    private static final Map<String, List<Runnable>> watchers = new HashMap<String, List<Runnable>>();
    private static final Map<String, Object> reports = new HashMap<String, Object>();
    private static boolean after = false;

    private static final class Pointer {
        final Map<String, List<BiConsumer<Integer, Integer>>> watchers =
            new HashMap<String, List<BiConsumer<Integer, Integer>>>();
        int x = 0;
        int y = 0;
        boolean down = false;

        Pointer() {
            for (String kind : new String[] {"press", "release", "move", "drag"}) {
                watchers.put(kind, new ArrayList<BiConsumer<Integer, Integer>>());
            }
        }
    }

    /** A bitmap's pixels, four bytes each, and the rectangle that changed
     *  since it was last shown. */
    private static final class Bitmap {
        final int width;
        final int height;
        final byte[] data;
        int x1;
        int y1;
        int x2;
        int y2;

        Bitmap(int width, int height) {
            this.width = width;
            this.height = height;
            this.data = new byte[width * height * 4];
            for (int i = 3; i < data.length; i += 4) {
                data[i] = (byte) 255;
            }
            x1 = 0;
            y1 = 0;
            x2 = width;
            y2 = height;
        }

        void touch(int x, int y) {
            x1 = java.lang.Math.min(x1, x);
            y1 = java.lang.Math.min(y1, y);
            x2 = java.lang.Math.max(x2, x + 1);
            y2 = java.lang.Math.max(y2, y + 1);
        }
    }
    private static Hub hub = null;

    // --- commands ---

    /** A string as JSON writes it, which is also how a log line quotes one. */
    private static String quote(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                case '\b': out.append("\\b"); break;
                case '\f': out.append("\\f"); break;
                default:
                    if (c < 0x20) {
                        out.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        return out.append('"').toString();
    }

    /** One command: its fields in order, as JSON for the page and as the
     *  line a log holds. */
    private static final class Command {
        final String op;
        final StringBuilder json = new StringBuilder();
        final StringBuilder line;
        String canvas = null;
        boolean clears = false;
        String label = null;
        // A `cmd` command's kind, identifier and mode.
        String kind = null;
        String id = null;
        int mode = 0;

        Command(String op) {
            this(op, op);
        }

        /** A command whose log line starts with another word than its op:
         *  a shape's kind, say. */
        Command(String op, String word) {
            this.op = op;
            this.json.append("{\"op\":").append(quote(op));
            this.line = new StringBuilder(word);
        }

        /** A field in the JSON alone, not in the log line. */
        Command hidden(String name, String value) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            return this;
        }

        /** A number in the JSON alone, not in the log line. */
        Command hiddenNumber(String name, int value) {
            json.append(",\"").append(name).append("\":").append(value);
            return this;
        }

        Command flag(String name, boolean value) {
            json.append(",\"").append(name).append("\":").append(value);
            line.append(' ').append(value);
            return this;
        }

        Command number(String name, int value) {
            json.append(",\"").append(name).append("\":").append(value);
            line.append(' ').append(value);
            return this;
        }

        Command seconds(String name, double value) {
            json.append(",\"").append(name).append("\":").append(Double.toString(value));
            line.append(' ').append(fixed3(value));
            return this;
        }

        Command bare(String name, String value) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            line.append(' ').append(value);
            return this;
        }

        /** A field written as JSON in the command and as `line` in the log. */
        Command raw(String name, String json, String words) {
            this.json.append(",\"").append(name).append("\":").append(json);
            line.append(' ').append(words);
            return this;
        }

        Command text(String name, String value) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            line.append(' ').append(quote(value));
            return this;
        }

        /** An element's text after its identifier: in the log line only
         *  where the two differ. */
        Command named(String name, String value, String id) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            if (!value.equals(id)) {
                line.append(' ').append(quote(value));
            }
            return this;
        }

        String json() {
            return json.toString() + "}";
        }
    }

    /** A number with three digits after the point, as C's "%.3f" writes
     *  it: one exactly halfway between two is rounded to the even one,
     *  where String.format rounds it up. */
    static String fixed3(double x) {
        if (Double.isNaN(x) || Double.isInfinite(x)) {
            return String.format(Locale.ROOT, "%.3f", x);
        }
        String digits = new java.math.BigDecimal(x).abs()
            .setScale(3, java.math.RoundingMode.HALF_EVEN).toPlainString();
        boolean negative = x < 0 || (x == 0.0 && 1.0 / x < 0);
        return negative ? "-" + digits : digits;
    }

    private static void writeLog(String line) {
        try (Writer log = new OutputStreamWriter(new FileOutputStream(LOG, true),
                StandardCharsets.UTF_8)) {
            log.write(line + "\n");
        } catch (IOException error) {
            // A log that cannot be written is not the program's problem.
        }
    }

    /** Ends the program with `message`, and with status 1. */
    private static void refuse(String message) {
        System.out.flush();
        System.err.println(message);
        System.exit(1);
    }

    /** What every function but web_init needs first: a log to write to,
     *  or a page served. */
    private static void ready() {
        if (LOG != null) {
            if (!after) {
                after = true;
                afterMain(new Runnable() {
                    public void run() {
                        deliverFile();
                    }
                });
            }
            return;
        }
        if (hub == null) {
            refuse("tinyweb: call tinyweb.web_init(port) before anything else, "
                + "or set PYKING_TINYWEB_LOG");
        }
    }

    /** Runs `what` once the thread calling this -- main -- has ended. */
    private static void afterMain(final Runnable what) {
        final Thread main = Thread.currentThread();
        Thread waiting = new Thread(new Runnable() {
            public void run() {
                try {
                    main.join();
                } catch (InterruptedException error) {
                    return;
                }
                what.run();
                System.out.flush();
            }
        }, "tinyweb");
        waiting.start();
    }

    private static synchronized void send(Command command) {
        ready();
        if (LOG != null) {
            if (!command.op.equals("frame_done") && !command.op.equals("event_done")) {
                writeLog(command.line.toString());
            }
        } else {
            hub.send(command);
        }
    }

    /** A new element's identifier: `name`, or `name` with the first
     *  number from 1 that makes it one nothing on the page has. */
    private static String fresh(String name) {
        // An empty name would be the page's own identifier.
        if (name.isEmpty()) name = "element";
        String found = name;
        for (int n = 1; names.contains(found); n++) {
            found = name + n;
        }
        names.add(found);
        return found;
    }

    // --- the functions tinyweb_external.pyk declares ---

    public static void web_start(int port) {
        if (LOG != null || hub != null) {
            return;
        }
        if (port < 0 || port > 65535) {
            refuse("tinyweb: cannot serve the page on port " + port
                + ": a port is a number from 0 to 65535");
        }
        hub = new Hub(port);
        System.out.println("tinyweb: http://127.0.0.1:" + hub.port() + "/");
        System.out.flush();
        afterMain(new Runnable() {
            public void run() {
                hub.deliverForever();
            }
        });
    }

    public static String canvas(int width, int height) {
        ready();
        String id = fresh("canvas");
        send(new Command("canvas").text("id", id).number("width", width)
            .number("height", height));
        return id;
    }

    public static void fill_canvas(String c, String color) {
        Command command = new Command("clear").text("c", c).bare("color", color);
        command.canvas = c;
        command.clears = true;
        send(command);
    }

    public static void draw_shape(String c, String kind, String numbers, String color,
                                  String outline, double width, double alpha) {
        Command command = new Command("shape", kind).hidden("kind", kind).text("c", c)
            .bare("numbers", numbers).text("color", color).text("outline", outline)
            .seconds("width", width).seconds("alpha", alpha);
        command.canvas = c;
        send(command);
    }

    /** Many points, circles or lines in one go: a list of the program's
     *  tuples, each read through the runtime's `pykItems`. */
    public static void draw_pairs(String c, String kind, java.util.List<?> items, String color,
                                  String outline, double width, double alpha) {
        drawNumbers(c, kind, items, color, outline, width, alpha);
    }

    public static void draw_triples(String c, String kind, java.util.List<?> items, String color,
                                    String outline, double width, double alpha) {
        drawNumbers(c, kind, items, color, outline, width, alpha);
    }

    public static void draw_quads(String c, String kind, java.util.List<?> items, String color,
                                  String outline, double width, double alpha) {
        drawNumbers(c, kind, items, color, outline, width, alpha);
    }

    private static final Map<Class<?>, java.lang.reflect.Method> ITEMS =
        new HashMap<Class<?>, java.lang.reflect.Method>();

    /** A tuple's parts, through the method every runtime tuple has. */
    private static Object[] partsOf(Object tuple) {
        try {
            java.lang.reflect.Method items = ITEMS.get(tuple.getClass());
            if (items == null) {
                items = tuple.getClass().getMethod("pykItems");
                items.setAccessible(true);
                ITEMS.put(tuple.getClass(), items);
            }
            return (Object[]) items.invoke(tuple);
        } catch (ReflectiveOperationException error) {
            return new Object[0];
        }
    }

    private static void drawNumbers(String c, String kind, java.util.List<?> items, String color,
                                    String outline, double width, double alpha) {
        StringBuilder json = new StringBuilder("[");
        StringBuilder words = new StringBuilder();
        boolean first = true;
        for (Object item : items) {
            for (Object part : partsOf(item)) {
                double x = ((Number) part).doubleValue();
                if (!first) {
                    json.append(',');
                    words.append(' ');
                }
                first = false;
                json.append(Double.toString(x));
                words.append(fixed3(x));
            }
        }
        Command command = new Command("shape", kind).hidden("kind", kind).text("c", c)
            .raw("numbers", json.append(']').toString(), words.toString())
            .text("color", color).text("outline", outline)
            .seconds("width", width).seconds("alpha", alpha);
        command.canvas = c;
        send(command);
    }

    public static void draw_text(String c, double x, double y, String words, String color,
                                 int size, String font, String align, String baseline,
                                 boolean bold, String outline, double outlineWidth,
                                 double alpha) {
        Command command = new Command("text").text("c", c).seconds("x", x).seconds("y", y)
            .text("color", color).number("size", size).text("font", font).bare("align", align)
            .bare("baseline", baseline).flag("bold", bold).text("outline", outline)
            .seconds("outline_width", outlineWidth).seconds("alpha", alpha)
            .text("words", words);
        command.canvas = c;
        send(command);
    }

    public static void measure(String words, int size, String font, boolean bold,
                               Consumer<Double> answer) {
        ready();
        String id = fresh("measure");
        measures.put(id, answer);
        send(new Command("measure").text("id", id).number("size", size).text("font", font)
            .flag("bold", bold).text("words", words));
    }

    public static void watch_pointer(String c, String kind, BiConsumer<Integer, Integer> f) {
        ready();
        Pointer seen = pointers.get(c);
        if (seen == null) {
            seen = new Pointer();
            pointers.put(c, seen);
            send(new Command("on_pointer").text("c", c));
        }
        List<BiConsumer<Integer, Integer>> watching = seen.watchers.get(kind);
        if (watching != null) {
            watching.add(f);
        }
    }

    public static int pointer(String c, String which) {
        ready();
        Pointer seen = pointers.get(c);
        if (seen == null) {
            return 0;
        }
        if (which.equals("x")) {
            return seen.x;
        }
        if (which.equals("y")) {
            return seen.y;
        }
        return seen.down ? 1 : 0;
    }

    // --- bitmaps ---

    /** FNV-1a, 32 bits, of the bytes: what the log says of a bitmap's
     *  pixels. */
    private static String digest(byte[] data) {
        int h = 0x811c9dc5;
        for (byte b : data) {
            h ^= b & 0xff;
            h *= 16777619;
        }
        return String.format(Locale.ROOT, "%08x", h);
    }

    public static String make_bitmap(int width, int height, int background) {
        ready();
        String id = fresh("bitmap");
        bitmaps.put(id, new Bitmap(java.lang.Math.max(1, width), java.lang.Math.max(1, height)));
        fill_bitmap(id, background);
        return id;
    }

    public static void set_pixel(String b, int x, int y, int color) {
        Bitmap bm = bitmaps.get(b);
        if (bm == null || x < 0 || y < 0 || x >= bm.width || y >= bm.height) {
            return;
        }
        int at = (y * bm.width + x) * 4;
        bm.data[at] = (byte) ((color >> 16) & 255);
        bm.data[at + 1] = (byte) ((color >> 8) & 255);
        bm.data[at + 2] = (byte) (color & 255);
        bm.touch(x, y);
    }

    public static int get_pixel(String b, int x, int y) {
        Bitmap bm = bitmaps.get(b);
        if (bm == null || x < 0 || y < 0 || x >= bm.width || y >= bm.height) {
            return 0;
        }
        int at = (y * bm.width + x) * 4;
        return ((bm.data[at] & 255) << 16) | ((bm.data[at + 1] & 255) << 8)
            | (bm.data[at + 2] & 255);
    }

    public static void fill_bitmap(String b, int color) {
        Bitmap bm = bitmaps.get(b);
        if (bm == null) {
            return;
        }
        for (int at = 0; at < bm.data.length; at += 4) {
            bm.data[at] = (byte) ((color >> 16) & 255);
            bm.data[at + 1] = (byte) ((color >> 8) & 255);
            bm.data[at + 2] = (byte) (color & 255);
            bm.data[at + 3] = (byte) 255;
        }
        bm.x1 = 0;
        bm.y1 = 0;
        bm.x2 = bm.width;
        bm.y2 = bm.height;
    }

    public static void draw_bitmap(String c, String b, int x, int y, double scale) {
        Bitmap bm = bitmaps.get(b);
        if (bm == null) {
            return;
        }
        int rx = 0;
        int ry = 0;
        int rw = 0;
        int rh = 0;
        if (bm.x2 > bm.x1 && bm.y2 > bm.y1) {
            rx = bm.x1;
            ry = bm.y1;
            rw = bm.x2 - bm.x1;
            rh = bm.y2 - bm.y1;
        }
        byte[] data = new byte[rw * rh * 4];
        for (int r = 0; r < rh; r++) {
            System.arraycopy(bm.data, ((ry + r) * bm.width + rx) * 4, data, r * rw * 4, rw * 4);
        }
        bm.x1 = bm.width;
        bm.y1 = bm.height;
        bm.x2 = 0;
        bm.y2 = 0;
        Command command = new Command("bitmap").text("c", c).text("id", b).number("x", x)
            .number("y", y).seconds("scale", scale).number("width", bm.width)
            .number("height", bm.height)
            .raw("rect", "[" + rx + "," + ry + "," + rw + "," + rh + "]",
                rx + " " + ry + " " + rw + " " + rh)
            .hidden("data", java.util.Base64.getEncoder().encodeToString(data))
            .bare("digest", digest(data));
        command.canvas = c;
        send(command);
    }

    public static void set_state(String c, String kind, String value, String numbers) {
        Command command = new Command("state", kind).hidden("kind", kind).text("c", c);
        if (value.isEmpty()) {
            command.hidden("value", value);
        } else {
            command.text("value", value);
        }
        if (numbers.isEmpty()) {
            command.hidden("numbers", numbers);
        } else {
            command.bare("numbers", numbers);
        }
        command.canvas = c;
        send(command);
    }

    public static String load_image(String name) {
        ready();
        String id = fresh(name);
        send(new Command("image_load", "load_image").text("id", id).named("name", name, id));
        return id;
    }

    public static void draw_image(String c, String picture, int x, int y, int width, int height,
                                  double alpha) {
        Command command = new Command("image").text("c", c).text("picture", picture)
            .number("x", x).number("y", y).number("width", width).number("height", height)
            .seconds("alpha", alpha);
        command.canvas = c;
        send(command);
    }

    public static String make_checkbox(String title, boolean checked, Consumer<Boolean> onChange) {
        ready();
        String id = fresh(title);
        checks.put(id, onChange);
        send(new Command("checkbox").text("id", id).named("title", title, id)
            .flag("checked", checked));
        return id;
    }

    public static String make_radio(String group, String title, boolean chosen,
                                    final Consumer<String> onPick) {
        ready();
        String id = fresh(title);
        final String picked = title;
        radios.put(id, new Runnable() {
            public void run() {
                onPick.accept(picked);
            }
        });
        send(new Command("radio").text("id", id).named("title", title, id).text("group", group)
            .flag("chosen", chosen));
        return id;
    }

    public static String make_choice(String options, int chosen, Consumer<Integer> onChange) {
        ready();
        String id = fresh("choice");
        choices.put(id, onChange);
        send(new Command("choice").text("id", id).number("chosen", chosen)
            .text("options", options));
        return id;
    }

    public static String make_text_input(String placeholder, Consumer<String> onEnter) {
        ready();
        String id = fresh(placeholder.isEmpty() ? "text" : placeholder);
        texts.put(id, onEnter);
        send(new Command("text_input").text("id", id).named("placeholder", placeholder, id));
        return id;
    }

    public static String make_number_input(int low, int high, int value,
                                           Consumer<Integer> onChange) {
        ready();
        String id = fresh("number");
        sliders.put(id, onChange);
        send(new Command("number").text("id", id).number("low", low).number("high", high)
            .number("value", value));
        return id;
    }

    public static void set_checked(String id, boolean checked) {
        Command command = new Command("set_checked").text("id", id).flag("checked", checked);
        command.label = id;
        send(command);
    }

    public static void set_value(String id, int value) {
        Command command = new Command("set_value").text("id", id).number("value", value);
        command.label = id;
        send(command);
    }

    public static String make_button(String title, Runnable onClick) {
        ready();
        String id = fresh(title);
        buttons.put(id, onClick);
        send(new Command("button").text("id", id).named("title", title, id));
        return id;
    }

    public static String label(String text) {
        ready();
        String id = fresh(text);
        send(new Command("label").text("id", id).named("text", text, id));
        return id;
    }

    public static String row() {
        ready();
        String id = fresh("row");
        send(new Command("row").text("id", id));
        return id;
    }

    public static String column() {
        ready();
        String id = fresh("column");
        send(new Command("column").text("id", id));
        return id;
    }

    public static void inside(String id) {
        send(new Command("inside").text("id", id));
    }

    public static void outside() {
        send(new Command("outside"));
    }

    public static void set_label(String id, String text) {
        Command command = new Command("set_label").text("id", id).text("text", text);
        command.label = id;
        send(command);
    }

    public static void apply_style(String id, String kind, String property, String value) {
        send(new Command("style").text("id", id).bare("kind", kind).bare("prop", property)
            .text("value", value));
    }

    public static String make_slider(int low, int high, int value, Consumer<Integer> onChange) {
        ready();
        String id = fresh("slider");
        sliders.put(id, onChange);
        send(new Command("slider").text("id", id).number("low", low).number("high", high)
            .number("value", value));
        return id;
    }

    public static String load_sample(String name) {
        ready();
        String id = fresh(name);
        send(new Command("load").text("id", id).named("name", name, id));
        return id;
    }

    public static String fresh_id(String name) {
        ready();
        return fresh(name);
    }

    public static void command(String kind, String id, String text, String numbers, int mode) {
        Command command = new Command("cmd", kind).hidden("kind", kind).text("id", id);
        if (text.isEmpty()) {
            command.hidden("text", text);
        } else {
            command.text("text", text);
        }
        if (numbers.isEmpty()) {
            command.hidden("numbers", numbers);
        } else {
            command.bare("numbers", numbers);
        }
        command.hiddenNumber("mode", mode);
        command.kind = kind;
        command.id = id;
        command.mode = mode;
        send(command);
    }

    public static void watch(String id, String kind, Runnable f) {
        ready();
        String key = id + "\0" + kind;
        List<Runnable> fs = watchers.get(key);
        if (fs == null) {
            fs = new ArrayList<Runnable>();
            watchers.put(key, fs);
        }
        fs.add(f);
    }

    public static double report_number(String name, int k) {
        Object value = reports.get(name);
        if (!(value instanceof double[])) {
            return 0.0;
        }
        double[] numbers = (double[]) value;
        return k >= 0 && k < numbers.length ? numbers[k] : 0.0;
    }

    public static String report_text(String name) {
        Object value = reports.get(name);
        return value instanceof String ? (String) value : "";
    }

    public static int report_count(String name) {
        Object value = reports.get(name);
        return value instanceof double[] ? ((double[]) value).length : 0;
    }

    public static void watch_text(String id, String kind, final String name, final Consumer<String> f) {
        watch(id, kind, () -> f.accept(report_text(name)));
    }

    public static void watch_step(String id, final String kind, final BiConsumer<Integer, Double> f) {
        watch(id, kind, () -> f.accept((int) report_number(kind, 0), report_number(kind, 1)));
    }

    public static void watch_pair(String id, final String kind, final BiConsumer<Double, Double> f) {
        watch(id, kind, () -> f.accept(report_number(kind, 0), report_number(kind, 1)));
    }

    public static void splash() {
        ready();
        send(new Command("splash"));
    }

    public static void set_splash(String message) {
        ready();
        send(new Command("splash_text").text("text", message));
    }

    public static double time() {
        ready();
        return clock;
    }

    /** Sends `sdelay` and waits for the page to answer it, delivering
     *  the page's other events meanwhile. With no page, moves the clock
     *  on to where it ends instead. */
    public static void sdelay(double time) {
        ready();
        double seconds = time > 0.0 ? time : 0.0;
        int id;
        synchronized (TinywebExternal.class) {
            sdelays++;
            id = sdelays;
        }
        Command command = new Command("sdelay").hiddenNumber("id", id).seconds("seconds", seconds);
        command.id = Integer.toString(id);
        send(command);
        if (LOG != null) {
            sdelayEnd = Double.isNaN(sdelayEnd) ? clock + seconds
                : java.lang.Math.max(sdelayEnd + seconds, clock);
            clock = sdelayEnd;
            return;
        }
        // Sound played after the first `sdelay` is live: a page
        // connecting later is not sent it, as it is not sent a callback's.
        delivered = true;
        System.out.flush();
        hub.flush();
        hub.waitFor(id);
    }

    public static void on_frame(Consumer<Double> draw) {
        ready();
        frames.add(draw);
        send(new Command("on_frame"));
    }

    public static void on_mouse(String c, BiConsumer<Integer, Integer> click) {
        ready();
        mice.add(new Object[] {c, click});
        send(new Command("on_mouse").text("c", c));
    }

    public static void on_key(Consumer<String> pressed) {
        ready();
        keys.add(pressed);
        send(new Command("on_key"));
    }

    public static void on_key_up(Consumer<String> released) {
        ready();
        keyUps.add(released);
        send(new Command("on_key"));
    }

    public static boolean key_down(String key) {
        ready();
        if (!keysOn && keys.isEmpty() && keyUps.isEmpty()) {
            keysOn = true;
            send(new Command("on_key"));
        }
        return down.contains(key);
    }

    // --- events ---

    /** Calls what the program handed over for one event, in the order it
     *  was handed over. */
    @SuppressWarnings("unchecked")
    private static void deliver(Map<String, String> event) {
        delivered = true;
        String t = event.get("t");
        if (t != null) {
            clock = Double.parseDouble(t);
        }
        String reported = event.get("reports");
        if (reported != null) {
            mergeReports(reported);
        }
        String kind = event.get("ev");
        if ("cb".equals(kind)) {
            List<Runnable> fs = watchers.get(event.get("id") + "\0" + event.get("kind"));
            if (fs != null) {
                for (Runnable f : new ArrayList<Runnable>(fs)) {
                    f.run();
                }
            }
        } else if ("click".equals(kind)) {
            Runnable f = buttons.get(event.get("id"));
            if (f != null) {
                f.run();
            }
        } else if ("slide".equals(kind)) {
            Consumer<Integer> f = sliders.get(event.get("id"));
            if (f != null) {
                f.accept(integer(event, "value"));
            }
        } else if ("check".equals(kind)) {
            Consumer<Boolean> f = checks.get(event.get("id"));
            if (f != null) {
                f.accept("true".equals(event.get("checked")));
            }
        } else if ("pick".equals(kind)) {
            Runnable f = radios.get(event.get("id"));
            if (f != null) {
                f.run();
            }
        } else if ("choose".equals(kind)) {
            Consumer<Integer> f = choices.get(event.get("id"));
            if (f != null) {
                f.accept(integer(event, "value"));
            }
        } else if ("enter".equals(kind)) {
            Consumer<String> f = texts.get(event.get("id"));
            if (f != null) {
                f.accept(event.containsKey("text") ? event.get("text") : "");
            }
        } else if ("frame".equals(kind)) {
            for (Consumer<Double> draw : new ArrayList<Consumer<Double>>(frames)) {
                draw.accept(clock);
            }
            send(new Command("frame_done"));
        } else if ("mouse".equals(kind)) {
            String c = event.get("c");
            for (Object[] entry : new ArrayList<Object[]>(mice)) {
                if (entry[0].equals(c)) {
                    ((BiConsumer<Integer, Integer>) entry[1])
                        .accept(integer(event, "x"), integer(event, "y"));
                }
            }
        } else if ("key".equals(kind)) {
            String key = event.containsKey("key") ? event.get("key") : "";
            down.add(key);
            for (Consumer<String> pressed : new ArrayList<Consumer<String>>(keys)) {
                pressed.accept(key);
            }
        } else if ("key_up".equals(kind)) {
            String key = event.containsKey("key") ? event.get("key") : "";
            down.remove(key);
            for (Consumer<String> released : new ArrayList<Consumer<String>>(keyUps)) {
                released.accept(key);
            }
        } else if ("press".equals(kind) || "release".equals(kind) || "move".equals(kind)) {
            Pointer seen = pointers.get(event.get("c"));
            if (seen != null) {
                seen.x = integer(event, "x");
                seen.y = integer(event, "y");
                if ("press".equals(kind)) {
                    seen.down = true;
                } else if ("release".equals(kind)) {
                    seen.down = false;
                }
                List<String> kinds = new ArrayList<String>();
                kinds.add(kind);
                if ("move".equals(kind) && seen.down) {
                    kinds.add("drag");
                }
                for (String k : kinds) {
                    for (BiConsumer<Integer, Integer> f
                             : new ArrayList<BiConsumer<Integer, Integer>>(seen.watchers.get(k))) {
                        f.accept(seen.x, seen.y);
                    }
                }
            }
        } else if ("measured".equals(kind)) {
            Consumer<Double> answer = measures.remove(event.get("id"));
            if (answer != null) {
                double width = 0.0;
                try {
                    width = Double.parseDouble(event.get("width"));
                } catch (NumberFormatException | NullPointerException error) {
                    width = 0.0;
                }
                answer.accept(width);
            }
        }
    }

    /** Puts the entries of a `reports` object into reports: each name with
     *  an array of numbers, a number, or a string. */
    private static void mergeReports(String text) {
        int n = text.length();
        int i = 0;
        while (true) {
            while (i < n && " \t\r\n,:{".indexOf(text.charAt(i)) >= 0) {
                i++;
            }
            if (i >= n || text.charAt(i) != '"') {
                return;
            }
            StringBuilder name = new StringBuilder();
            i = string(text, i + 1, name);
            while (i < n && " \t\r\n:".indexOf(text.charAt(i)) >= 0) {
                i++;
            }
            if (i >= n) {
                return;
            }
            char c = text.charAt(i);
            if (c == '"') {
                StringBuilder value = new StringBuilder();
                i = string(text, i + 1, value);
                reports.put(name.toString(), value.toString());
            } else if (c == '[') {
                int stop = nestedEnd(text, i);
                double[] numbers = new double[16];
                int count = 0;
                int j = i + 1;
                int last = java.lang.Math.max(j, stop - 1);
                while (j < last) {
                    int comma = text.indexOf(',', j);
                    if (comma < 0 || comma > last) {
                        comma = last;
                    }
                    try {
                        double x = Double.parseDouble(text.substring(j, comma).trim());
                        if (count == numbers.length) {
                            numbers = java.util.Arrays.copyOf(numbers, count * 2);
                        }
                        numbers[count++] = x;
                    } catch (NumberFormatException error) {
                        // Not a number: left out.
                    }
                    j = comma + 1;
                }
                reports.put(name.toString(), java.util.Arrays.copyOf(numbers, count));
                i = stop;
            } else {
                int start = i;
                while (i < n && ",} \t\r\n".indexOf(text.charAt(i)) < 0) {
                    i++;
                }
                try {
                    reports.put(name.toString(),
                        new double[] {Double.parseDouble(text.substring(start, i))});
                } catch (NumberFormatException error) {
                    // Not a number: nothing reported.
                }
            }
        }
    }

    /** Where the object or array starting at `i` ends: just past its
     *  closing bracket, strings inside it skipped. */
    private static int nestedEnd(String text, int i) {
        int n = text.length();
        int depth = 0;
        boolean inString = false;
        while (i < n) {
            char c = text.charAt(i);
            if (inString) {
                if (c == '\\') {
                    i++;
                } else if (c == '"') {
                    inString = false;
                }
            } else if (c == '"') {
                inString = true;
            } else if (c == '{' || c == '[') {
                depth++;
            } else if (c == '}' || c == ']') {
                depth--;
                if (depth == 0) {
                    return i + 1;
                }
            }
            i++;
        }
        return n;
    }

    private static int integer(Map<String, String> event, String name) {
        String value = event.get(name);
        if (value == null) {
            return 0;
        }
        try {
            return (int) Double.parseDouble(value);
        } catch (NumberFormatException error) {
            return 0;
        }
    }

    /** One line of an events file as the event the page would send, or
     *  null. The element an event is on is a quoted string, which may
     *  hold spaces, and the numbers it takes follow it. */
    private static Map<String, String> parseLine(String line) {
        Map<String, String> event = new HashMap<String, String>();
        if (line.startsWith("key ")) {
            event.put("ev", "key");
            event.put("key", line.substring(4));
            return event;
        }
        if (line.startsWith("key_up ")) {
            event.put("ev", "key_up");
            event.put("key", line.substring(7));
            return event;
        }
        String trimmed = line.trim();
        int space = trimmed.indexOf(' ');
        if (space < 0) {
            return null;
        }
        String kind = trimmed.substring(0, space);
        String after = trimmed.substring(space).trim();
        try {
            if (kind.equals("frame")) {
                String[] words = after.split("\\s+");
                if (words.length != 1) {
                    return null;
                }
                event.put("t", String.valueOf(Double.parseDouble(words[0])));
            } else {
                if (after.isEmpty() || after.charAt(0) != '"') {
                    return null;
                }
                StringBuilder id = new StringBuilder();
                int end = string(after, 1, id);
                String rest = end >= after.length() ? "" : after.substring(end).trim();
                String[] words = rest.isEmpty() ? new String[0] : rest.split("\\s+");
                if (kind.equals("report")) {
                    StringBuilder numbers = new StringBuilder();
                    for (String word : words) {
                        Double.parseDouble(word);
                        numbers.append(numbers.length() == 0 ? "" : ",").append(word);
                    }
                    event.put("ev", "report");
                    event.put("reports", "{" + quote(id.toString()) + ":[" + numbers + "]}");
                    return event;
                }
                if (kind.equals("cb") || kind.equals("report_text")) {
                    if (rest.isEmpty() || rest.charAt(0) != '"') {
                        return null;
                    }
                    StringBuilder second = new StringBuilder();
                    int stop = string(rest, 1, second);
                    if (stop < rest.length() && !rest.substring(stop).trim().isEmpty()) {
                        return null;
                    }
                    if (kind.equals("cb")) {
                        event.put("ev", "cb");
                        event.put("id", id.toString());
                        event.put("kind", second.toString());
                    } else {
                        event.put("ev", "report");
                        event.put("reports",
                            "{" + quote(id.toString()) + ":" + quote(second.toString()) + "}");
                    }
                    return event;
                }
                if (kind.equals("enter")) {
                    if (rest.isEmpty() || rest.charAt(0) != '"') {
                        return null;
                    }
                    StringBuilder typed = new StringBuilder();
                    int stop = string(rest, 1, typed);
                    if (stop < rest.length() && !rest.substring(stop).trim().isEmpty()) {
                        return null;
                    }
                    event.put("id", id.toString());
                    event.put("text", typed.toString());
                } else if (kind.equals("check") && words.length == 1
                           && (words[0].equals("true") || words[0].equals("false"))) {
                    event.put("id", id.toString());
                    event.put("checked", words[0]);
                } else if (kind.equals("pick") && words.length == 0) {
                    event.put("id", id.toString());
                } else if (kind.equals("choose") && words.length == 1) {
                    event.put("id", id.toString());
                    event.put("value", String.valueOf(Integer.parseInt(words[0])));
                } else if (kind.equals("click") && words.length == 0) {
                    event.put("id", id.toString());
                } else if (kind.equals("slide") && words.length == 1) {
                    event.put("id", id.toString());
                    event.put("value", String.valueOf(Integer.parseInt(words[0])));
                } else if (kind.equals("measured") && words.length == 1) {
                    event.put("id", id.toString());
                    event.put("width", String.valueOf(Double.parseDouble(words[0])));
                } else if ((kind.equals("mouse") || kind.equals("press") || kind.equals("release")
                            || kind.equals("move")) && words.length == 2) {
                    event.put("c", id.toString());
                    event.put("x", String.valueOf(Integer.parseInt(words[0])));
                    event.put("y", String.valueOf(Integer.parseInt(words[1])));
                } else {
                    return null;
                }
            }
        } catch (NumberFormatException error) {
            return null;
        }
        event.put("ev", kind);
        return event;
    }

    /** The events file, once main has returned: each line logged as it is
     *  delivered. */
    private static void deliverFile() {
        if (EVENTS == null || !new File(EVENTS).exists()) {
            return;
        }
        String all;
        try {
            all = new String(Files.readAllBytes(new File(EVENTS).toPath()), StandardCharsets.UTF_8);
        } catch (IOException error) {
            return;
        }
        for (String line : all.split("\n", -1)) {
            if (line.trim().isEmpty()) {
                continue;
            }
            writeLog("> " + line);
            Map<String, String> event = parseLine(line);
            if (event == null) {
                writeLog("! unknown event: " + line);
            } else {
                deliver(event);
            }
        }
    }

    /** The fields of one JSON object, each as its text: a string decoded,
     *  an object or array kept whole, anything else as written. */
    private static Map<String, String> parseEvent(String text) {
        Map<String, String> fields = new HashMap<String, String>();
        int i = 0;
        int n = text.length();
        while (i < n) {
            while (i < n && text.charAt(i) != '"') {
                i++;
            }
            if (i >= n) {
                break;
            }
            StringBuilder key = new StringBuilder();
            i = string(text, i + 1, key);
            while (i < n && (text.charAt(i) == ':' || Character.isWhitespace(text.charAt(i)))) {
                i++;
            }
            if (i < n && text.charAt(i) == '"') {
                StringBuilder value = new StringBuilder();
                i = string(text, i + 1, value);
                fields.put(key.toString(), value.toString());
            } else if (i < n && (text.charAt(i) == '{' || text.charAt(i) == '[')) {
                int stop = nestedEnd(text, i);
                fields.put(key.toString(), text.substring(i, stop));
                i = stop;
            } else {
                int start = i;
                while (i < n && ",} \t\r\n".indexOf(text.charAt(i)) < 0) {
                    i++;
                }
                fields.put(key.toString(), text.substring(start, i));
            }
        }
        return fields;
    }

    /** Reads a JSON string from just after its opening quote into out,
     *  answering where it ends. */
    private static int string(String text, int i, StringBuilder out) {
        int n = text.length();
        while (i < n && text.charAt(i) != '"') {
            char c = text.charAt(i);
            if (c == '\\' && i + 1 < n) {
                char next = text.charAt(i + 1);
                switch (next) {
                    case 'n': out.append('\n'); break;
                    case 't': out.append('\t'); break;
                    case 'r': out.append('\r'); break;
                    case 'b': out.append('\b'); break;
                    case 'f': out.append('\f'); break;
                    case 'u':
                        if (i + 5 < n) {
                            out.append((char) Integer.parseInt(text.substring(i + 2, i + 6), 16));
                            i += 4;
                        }
                        break;
                    default: out.append(next);
                }
                i += 2;
            } else {
                out.append(c);
                i++;
            }
        }
        return i + 1;
    }

    // --- the server ---

    /** The page's server: the commands sent so far, every page connected,
     *  and the events they have posted. */
    private static final class Hub {
        private final HttpServer server;
        private final List<Command> history = new ArrayList<Command>();
        private final List<String> pending = new ArrayList<String>();
        private final List<BlockingQueue<String>> clients = new ArrayList<BlockingQueue<String>>();
        private final BlockingQueue<Map<String, String>> events =
            new LinkedBlockingQueue<Map<String, String>>();
        private boolean batching = false;

        Hub(int port) {
            HttpServer made = null;
            try {
                made = HttpServer.create(
                    new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 16);
            } catch (IOException error) {
                refuse("tinyweb: cannot serve the page on port " + port + ": "
                    + error.getMessage());
            }
            server = made;
            server.setExecutor(Executors.newCachedThreadPool());
            server.createContext("/", new com.sun.net.httpserver.HttpHandler() {
                public void handle(HttpExchange exchange) throws IOException {
                    serve(exchange);
                }
            });
            server.start();
        }

        int port() {
            return server.getAddress().getPort();
        }

        /** Keeps a command for every page connected later, less what it
         *  makes invisible, and sends it to every page connected now --
         *  at once from main, and with the rest of its batch from a
         *  callback. */
        synchronized void send(Command command) {
            String op = command.op;
            boolean cmd = op.equals("cmd");
            boolean dropped = cmd && (command.mode == 3 || (command.mode == 2 && delivered));
            if (!dropped && !op.equals("frame_done") && !op.equals("event_done")) {
                List<Command> kept = new ArrayList<Command>();
                for (Command old : history) {
                    boolean hidden = (command.clears && old.canvas != null
                            && old.canvas.equals(command.canvas))
                        || (command.label != null && command.label.equals(old.label))
                        || (cmd && command.mode == 1 && old.op.equals("cmd")
                            && command.kind.equals(old.kind) && command.id.equals(old.id));
                    if (!hidden) {
                        kept.add(old);
                    }
                }
                kept.add(command);
                history.clear();
                history.addAll(kept);
            }
            pending.add(command.json());
            if (!batching) {
                flush();
            }
        }

        synchronized void flush() {
            if (pending.isEmpty()) {
                return;
            }
            String batch = "data: [" + String.join(",", pending) + "]\n\n";
            pending.clear();
            for (BlockingQueue<String> client : clients) {
                client.add(batch);
            }
        }

        synchronized BlockingQueue<String> connect() {
            BlockingQueue<String> client = new LinkedBlockingQueue<String>();
            if (!history.isEmpty()) {
                List<String> all = new ArrayList<String>();
                for (Command command : history) {
                    all.add(command.json());
                }
                client.add("data: [" + String.join(",", all) + "]\n\n");
            }
            clients.add(client);
            return client;
        }

        synchronized void disconnect(BlockingQueue<String> client) {
            clients.remove(client);
        }

        /** Forgets the `sdelay` the page has answered: a page connecting
         *  later is sent only one still waiting. */
        synchronized void answered(int id) {
            String key = Integer.toString(id);
            List<Command> kept = new ArrayList<Command>();
            for (Command old : history) {
                if (!(old.op.equals("sdelay") && key.equals(old.id))) {
                    kept.add(old);
                }
            }
            history.clear();
            history.addAll(kept);
        }

        /** Takes the events the pages post until the one answering
         *  `sdelay` number id, delivering the others as they come. */
        void waitFor(int id) {
            boolean was;
            synchronized (this) {
                was = batching;
            }
            String key = Integer.toString(id);
            try {
                while (true) {
                    Map<String, String> event;
                    try {
                        event = events.take();
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                    if ("sdelay".equals(event.get("ev"))) {
                        if (key.equals(event.get("id"))) {
                            synchronized (TinywebExternal.class) {
                                deliver(event);
                            }
                            answered(id);
                            return;
                        }
                        continue;
                    }
                    synchronized (this) {
                        batching = true;
                    }
                    synchronized (TinywebExternal.class) {
                        deliver(event);
                        TinywebExternal.send(new Command("event_done"));
                    }
                    System.out.flush();
                    flush();
                    synchronized (this) {
                        batching = was;
                    }
                }
            } finally {
                synchronized (this) {
                    batching = was;
                }
            }
        }

        /** Delivers every event the pages post, in order, until the
         *  program is stopped. */
        void deliverForever() {
            synchronized (this) {
                batching = true;
            }
            while (true) {
                Map<String, String> event;
                try {
                    event = events.take();
                } catch (InterruptedException error) {
                    return;
                }
                synchronized (TinywebExternal.class) {
                    deliver(event);
                    TinywebExternal.send(new Command("event_done"));
                }
                System.out.flush();
                flush();
            }
        }

        private void reply(HttpExchange exchange, int status, String kind, byte[] body)
                throws IOException {
            exchange.getResponseHeaders().set("Content-Type", kind);
            exchange.getResponseHeaders().set("Cache-Control", "no-store");
            exchange.sendResponseHeaders(status, body.length == 0 ? -1 : body.length);
            OutputStream out = exchange.getResponseBody();
            out.write(body);
            out.close();
        }

        private void serve(HttpExchange exchange) throws IOException {
            String path = exchange.getRequestURI().getPath();
            String method = exchange.getRequestMethod();
            if (method.equals("POST") && path.equals("/events")) {
                InputStream in = exchange.getRequestBody();
                ByteArrayOutputStream body = new ByteArrayOutputStream();
                byte[] chunk = new byte[4096];
                int got;
                while ((got = in.read(chunk)) > 0) {
                    body.write(chunk, 0, got);
                }
                events.add(parseEvent(new String(body.toByteArray(), StandardCharsets.UTF_8)));
                exchange.sendResponseHeaders(204, -1);
                exchange.close();
            } else if (!method.equals("GET")) {
                reply(exchange, 404, "text/plain", "not found\n".getBytes(StandardCharsets.UTF_8));
            } else if (path.equals("/") || path.equals("/index.html")) {
                reply(exchange, 200, "text/html; charset=utf-8",
                    String.join("", PAGE_HTML).getBytes(StandardCharsets.UTF_8));
            } else if (path.equals("/tinyweb_page.js")) {
                reply(exchange, 200, "text/javascript; charset=utf-8",
                    String.join("", PAGE_JS).getBytes(StandardCharsets.UTF_8));
            } else if (path.equals("/commands")) {
                stream(exchange);
            } else {
                File found = file(path);
                if (found == null) {
                    reply(exchange, 404, "text/plain",
                        "not found\n".getBytes(StandardCharsets.UTF_8));
                } else {
                    reply(exchange, 200, contentType(found.getName()),
                        Files.readAllBytes(found.toPath()));
                }
            }
        }

        private void stream(HttpExchange exchange) throws IOException {
            exchange.getResponseHeaders().set("Content-Type", "text/event-stream");
            exchange.getResponseHeaders().set("Cache-Control", "no-store");
            exchange.sendResponseHeaders(200, 0);
            OutputStream out = exchange.getResponseBody();
            BlockingQueue<String> client = connect();
            try {
                out.write(": tinyweb\n\n".getBytes(StandardCharsets.UTF_8));
                out.flush();
                while (true) {
                    out.write(client.take().getBytes(StandardCharsets.UTF_8));
                    out.flush();
                }
            } catch (IOException | InterruptedException error) {
                // The page has gone.
            } finally {
                disconnect(client);
                exchange.close();
            }
        }
    }

    /** The file a page asks for by `path`: beside where the program runs,
     *  and a library sample from tinyweb_assets/ beside this class. */
    private static File file(String path) {
        List<String> parts = new ArrayList<String>();
        for (String part : path.split("/")) {
            if (part.equals("..")) {
                return null;
            }
            if (!part.isEmpty() && !part.equals(".")) {
                parts.add(part);
            }
        }
        if (parts.isEmpty()) {
            return null;
        }
        String relative = String.join(File.separator, parts);
        List<File> places = new ArrayList<File>();
        places.add(new File(System.getProperty("user.dir")));
        if (parts.get(0).equals("tinyweb_assets")) {
            try {
                places.add(new File(TinywebExternal.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI()));
            } catch (Exception error) {
                // Only beside where the program runs, then.
            }
        }
        for (File place : places) {
            File candidate = new File(place, relative);
            if (candidate.isFile()) {
                return candidate;
            }
        }
        return null;
    }

    private static String contentType(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".html")) return "text/html; charset=utf-8";
        if (lower.endsWith(".js")) return "text/javascript; charset=utf-8";
        if (lower.endsWith(".css")) return "text/css; charset=utf-8";
        if (lower.endsWith(".json")) return "application/json";
        if (lower.endsWith(".wav")) return "audio/wav";
        if (lower.endsWith(".mp3")) return "audio/mpeg";
        if (lower.endsWith(".ogg")) return "audio/ogg";
        if (lower.endsWith(".png")) return "image/png";
        if (lower.endsWith(".jpg")) return "image/jpeg";
        if (lower.endsWith(".svg")) return "image/svg+xml";
        return "application/octet-stream";
    }

    // BEGIN tinyweb page
    // written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit
    private static final String[] PAGE_HTML = {
        "<!doctype html>\n",
        "<!-- The page a program serves after tinyweb.web_init: tinyweb_page.js\n",
        "     carries out the commands the program sends over /commands, and every\n",
        "     event is posted back to /events, in order. Each native\n",
        "     implementation carries a copy of this file, written into it by\n",
        "     tools/tinyweb/embed_page.py. See docs/libraries.md, \"tinyweb\". -->\n",
        "<html lang=\"en\">\n",
        "<head>\n",
        "<meta charset=\"utf-8\">\n",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
        "<title>tinyweb</title>\n",
        "<style>\n",
        "  body { margin: 0; padding: 16px; min-height: 100vh; box-sizing: border-box; }\n",
        "  .tinyweb-ended { margin-top: 12px; color: #666666; font-size: 14px; }\n",
        "</style>\n",
        "</head>\n",
        "<body>\n",
        "<script type=\"module\">\n",
        "import { mountPage } from \"./tinyweb_page.js\";\n",
        "\n",
        "// One event at a time, so the program sees them in the order they\n",
        "// happened.\n",
        "let posting = Promise.resolve();\n",
        "function post(event) {\n",
        "  posting = posting\n",
        "    .then(() => fetch(\"/events\", { method: \"POST\", body: JSON.stringify(event) }))\n",
        "    .catch(() => {});\n",
        "}\n",
        "\n",
        "const page = mountPage(document.body, post, { standalone: true });\n",
        "const stream = new EventSource(\"/commands\");\n",
        "stream.onmessage = (message) => page.receive(JSON.parse(message.data));\n",
        "stream.onerror = () => {\n",
        "  stream.close();\n",
        "  page.freeze();\n",
        "  const ended = document.createElement(\"div\");\n",
        "  ended.className = \"tinyweb-ended\";\n",
        "  ended.textContent = \"The program has stopped.\";\n",
        "  document.body.appendChild(ended);\n",
        "};\n",
        "</script>\n",
        "</body>\n",
        "</html>\n",
    };
    private static final String[] PAGE_JS = {
        "// tinyweb's page: the renderer that carries out the commands a program\n",
        "// sends and reports the events its reader causes. It is the one copy of\n",
        "// that code, used wherever a program talks to its page in commands:\n",
        "//\n",
        "//   - on an iweb page, where tinyweb_external_interpreter.js mounts it\n",
        "//     and calls it directly;\n",
        "//   - in the playground and the notebook, where the program runs on a\n",
        "//     worker and tools/webrun/assets/pages.js mounts it on the page;\n",
        "//   - on the page a compiled program serves after `web_init`, where\n",
        "//     tinyweb_page.html mounts it and the commands arrive from the\n",
        "//     program over HTTP. Each native implementation carries a copy of\n",
        "//     this file and of tinyweb_page.html, written into it by\n",
        "//     tools/tinyweb/embed_page.py.\n",
        "//\n",
        "// A command is a plain object such as {op: \"circle\", c, x, y, radius,\n",
        "// color}, and an event one such as {ev: \"click\", id}; see\n",
        "// docs/libraries.md, \"tinyweb\". The web implementation,\n",
        "// tinyweb_external_browser.js, does what this file does without the\n",
        "// commands in between. Keep the file ASCII: it is embedded in C.\n",
        "\n",
        "function now() {\n",
        "  return typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
        "}\n",
        "\n",
        "// BEGIN tinyweb style\n",
        "// The page's look: a theme, what the program changed of it for every\n",
        "// element of a kind, and what it changed of one element. A theme and a\n",
        "// kind's style are rules of a stylesheet of the page's own, scoped to the\n",
        "// element the page is mounted in, so the host page's own rules do not\n",
        "// reach in; one element's style is set on the element. This block is\n",
        "// copied into tinyweb_external_browser.js by tools/tinyweb/embed_page.py.\n",
        "\n",
        "// Each theme: CSS declarations for each place on the page (PLACES).\n",
        "const THEMES = {\n",
        "  light: {\n",
        "    page: { \"background\": \"#f6f6f4\", \"color\": \"#1d1f21\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
        "    box: { \"gap\": \"8px\" },\n",
        "    button: {\n",
        "      \"background\": \"#f0f2f5\", \"color\": \"#1f2328\", \"border\": \"1px solid #d4d8de\",\n",
        "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
        "    },\n",
        "    \"button:hover\": { \"border-color\": \"#2f5fc4\" },\n",
        "    \"button:active\": { \"background\": \"#e3e7ec\" },\n",
        "    \"slider input\": { \"accent-color\": \"#2f5fc4\" },\n",
        "    canvas: { \"border\": \"1px solid #c9ced6\" },\n",
        "  },\n",
        "  dark: {\n",
        "    page: { \"background\": \"#1d1f21\", \"color\": \"#e6e6e6\", \"font-family\": \"system-ui, sans-serif\", \"font-size\": \"15px\" },\n",
        "    box: { \"gap\": \"8px\" },\n",
        "    button: {\n",
        "      \"background\": \"#2f333a\", \"color\": \"#e6e6e6\", \"border\": \"1px solid #454a52\",\n",
        "      \"border-radius\": \"5px\", \"padding\": \"5px 10px\", \"font-family\": \"inherit\", \"font-size\": \"14px\",\n",
        "    },\n",
        "    \"button:hover\": { \"border-color\": \"#7aa2f7\" },\n",
        "    \"button:active\": { \"background\": \"#3a3f47\" },\n",
        "    \"slider input\": { \"accent-color\": \"#7aa2f7\" },\n",
        "    canvas: { \"border\": \"1px solid #454a52\" },\n",
        "  },\n",
        "  plain: {\n",
        "    page: { \"background\": \"#ffffff\", \"color\": \"#000000\", \"font-family\": \"system-ui, sans-serif\" },\n",
        "    box: { \"gap\": \"8px\" },\n",
        "    canvas: { \"border\": \"1px solid #8884\" },\n",
        "  },\n",
        "  paper: {\n",
        "    page: { \"background\": \"#fbf6ea\", \"color\": \"#3b3024\", \"font-family\": \"Georgia, 'Times New Roman', serif\", \"font-size\": \"16px\" },\n",
        "    box: { \"gap\": \"10px\" },\n",
        "    button: {\n",
        "      \"background\": \"#fffdf7\", \"color\": \"#3b3024\", \"border\": \"1px solid #3b3024\",\n",
        "      \"border-radius\": \"2px\", \"padding\": \"5px 14px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
        "    },\n",
        "    \"button:hover\": { \"background\": \"#f1e8d2\" },\n",
        "    \"button:active\": { \"background\": \"#e6d9bb\" },\n",
        "    \"slider input\": { \"accent-color\": \"#8a5a2b\" },\n",
        "    canvas: { \"border\": \"1px solid #3b302466\" },\n",
        "  },\n",
        "  retro: {\n",
        "    page: { \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"font-family\": \"'Courier New', monospace\", \"font-size\": \"15px\" },\n",
        "    box: { \"gap\": \"10px\" },\n",
        "    button: {\n",
        "      \"background\": \"#0b1a0b\", \"color\": \"#39ff6a\", \"border\": \"2px solid #39ff6a\",\n",
        "      \"border-radius\": \"0\", \"padding\": \"4px 12px\", \"font-family\": \"inherit\", \"font-size\": \"15px\",\n",
        "    },\n",
        "    \"button:hover\": { \"background\": \"#133313\" },\n",
        "    \"button:active\": { \"background\": \"#39ff6a\", \"color\": \"#0b1a0b\" },\n",
        "    \"slider input\": { \"accent-color\": \"#39ff6a\" },\n",
        "    canvas: { \"border\": \"2px solid #39ff6a\" },\n",
        "  },\n",
        "};\n",
        "\n",
        "// Where each place is, after the page's scope.\n",
        "const PLACES = {\n",
        "  page: \"\",\n",
        "  box: \" > .tinyweb-page\",\n",
        "  button: \" .tinyweb-page button\",\n",
        "  \"button:hover\": \" .tinyweb-page button:hover\",\n",
        "  \"button:active\": \" .tinyweb-page button:active\",\n",
        "  label: \" .tinyweb-page .tinyweb-label\",\n",
        "  slider: \" .tinyweb-page .tinyweb-slider\",\n",
        "  \"slider input\": \" .tinyweb-page .tinyweb-slider input\",\n",
        "  canvas: \" .tinyweb-page canvas\",\n",
        "};\n",
        "\n",
        "// What each property a program names is in CSS.\n",
        "const PROPERTIES = {\n",
        "  background: \"background\", color: \"color\", border: \"border\", radius: \"border-radius\",\n",
        "  font: \"font-family\", size: \"font-size\", padding: \"padding\", gap: \"gap\",\n",
        "  accent: \"accent-color\", width: \"width\", height: \"height\", align: \"align-items\",\n",
        "  weight: \"font-weight\",\n",
        "};\n",
        "\n",
        "// What an `align` a program names is in CSS.\n",
        "const ALIGNMENTS = { left: \"flex-start\", center: \"center\", right: \"flex-end\" };\n",
        "\n",
        "// The place a kind's property goes. String -> String -> String\n",
        "function placeOf(kind, property) {\n",
        "  if (kind === \"page\") return property === \"gap\" || property === \"align\" ? \"box\" : \"page\";\n",
        "  if (kind === \"slider\") return property === \"accent\" || property === \"width\" ? \"slider input\" : \"slider\";\n",
        "  return kind;\n",
        "}\n",
        "\n",
        "let styledPages = 0;\n",
        "\n",
        "// Gives the page mounted in `host` a stylesheet of its own, in the\n",
        "// default theme. Element -> Element -> Style\n",
        "function styled(host, box) {\n",
        "  styledPages += 1;\n",
        "  const sheet = document.createElement(\"style\");\n",
        "  sheet.setAttribute(\"data-tinyweb-style\", String(styledPages));\n",
        "  const style = { host, box, sheet, rules: null, elements: new Map(), name: String(styledPages) };\n",
        "  host.setAttribute(\"data-tinyweb-page\", style.name);\n",
        "  (document.head || document.body).appendChild(sheet);\n",
        "  setTheme(style, \"light\");\n",
        "  return style;\n",
        "}\n",
        "\n",
        "// Writes the stylesheet from the rules. Style -> ()\n",
        "function writeSheet(style) {\n",
        "  // The scope three times over, so the host page's rules for a button or\n",
        "  // a body do not outweigh the page's own.\n",
        "  const scope = `[data-tinyweb-page=\"${style.name}\"]`.repeat(3);\n",
        "  const text = [];\n",
        "  for (const place of Object.keys(PLACES)) {\n",
        "    const declarations = style.rules[place];\n",
        "    if (!declarations || Object.keys(declarations).length === 0) continue;\n",
        "    const body = Object.entries(declarations).map(([k, v]) => `${k}: ${v};`).join(\" \");\n",
        "    text.push(`${scope}${PLACES[place]} { ${body} }`);\n",
        "  }\n",
        "  style.sheet.textContent = text.join(\"\\n\");\n",
        "}\n",
        "\n",
        "// Puts the page in a theme, forgetting what was changed for each kind.\n",
        "// An unknown name changes nothing. Style -> String -> ()\n",
        "function setTheme(style, name) {\n",
        "  const theme = THEMES[name];\n",
        "  if (!theme) return;\n",
        "  style.rules = {};\n",
        "  for (const [place, declarations] of Object.entries(theme)) {\n",
        "    style.rules[place] = { ...declarations };\n",
        "  }\n",
        "  writeSheet(style);\n",
        "}\n",
        "\n",
        "// Remembers a page element by its id, so that its own style can be set.\n",
        "// Style -> Int -> Element -> ()\n",
        "function remember(style, id, element) {\n",
        "  style.elements.set(id, element);\n",
        "}\n",
        "\n",
        "// Carries out one style command: a theme, a property of every element\n",
        "// of a kind, or a property of the element `id` (kind \"element\").\n",
        "// Style -> Int -> String -> String -> String -> ()\n",
        "function applyStyle(style, id, kind, property, given) {\n",
        "  if (kind === \"theme\") {\n",
        "    setTheme(style, given);\n",
        "    return;\n",
        "  }\n",
        "  const css = PROPERTIES[property];\n",
        "  if (!css) return;\n",
        "  const value = property === \"align\" ? ALIGNMENTS[given] || \"flex-start\" : given;\n",
        "  if (kind === \"page\" && property === \"align\") {\n",
        "    // The box says where its elements stand on the element itself.\n",
        "    style.box.style.setProperty(css, value);\n",
        "    return;\n",
        "  }\n",
        "  if (kind === \"element\") {\n",
        "    let element = style.elements.get(id);\n",
        "    if (!element) return;\n",
        "    // A slider's own properties are its input's; the rest are its row's.\n",
        "    if (element.tagName === \"INPUT\" && property !== \"accent\" && property !== \"width\") {\n",
        "      element = element.parentNode;\n",
        "    }\n",
        "    element.style.setProperty(css, value);\n",
        "    return;\n",
        "  }\n",
        "  const place = placeOf(kind, property);\n",
        "  if (!(place in PLACES)) return;\n",
        "  if (!style.rules[place]) style.rules[place] = {};\n",
        "  style.rules[place][css] = value;\n",
        "  writeSheet(style);\n",
        "}\n",
        "\n",
        "// Takes the page's look off the element it was mounted in. Style -> ()\n",
        "function unstyled(style) {\n",
        "  style.sheet.remove();\n",
        "  if (style.host.getAttribute(\"data-tinyweb-page\") === style.name) {\n",
        "    style.host.removeAttribute(\"data-tinyweb-page\");\n",
        "  }\n",
        "}\n",
        "// What the splash screen says until the program sets it.\n",
        "const SPLASH_TEXT = \"Click to Start\";\n",
        "\n",
        "// The splash screen: the whole window dimmed, and `text` in white in\n",
        "// its middle under a play sign. String -> Element\n",
        "function splashScreen(text) {\n",
        "  const screen = document.createElement(\"div\");\n",
        "  screen.className = \"tinyweb-splash\";\n",
        "  screen.setAttribute(\"role\", \"button\");\n",
        "  screen.style.cssText =\n",
        "    \"position:fixed;inset:0;z-index:2147483647;display:flex;flex-direction:column;\" +\n",
        "    \"align-items:center;justify-content:center;gap:24px;background:rgba(0,0,0,0.62);\" +\n",
        "    \"color:#ffffff;cursor:pointer;user-select:none;font-family:system-ui,sans-serif\";\n",
        "  const ring = document.createElement(\"div\");\n",
        "  ring.style.cssText =\n",
        "    \"width:88px;height:88px;border-radius:50%;border:3px solid #ffffff;display:flex;\" +\n",
        "    \"align-items:center;justify-content:center;box-shadow:0 0 36px rgba(255,255,255,0.35)\";\n",
        "  const sign = document.createElement(\"div\");\n",
        "  sign.style.cssText =\n",
        "    \"width:0;height:0;margin-left:9px;border-top:19px solid transparent;\" +\n",
        "    \"border-bottom:19px solid transparent;border-left:32px solid #ffffff\";\n",
        "  ring.appendChild(sign);\n",
        "  const words = document.createElement(\"div\");\n",
        "  words.textContent = text;\n",
        "  words.style.cssText =\n",
        "    \"font-size:34px;font-weight:600;letter-spacing:0.03em;text-align:center;\" +\n",
        "    \"padding:0 24px;text-shadow:0 2px 14px rgba(0,0,0,0.6)\";\n",
        "  screen.append(ring, words);\n",
        "  return screen;\n",
        "}\n",
        "\n",
        "// Whether the reader has already done something on this page, which is\n",
        "// all a browser asks before it plays a sound. () -> Bool\n",
        "function readerActive() {\n",
        "  return Boolean(globalThis.navigator?.userActivation?.hasBeenActive);\n",
        "}\n",
        "// --- drawing (step 1) ---\n",
        "\n",
        "// A shape's numbers: the words tinyweb.pyk wrote, as numbers.\n",
        "function numbersOf(text) {\n",
        "  return text === \"\" ? [] : text.split(\" \").map(Number);\n",
        "}\n",
        "\n",
        "// A rectangle with rounded corners, as a path. Context -> ... -> ()\n",
        "function roundedRect(g, x, y, w, h, r) {\n",
        "  const k = Math.max(0, Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2));\n",
        "  g.moveTo(x + k, y);\n",
        "  g.arcTo(x + w, y, x + w, y + h, k);\n",
        "  g.arcTo(x + w, y + h, x, y + h, k);\n",
        "  g.arcTo(x, y + h, x, y, k);\n",
        "  g.arcTo(x, y, x + w, y, k);\n",
        "  g.closePath();\n",
        "}\n",
        "\n",
        "// The outline of one shape, added to the context's path. Whether a filled\n",
        "// arc is a slice from its centre is `slice`'s.\n",
        "// Context -> String -> [Float] -> Bool -> ()\n",
        "function shapePath(g, kind, n, slice) {\n",
        "  switch (kind) {\n",
        "    case \"rect\":\n",
        "      if (n[4] > 0) roundedRect(g, n[0], n[1], n[2], n[3], n[4]);\n",
        "      else g.rect(n[0], n[1], n[2], n[3]);\n",
        "      break;\n",
        "    case \"circle\":\n",
        "      g.arc(n[0], n[1], Math.max(0, n[2]), 0, 2 * Math.PI);\n",
        "      break;\n",
        "    case \"ellipse\":\n",
        "      g.ellipse(n[0], n[1], Math.max(0, n[2]), Math.max(0, n[3]), 0, 0, 2 * Math.PI);\n",
        "      break;\n",
        "    case \"arc\":\n",
        "      if (slice) g.moveTo(n[0], n[1]);\n",
        "      g.arc(n[0], n[1], Math.max(0, n[2]), n[3], n[4]);\n",
        "      if (slice) g.closePath();\n",
        "      break;\n",
        "    case \"line\":\n",
        "      g.moveTo(n[0], n[1]);\n",
        "      g.lineTo(n[2], n[3]);\n",
        "      break;\n",
        "    case \"lines\":\n",
        "      for (let i = 0; i + 3 < n.length; i += 4) {\n",
        "        g.moveTo(n[i], n[i + 1]);\n",
        "        g.lineTo(n[i + 2], n[i + 3]);\n",
        "      }\n",
        "      break;\n",
        "    case \"curve\":\n",
        "      g.moveTo(n[0], n[1]);\n",
        "      g.quadraticCurveTo(n[2], n[3], n[4], n[5]);\n",
        "      break;\n",
        "    case \"bezier\":\n",
        "      g.moveTo(n[0], n[1]);\n",
        "      g.bezierCurveTo(n[2], n[3], n[4], n[5], n[6], n[7]);\n",
        "      break;\n",
        "    case \"polygon\":\n",
        "    case \"path\":\n",
        "      for (let i = 0; i + 1 < n.length; i += 2) {\n",
        "        if (i === 0) g.moveTo(n[i], n[i + 1]);\n",
        "        else g.lineTo(n[i], n[i + 1]);\n",
        "      }\n",
        "      if (kind === \"polygon\") g.closePath();\n",
        "      break;\n",
        "  }\n",
        "}\n",
        "\n",
        "// The gradients a canvas has been given, by the text that describes\n",
        "// them, so a frame drawing the same one again does not make it again.\n",
        "const GRADIENTS_KEPT = 64;\n",
        "\n",
        "// What a color means on a context: a CSS color as it is, and a gradient\n",
        "// tinyweb.pyk described -- \"linear-gradient(x1 y1 x2 y2); 0 red; 1 blue\",\n",
        "// \"radial-gradient(x1 y1 r1 x2 y2 r2); ...\", \"conic-gradient(x y\n",
        "// angle); ...\" -- as the gradient. Context -> Entry? -> String -> Paint\n",
        "function paint(g, entry, color) {\n",
        "  const open = color.indexOf(\"(\");\n",
        "  if (open < 0 || !color.slice(0, open).endsWith(\"-gradient\")) return color;\n",
        "  const close = color.indexOf(\")\", open);\n",
        "  if (close < 0 || color.slice(close + 1, close + 2) !== \";\") return color;\n",
        "  const kept = entry ? entry.gradients : null;\n",
        "  if (kept && kept.has(color)) return kept.get(color);\n",
        "  const kind = color.slice(0, open);\n",
        "  const n = numbersOf(color.slice(open + 1, close).trim());\n",
        "  let gradient;\n",
        "  if (kind === \"linear-gradient\") gradient = g.createLinearGradient(n[0], n[1], n[2], n[3]);\n",
        "  else if (kind === \"radial-gradient\")\n",
        "    gradient = g.createRadialGradient(n[0], n[1], Math.max(0, n[2]), n[3], n[4], Math.max(0, n[5]));\n",
        "  else if (kind === \"conic-gradient\" && typeof g.createConicGradient === \"function\")\n",
        "    gradient = g.createConicGradient(n[2], n[0], n[1]);\n",
        "  else return \"#000000\";\n",
        "  // A stop's color may itself hold brackets and commas, \"rgba(0, 0, 0, 0.5)\",\n",
        "  // but never a semicolon.\n",
        "  for (const stop of color.slice(close + 2).split(\";\")) {\n",
        "    const text = stop.trim();\n",
        "    const space = text.indexOf(\" \");\n",
        "    if (space < 0) continue;\n",
        "    const at = Math.min(1, Math.max(0, Number(text.slice(0, space))));\n",
        "    try {\n",
        "      gradient.addColorStop(at, text.slice(space + 1).trim());\n",
        "    } catch (error) {\n",
        "      // A stop whose color the browser does not read is left out.\n",
        "    }\n",
        "  }\n",
        "  if (kept) {\n",
        "    if (kept.size >= GRADIENTS_KEPT) kept.delete(kept.keys().next().value);\n",
        "    kept.set(color, gradient);\n",
        "  }\n",
        "  return gradient;\n",
        "}\n",
        "\n",
        "// Draws one shape: filled with `color` and outlined with `outline`, each\n",
        "// unless it is \"\", at `alpha`, in the canvas's line style. The numbers\n",
        "// are the kind's own (see tinyweb.pyk), as words or as an array;\n",
        "// \"erase\" makes its rectangle transparent, and \"circles\" draws each\n",
        "// circle on its own. Context -> Entry? -> String -> Numbers -> ... -> ()\n",
        "function drawShape(g, entry, kind, numbers, color, outline, width, alpha) {\n",
        "  const n = typeof numbers === \"string\" ? numbersOf(numbers) : numbers;\n",
        "  if (kind === \"erase\") {\n",
        "    g.clearRect(n[0], n[1], n[2], n[3]);\n",
        "    return;\n",
        "  }\n",
        "  const before = g.globalAlpha;\n",
        "  g.globalAlpha = before * alpha;\n",
        "  if (kind === \"circles\") {\n",
        "    // Each circle on its own, so where two overlap both show.\n",
        "    if (color !== \"\") g.fillStyle = paint(g, entry, color);\n",
        "    if (outline !== \"\") {\n",
        "      g.strokeStyle = paint(g, entry, outline);\n",
        "      g.lineWidth = width;\n",
        "    }\n",
        "    for (let i = 0; i + 2 < n.length; i += 3) {\n",
        "      g.beginPath();\n",
        "      g.arc(n[i], n[i + 1], Math.max(0, n[i + 2]), 0, 2 * Math.PI);\n",
        "      if (color !== \"\") g.fill();\n",
        "      if (outline !== \"\") g.stroke();\n",
        "    }\n",
        "    g.globalAlpha = before;\n",
        "    return;\n",
        "  }\n",
        "  g.beginPath();\n",
        "  shapePath(g, kind, n, color !== \"\");\n",
        "  if (color !== \"\") {\n",
        "    g.fillStyle = paint(g, entry, color);\n",
        "    g.fill();\n",
        "  }\n",
        "  if (outline !== \"\") {\n",
        "    g.strokeStyle = paint(g, entry, outline);\n",
        "    g.lineWidth = width;\n",
        "    g.stroke();\n",
        "  }\n",
        "  g.globalAlpha = before;\n",
        "}\n",
        "\n",
        "// The font text is written in. Int -> String -> Bool -> String\n",
        "function fontOf(size, font, bold) {\n",
        "  return `${bold ? \"bold \" : \"\"}${size}px ${font === \"\" ? \"system-ui, sans-serif\" : font}`;\n",
        "}\n",
        "\n",
        "// Writes text at (x, y): its left end there, its middle or its right end,\n",
        "// as `align` says, and its top, middle, alphabetic baseline or bottom,\n",
        "// as `baseline` says. An `outline` is drawn round the letters first.\n",
        "// Context -> Entry? -> ... -> ()\n",
        "function drawText(g, entry, x, y, words, color, size, font, align, baseline, bold, outline,\n",
        "  outlineWidth, alpha) {\n",
        "  const before = g.globalAlpha;\n",
        "  g.globalAlpha = before * alpha;\n",
        "  g.font = fontOf(size, font, bold);\n",
        "  g.textBaseline = [\"top\", \"middle\", \"alphabetic\", \"bottom\"].includes(baseline) ? baseline : \"top\";\n",
        "  g.textAlign = align === \"center\" || align === \"right\" ? align : \"left\";\n",
        "  if (outline !== \"\") {\n",
        "    g.strokeStyle = paint(g, entry, outline);\n",
        "    g.lineWidth = outlineWidth;\n",
        "    g.strokeText(words, x, y);\n",
        "  }\n",
        "  if (color !== \"\") {\n",
        "    g.fillStyle = paint(g, entry, color);\n",
        "    g.fillText(words, x, y);\n",
        "  }\n",
        "  g.globalAlpha = before;\n",
        "}\n",
        "\n",
        "// How wide `words` is written in that font, in pixels.\n",
        "// String -> Int -> String -> Bool -> Float\n",
        "function textWidth(words, size, font, bold) {\n",
        "  if (typeof document === \"undefined\") return 0;\n",
        "  if (!textWidth.context) textWidth.context = document.createElement(\"canvas\").getContext(\"2d\");\n",
        "  const g = textWidth.context;\n",
        "  if (!g) return 0;\n",
        "  g.font = fontOf(size, font, bold);\n",
        "  return g.measureText(words).width;\n",
        "}\n",
        "\n",
        "// The line style a canvas starts with: round ends and corners, no dashes.\n",
        "// Context -> ()\n",
        "function plainLines(g) {\n",
        "  g.lineCap = \"round\";\n",
        "  g.lineJoin = \"round\";\n",
        "  if (typeof g.setLineDash === \"function\") g.setLineDash([]);\n",
        "  g.lineDashOffset = 0;\n",
        "}\n",
        "\n",
        "// Changes what the next drawing on a canvas is drawn with. `entry` keeps\n",
        "// the canvas's pixel ratio and how many `push`es are open.\n",
        "// Context -> Entry -> String -> String -> String -> ()\n",
        "function canvasState(g, entry, kind, value, numbers) {\n",
        "  const n = numbersOf(numbers);\n",
        "  switch (kind) {\n",
        "    case \"translate\":\n",
        "      g.translate(n[0], n[1]);\n",
        "      break;\n",
        "    case \"rotate\":\n",
        "      g.rotate(n[0]);\n",
        "      break;\n",
        "    case \"scale\":\n",
        "      g.scale(n[0], n[1]);\n",
        "      break;\n",
        "    case \"push\":\n",
        "      g.save();\n",
        "      entry.depth += 1;\n",
        "      break;\n",
        "    case \"pop\":\n",
        "      if (entry.depth > 0) {\n",
        "        g.restore();\n",
        "        entry.depth -= 1;\n",
        "      }\n",
        "      break;\n",
        "    case \"reset\":\n",
        "      g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
        "      break;\n",
        "    case \"shadow\":\n",
        "      g.shadowColor = value === \"\" ? \"transparent\" : value;\n",
        "      g.shadowBlur = value === \"\" ? 0 : n[0];\n",
        "      g.shadowOffsetX = value === \"\" ? 0 : n[1];\n",
        "      g.shadowOffsetY = value === \"\" ? 0 : n[2];\n",
        "      break;\n",
        "    case \"blend\":\n",
        "      g.globalCompositeOperation = value === \"add\" ? \"lighter\" : \"source-over\";\n",
        "      break;\n",
        "    case \"line_style\": {\n",
        "      // value: the ends and the corners; numbers: the dash offset, then\n",
        "      // the lengths of the dashes and the gaps.\n",
        "      const [cap, join] = value.split(\" \");\n",
        "      g.lineCap = [\"butt\", \"round\", \"square\"].includes(cap) ? cap : \"round\";\n",
        "      g.lineJoin = [\"miter\", \"round\", \"bevel\"].includes(join) ? join : \"round\";\n",
        "      if (typeof g.setLineDash === \"function\") g.setLineDash(n.slice(1));\n",
        "      g.lineDashOffset = n.length > 0 ? n[0] : 0;\n",
        "      break;\n",
        "    }\n",
        "    case \"clip\":\n",
        "      // value: the kind of shape the drawing is kept inside.\n",
        "      g.beginPath();\n",
        "      shapePath(g, value, n, false);\n",
        "      g.clip();\n",
        "      break;\n",
        "  }\n",
        "}\n",
        "\n",
        "// A canvas as it starts: every `push` closed, no transformation but the\n",
        "// pixel ratio, no shadow, no blending, no clipping and plain lines. What\n",
        "// `clear` begins with. Context -> Entry -> ()\n",
        "function freshState(g, entry) {\n",
        "  while (entry.depth > 0) {\n",
        "    g.restore();\n",
        "    entry.depth -= 1;\n",
        "  }\n",
        "  g.setTransform(entry.ratio, 0, 0, entry.ratio, 0, 0);\n",
        "  g.globalAlpha = 1;\n",
        "  g.shadowColor = \"transparent\";\n",
        "  g.shadowBlur = 0;\n",
        "  g.shadowOffsetX = 0;\n",
        "  g.shadowOffsetY = 0;\n",
        "  g.globalCompositeOperation = \"source-over\";\n",
        "  plainLines(g);\n",
        "}\n",
        "\n",
        "// Starts loading a picture: beside the page first, then among the ones\n",
        "// tinyweb ships beside `base`. Answers what `drawPicture` draws once it\n",
        "// has loaded; `loading` is true until it has loaded or failed, and then\n",
        "// each function in `settled` is called. String -> String -> Picture\n",
        "function loadPicture(name, base) {\n",
        "  const picture = { element: null, ready: false, retried: false, loading: false, settled: [] };\n",
        "  if (typeof Image === \"undefined\") return picture;\n",
        "  const element = new Image();\n",
        "  picture.element = element;\n",
        "  picture.loading = true;\n",
        "  const settle = () => {\n",
        "    picture.loading = false;\n",
        "    for (const then of picture.settled.splice(0)) then();\n",
        "  };\n",
        "  element.onload = () => {\n",
        "    picture.ready = true;\n",
        "    settle();\n",
        "  };\n",
        "  element.onerror = () => {\n",
        "    if (picture.retried) {\n",
        "      console.error(`tinyweb: cannot load the picture ${name}`);\n",
        "      settle();\n",
        "      return;\n",
        "    }\n",
        "    picture.retried = true;\n",
        "    element.src = new URL(\"tinyweb_assets/\" + name, base).href;\n",
        "  };\n",
        "  element.src = new URL(name, document.baseURI).href;\n",
        "  return picture;\n",
        "}\n",
        "\n",
        "// Draws a picture that has loaded; one still loading is not drawn.\n",
        "// Context -> Picture? -> ... -> ()\n",
        "function drawPicture(g, picture, x, y, width, height, alpha) {\n",
        "  if (!picture || !picture.ready) return;\n",
        "  const before = g.globalAlpha;\n",
        "  g.globalAlpha = before * alpha;\n",
        "  g.drawImage(picture.element, x, y, width, height);\n",
        "  g.globalAlpha = before;\n",
        "}\n",
        "\n",
        "// Keeps the pointer's moves and its release coming to the canvas it went\n",
        "// down on, wherever it goes. Element -> Event -> ()\n",
        "function capture(element, event) {\n",
        "  try {\n",
        "    if (element.setPointerCapture) element.setPointerCapture(event.pointerId);\n",
        "  } catch (error) {\n",
        "    // A pointer the browser does not know of, as a test's is, is not held.\n",
        "  }\n",
        "}\n",
        "\n",
        "// --- bitmaps (step 5) ---\n",
        "\n",
        "// The bytes of a bitmap's rectangle as they arrive: a base64 string from\n",
        "// a program on another host, or the bytes themselves. Data -> Uint8ClampedArray\n",
        "function bitmapBytes(data) {\n",
        "  if (typeof data !== \"string\") {\n",
        "    return ArrayBuffer.isView(data)\n",
        "      ? new Uint8ClampedArray(data.buffer, data.byteOffset, data.byteLength)\n",
        "      : new Uint8ClampedArray(data);\n",
        "  }\n",
        "  const text = atob(data);\n",
        "  const bytes = new Uint8ClampedArray(text.length);\n",
        "  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);\n",
        "  return bytes;\n",
        "}\n",
        "\n",
        "// A bitmap as the page keeps it: a canvas of its own, its pixels.\n",
        "// Int -> Int -> Surface\n",
        "function bitmapSurface(width, height) {\n",
        "  const element = document.createElement(\"canvas\");\n",
        "  element.width = Math.max(1, width);\n",
        "  element.height = Math.max(1, height);\n",
        "  return { element, context: element.getContext(\"2d\"), width, height };\n",
        "}\n",
        "\n",
        "// Puts the rectangle (rx, ry, rw, rh) of a bitmap's pixels on its\n",
        "// surface. Surface -> Int -> Int -> Int -> Int -> Data -> ()\n",
        "function updateSurface(surface, rx, ry, rw, rh, data) {\n",
        "  if (rw <= 0 || rh <= 0) return;\n",
        "  const bytes = bitmapBytes(data);\n",
        "  if (bytes.length !== rw * rh * 4) return;\n",
        "  surface.context.putImageData(new ImageData(bytes, rw, rh), rx, ry);\n",
        "}\n",
        "\n",
        "// Draws a bitmap's surface with its top left corner at (x, y), each pixel\n",
        "// `scale` pixels across: sharp squares when it grows, smooth when it\n",
        "// shrinks. Context -> Surface -> Float -> Float -> Float -> ()\n",
        "function drawSurface(g, surface, x, y, scale) {\n",
        "  const smoothing = g.imageSmoothingEnabled;\n",
        "  g.imageSmoothingEnabled = scale < 1;\n",
        "  g.drawImage(surface.element, x, y, surface.width * scale, surface.height * scale);\n",
        "  g.imageSmoothingEnabled = smoothing;\n",
        "}\n",
        "\n",
        "// A box whose elements go side by side, wrapping where the page is too\n",
        "// narrow for them, or one below another. String -> Bool -> Element\n",
        "function rowElement(id, across = true) {\n",
        "  const row = document.createElement(\"div\");\n",
        "  row.className = across ? \"tinyweb-row\" : \"tinyweb-column\";\n",
        "  row.setAttribute(\"data-tinyweb-id\", id);\n",
        "  row.style.cssText = across\n",
        "    ? \"display:flex;flex-direction:row;flex-wrap:wrap;align-items:center;gap:8px\"\n",
        "    : \"display:flex;flex-direction:column;align-items:flex-start;gap:6px\";\n",
        "  return row;\n",
        "}\n",
        "\n",
        "// --- widgets (step 2) ---\n",
        "\n",
        "// A checkbox or a radio button with its title beside it: the row, and\n",
        "// the input in it. String -> String -> String -> Bool -> (Element, Element)\n",
        "function choiceRow(type, id, title, checked) {\n",
        "  const row = document.createElement(\"label\");\n",
        "  row.className = type === \"checkbox\" ? \"tinyweb-check\" : \"tinyweb-radio\";\n",
        "  row.style.cssText = \"display:flex;align-items:center;gap:6px\";\n",
        "  const input = document.createElement(\"input\");\n",
        "  input.type = type;\n",
        "  input.setAttribute(\"data-tinyweb-id\", id);\n",
        "  input.checked = checked;\n",
        "  const text = document.createElement(\"span\");\n",
        "  text.textContent = title;\n",
        "  row.append(input, text);\n",
        "  return { row, input };\n",
        "}\n",
        "\n",
        "// A dropdown of the options, one per line of `options`, the one at\n",
        "// `chosen` chosen. String -> String -> Int -> Element\n",
        "function choiceElement(id, options, chosen) {\n",
        "  const select = document.createElement(\"select\");\n",
        "  select.className = \"tinyweb-choice\";\n",
        "  select.setAttribute(\"data-tinyweb-id\", id);\n",
        "  options.split(\"\\n\").forEach((text, position) => {\n",
        "    const option = document.createElement(\"option\");\n",
        "    option.value = String(position);\n",
        "    option.textContent = text;\n",
        "    select.appendChild(option);\n",
        "  });\n",
        "  select.value = String(chosen);\n",
        "  return select;\n",
        "}\n",
        "\n",
        "// A line to type text into. String -> String -> Element\n",
        "function textInputElement(id, placeholder) {\n",
        "  const input = document.createElement(\"input\");\n",
        "  input.type = \"text\";\n",
        "  input.className = \"tinyweb-text\";\n",
        "  input.setAttribute(\"data-tinyweb-id\", id);\n",
        "  input.placeholder = placeholder;\n",
        "  return input;\n",
        "}\n",
        "\n",
        "// A field for a whole number from `low` to `high`. ... -> Element\n",
        "function numberElement(id, low, high, value) {\n",
        "  const input = document.createElement(\"input\");\n",
        "  input.type = \"number\";\n",
        "  input.className = \"tinyweb-number\";\n",
        "  input.setAttribute(\"data-tinyweb-id\", id);\n",
        "  input.min = String(low);\n",
        "  input.max = String(high);\n",
        "  input.value = String(value);\n",
        "  return input;\n",
        "}\n",
        "\n",
        "// Whether a key press is the reader typing into a field, which the page\n",
        "// does not report as a key. Event -> Bool\n",
        "function typedInField(event) {\n",
        "  const target = event.target;\n",
        "  return !!target && typeof target.tagName === \"string\"\n",
        "    && (target.tagName === \"SELECT\"\n",
        "      || target.tagName === \"TEXTAREA\"\n",
        "      || (target.tagName === \"INPUT\" && (target.type === \"text\" || target.type === \"number\")));\n",
        "}\n",
        "\n",
        "// --- the engine: sound, the beat, timers and changing the page ---\n",
        "// What every `cmd` command does, the same for the page a program sends\n",
        "// commands to and for web, which calls it directly: makeEngine(host)\n",
        "// answers {command(cmd), reports(withSound), frozen(), held(cmd), close()}.\n",
        "// `host` is what the engine needs of the page:\n",
        "//   audio() -- the AudioContext once sound has started, or null\n",
        "//   startAudio() -- starts sound, where the reader has already done something\n",
        "//   clock() -- the page's clock, in seconds\n",
        "//   toAudio(t) -- a time on the page's clock as a time on the audio clock\n",
        "//   thaw(t) -- the clock goes on from `t` after a pause\n",
        "//   sample(id) -- a sample's loading, a Promise of its AudioBuffer (or null)\n",
        "//   addSample(id, loading) -- a sample loaded another way: a file the reader chose\n",
        "//   element(id) -- an element by its identifier; forget(id) when it is removed\n",
        "//   remember(id, element), place(element) -- a new element, put on the page\n",
        "//   canvas(id) -- a canvas's {element, width, height}\n",
        "//   send(event) -- reports an event to the program\n",
        "\n",
        "// How far ahead the beat is scheduled, and how often it is looked at.\n",
        "const LOOKAHEAD = 0.15;\n",
        "const TICK_MS = 25;\n",
        "\n",
        "// How long before an `sdelay` ends the page answers it, so that what the\n",
        "// program plays next reaches the page in time to start exactly there,\n",
        "// and how often the clock is looked at while one waits.\n",
        "const SDELAY_LEAD = 0.05;\n",
        "const SDELAY_TICK_MS = 5;\n",
        "\n",
        "// The numbers a command carries. String -> [Float]\n",
        "function engineNumbers(text) {\n",
        "  return text === \"\" || text === undefined ? [] : String(text).trim().split(/\\s+/).map(Number);\n",
        "}\n",
        "\n",
        "// A buffer played backwards, made once per buffer. AudioContext -> AudioBuffer -> AudioBuffer\n",
        "const reversedBuffers = new WeakMap();\n",
        "function reversedOf(context, buffer) {\n",
        "  let done = reversedBuffers.get(buffer);\n",
        "  if (done) return done;\n",
        "  done = context.createBuffer(buffer.numberOfChannels, buffer.length, buffer.sampleRate);\n",
        "  for (let k = 0; k < buffer.numberOfChannels; k++) {\n",
        "    const from = buffer.getChannelData(k);\n",
        "    const to = done.getChannelData(k);\n",
        "    for (let i = 0, n = from.length; i < n; i++) to[i] = from[n - 1 - i];\n",
        "  }\n",
        "  reversedBuffers.set(buffer, done);\n",
        "  return done;\n",
        "}\n",
        "\n",
        "// A reverb's impulse: two seconds of noise dying away. AudioContext -> AudioBuffer\n",
        "function impulseOf(context) {\n",
        "  const length = Math.round(context.sampleRate * 2);\n",
        "  const impulse = context.createBuffer(2, length, context.sampleRate);\n",
        "  // The same noise every time, so a render comes out the same.\n",
        "  let seed = 22222;\n",
        "  const random = () => {\n",
        "    seed = (seed * 1103515245 + 12345) % 2147483648;\n",
        "    return seed / 2147483648;\n",
        "  };\n",
        "  for (let k = 0; k < 2; k++) {\n",
        "    const data = impulse.getChannelData(k);\n",
        "    for (let i = 0; i < length; i++) data[i] = (random() * 2 - 1) * Math.pow(1 - i / length, 3);\n",
        "  }\n",
        "  return impulse;\n",
        "}\n",
        "\n",
        "// A channel's settings as `channel_style` gives them.\n",
        "const CHANNEL_DEFAULT = { volume: 1, pan: 0, echo: 0, echoTime: 0.3, feedback: 0.35, reverb: 0, lowPass: 0 };\n",
        "\n",
        "// The sound graph of one AudioContext: a master volume, an analyser on\n",
        "// it, and the channels each sound goes through: volume, pan, a low-pass\n",
        "// filter, and sends to an echo and a reverb. AudioContext -> {..}\n",
        "function soundGraph(context) {\n",
        "  const master = context.createGain();\n",
        "  const analyser = context.createAnalyser ? context.createAnalyser() : null;\n",
        "  if (analyser) {\n",
        "    master.connect(analyser);\n",
        "    analyser.connect(context.destination);\n",
        "  } else {\n",
        "    master.connect(context.destination);\n",
        "  }\n",
        "  const channels = new Map();\n",
        "  let impulse = null;\n",
        "  function channel(n) {\n",
        "    let ch = channels.get(n);\n",
        "    if (ch) return ch;\n",
        "    const input = context.createGain();\n",
        "    const panner = context.createStereoPanner ? context.createStereoPanner() : null;\n",
        "    const filter = context.createBiquadFilter();\n",
        "    filter.type = \"lowpass\";\n",
        "    filter.frequency.value = 22050;\n",
        "    const out = context.createGain();\n",
        "    if (panner) input.connect(panner).connect(filter);\n",
        "    else input.connect(filter);\n",
        "    filter.connect(out);\n",
        "    out.connect(master);\n",
        "    const delay = context.createDelay(5);\n",
        "    const feedback = context.createGain();\n",
        "    const echo = context.createGain();\n",
        "    echo.gain.value = 0;\n",
        "    out.connect(echo);\n",
        "    echo.connect(delay);\n",
        "    delay.connect(feedback);\n",
        "    feedback.connect(delay);\n",
        "    delay.connect(master);\n",
        "    const reverb = context.createGain();\n",
        "    reverb.gain.value = 0;\n",
        "    let convolver = null;\n",
        "    ch = { input, panner, filter, out, delay, feedback, echo, reverb, convolver };\n",
        "    channels.set(n, ch);\n",
        "    return ch;\n",
        "  }\n",
        "  function style(n, settings) {\n",
        "    const ch = channel(n);\n",
        "    ch.out.gain.value = settings.volume;\n",
        "    if (ch.panner) ch.panner.pan.value = Math.max(-1, Math.min(1, settings.pan));\n",
        "    ch.filter.frequency.value = settings.lowPass > 0 ? settings.lowPass : 22050;\n",
        "    ch.echo.gain.value = settings.echo;\n",
        "    ch.delay.delayTime.value = Math.max(0.001, Math.min(5, settings.echoTime));\n",
        "    ch.feedback.gain.value = Math.max(0, Math.min(0.95, settings.feedback));\n",
        "    if (settings.reverb > 0 && ch.convolver === null && context.createConvolver) {\n",
        "      if (impulse === null) impulse = impulseOf(context);\n",
        "      ch.convolver = context.createConvolver();\n",
        "      ch.convolver.buffer = impulse;\n",
        "      ch.out.connect(ch.reverb);\n",
        "      ch.reverb.connect(ch.convolver);\n",
        "      ch.convolver.connect(master);\n",
        "    }\n",
        "    ch.reverb.gain.value = settings.reverb;\n",
        "  }\n",
        "  return { context, master, analyser, channel, style };\n",
        "}\n",
        "\n",
        "// A WAV file of a rendered buffer, 16 bits, as bytes. AudioBuffer -> Uint8Array\n",
        "function wavBytes(buffer) {\n",
        "  const channels = buffer.numberOfChannels;\n",
        "  const frames = buffer.length;\n",
        "  const bytes = new Uint8Array(44 + frames * channels * 2);\n",
        "  const view = new DataView(bytes.buffer);\n",
        "  const text = (at, s) => { for (let i = 0; i < s.length; i++) bytes[at + i] = s.charCodeAt(i); };\n",
        "  text(0, \"RIFF\");\n",
        "  view.setUint32(4, 36 + frames * channels * 2, true);\n",
        "  text(8, \"WAVEfmt \");\n",
        "  view.setUint32(16, 16, true);\n",
        "  view.setUint16(20, 1, true);\n",
        "  view.setUint16(22, channels, true);\n",
        "  view.setUint32(24, buffer.sampleRate, true);\n",
        "  view.setUint32(28, buffer.sampleRate * channels * 2, true);\n",
        "  view.setUint16(32, channels * 2, true);\n",
        "  view.setUint16(34, 16, true);\n",
        "  text(36, \"data\");\n",
        "  view.setUint32(40, frames * channels * 2, true);\n",
        "  const data = [];\n",
        "  for (let k = 0; k < channels; k++) data.push(buffer.getChannelData(k));\n",
        "  let at = 44;\n",
        "  for (let i = 0; i < frames; i++) {\n",
        "    for (let k = 0; k < channels; k++) {\n",
        "      const v = Math.max(-1, Math.min(1, data[k][i]));\n",
        "      view.setInt16(at, v < 0 ? v * 0x8000 : v * 0x7fff, true);\n",
        "      at += 2;\n",
        "    }\n",
        "  }\n",
        "  return bytes;\n",
        "}\n",
        "\n",
        "// Offers `blob` to the reader as a file called `name`. Blob -> String -> ()\n",
        "function offerDownload(blob, name) {\n",
        "  const link = document.createElement(\"a\");\n",
        "  link.href = URL.createObjectURL(blob);\n",
        "  link.download = name;\n",
        "  link.style.display = \"none\";\n",
        "  document.body.appendChild(link);\n",
        "  link.click();\n",
        "  link.remove();\n",
        "  setTimeout(() => URL.revokeObjectURL(link.href), 10000);\n",
        "}\n",
        "\n",
        "function makeEngine(host) {\n",
        "  let graph = null;              // the live context's sound graph\n",
        "  const settings = new Map();    // channel -> its settings, for every graph\n",
        "  let masterVolume = 1;\n",
        "  const voices = new Map();      // voice -> {source, gain}\n",
        "  const sounding = new Set();    // every source started and not yet ended\n",
        "  // The beat: tempo and swing, and where the beat was at some time, so a\n",
        "  // change of tempo goes on from where the beat is.\n",
        "  let bpm = 120;\n",
        "  let swingAmount = 0;\n",
        "  let anchor = null;             // {time, beat}\n",
        "  const beats = new Map();       // watcher -> {steps, next}\n",
        "  const timers = new Map();      // timer -> {at, every}\n",
        "  let ticker = 0;\n",
        "  let frozen = null;             // the clock, while the program has paused it\n",
        "  let listening = null;          // {bins, smoothing}\n",
        "  let rendering = null;          // {id, name, seconds, commands}\n",
        "  let closed = false;\n",
        "\n",
        "  function live() {\n",
        "    const context = host.audio();\n",
        "    if (!context) return null;\n",
        "    if (graph === null || graph.context !== context) {\n",
        "      graph = soundGraph(context);\n",
        "      graph.master.gain.value = masterVolume;\n",
        "      for (const [n, s] of settings) graph.style(n, s);\n",
        "      if (listening) listen(listening.bins, listening.smoothing);\n",
        "    }\n",
        "    return graph;\n",
        "  }\n",
        "\n",
        "  function beatAt(t) {\n",
        "    return anchor === null ? 0 : anchor.beat + ((t - anchor.time) * bpm) / 60;\n",
        "  }\n",
        "\n",
        "  // When step `k` of a beat cut into `steps` steps sounds. Int -> Int -> Float\n",
        "  function stepTime(k, steps) {\n",
        "    const at = anchor.time + ((k / steps - anchor.beat) * 60) / bpm;\n",
        "    return k % 2 === 1 ? at + (swingAmount * 60) / bpm / steps : at;\n",
        "  }\n",
        "\n",
        "  function tick() {\n",
        "    if (closed) return;\n",
        "    const t = host.clock();\n",
        "    if (frozen !== null) return;\n",
        "    for (const [id, timer] of [...timers]) {\n",
        "      if (t + 0.0005 < timer.at) continue;\n",
        "      if (timer.every > 0) {\n",
        "        while (timer.at <= t + 0.0005) timer.at += timer.every;\n",
        "      } else {\n",
        "        timers.delete(id);\n",
        "      }\n",
        "      host.send({ ev: \"cb\", id, kind: \"timer\" });\n",
        "    }\n",
        "    for (const [id, watcher] of beats) {\n",
        "      for (let guard = 0; guard < 64; guard++) {\n",
        "        const at = stepTime(watcher.next, watcher.steps);\n",
        "        if (at > t + LOOKAHEAD) break;\n",
        "        host.send({ ev: \"cb\", id, kind: \"beat\",\n",
        "          reports: { beat: [watcher.next, Math.max(at, t), beatAt(t)] } });\n",
        "        watcher.next += 1;\n",
        "      }\n",
        "    }\n",
        "    if (timers.size === 0 && beats.size === 0) {\n",
        "      clearInterval(ticker);\n",
        "      ticker = 0;\n",
        "    }\n",
        "  }\n",
        "\n",
        "  function ticking() {\n",
        "    if (ticker === 0 && !closed) ticker = setInterval(tick, TICK_MS);\n",
        "  }\n",
        "\n",
        "  // Starts one sound on `g`'s context: a sample (`play` and `start`) or a\n",
        "  // tone, at `at` on that context's clock. Answers its source.\n",
        "  function sound(g, kind, sample, buffer, n, toTime) {\n",
        "    const context = g.context;\n",
        "    if (kind === \"tone\") {\n",
        "      const [frequency, at, duration, volume, pan, channel] = n;\n",
        "      const when = Math.max(context.currentTime, toTime(at));\n",
        "      const length = Math.max(0.02, duration);\n",
        "      const oscillator = context.createOscillator();\n",
        "      oscillator.type = [\"sine\", \"square\", \"triangle\", \"sawtooth\"].includes(sample) ? sample : \"sine\";\n",
        "      oscillator.frequency.value = frequency;\n",
        "      const gain = context.createGain();\n",
        "      const attack = Math.min(0.01, length / 4);\n",
        "      const release = Math.min(0.05, length / 4);\n",
        "      gain.gain.setValueAtTime(0, when);\n",
        "      gain.gain.linearRampToValueAtTime(volume, when + attack);\n",
        "      gain.gain.setValueAtTime(volume, when + length - release);\n",
        "      gain.gain.linearRampToValueAtTime(0, when + length);\n",
        "      const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;\n",
        "      if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));\n",
        "      oscillator.connect(gain);\n",
        "      (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);\n",
        "      oscillator.start(when);\n",
        "      oscillator.stop(when + length + 0.01);\n",
        "      return { source: oscillator, gain };\n",
        "    }\n",
        "    const [at, volume, rate, pan, channel, reverse, loop] = n;\n",
        "    const source = context.createBufferSource();\n",
        "    source.buffer = reverse ? reversedOf(context, buffer) : buffer;\n",
        "    source.playbackRate.value = rate > 0 ? rate : 1;\n",
        "    source.loop = !!loop;\n",
        "    const gain = context.createGain();\n",
        "    gain.gain.value = volume;\n",
        "    const panner = pan !== 0 && context.createStereoPanner ? context.createStereoPanner() : null;\n",
        "    if (panner) panner.pan.value = Math.max(-1, Math.min(1, pan));\n",
        "    source.connect(gain);\n",
        "    (panner ? gain.connect(panner) : gain).connect(g.channel(channel || 0).input);\n",
        "    source.start(Math.max(context.currentTime, toTime(at)));\n",
        "    return { source, gain };\n",
        "  }\n",
        "\n",
        "  // A sound command on the live context.\n",
        "  function playLive(cmd) {\n",
        "    const n = engineNumbers(cmd.numbers);\n",
        "    if (cmd.kind === \"tone\") {\n",
        "      host.startAudio();\n",
        "      const g = live();\n",
        "      if (!g) return;\n",
        "      const made = sound(g, \"tone\", cmd.text, null, n, host.toAudio);\n",
        "      sounding.add(made.source);\n",
        "      made.source.onended = () => sounding.delete(made.source);\n",
        "      return;\n",
        "    }\n",
        "    const sample = cmd.kind === \"play\" ? cmd.id : cmd.text;\n",
        "    host.startAudio();\n",
        "    const loading = host.sample(sample);\n",
        "    if (!loading) return;\n",
        "    const voice = cmd.kind === \"start\" ? cmd.id : null;\n",
        "    if (voice !== null) voices.set(voice, { source: null, gain: null, stopped: null });\n",
        "    loading.then((buffer) => {\n",
        "      const g = live();\n",
        "      if (buffer === null || closed || !g) return;\n",
        "      const entry = voice === null ? null : voices.get(voice);\n",
        "      if (entry && entry.stopped !== null && entry.stopped <= host.clock()) return;\n",
        "      const made = sound(g, \"sample\", sample, buffer, n, host.toAudio);\n",
        "      sounding.add(made.source);\n",
        "      made.source.onended = () => {\n",
        "        sounding.delete(made.source);\n",
        "        if (voice !== null && voices.get(voice)?.source === made.source) voices.delete(voice);\n",
        "      };\n",
        "      if (entry) {\n",
        "        entry.source = made.source;\n",
        "        entry.gain = made.gain;\n",
        "        if (entry.stopped !== null) made.source.stop(Math.max(g.context.currentTime, host.toAudio(entry.stopped)));\n",
        "        if (entry.fade) fadeVoice(entry, ...entry.fade);\n",
        "      }\n",
        "    });\n",
        "  }\n",
        "\n",
        "  function fadeVoice(entry, volume, over) {\n",
        "    const g = live();\n",
        "    if (!g || entry.gain === null) {\n",
        "      entry.fade = [volume, over];\n",
        "      return;\n",
        "    }\n",
        "    const now = g.context.currentTime;\n",
        "    const param = entry.gain.gain;\n",
        "    param.cancelScheduledValues(now);\n",
        "    param.setValueAtTime(param.value, now);\n",
        "    if (over > 0) param.linearRampToValueAtTime(volume, now + over);\n",
        "    else param.setValueAtTime(volume, now);\n",
        "  }\n",
        "\n",
        "  function stopAll() {\n",
        "    const g = live();\n",
        "    for (const source of sounding) {\n",
        "      try {\n",
        "        source.stop(g ? g.context.currentTime : 0);\n",
        "      } catch {\n",
        "        // already stopped\n",
        "      }\n",
        "    }\n",
        "    sounding.clear();\n",
        "    for (const entry of voices.values()) entry.stopped = -Infinity;\n",
        "    voices.clear();\n",
        "  }\n",
        "\n",
        "  function listen(bins, smoothing) {\n",
        "    listening = { bins, smoothing };\n",
        "    const g = graph;\n",
        "    if (!g || !g.analyser) return;\n",
        "    let size = 32;\n",
        "    while (size < bins * 2 && size < 32768) size *= 2;\n",
        "    g.analyser.fftSize = size;\n",
        "    g.analyser.smoothingTimeConstant = Math.max(0, Math.min(0.99, smoothing));\n",
        "  }\n",
        "\n",
        "  // What the page reports with an event: where the beat is, how late\n",
        "  // sound comes out, whether it is running; and with a frame, what the\n",
        "  // program listens to. Bool -> {..}\n",
        "  // The analyser's arrays, kept from frame to frame.\n",
        "  const scratch = { spectrum: new Uint8Array(0), samples: new Float32Array(0) };\n",
        "\n",
        "  function reports(withSound) {\n",
        "    const context = host.audio();\n",
        "    const t = host.clock();\n",
        "    const latency = context ? (context.outputLatency || 0) + (context.baseLatency || 0) : 0;\n",
        "    const out = { clock: [beatAt(t), latency, context && context.state === \"running\" ? 1 : 0] };\n",
        "    if (withSound && listening !== null) {\n",
        "      const g = live();\n",
        "      const bins = listening.bins;\n",
        "      const level = [0];\n",
        "      const band = new Array(bins).fill(0);\n",
        "      const wave = new Array(bins).fill(0);\n",
        "      if (g && g.analyser && g.analyser.getByteFrequencyData) {\n",
        "        const a = g.analyser;\n",
        "        if (scratch.spectrum.length !== a.frequencyBinCount) {\n",
        "          scratch.spectrum = new Uint8Array(a.frequencyBinCount);\n",
        "          scratch.samples = new Float32Array(a.fftSize);\n",
        "        }\n",
        "        const spectrum = scratch.spectrum;\n",
        "        a.getByteFrequencyData(spectrum);\n",
        "        const per = spectrum.length / bins;\n",
        "        for (let k = 0; k < bins; k++) {\n",
        "          let peak = 0;\n",
        "          for (let i = Math.floor(k * per); i < Math.max(Math.floor((k + 1) * per), Math.floor(k * per) + 1); i++) {\n",
        "            peak = Math.max(peak, spectrum[Math.min(i, spectrum.length - 1)]);\n",
        "          }\n",
        "          band[k] = Math.round((peak / 255) * 1000) / 1000;\n",
        "        }\n",
        "        const samples = scratch.samples;\n",
        "        a.getFloatTimeDomainData(samples);\n",
        "        let sum = 0;\n",
        "        for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];\n",
        "        level[0] = Math.round(Math.min(1, Math.sqrt(sum / samples.length) * Math.SQRT2) * 1000) / 1000;\n",
        "        const step = samples.length / bins;\n",
        "        for (let k = 0; k < bins; k++) wave[k] = Math.round(samples[Math.floor(k * step)] * 1000) / 1000;\n",
        "      }\n",
        "      out.level = level;\n",
        "      out.band = band;\n",
        "      out.wave = wave;\n",
        "    }\n",
        "    return out;\n",
        "  }\n",
        "\n",
        "  // Renders what was scheduled between `render` and `render_end` offline,\n",
        "  // offers it as a WAV file and reports how long that took and how loud\n",
        "  // its loudest sample is.\n",
        "  function finishRender(job) {\n",
        "    const Offline = globalThis.OfflineAudioContext;\n",
        "    const done = (took, peak) =>\n",
        "      host.send({ ev: \"cb\", id: job.id, kind: \"rendered\", reports: { rendered: [took, peak] } });\n",
        "    if (!Offline) {\n",
        "      done(0, 0);\n",
        "      return;\n",
        "    }\n",
        "    const rate = 44100;\n",
        "    const context = new Offline(2, Math.max(1, Math.ceil(job.seconds * rate)), rate);\n",
        "    const g = soundGraph(context);\n",
        "    g.master.gain.value = masterVolume;\n",
        "    for (const [n, s] of settings) g.style(n, s);\n",
        "    const wanted = job.commands.filter((c) => c.kind !== \"tone\")\n",
        "      .map((c) => host.sample(c.kind === \"play\" ? c.id : c.text) || Promise.resolve(null));\n",
        "    Promise.all(wanted).then((buffers) => {\n",
        "      let b = 0;\n",
        "      for (const c of job.commands) {\n",
        "        const n = engineNumbers(c.numbers);\n",
        "        if (c.kind === \"tone\") {\n",
        "          sound(g, \"tone\", c.text, null, n, (t) => t);\n",
        "        } else {\n",
        "          const buffer = buffers[b++];\n",
        "          if (buffer) sound(g, \"sample\", null, buffer, n, (t) => t);\n",
        "        }\n",
        "      }\n",
        "      const started = typeof performance !== \"undefined\" ? performance.now() : Date.now();\n",
        "      return context.startRendering().then((buffer) => {\n",
        "        const took = ((typeof performance !== \"undefined\" ? performance.now() : Date.now()) - started) / 1000;\n",
        "        let peak = 0;\n",
        "        for (let k = 0; k < buffer.numberOfChannels; k++) {\n",
        "          const data = buffer.getChannelData(k);\n",
        "          for (let i = 0; i < data.length; i++) peak = Math.max(peak, Math.abs(data[i]));\n",
        "        }\n",
        "        offerDownload(new Blob([wavBytes(buffer)], { type: \"audio/wav\" }), job.name);\n",
        "        done(Math.round(took * 1000) / 1000, Math.round(peak * 1000) / 1000);\n",
        "      });\n",
        "    }).catch((error) => {\n",
        "      console.error(`tinyweb: rendering ${job.name} failed: ${error.message}`);\n",
        "      done(0, 0);\n",
        "    });\n",
        "  }\n",
        "\n",
        "  // An element whose `display` the program sets: a slider's row, not\n",
        "  // its input.\n",
        "  function shown(element) {\n",
        "    return element.tagName === \"INPUT\" && element.type === \"range\" ? element.parentNode : element;\n",
        "  }\n",
        "\n",
        "  function value(id, text) {\n",
        "    host.send({ ev: \"report\", reports: { [\"value.\" + id]: String(text) } });\n",
        "  }\n",
        "\n",
        "  function command(cmd) {\n",
        "    const n = engineNumbers(cmd.numbers);\n",
        "    if (rendering !== null && [\"play\", \"start\", \"tone\"].includes(cmd.kind)) {\n",
        "      rendering.commands.push(cmd);\n",
        "      return;\n",
        "    }\n",
        "    switch (cmd.kind) {\n",
        "      // --- sound ---\n",
        "      case \"play\":\n",
        "      case \"start\":\n",
        "      case \"tone\":\n",
        "        playLive(cmd);\n",
        "        break;\n",
        "      case \"stop\": {\n",
        "        const entry = voices.get(cmd.id);\n",
        "        if (!entry) break;\n",
        "        const at = n[0] || 0;\n",
        "        entry.stopped = at;\n",
        "        const g = live();\n",
        "        if (entry.source && g) entry.source.stop(Math.max(g.context.currentTime, host.toAudio(at)));\n",
        "        break;\n",
        "      }\n",
        "      case \"fade\": {\n",
        "        const entry = voices.get(cmd.id);\n",
        "        if (entry) fadeVoice(entry, n[0] ?? 0, n[1] ?? 0);\n",
        "        break;\n",
        "      }\n",
        "      case \"stop_all\":\n",
        "        stopAll();\n",
        "        break;\n",
        "      case \"master\": {\n",
        "        masterVolume = n[0] ?? 1;\n",
        "        const g = live();\n",
        "        if (g) g.master.gain.value = masterVolume;\n",
        "        break;\n",
        "      }\n",
        "      case \"channel\": {\n",
        "        const ch = Number(cmd.id) || 0;\n",
        "        const s = { volume: n[0] ?? 1, pan: n[1] ?? 0, echo: n[2] ?? 0, echoTime: n[3] ?? 0.3,\n",
        "          feedback: n[4] ?? 0.35, reverb: n[5] ?? 0, lowPass: n[6] ?? 0 };\n",
        "        settings.set(ch, s);\n",
        "        const g = live();\n",
        "        if (g) g.style(ch, s);\n",
        "        break;\n",
        "      }\n",
        "      case \"listen\":\n",
        "        listen(Math.max(1, Math.min(1024, Math.round(n[0] || 32))), n[1] ?? 0.8);\n",
        "        live();\n",
        "        break;\n",
        "      case \"tempo\": {\n",
        "        const t = host.clock();\n",
        "        anchor = anchor === null ? null : { time: t, beat: beatAt(t) };\n",
        "        bpm = Math.max(1, n[0] || 120);\n",
        "        break;\n",
        "      }\n",
        "      case \"swing\":\n",
        "        swingAmount = Math.max(0, Math.min(0.9, n[0] || 0));\n",
        "        break;\n",
        "      case \"beat\": {\n",
        "        const t = host.clock();\n",
        "        const steps = Math.max(1, Math.round(n[0] || 1));\n",
        "        if (anchor === null) anchor = { time: t + 0.05, beat: 0 };\n",
        "        // The first step not yet passed, from where the beat is.\n",
        "        // `+ 0` makes a -0 at the very start a 0: a step is a whole number.\n",
        "        let next = Math.ceil(beatAt(t) * steps - 1e-9) + 0;\n",
        "        while (stepTime(next, steps) < t) next += 1;\n",
        "        beats.set(cmd.id, { steps, next });\n",
        "        ticking();\n",
        "        break;\n",
        "      }\n",
        "      case \"beat_stop\":\n",
        "        beats.delete(cmd.id);\n",
        "        break;\n",
        "      case \"audio\": {\n",
        "        const context = host.audio();\n",
        "        if (cmd.text === \"pause\" && frozen === null) {\n",
        "          frozen = host.clock();\n",
        "          if (context && context.state === \"running\") context.suspend();\n",
        "        } else if (cmd.text === \"resume\" && frozen !== null) {\n",
        "          const at = frozen;\n",
        "          if (context) {\n",
        "            context.resume().then(() => {\n",
        "              host.thaw(at);\n",
        "              frozen = null;\n",
        "            });\n",
        "          } else {\n",
        "            host.thaw(at);\n",
        "            frozen = null;\n",
        "          }\n",
        "        }\n",
        "        break;\n",
        "      }\n",
        "      case \"render\":\n",
        "        rendering = { id: cmd.id, name: cmd.text, seconds: n[0] || 1, commands: [] };\n",
        "        break;\n",
        "      case \"render_end\":\n",
        "        if (rendering !== null) {\n",
        "          const job = rendering;\n",
        "          rendering = null;\n",
        "          finishRender(job);\n",
        "        }\n",
        "        break;\n",
        "      // --- timers ---\n",
        "      case \"after\":\n",
        "      case \"every\": {\n",
        "        const seconds = Math.max(0, n[0] || 0);\n",
        "        timers.set(cmd.id, { at: host.clock() + seconds, every: cmd.kind === \"every\" ? Math.max(0.001, seconds) : 0 });\n",
        "        ticking();\n",
        "        break;\n",
        "      }\n",
        "      case \"cancel\":\n",
        "        timers.delete(cmd.id);\n",
        "        beats.delete(cmd.id);\n",
        "        break;\n",
        "      // --- changing what is on the page ---\n",
        "      case \"set_text\": {\n",
        "        const element = host.element(cmd.id);\n",
        "        if (!element) break;\n",
        "        if (element.tagName === \"INPUT\" || element.tagName === \"TEXTAREA\") element.value = cmd.text;\n",
        "        else element.textContent = cmd.text;\n",
        "        break;\n",
        "      }\n",
        "      case \"visible\": {\n",
        "        const element = host.element(cmd.id);\n",
        "        if (element) shown(element).style.display = n[0] ? \"\" : \"none\";\n",
        "        break;\n",
        "      }\n",
        "      case \"enabled\": {\n",
        "        const element = host.element(cmd.id);\n",
        "        if (element) element.disabled = !n[0];\n",
        "        break;\n",
        "      }\n",
        "      case \"remove\": {\n",
        "        const element = host.element(cmd.id);\n",
        "        if (element) shown(element).remove();\n",
        "        host.forget(cmd.id);\n",
        "        break;\n",
        "      }\n",
        "      case \"text_area\": {\n",
        "        const area = document.createElement(\"textarea\");\n",
        "        area.setAttribute(\"data-tinyweb-id\", String(cmd.id));\n",
        "        area.value = cmd.text;\n",
        "        area.rows = Math.max(1, Math.round(n[0] || 4));\n",
        "        area.cols = Math.max(1, Math.round(n[1] || 40));\n",
        "        area.addEventListener(\"input\", () => {\n",
        "          host.send({ ev: \"cb\", id: cmd.id, kind: \"change\", reports: { [\"value.\" + cmd.id]: area.value } });\n",
        "        });\n",
        "        host.remember(cmd.id, area);\n",
        "        host.place(area);\n",
        "        break;\n",
        "      }\n",
        "      case \"file_button\": {\n",
        "        const button = document.createElement(\"button\");\n",
        "        button.setAttribute(\"data-tinyweb-id\", String(cmd.id));\n",
        "        button.textContent = cmd.text;\n",
        "        const input = document.createElement(\"input\");\n",
        "        input.type = \"file\";\n",
        "        input.style.display = \"none\";\n",
        "        button.addEventListener(\"click\", () => {\n",
        "          host.startAudio();\n",
        "          input.click();\n",
        "        });\n",
        "        // The input is inside the button: its own click is not the button's.\n",
        "        input.addEventListener(\"click\", (event) => event.stopPropagation());\n",
        "        input.addEventListener(\"change\", () => {\n",
        "          const file = input.files && input.files[0];\n",
        "          if (!file) return;\n",
        "          file.arrayBuffer().then((bytes) => {\n",
        "            if (/^audio\\//.test(file.type) || /\\.(wav|mp3|ogg|m4a|flac|aac)$/i.test(file.name)) {\n",
        "              const decoder = new OfflineAudioContext(1, 1, 44100);\n",
        "              const loading = decoder.decodeAudioData(bytes).catch(() => null);\n",
        "              host.addSample(cmd.id, loading);\n",
        "              loading.then(() => host.send({ ev: \"cb\", id: cmd.id, kind: \"loaded\",\n",
        "                reports: { file: file.name, [\"file.text\"]: \"\" } }));\n",
        "            } else {\n",
        "              const text = new TextDecoder().decode(bytes);\n",
        "              host.send({ ev: \"cb\", id: cmd.id, kind: \"loaded\", reports: { file: file.name, [\"file.text\"]: text } });\n",
        "            }\n",
        "          });\n",
        "        });\n",
        "        host.remember(cmd.id, button);\n",
        "        host.place(button);\n",
        "        button.appendChild(input);\n",
        "        break;\n",
        "      }\n",
        "      case \"cursor\": {\n",
        "        const target = cmd.id === \"\" ? document.body : host.canvas(cmd.id)?.element;\n",
        "        if (target) target.style.cursor = cmd.text || \"auto\";\n",
        "        break;\n",
        "      }\n",
        "      case \"save_canvas\": {\n",
        "        const entry = host.canvas(cmd.id);\n",
        "        if (!entry || !entry.element.toBlob) break;\n",
        "        const out = document.createElement(\"canvas\");\n",
        "        out.width = entry.width;\n",
        "        out.height = entry.height;\n",
        "        const g = out.getContext(\"2d\");\n",
        "        g.fillStyle = \"#ffffff\";\n",
        "        g.fillRect(0, 0, out.width, out.height);\n",
        "        g.drawImage(entry.element, 0, 0, out.width, out.height);\n",
        "        out.toBlob((blob) => { if (blob) offerDownload(blob, cmd.text); }, \"image/png\");\n",
        "        break;\n",
        "      }\n",
        "      case \"download\":\n",
        "        offerDownload(new Blob([cmd.text], { type: \"text/plain\" }), cmd.id);\n",
        "        break;\n",
        "    }\n",
        "  }\n",
        "\n",
        "  return {\n",
        "    command,\n",
        "    reports,\n",
        "    value,\n",
        "    // The clock while the program has paused it, or null.\n",
        "    frozen: () => frozen,\n",
        "    // Whether a command needs sound, which may need the splash screen first.\n",
        "    sounds: (cmd) => [\"play\", \"start\", \"tone\"].includes(cmd.kind),\n",
        "    close() {\n",
        "      closed = true;\n",
        "      clearInterval(ticker);\n",
        "      ticker = 0;\n",
        "      stopAll();\n",
        "    },\n",
        "  };\n",
        "}\n",
        "// END tinyweb style\n",
        "\n",
        "// Mounts a tinyweb page in `element` and answers {receive, freeze, close}:\n",
        "// `receive(commands)` carries out a batch of commands, and `send(event)`\n",
        "// is how the page reports one. `standalone` is true where the page is\n",
        "// the whole document, which is where a key press is listened for; a\n",
        "// page inside another (a notebook cell) listens on `element`, which\n",
        "// takes the focus when clicked. `activated` is true where the reader\n",
        "// started the program with a click or a key, as in the playground and\n",
        "// a notebook, and the page then never shows the splash screen.\n",
        "// `silent` is true where the page is only a picture of what a program\n",
        "// drew -- a notebook's result diff -- and never makes a sound.\n",
        "export function mountPage(element, sendEvent,\n",
        "                          { standalone = false, activated = false, silent = false } = {}) {\n",
        "  const box = document.createElement(\"div\");\n",
        "  box.className = \"tinyweb-page\";\n",
        "  box.style.cssText =\n",
        "    \"display:flex;flex-direction:column;align-items:flex-start;outline:none\";\n",
        "  element.appendChild(box);\n",
        "  const look = styled(element, box);\n",
        "\n",
        "  const canvases = new Map();\n",
        "  const labels = new Map();\n",
        "  const samples = new Map();\n",
        "  const pictures = new Map();\n",
        "  // What `set_checked` and `set_value` change, by identifier, and each\n",
        "  // group of radio buttons.\n",
        "  const checks = new Map();\n",
        "  const values = new Map();\n",
        "  const groups = new Map();\n",
        "  const bitmaps = new Map();\n",
        "  // Where an element made now goes: the page, or a row it was put inside.\n",
        "  const rows = new Map();\n",
        "  let parent = box;\n",
        "  // The keys held down, reported again as released when the page loses\n",
        "  // the focus.\n",
        "  const heldKeys = new Set();\n",
        "  let start = now();\n",
        "  let audio = null;\n",
        "  let offset = 0;\n",
        "  let frameWanted = false;\n",
        "  let frameWaiting = false;\n",
        "  let frameRequest = 0;\n",
        "  let closed = false;\n",
        "  // Sound, the beat, timers and page changes (the `cmd` commands).\n",
        "  let engine = null;\n",
        "  // Inside another page the keys go to the element the page is mounted\n",
        "  // in, which takes the focus when anything in it is clicked; that page\n",
        "  // shows the focus (:focus-within).\n",
        "  const keyTarget = standalone ? window : element;\n",
        "  let keysWanted = false;\n",
        "  // The splash screen: what it says, whether it has been shown (or is\n",
        "  // not needed), and while it is shown the element, the commands held\n",
        "  // until it is dismissed, and the clock where it stopped.\n",
        "  let splashText = SPLASH_TEXT;\n",
        "  let splashDone = activated;\n",
        "  let splash = null;\n",
        "  let held = null;\n",
        "  let heldClock = 0;\n",
        "  let heldAt = 0;\n",
        "  // The picture the held commands wait for, and the events the reader\n",
        "  // caused while they waited for it.\n",
        "  let waitingFor = null;\n",
        "  let deferred = [];\n",
        "  // tinyweb's `sdelay`: where the last one ends on the page's clock (null\n",
        "  // before the first), the one to answer and when, and once it is\n",
        "  // answered, what the program does next that is not a sound, held until\n",
        "  // the end -- a sound is started at the end instead (`timed`). The\n",
        "  // interval looks at the clock while one of them waits.\n",
        "  let sdelayEnd = null;\n",
        "  let answering = null;\n",
        "  let paced = null;\n",
        "  let pacer = 0;\n",
        "\n",
        "  let focusable = false;    // whether mounting made `element` focusable\n",
        "\n",
        "  function takeFocus(event) {\n",
        "    // A slider keeps the focus for its arrow keys.\n",
        "    if (!event.target.closest(\"input\")) element.focus({ preventScroll: true });\n",
        "  }\n",
        "\n",
        "  if (!standalone) {\n",
        "    focusable = element.tabIndex < 0;\n",
        "    if (focusable) element.tabIndex = 0;\n",
        "    element.addEventListener(\"click\", takeFocus);\n",
        "  }\n",
        "\n",
        "  // The page's clock: the audio clock once sound has started, and until\n",
        "  // then the seconds since the page was mounted. `offset` joins the two,\n",
        "  // so the clock never goes back.\n",
        "  function running() {\n",
        "    return audio !== null && audio.state === \"running\";\n",
        "  }\n",
        "\n",
        "  function clockNow() {\n",
        "    if (held !== null) return heldClock;\n",
        "    const paused = engine === null ? null : engine.frozen();\n",
        "    if (paused !== null) return paused;\n",
        "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
        "  }\n",
        "\n",
        "  // Every event carries where the beat is and how late sound comes out,\n",
        "  // and a frame what the program listens to.\n",
        "  function report(event) {\n",
        "    if (closed) return;\n",
        "    if (held !== null) {\n",
        "      if (splash === null) deferred.push(event);\n",
        "      return;\n",
        "    }\n",
        "    const reports = { ...engine.reports(event.ev === \"frame\"), ...(event.reports || {}) };\n",
        "    sendEvent({ ...event, t: clockNow(), running: running(), reports });\n",
        "  }\n",
        "\n",
        "  // Whether a sound now would need the splash screen first.\n",
        "  function splashWanted() {\n",
        "    return !splashDone && splashText !== \"\" && !running() && !readerActive();\n",
        "  }\n",
        "\n",
        "  // Shows the splash screen and holds what comes after it: the commands,\n",
        "  // the frames and the clock.\n",
        "  function showSplash() {\n",
        "    splashDone = true;\n",
        "    heldClock = clockNow();\n",
        "    heldAt = now();\n",
        "    held = [];\n",
        "    splash = splashScreen(splashText);\n",
        "    splash.addEventListener(\"click\", dismissSplash);\n",
        "    window.addEventListener(\"keydown\", dismissSplash, true);\n",
        "    document.body.appendChild(splash);\n",
        "  }\n",
        "\n",
        "  // The reader's click or key: the splash screen goes, sound starts, the\n",
        "  // clock goes on from where it stopped, and what was held is carried out.\n",
        "  function dismissSplash(event) {\n",
        "    if (splash === null) return;\n",
        "    event?.preventDefault?.();\n",
        "    event?.stopImmediatePropagation?.();\n",
        "    window.removeEventListener(\"keydown\", dismissSplash, true);\n",
        "    splash.remove();\n",
        "    splash = null;\n",
        "    startAudio();\n",
        "    release();\n",
        "  }\n",
        "\n",
        "  // Holds what comes after a picture still loading, until it has loaded\n",
        "  // or failed: the commands, the frames, the events and the clock.\n",
        "  // Picture -> ()\n",
        "  function waitFor(picture) {\n",
        "    if (held === null) {\n",
        "      heldClock = clockNow();\n",
        "      heldAt = now();\n",
        "      held = [];\n",
        "    }\n",
        "    waitingFor = picture;\n",
        "    picture.settled.push(() => {\n",
        "      waitingFor = null;\n",
        "      release();\n",
        "    });\n",
        "  }\n",
        "\n",
        "  // Carries out what was held once nothing holds it any more, then sends\n",
        "  // the events that waited with it. ()\n",
        "  function release() {\n",
        "    if (held === null || splash !== null || waitingFor !== null) return;\n",
        "    start += now() - heldAt;\n",
        "    const pending = held;\n",
        "    held = null;\n",
        "    for (const command of pending) take(command);\n",
        "    if (held !== null) return;\n",
        "    const events = deferred;\n",
        "    deferred = [];\n",
        "    for (const event of events) report(event);\n",
        "  }\n",
        "\n",
        "  // Carries out a command, or holds it while something holds the page,\n",
        "  // or until the `sdelay` before it has ended. Command -> ()\n",
        "  function take(command) {\n",
        "    if (held !== null) held.push(command);\n",
        "    else if (paced !== null && !sound(command)) paced.push(command);\n",
        "    else carryOut(paced !== null ? timed(command) : command);\n",
        "  }\n",
        "\n",
        "  // `sdelay seconds`, reached in the program's order: it ends `seconds`\n",
        "  // after the last one ended -- or after now, for the first, and where\n",
        "  // that end has passed already, so a program that fell behind starts\n",
        "  // again from now rather than catching up. The program waits until the\n",
        "  // page answers it. Command -> ()\n",
        "  function sdelay(command) {\n",
        "    const t = clockNow();\n",
        "    const seconds = Math.max(0, Number(command.seconds) || 0);\n",
        "    sdelayEnd = sdelayEnd === null ? t + seconds : Math.max(sdelayEnd + seconds, t);\n",
        "    answering = { id: command.id, at: sdelayEnd - SDELAY_LEAD };\n",
        "    pace();\n",
        "  }\n",
        "\n",
        "  // Looks at the clock for the `sdelay` waiting: answers it a little\n",
        "  // before its end, and carries out what was held after it once the end\n",
        "  // has come. ()\n",
        "  function pace() {\n",
        "    if (closed) return;\n",
        "    const t = clockNow();\n",
        "    if (answering !== null && t >= answering.at) {\n",
        "      const { id } = answering;\n",
        "      answering = null;\n",
        "      if (paced === null) paced = [];\n",
        "      report({ ev: \"sdelay\", id });\n",
        "    }\n",
        "    if (paced !== null && answering === null && t >= sdelayEnd) {\n",
        "      const pending = paced;\n",
        "      paced = null;\n",
        "      for (const command of pending) take(command);\n",
        "    }\n",
        "    const needed = answering !== null || paced !== null;\n",
        "    if (needed && pacer === 0) pacer = setInterval(pace, SDELAY_TICK_MS);\n",
        "    else if (!needed && pacer !== 0) {\n",
        "      clearInterval(pacer);\n",
        "      pacer = 0;\n",
        "    }\n",
        "  }\n",
        "\n",
        "  // Whether a command starts a sound. Command -> Bool\n",
        "  function sound(command) {\n",
        "    return command.op === \"cmd\" && engine.sounds(command);\n",
        "  }\n",
        "\n",
        "  // A sound the program starts after an `sdelay`, with no time of its\n",
        "  // own, starts where the `sdelay` ends, exactly. Command -> Command\n",
        "  function timed(command) {\n",
        "    if (sdelayEnd === null || !sound(command)) return command;\n",
        "    const n = String(command.numbers ?? \"\").trim().split(/\\s+/);\n",
        "    const k = command.kind === \"tone\" ? 1 : 0;\n",
        "    if (n.length <= k || Number(n[k]) !== 0) return command;\n",
        "    n[k] = String(sdelayEnd);\n",
        "    return { ...command, numbers: n.join(\" \") };\n",
        "  }\n",
        "\n",
        "  // Sound may start only after the reader did something, so every\n",
        "  // gesture is a chance to start it.\n",
        "  function startAudio() {\n",
        "    if (silent) return;\n",
        "    if (audio === null) {\n",
        "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n",
        "      if (!Context) return;\n",
        "      const before = clockNow();\n",
        "      audio = new Context();\n",
        "      offset = before - audio.currentTime;\n",
        "      audio.onstatechange = () => {\n",
        "        if (audio.state !== \"running\") return;\n",
        "        const paused = engine.frozen();\n",
        "        offset = (paused !== null ? paused : (now() - start) / 1000) - audio.currentTime;\n",
        "      };\n",
        "    }\n",
        "    if (audio.state === \"suspended\") audio.resume();\n",
        "  }\n",
        "\n",
        "  box.addEventListener(\"pointerdown\", startAudio);\n",
        "\n",
        "  engine = makeEngine({\n",
        "    audio: () => audio,\n",
        "    startAudio,\n",
        "    clock: clockNow,\n",
        "    toAudio: (t) => t - offset,\n",
        "    thaw: (t) => {\n",
        "      start = now() - t * 1000;\n",
        "      if (running()) offset = t - audio.currentTime;\n",
        "    },\n",
        "    sample: (id) => samples.get(id),\n",
        "    addSample: (id, loading) => samples.set(id, loading),\n",
        "    element: (id) => look.elements.get(id),\n",
        "    forget: (id) => look.elements.delete(id),\n",
        "    remember: (id, made) => remember(look, id, made),\n",
        "    place: (made) => parent.appendChild(made),\n",
        "    canvas: (id) => canvases.get(id),\n",
        "    send: (event) => report(event),\n",
        "  });\n",
        "\n",
        "  function onKey(event) {\n",
        "    if (splash !== null) {\n",
        "      dismissSplash(event);\n",
        "      return;\n",
        "    }\n",
        "    startAudio();\n",
        "    if (!keysWanted || typedInField(event)) return;\n",
        "    // Arrows and the space bar move the program's world, not the page.\n",
        "    if (standalone && [\"ArrowUp\", \"ArrowDown\", \"ArrowLeft\", \"ArrowRight\", \" \"].includes(event.key)) {\n",
        "      event.preventDefault?.();\n",
        "    }\n",
        "    heldKeys.add(event.key);\n",
        "    report({ ev: \"key\", key: event.key });\n",
        "  }\n",
        "  keyTarget.addEventListener(\"keydown\", onKey);\n",
        "\n",
        "  function onKeyUp(event) {\n",
        "    if (!keysWanted) return;\n",
        "    if (heldKeys.delete(event.key)) report({ ev: \"key_up\", key: event.key });\n",
        "  }\n",
        "  keyTarget.addEventListener(\"keyup\", onKeyUp);\n",
        "\n",
        "  // A key released while the page did not have the focus is never\n",
        "  // reported, so leaving the page lets go of every key.\n",
        "  function onBlur() {\n",
        "    for (const key of heldKeys) report({ ev: \"key_up\", key });\n",
        "    heldKeys.clear();\n",
        "  }\n",
        "  window.addEventListener(\"blur\", onBlur);\n",
        "\n",
        "  function loadSample(name) {\n",
        "    const decoder = new OfflineAudioContext(1, 1, 44100);\n",
        "    const fetchArray = (url) =>\n",
        "      fetch(url).then((response) => {\n",
        "        if (!response.ok) throw new Error(`${name}: ${response.status}`);\n",
        "        return response.arrayBuffer();\n",
        "      });\n",
        "    return fetchArray(new URL(name, document.baseURI))\n",
        "      .catch(() => fetchArray(new URL(\"tinyweb_assets/\" + name, import.meta.url)))\n",
        "      .then((bytes) => decoder.decodeAudioData(bytes))\n",
        "      .catch((error) => {\n",
        "        console.error(`tinyweb: cannot load the sample ${name}: ${error.message}`);\n",
        "        return null;\n",
        "      });\n",
        "  }\n",
        "\n",
        "  function frame() {\n",
        "    if (closed) return;\n",
        "    if (!frameWaiting && held === null) {\n",
        "      frameWaiting = true;\n",
        "      report({ ev: \"frame\" });\n",
        "    }\n",
        "    if (answering !== null || paced !== null) pace();\n",
        "    frameRequest = requestAnimationFrame(frame);\n",
        "  }\n",
        "\n",
        "  function newCanvas({ id, width, height }) {\n",
        "    const element = document.createElement(\"canvas\");\n",
        "    element.setAttribute(\"data-tinyweb-id\", String(id));\n",
        "    const ratio = globalThis.devicePixelRatio || 1;\n",
        "    element.width = Math.round(width * ratio);\n",
        "    element.height = Math.round(height * ratio);\n",
        "    element.style.width = width + \"px\";\n",
        "    element.style.height = height + \"px\";\n",
        "    element.style.background = \"#ffffff\";\n",
        "    const context = element.getContext(\"2d\");\n",
        "    context.scale(ratio, ratio);\n",
        "    plainLines(context);\n",
        "    const entry = {\n",
        "      element, context, width, height, mouse: false, pointer: false, ratio, depth: 0,\n",
        "      gradients: new Map(),\n",
        "    };\n",
        "    canvases.set(id, entry);\n",
        "    remember(look, id, element);\n",
        "    const where = (event) => {\n",
        "      const bounds = element.getBoundingClientRect();\n",
        "      return {\n",
        "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
        "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
        "      };\n",
        "    };\n",
        "    element.addEventListener(\"click\", (event) => {\n",
        "      if (entry.mouse) report({ ev: \"mouse\", c: id, ...where(event) });\n",
        "    });\n",
        "    // A browser reports a move at most once a frame already.\n",
        "    element.addEventListener(\"pointerdown\", (event) => {\n",
        "      if (!entry.pointer) return;\n",
        "      capture(element, event);\n",
        "      startAudio();\n",
        "      report({ ev: \"press\", c: id, ...where(event) });\n",
        "    });\n",
        "    element.addEventListener(\"pointerup\", (event) => {\n",
        "      if (entry.pointer) report({ ev: \"release\", c: id, ...where(event) });\n",
        "    });\n",
        "    element.addEventListener(\"pointermove\", (event) => {\n",
        "      if (entry.pointer) report({ ev: \"move\", c: id, ...where(event) });\n",
        "    });\n",
        "    element.addEventListener(\"contextmenu\", (event) => {\n",
        "      if (entry.pointer) event.preventDefault?.();\n",
        "    });\n",
        "    element.style.touchAction = \"none\";\n",
        "    parent.appendChild(element);\n",
        "  }\n",
        "\n",
        "  function draw(c, paint) {\n",
        "    const entry = canvases.get(c);\n",
        "    if (entry) paint(entry.context, entry);\n",
        "  }\n",
        "\n",
        "  function carryOut(command) {\n",
        "    switch (command.op) {\n",
        "      case \"canvas\":\n",
        "        newCanvas(command);\n",
        "        break;\n",
        "      case \"clear\":\n",
        "        draw(command.c, (g, entry) => {\n",
        "          freshState(g, entry);\n",
        "          g.fillStyle = paint(g, entry, command.color);\n",
        "          g.fillRect(0, 0, entry.width, entry.height);\n",
        "        });\n",
        "        break;\n",
        "      case \"shape\":\n",
        "        draw(command.c, (g, entry) => drawShape(g, entry, command.kind, command.numbers,\n",
        "          command.color, command.outline, command.width, command.alpha));\n",
        "        break;\n",
        "      case \"text\":\n",
        "        draw(command.c, (g, entry) => drawText(g, entry, command.x, command.y, command.words,\n",
        "          command.color, command.size, command.font, command.align, command.baseline,\n",
        "          command.bold, command.outline, command.outline_width, command.alpha));\n",
        "        break;\n",
        "      case \"measure\": {\n",
        "        // Answered once the code that asked has finished, as any event is.\n",
        "        const width = textWidth(command.words, command.size, command.font, command.bold);\n",
        "        queueMicrotask(() => report({ ev: \"measured\", id: command.id, width }));\n",
        "        break;\n",
        "      }\n",
        "      case \"bitmap\": {\n",
        "        let surface = bitmaps.get(command.id);\n",
        "        if (!surface || surface.width !== command.width || surface.height !== command.height) {\n",
        "          surface = bitmapSurface(command.width, command.height);\n",
        "          bitmaps.set(command.id, surface);\n",
        "        }\n",
        "        const [rx, ry, rw, rh] = command.rect;\n",
        "        updateSurface(surface, rx, ry, rw, rh, command.data);\n",
        "        draw(command.c, (g) => drawSurface(g, surface, command.x, command.y, command.scale));\n",
        "        break;\n",
        "      }\n",
        "      case \"state\":\n",
        "        draw(command.c, (g, entry) => canvasState(g, entry, command.kind, command.value,\n",
        "          command.numbers));\n",
        "        break;\n",
        "      case \"image_load\":\n",
        "        pictures.set(command.id, loadPicture(command.name, import.meta.url));\n",
        "        break;\n",
        "      case \"image\": {\n",
        "        const picture = pictures.get(command.picture);\n",
        "        if (picture && picture.loading) {\n",
        "          waitFor(picture);\n",
        "          held.push(command);\n",
        "          break;\n",
        "        }\n",
        "        draw(command.c, (g) => drawPicture(g, picture, command.x,\n",
        "          command.y, command.width, command.height, command.alpha));\n",
        "        break;\n",
        "      }\n",
        "      case \"checkbox\": {\n",
        "        const { row, input } = choiceRow(\"checkbox\", command.id, command.title, command.checked);\n",
        "        input.addEventListener(\"change\", () => {\n",
        "          startAudio();\n",
        "          report({ ev: \"check\", id: command.id, checked: input.checked,\n",
        "            reports: { [\"value.\" + command.id]: String(input.checked) } });\n",
        "        });\n",
        "        checks.set(command.id, (on) => { input.checked = on; });\n",
        "        remember(look, command.id, input);\n",
        "        parent.appendChild(row);\n",
        "        break;\n",
        "      }\n",
        "      case \"radio\": {\n",
        "        const members = groups.get(command.group) || [];\n",
        "        groups.set(command.group, members);\n",
        "        const first = members.length === 0;\n",
        "        const { row, input } = choiceRow(\"radio\", command.id, command.title,\n",
        "          command.chosen || first);\n",
        "        input.name = `${look.name}:${command.group}`;\n",
        "        const choose = () => {\n",
        "          for (const other of members) other.checked = other === input;\n",
        "        };\n",
        "        if (command.chosen) choose();\n",
        "        members.push(input);\n",
        "        input.addEventListener(\"change\", () => {\n",
        "          startAudio();\n",
        "          choose();\n",
        "          report({ ev: \"pick\", id: command.id });\n",
        "        });\n",
        "        checks.set(command.id, (on) => {\n",
        "          if (on) choose();\n",
        "          else input.checked = false;\n",
        "        });\n",
        "        remember(look, command.id, input);\n",
        "        parent.appendChild(row);\n",
        "        break;\n",
        "      }\n",
        "      case \"choice\": {\n",
        "        const select = choiceElement(command.id, command.options, command.chosen);\n",
        "        select.addEventListener(\"change\", () => {\n",
        "          startAudio();\n",
        "          report({ ev: \"choose\", id: command.id, value: Number(select.value),\n",
        "            reports: { [\"value.\" + command.id]: select.value } });\n",
        "        });\n",
        "        values.set(command.id, (value) => { select.value = String(value); });\n",
        "        remember(look, command.id, select);\n",
        "        parent.appendChild(select);\n",
        "        break;\n",
        "      }\n",
        "      case \"text_input\": {\n",
        "        const input = textInputElement(command.id, command.placeholder);\n",
        "        input.addEventListener(\"input\", () => engine.value(command.id, input.value));\n",
        "        input.addEventListener(\"keydown\", (event) => {\n",
        "          if (event.key === \"Enter\") {\n",
        "            startAudio();\n",
        "            report({ ev: \"enter\", id: command.id, text: input.value });\n",
        "          }\n",
        "        });\n",
        "        remember(look, command.id, input);\n",
        "        parent.appendChild(input);\n",
        "        break;\n",
        "      }\n",
        "      case \"number\": {\n",
        "        const input = numberElement(command.id, command.low, command.high, command.value);\n",
        "        input.addEventListener(\"change\", () => {\n",
        "          startAudio();\n",
        "          report({ ev: \"slide\", id: command.id, value: Number(input.value),\n",
        "            reports: { [\"value.\" + command.id]: input.value } });\n",
        "        });\n",
        "        values.set(command.id, (value) => { input.value = String(value); });\n",
        "        remember(look, command.id, input);\n",
        "        parent.appendChild(input);\n",
        "        break;\n",
        "      }\n",
        "      case \"set_checked\":\n",
        "        if (checks.has(command.id)) checks.get(command.id)(command.checked);\n",
        "        break;\n",
        "      case \"set_value\":\n",
        "        if (values.has(command.id)) values.get(command.id)(command.value);\n",
        "        break;\n",
        "      case \"button\": {\n",
        "        const button = document.createElement(\"button\");\n",
        "        button.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
        "        button.textContent = command.title;\n",
        "        button.addEventListener(\"click\", () => {\n",
        "          startAudio();\n",
        "          report({ ev: \"click\", id: command.id });\n",
        "        });\n",
        "        remember(look, command.id, button);\n",
        "        parent.appendChild(button);\n",
        "        break;\n",
        "      }\n",
        "      case \"label\": {\n",
        "        const text = document.createElement(\"div\");\n",
        "        text.className = \"tinyweb-label\";\n",
        "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
        "        text.textContent = command.text;\n",
        "        labels.set(command.id, text);\n",
        "        remember(look, command.id, text);\n",
        "        parent.appendChild(text);\n",
        "        break;\n",
        "      }\n",
        "      case \"row\":\n",
        "      case \"column\": {\n",
        "        const row = rowElement(command.id, command.op === \"row\");\n",
        "        rows.set(command.id, row);\n",
        "        remember(look, command.id, row);\n",
        "        parent.appendChild(row);\n",
        "        break;\n",
        "      }\n",
        "      case \"inside\":\n",
        "        parent = rows.get(command.id) || box;\n",
        "        break;\n",
        "      case \"outside\":\n",
        "        parent = box;\n",
        "        break;\n",
        "      case \"set_label\":\n",
        "        // A label's text, or a button's title.\n",
        "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
        "        else if (look.elements.get(command.id)?.tagName === \"BUTTON\") {\n",
        "          look.elements.get(command.id).textContent = command.text;\n",
        "        }\n",
        "        break;\n",
        "      case \"slider\": {\n",
        "        const row = document.createElement(\"label\");\n",
        "        row.className = \"tinyweb-slider\";\n",
        "        row.style.cssText = \"display:flex;align-items:center;gap:8px\";\n",
        "        const input = document.createElement(\"input\");\n",
        "        input.type = \"range\";\n",
        "        input.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
        "        input.min = String(command.low);\n",
        "        input.max = String(command.high);\n",
        "        input.value = String(command.value);\n",
        "        const shown = document.createElement(\"span\");\n",
        "        shown.textContent = input.value;\n",
        "        input.addEventListener(\"input\", () => {\n",
        "          shown.textContent = input.value;\n",
        "          report({ ev: \"slide\", id: command.id, value: Number(input.value),\n",
        "            reports: { [\"value.\" + command.id]: input.value } });\n",
        "        });\n",
        "        row.append(input, shown);\n",
        "        values.set(command.id, (value) => {\n",
        "          input.value = String(value);\n",
        "          shown.textContent = input.value;\n",
        "        });\n",
        "        remember(look, command.id, input);\n",
        "        parent.appendChild(row);\n",
        "        break;\n",
        "      }\n",
        "      case \"style\":\n",
        "        applyStyle(look, command.id, command.kind, command.prop, command.value);\n",
        "        break;\n",
        "      case \"load\":\n",
        "        samples.set(command.id, loadSample(command.name));\n",
        "        break;\n",
        "      case \"cmd\":\n",
        "        if (engine.sounds(command) && splashWanted()) {\n",
        "          showSplash();\n",
        "          held.push(command);\n",
        "        } else {\n",
        "          engine.command(command);\n",
        "        }\n",
        "        break;\n",
        "      case \"splash\":\n",
        "        if (splashWanted()) showSplash();\n",
        "        break;\n",
        "      case \"splash_text\":\n",
        "        splashText = command.text;\n",
        "        break;\n",
        "      case \"on_frame\":\n",
        "        if (!frameWanted) {\n",
        "          frameWanted = true;\n",
        "          frameRequest = requestAnimationFrame(frame);\n",
        "        }\n",
        "        break;\n",
        "      case \"frame_done\":\n",
        "        frameWaiting = false;\n",
        "        break;\n",
        "      case \"sdelay\":\n",
        "        sdelay(command);\n",
        "        break;\n",
        "      case \"on_mouse\": {\n",
        "        const entry = canvases.get(command.c);\n",
        "        if (entry) entry.mouse = true;\n",
        "        break;\n",
        "      }\n",
        "      case \"on_pointer\": {\n",
        "        const entry = canvases.get(command.c);\n",
        "        if (entry) entry.pointer = true;\n",
        "        break;\n",
        "      }\n",
        "      case \"on_key\":\n",
        "        keysWanted = true;\n",
        "        // Inside another page the keys go where the focus is, which is\n",
        "        // still the Run button that started the program; one typing in\n",
        "        // an editor keeps it.\n",
        "        if (!standalone && !typing()) element.focus({ preventScroll: true });\n",
        "        break;\n",
        "    }\n",
        "  }\n",
        "\n",
        "  function typing() {\n",
        "    const active = document.activeElement;\n",
        "    return !!active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName));\n",
        "  }\n",
        "\n",
        "  function freeze() {\n",
        "    if (closed) return;\n",
        "    closed = true;\n",
        "    cancelAnimationFrame(frameRequest);\n",
        "    if (pacer !== 0) clearInterval(pacer);\n",
        "    if (splash !== null) {\n",
        "      window.removeEventListener(\"keydown\", dismissSplash, true);\n",
        "      splash.remove();\n",
        "    }\n",
        "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
        "    keyTarget.removeEventListener(\"keyup\", onKeyUp);\n",
        "    window.removeEventListener(\"blur\", onBlur);\n",
        "    if (!standalone) element.removeEventListener(\"click\", takeFocus);\n",
        "    engine.close();\n",
        "    if (audio !== null) audio.close();\n",
        "  }\n",
        "\n",
        "  return {\n",
        "    receive(commands) {\n",
        "      if (closed) return;\n",
        "      for (const command of commands) take(command);\n",
        "    },\n",
        "    // Stops: no more events, frames or sound, and what is shown stays.\n",
        "    freeze,\n",
        "    close() {\n",
        "      freeze();\n",
        "      box.remove();\n",
        "      unstyled(look);\n",
        "      if (focusable) {\n",
        "        element.removeAttribute(\"tabindex\");\n",
        "        element.blur();\n",
        "      }\n",
        "    },\n",
        "  };\n",
        "}\n",
    };
    // END tinyweb page
}
