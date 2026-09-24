#ifndef MT_ICON_SERVICE_EXECUTION_COUNTERS_H
#define MT_ICON_SERVICE_EXECUTION_COUNTERS_H

#include <stdatomic.h>
#include <stdint.h>

static inline void MTIconServiceCount32(_Atomic(uint32_t) *counter) {
    uint32_t value = atomic_load_explicit(counter, memory_order_relaxed);
    while (value < UINT32_MAX &&
        !atomic_compare_exchange_weak_explicit(counter, &value,
            value + 1, memory_order_relaxed, memory_order_relaxed)) {}
}

// Older observation structs retain their 64-bit layout for binary tooling;
// their Runtime 208 counts are also saturated at the published 32-bit bound.
static inline void MTIconServiceCount64(_Atomic(uint64_t) *counter) {
    uint64_t value = atomic_load_explicit(counter, memory_order_relaxed);
    while (value < UINT32_MAX &&
        !atomic_compare_exchange_weak_explicit(counter, &value,
            value + 1, memory_order_relaxed, memory_order_relaxed)) {}
}

#endif
