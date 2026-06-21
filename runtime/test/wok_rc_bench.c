#include "wok_rc.h"
#include <stdint.h>
#include <stdio.h>
#include <time.h>

/* Allocate then free a churn of small cells, exercising the reuse fast path.
   Build once as the arena (default) and once with -DWOK_RC_MALLOC to compare. */
int main(void) {
    enum { ROUNDS = 2000000 };
    WokHeap* h = wok_heap_new();
    clock_t t0 = clock();
    for (long i = 0; i < ROUNDS; i++) {
        WokObj* p = wok_alloc(h, 1u, 2u);   /* arity 2: the common Cons shape */
        p->rc = 0u;                          /* simulate drop-to-zero */
        wok_free(h, p);
    }
    clock_t t1 = clock();
    double ns = (double)(t1 - t0) / (double)CLOCKS_PER_SEC * 1e9 / (double)ROUNDS;
#ifdef WOK_RC_MALLOC
    const char* which = "malloc";
#else
    const char* which = "arena ";
#endif
    printf("%s  %.2f ns/alloc+free  (reused=%llu, slabs=%llu)\n",
           which, ns,
           (unsigned long long)wok_stat_reused(h),
           (unsigned long long)wok_stat_slabs(h));
    wok_heap_free(h);
    return 0;
}
