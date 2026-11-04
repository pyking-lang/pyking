/* The C implementation of the names declared in sys_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>.

   Plain C (c89, c99, c23) has `exit` alone: `args` and `env` answer a
   list, which plain C has no heap for, so a program using either does
   not build there (docs/libraries.md).

   c23-gc compiles this file with PYKING_GC defined, and has all five. A
   list crosses as a pointer to its first cell, NULL for `[]`, and a
   tuple as the struct the program declares for it -- each declared
   below exactly as the program declares it, guarded the same, its
   cells from the collector (docs/target_c.md, "External modules"). The
   program's main hands this file its argv first, through
   pyk_sys_start, which is how `args`, `prog_name` and `prog_path` see
   it. */

#ifdef PYKING_GC
/* getcwd and environ are POSIX's, not ISO C's. */
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>

void sys_exit(int code);

void sys_exit(int code)
{
    fflush(stdout);
    exit(code);
}

#ifdef PYKING_GC
#include <string.h>
#include <unistd.h>
#include <gc.h>

#ifndef PYK_TYPE_PYK_L_LS_
#define PYK_TYPE_PYK_L_LS_
typedef struct pyk_l_Ls_ {
    const char *head;
    struct pyk_l_Ls_ *tail;
} pyk_l_Ls_;
#endif

#ifndef PYK_TYPE_PYK_T_TSS_
#define PYK_TYPE_PYK_T_TSS_
typedef struct pyk_t_Tss_ {
    const char *a0;
    const char *a1;
} pyk_t_Tss_;
#endif

#ifndef PYK_TYPE_PYK_L_LTSS__
#define PYK_TYPE_PYK_L_LTSS__
typedef struct pyk_l_LTss__ {
    pyk_t_Tss_ head;
    struct pyk_l_LTss__ *tail;
} pyk_l_LTss__;
#endif

extern char **environ;

void pyk_sys_start(int argc, char **argv);
pyk_l_Ls_ *sys_args(void);
pyk_l_LTss__ *sys_env(void);
const char *sys_prog_name(void);
const char *sys_prog_path(void);

static int sys_argc;
static char **sys_argv;

void pyk_sys_start(int argc, char **argv)
{
    sys_argc = argc;
    sys_argv = argv;
}

/* The first n bytes of s, as a String of their own. */
static const char *sys_copy(const char *s, size_t n)
{
    char *out = GC_MALLOC_ATOMIC(n + 1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

/* argv[0] is the program itself; its own arguments start at 1. */
pyk_l_Ls_ *sys_args(void)
{
    pyk_l_Ls_ *result = NULL;
    pyk_l_Ls_ **end = &result;
    int i;
    for (i = 1; i < sys_argc; i++) {
        *end = GC_MALLOC(sizeof **end);
        (*end)->head = sys_argv[i];
        (*end)->tail = NULL;
        end = &(*end)->tail;
    }
    return result;
}

pyk_l_LTss__ *sys_env(void)
{
    pyk_l_LTss__ *result = NULL;
    pyk_l_LTss__ **end = &result;
    char **entry;
    for (entry = environ; *entry != NULL; entry++) {
        const char *at = strchr(*entry, '=');
        if (at == NULL) {
            continue;
        }
        *end = GC_MALLOC(sizeof **end);
        (*end)->head.a0 = sys_copy(*entry, (size_t)(at - *entry));
        (*end)->head.a1 = at + 1;
        (*end)->tail = NULL;
        end = &(*end)->tail;
    }
    return result;
}

const char *sys_prog_name(void)
{
    const char *slash;
    if (sys_argc < 1) {
        return "";
    }
    slash = strrchr(sys_argv[0], '/');
    return slash == NULL ? sys_argv[0] : slash + 1;
}

/* The directory argv[0] names, made absolute against the working one. */
const char *sys_prog_path(void)
{
    char here[4096];
    const char *slash;
    const char *directory;
    char *out;
    if (sys_argc < 1) {
        return "";
    }
    slash = strrchr(sys_argv[0], '/');
    directory = slash == NULL ? "." : sys_copy(sys_argv[0], (size_t)(slash - sys_argv[0]));
    if (directory[0] == '/') {
        return directory;
    }
    if (getcwd(here, sizeof here) == NULL) {
        return directory;
    }
    out = GC_MALLOC_ATOMIC(strlen(here) + strlen(directory) + 2);
    strcpy(out, here);
    strcat(out, "/");
    strcat(out, directory);
    return out;
}
#endif
