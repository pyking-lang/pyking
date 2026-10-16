// The Java implementation of the names declared in math_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not.
//
// `java.lang.Math` is written out in full: the Pyking module `math`
// compiles to a class `Math` in the same (unnamed) package as this one,
// which an unqualified `Math` would name.

public final class MathExternal {

    public static double host_sin(double x) { return java.lang.Math.sin(x); }
    public static double host_cos(double x) { return java.lang.Math.cos(x); }
    public static double host_tan(double x) { return java.lang.Math.tan(x); }
    public static double host_asin(double x) { return java.lang.Math.asin(x); }
    public static double host_acos(double x) { return java.lang.Math.acos(x); }
    public static double host_atan(double x) { return java.lang.Math.atan(x); }
    public static double host_atan2(double y, double x) { return java.lang.Math.atan2(y, x); }
    public static double host_sinh(double x) { return java.lang.Math.sinh(x); }
    public static double host_cosh(double x) { return java.lang.Math.cosh(x); }
    public static double host_tanh(double x) { return java.lang.Math.tanh(x); }
    public static double host_exp(double x) { return java.lang.Math.exp(x); }
    public static double host_log(double x) { return java.lang.Math.log(x); }
    public static double host_log10(double x) { return java.lang.Math.log10(x); }
    public static double host_sqrt(double x) { return java.lang.Math.sqrt(x); }
    public static double host_cbrt(double x) { return java.lang.Math.cbrt(x); }
    public static double host_pow(double x, double y) { return java.lang.Math.pow(x, y); }
    public static double host_hypot(double x, double y) { return java.lang.Math.hypot(x, y); }
    public static double host_floor(double x) { return java.lang.Math.floor(x); }
    public static double host_ceil(double x) { return java.lang.Math.ceil(x); }

    // Java has no log2: a power of two is answered by its exponent,
    // exactly, and anything else through the natural logarithm.
    public static double host_log2(double x) {
        if (x > 0.0 && !Double.isInfinite(x)) {
            int exponent = java.lang.Math.getExponent(x);
            if (x == java.lang.Math.scalb(1.0, exponent)) {
                return exponent;
            }
        }
        return java.lang.Math.log(x) / java.lang.Math.log(2.0);
    }

    // Nor a trunc: toward zero is down for a positive number and up for
    // a negative one.
    public static double host_trunc(double x) {
        return x < 0.0 ? java.lang.Math.ceil(x) : java.lang.Math.floor(x);
    }
}
