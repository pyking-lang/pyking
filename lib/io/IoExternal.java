// The Java implementation of the names declared in io_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not: the generated
// program calls IoExternal.write_line.
//
// Standard input is one reader for the whole run, marked before a
// character is looked at so that `is_eof` can put it back. `print`
// compiles to System.out.println, the same stream `write` uses.

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

public final class IoExternal {

    private static final BufferedReader INPUT =
        new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));

    public static void write(String text) {
        System.out.print(text);
    }

    public static void write_line(String text) {
        System.out.print(text);
        System.out.print('\n');
    }

    // readLine drops "\n", "\r\n" and a lone "\r" alike, and answers
    // null at the end of the input.
    public static String prompt_line(String prompt) {
        System.out.print(prompt);
        System.out.flush();
        try {
            String line = INPUT.readLine();
            return line == null ? "" : line;
        } catch (IOException error) {
            return "";
        }
    }

    public static String read() {
        System.out.flush();
        StringBuilder text = new StringBuilder();
        char[] chunk = new char[4096];
        try {
            int count;
            while ((count = INPUT.read(chunk, 0, chunk.length)) != -1) {
                text.append(chunk, 0, count);
            }
        } catch (IOException error) {
            return text.toString();
        }
        return text.toString();
    }

    public static boolean is_eof() {
        System.out.flush();
        try {
            INPUT.mark(1);
            if (INPUT.read() == -1) {
                return true;
            }
            INPUT.reset();
            return false;
        } catch (IOException error) {
            return true;
        }
    }
}
