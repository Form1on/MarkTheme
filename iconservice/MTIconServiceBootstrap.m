#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#import <os/log.h>

#include <stdatomic.h>

#import "MTIconServiceGenerationAdapter.h"
#import "MTIconServiceApplyEvidence.h"
#import "MTIconServiceImageResolver.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTIconServiceStoreInvalidator.h"
#import "MTApplicationIconSourceState.h"
#import "MTGenerationReader.h"
#import "MTGenerationDescriptor.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"

#if !defined(MARKTHEME_ICON_SERVICE_STORE_CONTROL)
#define MARKTHEME_ICON_SERVICE_STORE_CONTROL 1
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_STORE_CONTROL == 0 ||
               MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1,
    "MARKTHEME_ICON_SERVICE_STORE_CONTROL must be disabled or enabled");

static MTRuntimeKernel *MTIconServiceKernel;
static MTIconServiceImageResolver *MTIconServiceResolver;
static MTIconServiceStoreInvalidator *MTIconServiceInvalidator;
static atomic_bool MTIconServiceRuntimeReady;
static atomic_bool MTIconServiceApplyEvidenceFailed;
static NSString *MTIconServiceCompletedGenerationIdentifier;
static const int64_t MTGenerationObservationWindow = 350 * NSEC_PER_MSEC;

static os_log_t MTIconServiceLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create(
            "com.hmmzzz.marktheme", "icon-service-runtime");
    });
    return log;
}

static void MTIconServiceLogError(NSString *stage, NSError *error) {
    os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_ERROR,
        "icon service %{public}@ failed: %{public}@/%{public}ld: %{public}@",
        stage, error.domain ?: @"unknown", (long)error.code,
        error.localizedDescription ?: @"no error description");
}

static uint8_t MTIconServiceErrorDetail(NSError *error) {
    if (error == nil || error.code <= 0) return 0;
    return (uint8_t)MIN((NSUInteger)error.code, (NSUInteger)UINT8_MAX);
}

static BOOL MTIconServicePublishReadyIfAvailable(void) {
    BOOL runtimeReady = atomic_load_explicit(
        &MTIconServiceRuntimeReady, memory_order_acquire);
    BOOL storeReady = MARKTHEME_ICON_SERVICE_STORE_CONTROL != 1 ||
        MTIconServiceInvalidator.isServiceAvailable;
    return runtimeReady && storeReady &&
        !atomic_load_explicit(&MTIconServiceApplyEvidenceFailed,
            memory_order_acquire) &&
        MTIconServicePublishRuntimeStatus(
            MTIconServiceRuntimeStageReady, 0);
}

static BOOL MTIconServiceSnapshotRequestsApplicationIcons(
    MTRuntimeSnapshot *snapshot) {
    if (!snapshot.isReady) return NO;
    NSArray<NSString *> *modules = snapshot.generation.descriptor.moduleIDs;
    return [modules containsObject:@"icons.static"] ||
        [modules containsObject:@"icons.mask"] ||
        [modules containsObject:@"icons.overlay"];
}

static void MTIconServiceFinishVerifiedCycle(
    NSString *generationIdentifier, uint64_t sequence,
    BOOL requestsApplicationIcons) {
    if (MTIconServiceKernel != nil &&
        MTIconServiceKernel.currentSnapshot.state.sequence != sequence) return;
    uint32_t calls = MTIconServiceGenerationAdapterCycleHookCalls(sequence);
    uint32_t replacements =
        MTIconServiceGenerationAdapterCycleReplacements(sequence);
    MTIconServiceGenerationAdapterPublishTelemetry();
    if (!MTIconServiceApplyEvidenceSatisfied(true, requestsApplicationIcons,
            calls, replacements)) {
        atomic_store_explicit(&MTIconServiceApplyEvidenceFailed,
            true, memory_order_release);
        (void)MTIconServicePublishRuntimeStatus(
            calls == 0 ? MTIconServiceRuntimeStageGenerationNotObserved :
                MTIconServiceRuntimeStageReplacementNotProduced, 0);
        return;
    }
    atomic_store_explicit(&MTIconServiceApplyEvidenceFailed,
        false, memory_order_release);
    @synchronized (MTIconServiceImageResolver.class) {
        MTIconServiceCompletedGenerationIdentifier = generationIdentifier;
    }
    (void)MTIconServicePublishRuntimeStatus(MTIconServiceRuntimeStageReady, 0);
    (void)MTIconServicePostAcknowledgement(sequence);
}

