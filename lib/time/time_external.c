/* The C implementation of the names declared in time_external.pyk. The
   program that imports it declares these from the signatures, so there
   is no header to write here: a name is <module>_<field>. Every time is
   UTC, as on every other target.

   A tuple crosses as the struct the compiler writes for it, so `now`
   answers that struct, declared here exactly as the program declares
   it (docs/target_c.md, "Tuples"). */

#include <time.h>

#ifndef PYK_TYPE_PYK_T_TIIIIII_
#define PYK_TYPE_PYK_T_TIIIIII_
typedef struct pyk_t_Tiiiiii_ {
    int a0;
    int a1;
    int a2;
    int a3;
    int a4;
    int a5;
} pyk_t_Tiiiiii_;
#endif

int time_instant(void);
pyk_t_Tiiiiii_ time_now(void);
int time_year_of(int seconds);
int time_month_of(int seconds);
int time_day_of(int seconds);
int time_hour_of(int seconds);
int time_minute_of(int seconds);
int time_second_of(int seconds);

int time_instant(void)
{
    return (int)time(NULL);
}

static struct tm time_parts(int seconds)
{
    time_t t = (time_t)seconds;
    return *gmtime(&t);
}

pyk_t_Tiiiiii_ time_now(void)
{
    struct tm parts = time_parts(time_instant());
    pyk_t_Tiiiiii_ out;
    out.a0 = parts.tm_year + 1900;
    out.a1 = parts.tm_mon + 1;
    out.a2 = parts.tm_mday;
    out.a3 = parts.tm_hour;
    out.a4 = parts.tm_min;
    out.a5 = parts.tm_sec;
    return out;
}

int time_year_of(int seconds)
{
    return time_parts(seconds).tm_year + 1900;
}

int time_month_of(int seconds)
{
    return time_parts(seconds).tm_mon + 1;
}

int time_day_of(int seconds)
{
    return time_parts(seconds).tm_mday;
}

int time_hour_of(int seconds)
{
    return time_parts(seconds).tm_hour;
}

int time_minute_of(int seconds)
{
    return time_parts(seconds).tm_min;
}

int time_second_of(int seconds)
{
    return time_parts(seconds).tm_sec;
}
