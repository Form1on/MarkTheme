#import "MTIconServiceGenerationAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>

#include <stdatomic.h>

#import "MTIconServiceABI.h"
#import "MTIconServiceABIDiagnostics.h"
#import "MTIconServiceExecutionCounters.h"
#import "MTIconServiceImageResolver.h"
#import "MTRuntimeInvalidation.h"

NSString *const MTIconServiceGenerationAdapterErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-generation-adapter";

typedef id (*MTIconServiceGenerationFunction)(
    id, SEL, id __autoreleasing *_Nullable);

MTIconServiceGenerationObservation MTIconServiceGenerationAdapterObservation = {
    .schemaVersion = 2,
    .installed = ATOMIC_VAR_INIT(0),
    .calls = ATOMIC_VAR_INIT(0),
    .acceptedRequests = ATOMIC_VAR_INIT(0),
    .resolverHits = ATOMIC_VAR_INIT(0),
    .replacements = ATOMIC_VAR_INIT(0),
    .fallbacks = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconServiceGenerationObservation) == 48,
    "Icon service generation observation ABI changed");

static MTIconServiceGenerationFunction MTOriginalGeneration;
static MTIconServiceRuntimeMode MTInstalledMode;
static MTIconServiceImageResolver *MTInstalledResolver;
static os_unfair_lock MTTelemetryLock = OS_UNFAIR_LOCK_INIT;
static NSString *MTLastBundleIdentifier;
static NSString *MTActiveCycleGenerationIdentifier;
static uint64_t MTActiveCycleSequence;
static uint32_t MTActiveCycleHookCalls;
static uint32_t MTActiveCycleReplacements;
static _Atomic(uint32_t) MTResolverCalls;
static _Atomic(uint32_t) MTCGImages;
static _Atomic(uint32_t) MTIFImages;
static _Atomic(uint32_t) MTConstructionFailures;
static atomic_bool MTTelemetryPublishScheduled;

void MTIconServiceGenerationAdapterPublishTelemetry(void) {
    NSString *bundle = nil;
    uint64_t sequence = 0;
    uint32_t cycleCalls = 0;
    uint32_t cycleReplacements = 0;
    os_unfair_lock_lock(&MTTelemetryLock);
    bundle = MTLastBundleIdentifier;
    sequence = MTActiveCycleSequence;
    cycleCalls = MTActiveCycleHookCalls;
    cycleReplacements = MTActiveCycleReplacements;
    os_unfair_lock_unlock(&MTTelemetryLock);
    MTIconServiceGenerationObservation *observation =
        &MTIconServiceGenerationAdapterObservation;
    (void)MTIconServicePublishExecutionTelemetry(@{
        @"generationAdapterInstalled" : @(
            atomic_load_explicit(&observation->installed, memory_order_relaxed)),
        @"generationHookCallCount" : @(
            MIN(atomic_load_explicit(&observation->calls, memory_order_relaxed), UINT32_MAX)),
        @"resolverCallCount" : @(
            atomic_load_explicit(&MTResolverCalls, memory_order_relaxed)),
        @"themedResolverMatchCount" : @(
            atomic_load_explicit(
                &MTRuntimeIconServiceImageResolverObservation.themedMatches,
                memory_order_relaxed)),
        @"replacementCGImageCount" : @(
            atomic_load_explicit(&MTCGImages, memory_order_relaxed)),
        @"replacementIFImageCount" : @(
            atomic_load_explicit(&MTIFImages, memory_order_relaxed)),
        @"replacementReturnedCount" : @(
            MIN(atomic_load_explicit(&observation->replacements, memory_order_relaxed), UINT32_MAX)),
        @"passthroughCount" : @(
            MIN(atomic_load_explicit(&observation->fallbacks, memory_order_relaxed), UINT32_MAX)),
        @"constructionFailureCount" : @(
            atomic_load_explicit(&MTConstructionFailures, memory_order_relaxed)),
        @"generationCycleSequence" : @(MIN(sequence, (uint64_t)UINT32_MAX)),
        @"generationCycleHookCallCount" : @(cycleCalls),
        @"generationCycleReplacementReturnedCount" : @(cycleReplacements),
        @"selectedImageConstructionPath" : MTIconServiceABISelectedImageConstructionPath(),
        @"lastBundleIdentifier" : bundle ?: @"",
    });
}