static void MTIconServiceCompleteSnapshot(
    MTRuntimeSnapshot *snapshot) {
    if (!atomic_load_explicit(
            &MTIconServiceRuntimeReady, memory_order_acquire) ||
        MARKTHEME_ICON_SERVICE_STORE_CONTROL != 1) {
        return;
    }
    NSString *generationIdentifier = snapshot.isReady
        ? snapshot.generation.generationIdentifier : @"stock";
    uint64_t sequence = snapshot.state.sequence;
    BOOL requestsApplicationIcons =
        MTIconServiceSnapshotRequestsApplicationIcons(snapshot);
    @synchronized (MTIconServiceImageResolver.class) {
        if ([MTIconServiceCompletedGenerationIdentifier
                isEqualToString:generationIdentifier]) {
            os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_DEFAULT,
                "Generation unchanged sequence=%{public}llu; "
                "native cache transaction skipped",
                (unsigned long long)sequence);
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageReady, 0);
            (void)MTIconServicePostAcknowledgement(sequence);
            return;
        }
    }
    atomic_store_explicit(&MTIconServiceApplyEvidenceFailed,
        false, memory_order_release);
    MTIconServiceGenerationAdapterBeginCycle(sequence, generationIdentifier);
    MTIconServiceStoreInvalidator *storeInvalidator =
        MTIconServiceInvalidator;
    [storeInvalidator invalidateWholeStoreWithCompletion:
        ^(MTIconServiceStoreInvalidationResult *result) {
            os_log_with_type(
                MTIconServiceLog(),
                result.isVerified
                    ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
                "native whole-cache transaction outcome=%{public}@",
                result.outcome);
            if (result.isVerified) {
                if (requestsApplicationIcons) {
                    // A whole-cache operation can finish without ever calling
                    // the validated generation hook. Observe a bounded window
                    // after its normal return before accepting icon Apply.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            MTGenerationObservationWindow),
                        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                            MTIconServiceFinishVerifiedCycle(
                                generationIdentifier, sequence, YES);
                        });
                } else {
                    MTIconServiceFinishVerifiedCycle(
                        generationIdentifier, sequence, NO);
                }
            } else {
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageTransactionFailed, 2);
            }
        }];
}

__attribute__((constructor))
static void MTIconServiceBootstrap(void) {
    @autoreleasepool {
        MTIconServiceRuntimeMode mode =
            MTIconServiceConfiguredRuntimeMode();
        // The release-development default performs no class lookup, framework
        // call, store read, listener registration, or Hook installation.
        if (mode == MTIconServiceRuntimeModeDisabled) {
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageDisabled, 0);
            return;
        }
        (void)MTIconServicePublishRuntimeStatus(
            MTIconServiceRuntimeStageStarting, 0);

        NSError *error = nil;
        if (mode == MTIconServiceRuntimeModeSource) {
            MTRuntimeSnapshotLoader *loader =
                [MTRuntimeSnapshotLoader defaultLoaderWithError:&error];
            if (loader == nil) {
                MTIconServiceLogError(@"snapshot-loader", error);
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageSnapshotLoaderFailed,
                    MTIconServiceErrorDetail(error));
                return;
            }
            MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
                initWithLoader:loader
                notificationName:MTIconServiceInvalidationNotificationName
                reloadHandler:^(MTRuntimeReloadDisposition disposition,
                                MTRuntimeSnapshot *snapshot,
                                NSError *reloadError) {
                    if (disposition ==
                        MTRuntimeReloadDispositionRetainedAfterFailure) {
                        MTIconServiceLogError(@"snapshot-reload", reloadError);
                        return;
                    }
                    MTIconServiceCompleteSnapshot(snapshot);
                }];
            MTIconServiceImageResolver *resolver =
                [[MTIconServiceImageResolver alloc]
                    initWithSnapshotProvider:^MTRuntimeSnapshot *{
                        return kernel.currentSnapshot;
                    }];
            if (kernel == nil || resolver == nil) return;
            MTIconServiceKernel = kernel;
            MTIconServiceResolver = resolver;
            if (![kernel startSynchronouslyWithError:&error]) {
                MTIconServiceLogError(@"initial-snapshot", error);
                // The Kernel retains its stock snapshot and can recover on a
                // later canonical Runtime notification.
            }
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageSnapshotReady, 0);
        }
        if (MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1) {
            MTIconServiceStoreInvalidator *invalidator =
                [[MTIconServiceStoreInvalidator alloc] init];
            if (![invalidator installWithError:&error]) {
                MTIconServiceLogError(@"store-control", error);
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageStoreControlFailed,
                    MTIconServiceErrorDetail(error));
                MTIconServiceResolver = nil;
                MTIconServiceKernel = nil;
                return;
            }
            MTIconServiceInvalidator = invalidator;
            [invalidator setServiceAvailabilityHandler:^{
                (void)MTIconServicePublishReadyIfAvailable();
            }];
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageStoreControlReady, 0);
        }
        if (!MTIconServiceGenerationAdapterInstall(
                mode, MTIconServiceResolver, &error)) {
            MTIconServiceLogError(@"generation-adapter", error);
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageGenerationAdapterFailed,
                MTIconServiceErrorDetail(error));
            MTIconServiceResolver = nil;
            MTIconServiceKernel = nil;
            return;
        }
        atomic_store_explicit(
            &MTIconServiceRuntimeReady, true, memory_order_release);
        BOOL transactionReady =
            MTIconServicePublishReadyIfAvailable();
        os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_DEFAULT,
            "icon service runtime started mode=%{public}@ "
            "transactionReady=%{public}d",
            MTIconServiceRuntimeModeName(mode), transactionReady);
    }
}
