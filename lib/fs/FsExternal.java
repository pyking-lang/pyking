// The Java implementation of the Pyking module declared in
// fs_external.pyk. Java requires the file name and the public class to
// match, so this one file is capitalised where its siblings are not:
// the generated program calls FsExternal.read_text.

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

public final class FsExternal {

    // Reading a file that is not there is undefined (fs_external.pyk),
    // and the empty string is this host's version of undefined: there
    // is no value in Pyking that means "no file".
    //
    // readAllBytes/write rather than readString/writeString: the latter
    // two arrived in Java 11, and this one file serves java8 as well.
    public static String read_text(String filename) {
        try {
            byte[] bytes = Files.readAllBytes(Paths.get(filename));
            return new String(bytes, StandardCharsets.UTF_8);
        } catch (IOException error) {
            return "";
        }
    }

    public static void write_text(String filename, String text) {
        try {
            Files.write(Paths.get(filename), text.getBytes(StandardCharsets.UTF_8));
        } catch (IOException error) {
            return;
        }
    }

    public static boolean exists(String filename) {
        Path path = Paths.get(filename);
        return Files.isRegularFile(path);
    }
}