static void MTQueueTelemetryPublish(void) {
    if (atomic_exchange_explicit(&MTTelemetryPublishScheduled,
            true, memory_order_acq_rel)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            atomic_store_explicit(&MTTelemetryPublishScheduled,
                false, memory_order_release);
            MTIconServiceGenerationAdapterPublishTelemetry();
        });
}

void MTIconServiceGenerationAdapterBeginCycle(uint64_t sequence,
                                               NSString *generationIdentifier) {
    os_unfair_lock_lock(&MTTelemetryLock);
    MTActiveCycleSequence = sequence;
    MTActiveCycleGenerationIdentifier = [generationIdentifier copy];
    MTActiveCycleHookCalls = 0;
    MTActiveCycleReplacements = 0;
    os_unfair_lock_unlock(&MTTelemetryLock);
}

uint32_t MTIconServiceGenerationAdapterCycleHookCalls(uint64_t sequence) {
    os_unfair_lock_lock(&MTTelemetryLock);
    uint32_t count = sequence == MTActiveCycleSequence ? MTActiveCycleHookCalls : 0;
    os_unfair_lock_unlock(&MTTelemetryLock);
    return count;
}

uint32_t MTIconServiceGenerationAdapterCycleReplacements(uint64_t sequence) {
    os_unfair_lock_lock(&MTTelemetryLock);
    uint32_t count = sequence == MTActiveCycleSequence ? MTActiveCycleReplacements : 0;
    os_unfair_lock_unlock(&MTTelemetryLock);
    return count;
}

static void MTIconServiceAdapterSetError(NSError **error,
                                         NSInteger code,
                                         NSString *description,
                                         NSError *_Nullable underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey : description,
    } mutableCopy];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:
        MTIconServiceGenerationAdapterErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static id MTIconServiceHookedGeneration(
    id self,
    SEL selector,
    id __autoreleasing *recordIdentifiersOut) {
    id original = MTOriginalGeneration(
        self, selector, recordIdentifiersOut);
    MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.calls);
    uint64_t cycleSequence = 0;
    os_unfair_lock_lock(&MTTelemetryLock);
    cycleSequence = MTActiveCycleSequence;
    if (cycleSequence != 0 && MTActiveCycleHookCalls < UINT32_MAX) {
        MTActiveCycleHookCalls++;
    }
    os_unfair_lock_unlock(&MTTelemetryLock);
    MTQueueTelemetryPublish();
    if (MTInstalledMode != MTIconServiceRuntimeModeSource ||
        MTInstalledResolver == nil || original == nil) {
        MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
        return original;
    }

    BOOL constructing = NO;
    @try {
        MTIconServiceRequestContext *context =
            MTIconServiceABIContextForRequest(self, NULL);
        if (context.bundleIdentifier.length > 0) {
            os_unfair_lock_lock(&MTTelemetryLock);
            MTLastBundleIdentifier = [context.bundleIdentifier copy];
            os_unfair_lock_unlock(&MTTelemetryLock);
        }
        MTIconServiceImageGeometry geometry = {0};
        NSString *stockDigest = MTIconServiceABIImageDigest(original);
        if (context == nil || stockDigest.length == 0 ||
            !MTIconServiceABIReadImageGeometry(original, &geometry) ||
            !MTIconServiceImageGeometryIsSupported(geometry)) {
            MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
            return original;
        }
        MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.acceptedRequests);
        CGImageRef stockCGImage =
            MTIconServiceABICopyImageCGImage(original);
        if (stockCGImage == NULL) {
            MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
            return original;
        }
        MTIconServiceCount32(&MTResolverCalls);
        NSString *resolvedGenerationIdentifier = nil;
        CGImageRef replacementCGImage = [MTInstalledResolver
            copyReplacementForBundleIdentifier:context.bundleIdentifier
            pointSize:context.pointSize
            scale:context.scale
            pixelWidth:(uint32_t)geometry.pixelSize.width
            pixelHeight:(uint32_t)geometry.pixelSize.height
            stockImageDigest:stockDigest
            stockCGImage:stockCGImage
            generationIdentifierOut:&resolvedGenerationIdentifier
            error:NULL];
        CGImageRelease(stockCGImage);
        if (replacementCGImage == NULL) {
            MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
            return original;
        }
        MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.resolverHits);
        MTIconServiceCount32(&MTCGImages);
        constructing = YES;
        id replacement = MTIconServiceABICreateReplacementImage(
            replacementCGImage, original, geometry, NULL);
        constructing = NO;
        CGImageRelease(replacementCGImage);
        if (replacement == nil) {
            MTIconServiceCount32(&MTConstructionFailures);
            MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
            return original;
        }
        MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.replacements);
        MTIconServiceCount32(&MTIFImages);
        os_unfair_lock_lock(&MTTelemetryLock);
        if (cycleSequence != 0 && cycleSequence == MTActiveCycleSequence &&
            [resolvedGenerationIdentifier isEqualToString:
                MTActiveCycleGenerationIdentifier] &&
            MTActiveCycleReplacements < UINT32_MAX) {
            MTActiveCycleReplacements++;
        }
        os_unfair_lock_unlock(&MTTelemetryLock);
        MTQueueTelemetryPublish();
        return replacement;
    } @catch (__unused NSException *exception) {
        if (constructing) MTIconServiceCount32(&MTConstructionFailures);
        MTIconServiceCount64(&MTIconServiceGenerationAdapterObservation.fallbacks);
        return original;
    }
}

