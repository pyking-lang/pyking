/* The C implementation of the Pyking module declared in
   external_all_mod1.external.pyk. The program that imports it declares
   these from the signatures, so there is no header to write here: a
   name is <module>_<field>, and a String is a const char *.

   A Bool is the one type the two C targets spell differently: `c89`
   declares it `int` and `c23` declares it `bool`, because that is what
   each standard has. One file serving both has to agree with whichever
   it is compiled under, which is what the block below is for -- the
   same shape a portable C library uses.

   Concatenation allocates and never frees, which is what the C backend
   does for Pyking's own `++` (docs/target_c.md): Pyking has no
   ownership to compile into a free, and an implementation on this side
   of the boundary has none either. */

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#include <stdbool.h>
#else
typedef int bool;
#define true 1
#define false 0
#endif

#include <stdlib.h>
#include <string.h>

const char *external_all_mod1_shout(const char *s);
int external_all_mod1_twice(int n);
bool external_all_mod1_flip(bool b);

int external_all_mod1_origin = 0;
const char *external_all_mod1_greeting = "hello";

const char *external_all_mod1_shout(const char *s)
{
    size_t length = strlen(s);
    char *result = malloc(length + 2);
    memcpy(result, s, length);
    result[length] = '!';
    result[length + 1] = '\0';
    return result;
}

int external_all_mod1_twice(int n)
{
    return n * 2;
}

bool external_all_mod1_flip(bool b)
{
    return !b;
}
