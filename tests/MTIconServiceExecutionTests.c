#include "MTIconServiceApplyEvidence.h"
#include "MTIconServiceExecutionCounters.h"

#include <assert.h>
#include <pthread.h>

static _Atomic(uint32_t) calls;
static _Atomic(uint64_t) returns;

static void *increment(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 10000; i++) {
        MTIconServiceCount32(&calls);
        MTIconServiceCount64(&returns);
    }
    return NULL;
}

int main(void) {
    assert(!MTIconServiceApplyEvidenceSatisfied(false, true, 1, 1));
    assert(!MTIconServiceApplyEvidenceSatisfied(true, true, 0, 1));
    assert(!MTIconServiceApplyEvidenceSatisfied(true, true, 1, 0));
    assert(MTIconServiceApplyEvidenceSatisfied(true, true, 1, 1));
    assert(MTIconServiceApplyEvidenceSatisfied(true, false, 0, 0));
    assert(!MTIconServiceApplyEvidenceSatisfied(false, false, 1, 1));

    pthread_t threads[4];
    for (unsigned i = 0; i < 4; i++) {
        assert(pthread_create(&threads[i], NULL, increment, NULL) == 0);
    }
    for (unsigned i = 0; i < 4; i++) {
        assert(pthread_join(threads[i], NULL) == 0);
    }
    assert(atomic_load(&calls) == 40000);
    assert(atomic_load(&returns) == 40000);
    atomic_store(&calls, UINT32_MAX - 1);
    atomic_store(&returns, UINT32_MAX - 1);
    for (unsigned i = 0; i < 4; i++) {
        assert(pthread_create(&threads[i], NULL, increment, NULL) == 0);
    }
    for (unsigned i = 0; i < 4; i++) {
        assert(pthread_join(threads[i], NULL) == 0);
    }
    assert(atomic_load(&calls) == UINT32_MAX);
    assert(atomic_load(&returns) == UINT32_MAX);
    return 0;
}
