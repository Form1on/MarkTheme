#ifndef MT_ICON_SERVICE_IMAGE_CONSTRUCTION_H
#define MT_ICON_SERVICE_IMAGE_CONSTRUCTION_H

#include <stdbool.h>

typedef enum MTIconServiceImageConstructionPath {
    MTIconServiceImageConstructionUnavailable = 0,
    MTIconServiceImageConstructionLegacy,
    MTIconServiceImageConstructionSplit,
} MTIconServiceImageConstructionPath;

// Inputs are exact ABI validation results, not selector-presence checks.
// Both constructors feed the same native serializer and final rehydrator.
static inline MTIconServiceImageConstructionPath MTIconServiceSelectImageConstruction(
    bool legacy, bool split, bool iconSizeSetter, bool bitmapData, bool rehydrator) {
    if (!bitmapData || !rehydrator) return MTIconServiceImageConstructionUnavailable;
    if (legacy) return MTIconServiceImageConstructionLegacy;
    if (split && iconSizeSetter) return MTIconServiceImageConstructionSplit;
    return MTIconServiceImageConstructionUnavailable;
}

static inline const char *MTIconServiceImageConstructionPathName(
    MTIconServiceImageConstructionPath path) {
    switch (path) {
        case MTIconServiceImageConstructionLegacy:
            return "legacy-cache-image-bitmap-data";
        case MTIconServiceImageConstructionSplit:
            return "split-cache-image-init-icon-size-bitmap-data";
        default:
            return "unavailable";
    }
}

#endif
