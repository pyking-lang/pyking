// The Java implementation of the Pyking module declared in
// external_float_mod1_external.pyk. Java requires the file name and the
// public class to match, so this one file is capitalised where its
// siblings are not. A Pyking Float is a Java double.

public final class ExternalFloatMod1External {

    public static double halve(double x) {
        return x / 2.0;
    }

    public static double hypot_sq(double a, double b) {
        return (a * a) + (b * b);
    }

    public static double widen(int n) {
        return (double) n;
    }

    public static double epsilon = 0.5;
}
