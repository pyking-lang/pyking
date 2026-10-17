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

    private static int last = 0;
    private static double clock = 0.0;
    // Whether an event has been delivered: until one is, the program is
    // in its top level, whose sound a page connecting later still plays.
    private static volatile boolean delivered = false;
    private static final Map<Integer, Runnable> buttons = new HashMap<Integer, Runnable>();
    private static final Map<Integer, Consumer<Integer>> sliders =
        new HashMap<Integer, Consumer<Integer>>();
    private static final List<Consumer<Double>> frames = new ArrayList<Consumer<Double>>();
    private static final List<Object[]> mice = new ArrayList<Object[]>();
    private static final List<Consumer<String>> keys = new ArrayList<Consumer<String>>();
    private static boolean after = false;
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
        int canvas = -1;
        boolean clears = false;
        int label = -1;

        Command(String op) {
            this.op = op;
            this.json.append("{\"op\":").append(quote(op));
            this.line = new StringBuilder(op);
        }

        Command number(String name, int value) {
            json.append(",\"").append(name).append("\":").append(value);
            line.append(' ').append(value);
            return this;
        }

        Command seconds(String name, double value) {
            json.append(",\"").append(name).append("\":").append(Double.toString(value));
            line.append(' ').append(String.format(Locale.ROOT, "%.3f", value));
            return this;
        }

        Command bare(String name, String value) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            line.append(' ').append(value);
            return this;
        }

        Command text(String name, String value) {
            json.append(",\"").append(name).append("\":").append(quote(value));
            line.append(' ').append(quote(value));
            return this;
        }

        String json() {
            return json.toString() + "}";
        }
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

    private static int fresh() {
        last += 1;
        return last;
    }

    // --- the functions tinyweb_external.pyk declares ---

    public static void web_init(int port) {
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

    public static int canvas(int width, int height) {
        ready();
        int id = fresh();
        send(new Command("canvas").number("id", id).number("width", width)
            .number("height", height));
        return id;
    }

    public static void fill_canvas(int c, String color) {
        Command command = new Command("clear").number("c", c).bare("color", color);
        command.canvas = c;
        command.clears = true;
        send(command);
    }

    public static void draw_circle(int c, int x, int y, int radius, String color) {
        Command command = new Command("circle").number("c", c).number("x", x).number("y", y)
            .number("radius", radius).bare("color", color);
        command.canvas = c;
        send(command);
    }

    public static void draw_rect(int c, int x, int y, int width, int height, String color) {
        Command command = new Command("rect").number("c", c).number("x", x).number("y", y)
            .number("width", width).number("height", height).bare("color", color);
        command.canvas = c;
        send(command);
    }

    public static void draw_line(int c, int x1, int y1, int x2, int y2, String color,
                                 int width) {
        Command command = new Command("line").number("c", c).number("x1", x1)
            .number("y1", y1).number("x2", x2).number("y2", y2).bare("color", color)
            .number("width", width);
        command.canvas = c;
        send(command);
    }

    public static void draw_text(int c, int x, int y, String words, String color, int size) {
        Command command = new Command("text").number("c", c).number("x", x).number("y", y)
            .bare("color", color).number("size", size).text("words", words);
        command.canvas = c;
        send(command);
    }

    public static int make_button(String title, Runnable onClick) {
        ready();
        int id = fresh();
        buttons.put(id, onClick);
        send(new Command("button").number("id", id).text("title", title));
        return id;
    }

    public static int label(String text) {
        ready();
        int id = fresh();
        send(new Command("label").number("id", id).text("text", text));
        return id;
    }

    public static void set_label(int id, String text) {
        Command command = new Command("set_label").number("id", id).text("text", text);
        command.label = id;
        send(command);
    }

    public static void apply_style(int id, String kind, String property, String value) {
        send(new Command("style").number("id", id).bare("kind", kind).bare("prop", property)
            .text("value", value));
    }

    public static int make_slider(int low, int high, int value, Consumer<Integer> onChange) {
        ready();
        int id = fresh();
        sliders.put(id, onChange);
        send(new Command("slider").number("id", id).number("low", low).number("high", high)
            .number("value", value));
        return id;
    }

    public static int load_sample(String name) {
        ready();
        int id = fresh();
        send(new Command("load").number("id", id).text("name", name));
        return id;
    }

    public static void play_sample(int sample, double at, double volume, double rate) {
        send(new Command("play").number("sample", sample).seconds("at", at)
            .seconds("volume", volume).seconds("rate", rate));
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

    public static void on_frame(Consumer<Double> draw) {
        ready();
        frames.add(draw);
        send(new Command("on_frame"));
    }

    public static void on_mouse(int c, BiConsumer<Integer, Integer> click) {
        ready();
        mice.add(new Object[] {c, click});
        send(new Command("on_mouse").number("c", c));
    }

    public static void on_key(Consumer<String> pressed) {
        ready();
        keys.add(pressed);
        send(new Command("on_key"));
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
        String kind = event.get("ev");
        if ("click".equals(kind)) {
            Runnable f = buttons.get(integer(event, "id"));
            if (f != null) {
                f.run();
            }
        } else if ("slide".equals(kind)) {
            Consumer<Integer> f = sliders.get(integer(event, "id"));
            if (f != null) {
                f.accept(integer(event, "value"));
            }
        } else if ("frame".equals(kind)) {
            for (Consumer<Double> draw : new ArrayList<Consumer<Double>>(frames)) {
                draw.accept(clock);
            }
            send(new Command("frame_done"));
        } else if ("mouse".equals(kind)) {
            int c = integer(event, "c");
            for (Object[] entry : new ArrayList<Object[]>(mice)) {
                if ((Integer) entry[0] == c) {
                    ((BiConsumer<Integer, Integer>) entry[1])
                        .accept(integer(event, "x"), integer(event, "y"));
                }
            }
        } else if ("key".equals(kind)) {
            String key = event.containsKey("key") ? event.get("key") : "";
            for (Consumer<String> pressed : new ArrayList<Consumer<String>>(keys)) {
                pressed.accept(key);
            }
        }
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
     *  null. */
    private static Map<String, String> parseLine(String line) {
        Map<String, String> event = new HashMap<String, String>();
        if (line.startsWith("key ")) {
            event.put("ev", "key");
            event.put("key", line.substring(4));
            return event;
        }
        String[] words = line.trim().split("\\s+");
        try {
            if (words[0].equals("click") && words.length == 2) {
                event.put("id", String.valueOf(Integer.parseInt(words[1])));
            } else if (words[0].equals("slide") && words.length == 3) {
                event.put("id", String.valueOf(Integer.parseInt(words[1])));
                event.put("value", String.valueOf(Integer.parseInt(words[2])));
            } else if (words[0].equals("frame") && words.length == 2) {
                event.put("t", String.valueOf(Double.parseDouble(words[1])));
            } else if (words[0].equals("mouse") && words.length == 4) {
                event.put("c", String.valueOf(Integer.parseInt(words[1])));
                event.put("x", String.valueOf(Integer.parseInt(words[2])));
                event.put("y", String.valueOf(Integer.parseInt(words[3])));
            } else {
                return null;
            }
        } catch (NumberFormatException error) {
            return null;
        }
        event.put("ev", words[0]);
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

    /** The fields of one flat JSON object, each as its text: a string
     *  decoded, anything else as written. */
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
            boolean sound = op.equals("play") && delivered;
            if (!sound && !op.equals("frame_done") && !op.equals("event_done")) {
                List<Command> kept = new ArrayList<Command>();
                for (Command old : history) {
                    boolean hidden = (command.clears && old.canvas == command.canvas)
                        || (command.label >= 0 && old.label == command.label);
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
                flush();
                System.out.flush();
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
        "//   - on an iweb24 page, where tinyweb_external_interpreter.js mounts it\n",
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
        "// docs/libraries.md, \"tinyweb\". The web24 implementation,\n",
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
        "  accent: \"accent-color\", width: \"width\",\n",
        "};\n",
        "\n",
        "// The place a kind's property goes. String -> String -> String\n",
        "function placeOf(kind, property) {\n",
        "  if (kind === \"page\") return property === \"gap\" ? \"box\" : \"page\";\n",
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
        "function applyStyle(style, id, kind, property, value) {\n",
        "  if (kind === \"theme\") {\n",
        "    setTheme(style, value);\n",
        "    return;\n",
        "  }\n",
        "  const css = PROPERTIES[property];\n",
        "  if (!css) return;\n",
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
        "export function mountPage(element, sendEvent, { standalone = false, activated = false } = {}) {\n",
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
        "  let start = now();\n",
        "  let audio = null;\n",
        "  let offset = 0;\n",
        "  let frameWanted = false;\n",
        "  let frameWaiting = false;\n",
        "  let frameRequest = 0;\n",
        "  let closed = false;\n",
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
        "    return running() ? audio.currentTime + offset : (now() - start) / 1000;\n",
        "  }\n",
        "\n",
        "  function report(event) {\n",
        "    if (!closed && held === null) sendEvent({ ...event, t: clockNow(), running: running() });\n",
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
        "    if (held === null) return;\n",
        "    event?.preventDefault?.();\n",
        "    event?.stopImmediatePropagation?.();\n",
        "    window.removeEventListener(\"keydown\", dismissSplash, true);\n",
        "    splash.remove();\n",
        "    splash = null;\n",
        "    start += now() - heldAt;\n",
        "    const pending = held;\n",
        "    held = null;\n",
        "    startAudio();\n",
        "    for (const command of pending) carryOut(command);\n",
        "  }\n",
        "\n",
        "  // Sound may start only after the reader did something, so every\n",
        "  // gesture is a chance to start it.\n",
        "  function startAudio() {\n",
        "    if (audio === null) {\n",
        "      const Context = globalThis.AudioContext || globalThis.webkitAudioContext;\n",
        "      if (!Context) return;\n",
        "      const before = clockNow();\n",
        "      audio = new Context();\n",
        "      offset = before - audio.currentTime;\n",
        "      audio.onstatechange = () => {\n",
        "        if (audio.state === \"running\") offset = (now() - start) / 1000 - audio.currentTime;\n",
        "      };\n",
        "    }\n",
        "    if (audio.state === \"suspended\") audio.resume();\n",
        "  }\n",
        "\n",
        "  box.addEventListener(\"pointerdown\", startAudio);\n",
        "\n",
        "  function onKey(event) {\n",
        "    if (held !== null) {\n",
        "      dismissSplash(event);\n",
        "      return;\n",
        "    }\n",
        "    startAudio();\n",
        "    if (keysWanted) report({ ev: \"key\", key: event.key });\n",
        "  }\n",
        "  keyTarget.addEventListener(\"keydown\", onKey);\n",
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
        "  function play({ sample, at, volume, rate }) {\n",
        "    startAudio();\n",
        "    const loading = samples.get(sample);\n",
        "    if (!loading || audio === null) return;\n",
        "    loading.then((buffer) => {\n",
        "      if (buffer === null || closed) return;\n",
        "      const source = audio.createBufferSource();\n",
        "      source.buffer = buffer;\n",
        "      source.playbackRate.value = rate;\n",
        "      const gain = audio.createGain();\n",
        "      gain.gain.value = volume;\n",
        "      source.connect(gain).connect(audio.destination);\n",
        "      source.start(Math.max(audio.currentTime, at - offset));\n",
        "    });\n",
        "  }\n",
        "\n",
        "  function frame() {\n",
        "    if (closed) return;\n",
        "    if (!frameWaiting && held === null) {\n",
        "      frameWaiting = true;\n",
        "      report({ ev: \"frame\" });\n",
        "    }\n",
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
        "    canvases.set(id, { element, context, width, height, mouse: false });\n",
        "    remember(look, id, element);\n",
        "    element.addEventListener(\"click\", (event) => {\n",
        "      const entry = canvases.get(id);\n",
        "      if (!entry.mouse) return;\n",
        "      const bounds = element.getBoundingClientRect();\n",
        "      report({\n",
        "        ev: \"mouse\",\n",
        "        c: id,\n",
        "        x: Math.round(((event.clientX - bounds.left) * width) / bounds.width),\n",
        "        y: Math.round(((event.clientY - bounds.top) * height) / bounds.height),\n",
        "      });\n",
        "    });\n",
        "    box.appendChild(element);\n",
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
        "          g.fillStyle = command.color;\n",
        "          g.fillRect(0, 0, entry.width, entry.height);\n",
        "        });\n",
        "        break;\n",
        "      case \"circle\":\n",
        "        draw(command.c, (g) => {\n",
        "          g.fillStyle = command.color;\n",
        "          g.beginPath();\n",
        "          g.arc(command.x, command.y, Math.max(0, command.radius), 0, 2 * Math.PI);\n",
        "          g.fill();\n",
        "        });\n",
        "        break;\n",
        "      case \"rect\":\n",
        "        draw(command.c, (g) => {\n",
        "          g.fillStyle = command.color;\n",
        "          g.fillRect(command.x, command.y, command.width, command.height);\n",
        "        });\n",
        "        break;\n",
        "      case \"line\":\n",
        "        draw(command.c, (g) => {\n",
        "          g.strokeStyle = command.color;\n",
        "          g.lineWidth = command.width;\n",
        "          g.lineCap = \"round\";\n",
        "          g.beginPath();\n",
        "          g.moveTo(command.x1, command.y1);\n",
        "          g.lineTo(command.x2, command.y2);\n",
        "          g.stroke();\n",
        "        });\n",
        "        break;\n",
        "      case \"text\":\n",
        "        draw(command.c, (g) => {\n",
        "          g.fillStyle = command.color;\n",
        "          g.font = `${command.size}px system-ui, sans-serif`;\n",
        "          g.textBaseline = \"top\";\n",
        "          g.fillText(command.words, command.x, command.y);\n",
        "        });\n",
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
        "        box.appendChild(button);\n",
        "        break;\n",
        "      }\n",
        "      case \"label\": {\n",
        "        const text = document.createElement(\"div\");\n",
        "        text.className = \"tinyweb-label\";\n",
        "        text.setAttribute(\"data-tinyweb-id\", String(command.id));\n",
        "        text.textContent = command.text;\n",
        "        labels.set(command.id, text);\n",
        "        remember(look, command.id, text);\n",
        "        box.appendChild(text);\n",
        "        break;\n",
        "      }\n",
        "      case \"set_label\":\n",
        "        if (labels.has(command.id)) labels.get(command.id).textContent = command.text;\n",
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
        "          report({ ev: \"slide\", id: command.id, value: Number(input.value) });\n",
        "        });\n",
        "        row.append(input, shown);\n",
        "        remember(look, command.id, input);\n",
        "        box.appendChild(row);\n",
        "        break;\n",
        "      }\n",
        "      case \"style\":\n",
        "        applyStyle(look, command.id, command.kind, command.prop, command.value);\n",
        "        break;\n",
        "      case \"load\":\n",
        "        samples.set(command.id, loadSample(command.name));\n",
        "        break;\n",
        "      case \"play\":\n",
        "        if (splashWanted()) {\n",
        "          showSplash();\n",
        "          held.push(command);\n",
        "        } else {\n",
        "          play(command);\n",
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
        "      case \"on_mouse\": {\n",
        "        const entry = canvases.get(command.c);\n",
        "        if (entry) entry.mouse = true;\n",
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
        "    if (splash !== null) {\n",
        "      window.removeEventListener(\"keydown\", dismissSplash, true);\n",
        "      splash.remove();\n",
        "    }\n",
        "    keyTarget.removeEventListener(\"keydown\", onKey);\n",
        "    if (!standalone) element.removeEventListener(\"click\", takeFocus);\n",
        "    if (audio !== null) audio.close();\n",
        "  }\n",
        "\n",
        "  return {\n",
        "    receive(commands) {\n",
        "      if (closed) return;\n",
        "      for (const command of commands) {\n",
        "        if (held !== null) held.push(command);\n",
        "        else carryOut(command);\n",
        "      }\n",
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
