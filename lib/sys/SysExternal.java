// The Java implementation of the names declared in sys_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not.
//
// Only `exit` is here. `args` and `env` answer a list, which the Java
// targets have no representation for, and `prog_name` and `prog_path`
// need the program's own arguments, which this class cannot see -- so a
// program using any of the four does not build for Java
// (docs/libraries.md).

public final class SysExternal {

    public static void exit(int code) {
        System.out.flush();
        System.exit(code);
    }
}
