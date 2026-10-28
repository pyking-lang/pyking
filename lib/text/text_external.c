/* The C implementation of the names declared in text_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>, and a String
   is a const char *.

   A string is UTF-8 bytes, so a position in code points is found by
   walking from the start: a code point begins at every byte that is not
   a continuation byte (10xxxxxx).

   A String answered here is allocated and never freed, which is what the
   C backend does for Pyking's own `++` (docs/target_c.md). */

#include <stdlib.h>
#include <string.h>

int text_host_length(const char *s);
const char *text_host_slice(const char *s, int start, int stop);
int text_host_find(const char *s, const char *part, int start);
int text_host_code(const char *s, int k);
const char *text_host_replace(const char *s, const char *old, const char *by);
const char *text_host_upper(const char *s);
const char *text_host_lower(const char *s);

#define CONTINUES(c) ((((unsigned char) (c)) & 0xC0) == 0x80)

/* Where code point `k` begins, counting from `from`. */
static const char *text_skip(const char *from, int k)
{
    while (k > 0 && *from != '\0') {
        from++;
        while (*from != '\0' && CONTINUES(*from)) {
            from++;
        }
        k--;
    }
    return from;
}

/* The number of code points from `s` up to `stop`. */
static int text_points(const char *s, const char *stop)
{
    int n = 0;
    for (; s < stop; s++) {
        if (!CONTINUES(*s)) {
            n++;
        }
    }
    return n;
}

static char *text_copy(const char *from, size_t length)
{
    char *out = malloc(length + 1);
    memcpy(out, from, length);
    out[length] = '\0';
    return out;
}

int text_host_length(const char *s)
{
    return text_points(s, s + strlen(s));
}

const char *text_host_slice(const char *s, int start, int stop)
{
    const char *a = text_skip(s, start);
    const char *b = text_skip(a, stop - start);
    return text_copy(a, (size_t) (b - a));
}

int text_host_find(const char *s, const char *part, int start)
{
    const char *found = strstr(text_skip(s, start), part);
    return found == NULL ? -1 : text_points(s, found);
}

int text_host_code(const char *s, int k)
{
    const unsigned char *p = (const unsigned char *) text_skip(s, k);
    int extra, code, i;
    if (*p < 0x80) {
        return *p;
    } else if (*p >= 0xF0) {
        code = *p & 0x07;
        extra = 3;
    } else if (*p >= 0xE0) {
        code = *p & 0x0F;
        extra = 2;
    } else {
        code = *p & 0x1F;
        extra = 1;
    }
    for (i = 1; i <= extra && CONTINUES(p[i]); i++) {
        code = (code << 6) | (p[i] & 0x3F);
    }
    return code;
}

const char *text_host_replace(const char *s, const char *old, const char *by)
{
    size_t m = strlen(old), k = strlen(by), count = 0, length;
    const char *at, *found;
    char *out, *end;
    for (at = s; (found = strstr(at, old)) != NULL; at = found + m) {
        count++;
    }
    length = strlen(s) - count * m + count * k;
    out = malloc(length + 1);
    end = out;
    for (at = s; (found = strstr(at, old)) != NULL; at = found + m) {
        memcpy(end, at, (size_t) (found - at));
        end += found - at;
        memcpy(end, by, k);
        end += k;
    }
    strcpy(end, at);
    return out;
}

/* `s` with every byte from `low` to `high` moved by `by`. */
static const char *text_shifted(const char *s, char low, char high, int by)
{
    char *out = text_copy(s, strlen(s));
    char *p;
    for (p = out; *p != '\0'; p++) {
        if (*p >= low && *p <= high) {
            *p = (char) (*p + by);
        }
    }
    return out;
}

const char *text_host_upper(const char *s)
{
    return text_shifted(s, 'a', 'z', 'A' - 'a');
}

const char *text_host_lower(const char *s)
{
    return text_shifted(s, 'A', 'Z', 'a' - 'A');
}
