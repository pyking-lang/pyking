/* The C implementation of the Pyking module declared in
   fs.external.pyk. The program that imports it declares these from the
   signatures, so there is no header to write here: a name is
   <module>_<field>, and a String is a const char *.

   A Bool is the one type the two C targets spell differently: `c89`
   declares it `int` and `c23` declares it `bool`. One file serving both
   has to agree with whichever it is compiled under, which is what the
   block below is for.

   read_text allocates and never frees, which is what the C backend does
   for Pyking's own `++` (docs/target_c.md): Pyking has no ownership to
   compile into a free, and an implementation on this side of the
   boundary has none either. */

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#include <stdbool.h>
#else
typedef int bool;
#define true 1
#define false 0
#endif

#include <stdio.h>
#include <stdlib.h>

const char *fs_read_text(const char *filename);
void fs_write_text(const char *filename, const char *text);
bool fs_exists(const char *filename);

/* Reading a file that is not there is undefined (fs.external.pyk), and
   the empty string is this host's version of undefined: there is no
   value in Pyking that means "no file". */
const char *fs_read_text(const char *filename)
{
    FILE *handle = fopen(filename, "rb");
    long length;
    char *buffer;
    size_t read;

    if (handle == NULL) {
        return "";
    }
    fseek(handle, 0L, SEEK_END);
    length = ftell(handle);
    fseek(handle, 0L, SEEK_SET);
    buffer = malloc((size_t)length + 1);
    read = fread(buffer, 1, (size_t)length, handle);
    buffer[read] = '\0';
    fclose(handle);
    return buffer;
}

void fs_write_text(const char *filename, const char *text)
{
    FILE *handle = fopen(filename, "wb");
    if (handle == NULL) {
        return;
    }
    fputs(text, handle);
    fclose(handle);
}

bool fs_exists(const char *filename)
{
    FILE *handle = fopen(filename, "rb");
    if (handle == NULL) {
        return false;
    }
    fclose(handle);
    return true;
}
