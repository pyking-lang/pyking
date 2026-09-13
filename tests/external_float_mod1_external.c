/* The C implementation of the Pyking module declared in
   external_float_mod1.external.pyk. A Pyking Float is a double, which
   both C standards spell the same way -- so unlike a Bool, this file
   needs nothing to serve c89 and c23 alike. */

double external_float_mod1_halve(double x);
double external_float_mod1_hypot_sq(double a, double b);
double external_float_mod1_widen(int n);

double external_float_mod1_epsilon = 0.5;

double external_float_mod1_halve(double x)
{
    return x / 2.0;
}

double external_float_mod1_hypot_sq(double a, double b)
{
    return (a * a) + (b * b);
}

double external_float_mod1_widen(int n)
{
    return (double)n;
}
