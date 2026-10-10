/* A Pyking function is a pointer to a C function; `later` runs its
   callback once main has returned. */

#include <stdlib.h>
#include <string.h>

void external_callback_mod1_each(void (*f)(int), int n);
void external_callback_mod1_with_float(void (*f)(double), double x);
void external_callback_mod1_with_pair(void (*f)(int, const char *), int n, const char *s);
void external_callback_mod1_later(void (*f)(void));

void external_callback_mod1_each(void (*f)(int), int n)
{
    int i;
    for (i = 0; i < n; i++) f(i);
}

void external_callback_mod1_with_float(void (*f)(double), double x)
{
    f(x * 2);
}

void external_callback_mod1_with_pair(void (*f)(int, const char *), int n, const char *s)
{
    char *joined = malloc(strlen(s) + 2);
    strcpy(joined, s);
    strcat(joined, "!");
    f(n + 1, joined);
}

void external_callback_mod1_later(void (*f)(void))
{
    atexit(f);
}
