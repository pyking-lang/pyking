/* The C implementation of the names declared in math_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>.

   <math.h> is the system's, in angle brackets: the module `math`
   compiles to a math.h of its own beside the program, which a quoted
   include would find. A program using it is linked with -lm.

   C89's <math.h> has no log2, cbrt, hypot or trunc. Where the compiler
   is C99 or later they are the library's; under C89 they are written
   here, exact where the library's are exact -- a power of two's
   logarithm, a 3-4-5 triangle; math.pyk makes a perfect cube's root
   exact on every host. */

#include <math.h>

double math_host_sin(double x);
double math_host_cos(double x);
double math_host_tan(double x);
double math_host_asin(double x);
double math_host_acos(double x);
double math_host_atan(double x);
double math_host_sinh(double x);
double math_host_cosh(double x);
double math_host_tanh(double x);
double math_host_exp(double x);
double math_host_log(double x);
double math_host_log10(double x);
double math_host_sqrt(double x);
double math_host_floor(double x);
double math_host_ceil(double x);
double math_host_atan2(double y, double x);
double math_host_pow(double x, double y);
double math_host_log2(double x);
double math_host_cbrt(double x);
double math_host_hypot(double x, double y);
double math_host_trunc(double x);

double math_host_sin(double x)
{
    return sin(x);
}

double math_host_cos(double x)
{
    return cos(x);
}

double math_host_tan(double x)
{
    return tan(x);
}

double math_host_asin(double x)
{
    return asin(x);
}

double math_host_acos(double x)
{
    return acos(x);
}

double math_host_atan(double x)
{
    return atan(x);
}

double math_host_sinh(double x)
{
    return sinh(x);
}

double math_host_cosh(double x)
{
    return cosh(x);
}

double math_host_tanh(double x)
{
    return tanh(x);
}

double math_host_exp(double x)
{
    return exp(x);
}

double math_host_log(double x)
{
    return log(x);
}

double math_host_log10(double x)
{
    return log10(x);
}

double math_host_sqrt(double x)
{
    return sqrt(x);
}

double math_host_floor(double x)
{
    return floor(x);
}

double math_host_ceil(double x)
{
    return ceil(x);
}

double math_host_atan2(double y, double x)
{
    return atan2(y, x);
}

double math_host_pow(double x, double y)
{
    return pow(x, y);
}

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L

double math_host_log2(double x)
{
    return log2(x);
}

double math_host_cbrt(double x)
{
    return cbrt(x);
}

double math_host_hypot(double x, double y)
{
    return hypot(x, y);
}

double math_host_trunc(double x)
{
    return trunc(x);
}

#else

double math_host_log2(double x)
{
    int exponent;
    /* Finite and positive: a power of two is its mantissa 0.5. */
    if (x > 0.0 && x - x == 0.0 && frexp(x, &exponent) == 0.5) {
        return (double) (exponent - 1);
    }
    return log(x) / log(2.0);
}

double math_host_cbrt(double x)
{
    double y;
    if (x == 0.0 || x - x != 0.0) {
        return x;
    }
    y = pow(fabs(x), 1.0 / 3.0);
    return x < 0.0 ? -y : y;
}

double math_host_hypot(double x, double y)
{
    double a = fabs(x), b = fabs(y), t;
    if (a == HUGE_VAL || b == HUGE_VAL) {
        return HUGE_VAL;
    }
    if (a != a || b != b) {
        return a + b;
    }
    if (a < b) {
        t = a;
        a = b;
        b = t;
    }
    if (a == 0.0) {
        return 0.0;
    }
    t = b / a;
    return a * sqrt(1.0 + t * t);
}

double math_host_trunc(double x)
{
    return x < 0.0 ? ceil(x) : floor(x);
}

#endif
