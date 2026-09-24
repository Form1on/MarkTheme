#include "MTIconServiceImageConstruction.h"
#include <assert.h>
#include <string.h>

int main(void) {
    assert(MTIconServiceSelectImageConstruction(1, 1, 1, 1, 1) == MTIconServiceImageConstructionLegacy);
    assert(MTIconServiceSelectImageConstruction(1, 0, 0, 1, 1) == MTIconServiceImageConstructionLegacy);
    assert(MTIconServiceSelectImageConstruction(0, 1, 1, 1, 1) == MTIconServiceImageConstructionSplit);
    assert(MTIconServiceSelectImageConstruction(0, 0, 1, 1, 1) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(0, 1, 0, 1, 1) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(0, 1, 1, 0, 1) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(0, 1, 1, 1, 0) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(1, 1, 1, 0, 1) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(1, 1, 1, 1, 0) == MTIconServiceImageConstructionUnavailable);
    assert(MTIconServiceSelectImageConstruction(0, 0, 0, 0, 0) == MTIconServiceImageConstructionUnavailable);
    assert(strcmp(MTIconServiceImageConstructionPathName(MTIconServiceImageConstructionLegacy),
                  "legacy-cache-image-bitmap-data") == 0);
    assert(strcmp(MTIconServiceImageConstructionPathName(MTIconServiceImageConstructionSplit),
                  "split-cache-image-init-icon-size-bitmap-data") == 0);
    assert(strcmp(MTIconServiceImageConstructionPathName(MTIconServiceImageConstructionUnavailable),
                  "unavailable") == 0);
    return 0;
}
