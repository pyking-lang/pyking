/* The C implementation of the names declared in io_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>, and a String
   is a const char *.

   A Bool is spelled differently by the two C targets, `int` for c89 and
   `bool` for c23, which is what the block below is for.

   A line is read into memory that is never freed, which is what the C
   backend does for Pyking's own `++` (docs/target_c.md). `printf`, which
   `print` compiles to, writes to the same stdout as `fputs` does here,
   so the two interleave in the order they ran. */

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#include <stdbool.h>
#else
typedef int bool;
#define true 1
#define false 0
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void io_write(const char *text);
void io_write_line(const char *text);
const char *io_read(void);
bool io_is_eof(void);
const char *io_prompt_line(const char *prompt);

void io_write(const char *text)
{
    fputs(text, stdout);
}

void io_write_line(const char *text)
{
    fputs(text, stdout);
    fputc('\n', stdout);
}

/* Appends one character to a growing buffer, doubling it when full. */
static char *append(char *buffer, size_t *length, size_t *capacity, int c)
{
    if (*length + 1 >= *capacity) {
        *capacity = *capacity * 2;
        buffer = realloc(buffer, *capacity);
    }
    buffer[*length] = (char)c;
    *length = *length + 1;
    return buffer;
}

const char *io_prompt_line(const char *prompt)
{
    size_t length = 0;
    size_t capacity = 80;
    char *buffer = malloc(capacity);
    int c;

    fputs(prompt, stdout);
    fflush(stdout);
    while ((c = getchar()) != EOF && c != '\n') {
        buffer = append(buffer, &length, &capacity, c);
    }
    if (length > 0 && buffer[length - 1] == '\r') {
        length = length - 1;
    }
    buffer[length] = '\0';
    return buffer;
}

const char *io_read(void)
{
    size_t length = 0;
    size_t capacity = 4096;
    char *buffer = malloc(capacity);
    int c;

    fflush(stdout);
    while ((c = getchar()) != EOF) {
        buffer = append(buffer, &length, &capacity, c);
    }
    buffer[length] = '\0';
    return buffer;
}

bool io_is_eof(void)
{
    int c;

    fflush(stdout);
    c = getchar();
    if (c == EOF) {
        return true;
    }
    ungetc(c, stdin);
    return false;
}
