/* The C implementation of the names declared in sys_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>.

   Only `exit` is here. `args` and `env` answer a list, which the C
   targets have no representation for, and `prog_name` and `prog_path`
   need the program's own argv, which this file cannot see -- so a
   program using any of the four does not build for C
   (docs/libraries.md). */

#include <stdio.h>
#include <stdlib.h>

void sys_exit(int code);

void sys_exit(int code)
{
    fflush(stdout);
    exit(code);
}
