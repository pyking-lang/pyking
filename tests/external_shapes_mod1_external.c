/* The C implementation of the Pyking module declared in
   external_shapes_mod1_external.pyk, for c23-gc: the one C target with
   lists. A tuple crosses as the struct the program declares for it and
   a list as a pointer to its first cell, NULL for `[]`, each declared
   here exactly as the program declares it and guarded the same
   (docs/target_c.md, "External modules"). Cells come from the
   collector, as the program's own do. */

#include <string.h>
#include <gc.h>

#ifndef PYK_TYPE_PYK_T_TSB_
#define PYK_TYPE_PYK_T_TSB_
typedef struct pyk_t_Tsb_ {
    const char *a0;
    bool a1;
} pyk_t_Tsb_;
#endif

#ifndef PYK_TYPE_PYK_L_LI_
#define PYK_TYPE_PYK_L_LI_
typedef struct pyk_l_Li_ {
    int head;
    struct pyk_l_Li_ *tail;
} pyk_l_Li_;
#endif

pyk_t_Tsb_ external_shapes_mod1_split(const char *s);
pyk_l_Li_ *external_shapes_mod1_counts(int n);

pyk_t_Tsb_ external_shapes_mod1_split(const char *s)
{
    pyk_t_Tsb_ v;
    v.a0 = s;
    v.a1 = strlen(s) > 1;
    return v;
}

/* [n, n + 1]. */
pyk_l_Li_ *external_shapes_mod1_counts(int n)
{
    pyk_l_Li_ *second = GC_MALLOC(sizeof *second);
    pyk_l_Li_ *first = GC_MALLOC(sizeof *first);
    second->head = n + 1;
    second->tail = NULL;
    first->head = n;
    first->tail = second;
    return first;
}