BOOL MTIconServiceGenerationAdapterInstall(
    MTIconServiceRuntimeMode mode,
    MTIconServiceImageResolver *resolver,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (mode != MTIconServiceRuntimeModeObserve &&
        mode != MTIconServiceRuntimeModeSource) {
        MTIconServiceAdapterSetError(error, 1,
            @"Icon service adapter requires observe or source mode.", nil);
        return NO;
    }
    if (mode == MTIconServiceRuntimeModeSource && resolver == nil) {
        MTIconServiceAdapterSetError(error, 2,
            @"Icon service source mode requires an image resolver.", nil);
        return NO;
    }
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            &expected, 1, memory_order_acq_rel, memory_order_acquire)) {
        MTIconServiceAdapterSetError(error, 3,
            @"Icon service adapter is already installed.", nil);
        return NO;
    }
    Method method = NULL;
    NSError *ABIError = nil;
    if (!MTIconServiceABIValidateRuntime(&method, &ABIError) ||
        method == NULL) {
        // Store-control Hooks may already be installed. Their live IMPs are
        // not evidence of a cache-control validation failure at this stage.
        NSMutableDictionary *diagnostic =
            [MTIconServiceImageConstructionDiagnosticReport() mutableCopy];
        if (ABIError != nil) diagnostic[@"failure"] = @{
            @"domain" : ABIError.domain, @"code" : @(ABIError.code),
            @"description" : ABIError.localizedDescription,
        };
        MTIconServiceLogABIDiagnosticReport(diagnostic);
        atomic_store_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            0, memory_order_release);
        MTIconServiceAdapterSetError(error, 4,
            @"Icon service ABI rejected adapter installation.", ABIError);
        return NO;
    }
    MTInstalledMode = mode;
    MTInstalledResolver = resolver;
    MTOriginalGeneration = NULL;
    MSHookMessageEx(
        objc_getClass("ISGenerationRequest"), method_getName(method),
        (IMP)MTIconServiceHookedGeneration,
        (IMP *)&MTOriginalGeneration);
    if (MTOriginalGeneration == NULL) {
        MTInstalledResolver = nil;
        MTInstalledMode = MTIconServiceRuntimeModeDisabled;
        atomic_store_explicit(
            &MTIconServiceGenerationAdapterObservation.installed,
            0, memory_order_release);
        MTIconServiceAdapterSetError(error, 5,
            @"Hook backend did not return the original generation IMP.", nil);
        return NO;
    }
    MTIconServiceGenerationAdapterPublishTelemetry();
    return YES;
}
