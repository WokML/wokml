#include "wok_rc.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    WokHeap* h = wok_heap_new();
    WokObj* p = wok_alloc(h, 7u, 2u);
    wok_slot_set(p, 0u, 0u /*WS_LIT_INT*/, 42u);
    wok_slot_set(p, 1u, 2u /*WS_LIT_UNIT*/, 0u);
    assert(wok_tag(p) == 7u);
    assert(wok_arity(p) == 2u);
    uint64_t t, v;
    wok_slot_get(p, 0u, &t, &v);
    assert(t == 0u && v == 42u);
    wok_dup(p);
    assert(wok_dec(p) == 1u);
    assert(wok_dec(p) == 0u);
    wok_free(h, p);
    assert(wok_stat_allocs(h) == 1u);
    assert(wok_stat_frees(h) == 1u);
    assert(wok_stat_live(h) == 0);
    assert(wok_stat_peak(h) == 1);
    wok_heap_free(h);
    printf("OK\n");
    return 0;
}
