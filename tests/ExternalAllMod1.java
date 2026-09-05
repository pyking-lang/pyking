// The Java implementation of the Pyking module declared in
// external_all_mod1.external.pyk. Java requires the file name and the
// public class to match, so this one file is capitalised where its
// siblings are not: the generated program calls ExternalAllMod1.shout.

public final class ExternalAllMod1 {

    public static String shout(String s) {
        return s + "!";
    }

    public static int twice(int n) {
        return n * 2;
    }

    public static boolean flip(boolean b) {
        return !b;
    }

    public static int origin = 0;
    public static String greeting = "hello";
}
