// The Java implementation of the names declared in sys_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not.
//
// A Java program's arguments reach only its `main`, so the generated
// `main` of a program that imports sys leaves them, and its own class,
// in two system properties this class reads: `pyking.args` and
// `pyking.main`. A list is a java.util.List and a tuple the runtime's
// PykRuntime.T2, which the compiler writes beside every program.

public final class SysExternal {

    public static java.util.List<String> args() {
        Object held = System.getProperties().get("pyking.args");
        String[] given = held instanceof String[] ? (String[]) held : new String[0];
        return java.util.Collections.unmodifiableList(java.util.Arrays.asList(given));
    }

    public static java.util.List<PykRuntime.T2<String, String>> env() {
        java.util.ArrayList<PykRuntime.T2<String, String>> out =
            new java.util.ArrayList<PykRuntime.T2<String, String>>();
        for (java.util.Map.Entry<String, String> e : System.getenv().entrySet()) {
            out.add(new PykRuntime.T2<String, String>(e.getKey(), e.getValue()));
        }
        return java.util.Collections.unmodifiableList(out);
    }

    // The program's own class: what a Java program is run as.
    public static String prog_name() {
        Object held = System.getProperties().get("pyking.main");
        return held instanceof Class ? ((Class<?>) held).getSimpleName() : "";
    }

    // The directory that class was loaded from.
    public static String prog_path() {
        Object held = System.getProperties().get("pyking.main");
        if (!(held instanceof Class)) return "";
        try {
            java.io.File where = new java.io.File(
                ((Class<?>) held).getProtectionDomain().getCodeSource().getLocation().toURI());
            return where.getAbsolutePath();
        } catch (Exception unknown) {
            return "";
        }
    }

    public static void exit(int code) {
        System.out.flush();
        System.exit(code);
    }
}
