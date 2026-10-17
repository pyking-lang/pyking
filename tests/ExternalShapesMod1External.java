// The Java implementation of the Pyking module declared in
// external_shapes_mod1_external.pyk. A Pyking tuple is the runtime's
// PykRuntime.T2, which the compiler writes beside every program, and a
// list is a java.util.List.

public final class ExternalShapesMod1External {

    public static PykRuntime.T2<String, Boolean> split(String s) {
        return new PykRuntime.T2<String, Boolean>(s, s.length() > 1);
    }

    public static java.util.List<Integer> counts(int n) {
        return java.util.Arrays.asList(n, n + 1);
    }
}
