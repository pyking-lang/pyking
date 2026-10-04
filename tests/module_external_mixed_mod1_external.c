/* The C implementation of what module_external_mixed_mod1_external.pyk
   declares. A name is <module>_<field> whichever half of the module
   provides it, so the private g2 is spelled the way the public g1 is. */

int module_external_mixed_mod1_g1(int x);
int module_external_mixed_mod1_g2(int x);

int module_external_mixed_mod1_g1(int x)
{
    return x + 100;
}

int module_external_mixed_mod1_g2(int x)
{
    return x + 1000;
}
