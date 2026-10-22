// The Java implementation of the names declared in text_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not.
//
// A Java String is UTF-16, so a character past the first 65536 is two
// chars there and one code point in Pyking: every position is converted
// with offsetByCodePoints on the way in and codePointCount on the way
// out.

public final class TextExternal {

    public static int host_length(String s) {
        return s.codePointCount(0, s.length());
    }

    public static String host_slice(String s, int start, int stop) {
        int i = s.offsetByCodePoints(0, start);
        return s.substring(i, s.offsetByCodePoints(i, stop - start));
    }

    public static int host_find(String s, String part, int start) {
        int i = s.indexOf(part, s.offsetByCodePoints(0, start));
        return i < 0 ? -1 : s.codePointCount(0, i);
    }

    public static int host_code(String s, int k) {
        return s.codePointAt(s.offsetByCodePoints(0, k));
    }

    public static String host_from_code(int n) {
        return new String(Character.toChars(n));
    }

    public static String host_replace(String s, String old, String by) {
        return s.replace(old, by);
    }

    public static String host_upper(String s) {
        return shifted(s, 'a', 'z', 'A' - 'a');
    }

    public static String host_lower(String s) {
        return shifted(s, 'A', 'Z', 'a' - 'A');
    }

    // `s` with every char from `low` to `high` moved by `by`.
    private static String shifted(String s, char low, char high, int by) {
        StringBuilder out = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            out.append(c >= low && c <= high ? (char) (c + by) : c);
        }
        return out.toString();
    }
}
