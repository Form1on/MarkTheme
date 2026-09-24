#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTIconServiceRuntimeMode.h"

@class MTIconServiceImageResolver;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceGenerationAdapterErrorDomain;

typedef struct MTIconServiceGenerationObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) acceptedRequests;
    _Atomic(uint64_t) resolverHits;
    _Atomic(uint64_t) replacements;
    _Atomic(uint64_t) fallbacks;
} MTIconServiceGenerationObservation;

FOUNDATION_EXPORT MTIconServiceGenerationObservation
    MTIconServiceGenerationAdapterObservation;

FOUNDATION_EXPORT BOOL MTIconServiceGenerationAdapterInstall(
    MTIconServiceRuntimeMode mode,
    MTIconServiceImageResolver *_Nullable resolver,
    NSError **error);

// One active invalidate/generate cycle, associated with its exact Generation.
FOUNDATION_EXPORT void MTIconServiceGenerationAdapterBeginCycle(
    uint64_t sequence, NSString *generationIdentifier);
FOUNDATION_EXPORT uint32_t MTIconServiceGenerationAdapterCycleHookCalls(
    uint64_t sequence);
FOUNDATION_EXPORT uint32_t MTIconServiceGenerationAdapterCycleReplacements(
    uint64_t sequence);
FOUNDATION_EXPORT void MTIconServiceGenerationAdapterPublishTelemetry(void);

NS_ASSUME_NONNULL_END
