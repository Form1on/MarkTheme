#ifndef MT_ICON_SERVICE_APPLY_EVIDENCE_H
#define MT_ICON_SERVICE_APPLY_EVIDENCE_H

#include <stdbool.h>
#include <stdint.h>

// The native clear is necessary, but an application-icon theme additionally
// needs evidence from the same generation cycle's hooked return path.
static inline bool MTIconServiceApplyEvidenceSatisfied(
    bool verified, bool requestsApplicationIcons,
    uint32_t generationCalls, uint32_t replacementReturns) {
    return verified && (!requestsApplicationIcons ||
        (generationCalls > 0 && replacementReturns > 0));
}

#endif
