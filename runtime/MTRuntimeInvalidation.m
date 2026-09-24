#import "MTRuntimeInvalidation.h"

#import <dispatch/dispatch.h>
#import <notify.h>
#import <os/lock.h>

#include <errno.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#if !defined(MARKTHEME_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME_RUNTIME_BUILD_NUMBER must identify the exact Runtime build"
#endif

_Static_assert(MARKTHEME_RUNTIME_BUILD_NUMBER > 0 &&
               MARKTHEME_RUNTIME_BUILD_NUMBER <= UINT16_MAX,
    "Runtime build must fit the IconServices readiness protocol");

NSString *const MTIconServiceInvalidationNotificationName =
    @"com.hmmzzz.marktheme.icon-service-store-changed";
static NSString *const MTIconServiceRuntimeStatusNotificationName =
    @"com.hmmzzz.marktheme.icon-service-runtime-status";
// notify state is shared with the Helper; the writer is the injected agent.
// A versioned header brackets all fields so a reader cannot mix two updates.
static const char *const MTExecutionNames[] = {
    "com.hmmzzz.marktheme.execution208.header",
    "com.hmmzzz.marktheme.execution208.installed",
    "com.hmmzzz.marktheme.execution208.hooks",
    "com.hmmzzz.marktheme.execution208.resolver",
    "com.hmmzzz.marktheme.execution208.matches",
    "com.hmmzzz.marktheme.execution208.cgimage",
    "com.hmmzzz.marktheme.execution208.ifimage",
    "com.hmmzzz.marktheme.execution208.returned",
    "com.hmmzzz.marktheme.execution208.passthrough",
    "com.hmmzzz.marktheme.execution208.failed",
    "com.hmmzzz.marktheme.execution208.cycle-sequence",
    "com.hmmzzz.marktheme.execution208.cycle-hooks",
    "com.hmmzzz.marktheme.execution208.cycle-returns",
    "com.hmmzzz.marktheme.execution208.path",
    "com.hmmzzz.marktheme.execution208.bundle0",
    "com.hmmzzz.marktheme.execution208.bundle1",
    "com.hmmzzz.marktheme.execution208.bundle2",
    "com.hmmzzz.marktheme.execution208.bundle3",
    "com.hmmzzz.marktheme.execution208.bundle4",
    "com.hmmzzz.marktheme.execution208.bundle5",
};
static NSString *const MTExecutionKeys[] = {
    @"generationAdapterInstalled", @"generationHookCallCount",
    @"resolverCallCount", @"themedResolverMatchCount",
    @"replacementCGImageCount", @"replacementIFImageCount",
    @"replacementReturnedCount", @"passthroughCount",
    @"constructionFailureCount",
    @"generationCycleSequence", @"generationCycleHookCallCount",
    @"generationCycleReplacementReturnedCount",
};
enum { MTExecutionFieldCount = sizeof(MTExecutionNames) / sizeof(MTExecutionNames[0]),
       MTExecutionCounterCount = 12, MTExecutionPathIndex = 13,
       MTExecutionBundleIndex = 14, MTExecutionBundleChunks = 6 };
static os_unfair_lock MTExecutionPublishLock = OS_UNFAIR_LOCK_INIT;
static uint32_t MTExecutionRevision;

static uint64_t MTExecutionHeader(uint32_t revision) {
    return ((uint64_t)MARKTHEME_RUNTIME_BUILD_NUMBER << 48) |
        (((uint64_t)getpid() & UINT64_C(0xffffff)) << 24) |
        (revision & UINT32_C(0xffffff));
}

BOOL MTIconServicePublishExecutionTelemetry(NSDictionary<NSString *, id> *telemetry) {
    if (telemetry == nil) return NO;
    static int tokens[MTExecutionFieldCount];
    static BOOL registered;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registered = YES;
        for (NSUInteger i = 0; i < MTExecutionFieldCount; i++) {
            if (notify_register_check(MTExecutionNames[i], &tokens[i]) !=
                NOTIFY_STATUS_OK || tokens[i] == NOTIFY_TOKEN_INVALID) {
                registered = NO;
            }
        }
    });
    if (!registered) return NO;
    uint64_t values[MTExecutionFieldCount] = {0};
    for (NSUInteger i = 0; i < MTExecutionCounterCount; i++) {
        id value = telemetry[MTExecutionKeys[i]];
        values[i + 1] = [value respondsToSelector:@selector(unsignedLongLongValue)]
            ? MIN([value unsignedLongLongValue], (uint64_t)UINT32_MAX) : 0;
    }
    NSString *path = telemetry[@"selectedImageConstructionPath"];
    values[MTExecutionPathIndex] = [path isEqualToString:@"legacy-cache-image-bitmap-data"] ? 1 :
        [path isEqualToString:@"split-cache-image-init-icon-size-bitmap-data"] ? 2 : 0;
    NSString *bundle = telemetry[@"lastBundleIdentifier"];
    // Bundle IDs are ASCII in the validated request contract. Clamp before
    // encoding; the zero-initialized last byte always terminates the string.
    char bytes[MTExecutionBundleChunks * sizeof(uint64_t)] = {0};
    if ([bundle isKindOfClass:NSString.class]) {
        const char *UTF8 = bundle.UTF8String;
        if (UTF8 != NULL) {
            size_t length = strnlen(UTF8, sizeof(bytes) - 1);
            memcpy(bytes, UTF8, length);
            if (UTF8[length] != '\0') values[MTExecutionPathIndex] |= 8;
        }
    }
    for (NSUInteger i = 0; i < MTExecutionBundleChunks; i++) {
        for (NSUInteger byte = 0; byte < 8; byte++) {
            values[MTExecutionBundleIndex + i] |=
                ((uint64_t)(uint8_t)bytes[i * 8 + byte]) << (byte * 8);
        }
    }
    os_unfair_lock_lock(&MTExecutionPublishLock);
    uint32_t odd = (MTExecutionRevision + 1) & UINT32_C(0xffffff);
    if ((odd & 1) == 0) odd = (odd + 1) & UINT32_C(0xffffff);
    MTExecutionRevision = odd;
    BOOL ok = notify_set_state(tokens[0], MTExecutionHeader(odd)) == NOTIFY_STATUS_OK;
    for (NSUInteger i = 1; i < MTExecutionFieldCount; i++) {
        ok = (notify_set_state(tokens[i], values[i]) == NOTIFY_STATUS_OK) && ok;
    }
    MTExecutionRevision = (odd + 1) & UINT32_C(0xffffff);
    ok = (notify_set_state(tokens[0], MTExecutionHeader(MTExecutionRevision)) ==
        NOTIFY_STATUS_OK) && ok;
    os_unfair_lock_unlock(&MTExecutionPublishLock);
    return ok;
}

NSDictionary<NSString *, id> *MTIconServiceReadExecutionTelemetry(
    MTIconServiceRuntimeStatus status) {
    if (!MTIconServiceRuntimeStatusIsCurrentAndLive(status)) {
        return @{@"telemetryAvailable" : @NO};
    }
    int tokens[MTExecutionFieldCount] = {0};
    NSUInteger registered = 0;
    for (; registered < MTExecutionFieldCount; registered++) {
        if (notify_register_check(MTExecutionNames[registered],
                &tokens[registered]) != NOTIFY_STATUS_OK ||
            tokens[registered] == NOTIFY_TOKEN_INVALID) break;
    }
    uint64_t values[MTExecutionFieldCount] = {0};
    BOOL valid = registered == MTExecutionFieldCount;
    if (valid) {
        uint64_t start = 0, end = 0;
        valid = notify_get_state(tokens[0], &start) == NOTIFY_STATUS_OK &&
            (start & 1) == 0 && (start >> 48) == status.runtimeBuild &&
            ((start >> 24) & UINT64_C(0xffffff)) == status.processIdentifier;
        for (NSUInteger i = 1; valid && i < MTExecutionFieldCount; i++) {
            valid = notify_get_state(tokens[i], &values[i]) == NOTIFY_STATUS_OK;
        }
        valid = valid && notify_get_state(tokens[0], &end) == NOTIFY_STATUS_OK &&
            start == end;
    }
    for (NSUInteger i = 0; i < registered; i++) notify_cancel(tokens[i]);
    if (!valid) return @{@"telemetryAvailable" : @NO};
    NSMutableDictionary<NSString *, id> *result = [@{
        @"telemetryAvailable" : @YES,
        @"selectedImageConstructionPath" :
            (values[MTExecutionPathIndex] & 7) == 1 ? @"legacy-cache-image-bitmap-data" :
            (values[MTExecutionPathIndex] & 7) == 2 ? @"split-cache-image-init-icon-size-bitmap-data" :
            @"unavailable",
        @"lastBundleIdentifierTruncated" : @((values[MTExecutionPathIndex] & 8) != 0),
    } mutableCopy];
    for (NSUInteger i = 0; i < MTExecutionCounterCount; i++) {
        result[MTExecutionKeys[i]] = @(values[i + 1]);
    }
    char bytes[MTExecutionBundleChunks * sizeof(uint64_t) + 1] = {0};
    for (NSUInteger i = 0; i < MTExecutionBundleChunks; i++) {
        for (NSUInteger byte = 0; byte < 8; byte++) {
            bytes[i * 8 + byte] = (char)(values[MTExecutionBundleIndex + i] >> (byte * 8));
        }
    }
    NSString *bundle = [NSString stringWithUTF8String:bytes];
    if (bundle.length > 0) result[@"lastBundleIdentifier"] = bundle;
    return result;
}

static const uint64_t MTIconServiceStatusBuildShift = 48;
static const uint64_t MTIconServiceStatusPIDShift = 24;
static const uint64_t MTIconServiceStatusStageShift = 16;
static const uint64_t MTIconServiceStatusBuildMask = UINT64_C(0xffff);
static const uint64_t MTIconServiceStatusPIDMask = UINT64_C(0xffffff);
static const uint64_t MTIconServiceStatusByteMask = UINT64_C(0xff);

// Each phase is a verified transaction, not a UI animation deadline. Five
// seconds leaves room for a native IconServices clear operation or a busy
// SpringBoard main queue without turning a successful apply into a false
// reload request.
static const int64_t MTIconServiceAcknowledgementTimeoutNanoseconds =
    5000LL * NSEC_PER_MSEC;

static uint64_t MTIconServiceRuntimeStatusWord(
    MTIconServiceRuntimeStage stage,
    uint8_t detail) {
    uint64_t build = (uint64_t)MARKTHEME_RUNTIME_BUILD_NUMBER;
    uint64_t processIdentifier = (uint64_t)getpid();
    return ((build & MTIconServiceStatusBuildMask)
                << MTIconServiceStatusBuildShift) |
        ((processIdentifier & MTIconServiceStatusPIDMask)
                << MTIconServiceStatusPIDShift) |
        (((uint64_t)stage & MTIconServiceStatusByteMask)
                << MTIconServiceStatusStageShift) |
        ((uint64_t)detail & MTIconServiceStatusByteMask);
}

BOOL MTIconServicePublishRuntimeStatus(MTIconServiceRuntimeStage stage,
                                       uint8_t detail) {
    static int token = NOTIFY_TOKEN_INVALID;
    static int registration = NOTIFY_STATUS_FAILED;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registration = notify_register_check(
            MTIconServiceRuntimeStatusNotificationName.UTF8String,
            &token);
    });
    if (registration != NOTIFY_STATUS_OK ||
        token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t status = MTIconServiceRuntimeStatusWord(stage, detail);
    return notify_set_state(token, status) == NOTIFY_STATUS_OK &&
        notify_post(
            MTIconServiceRuntimeStatusNotificationName.UTF8String) ==
            NOTIFY_STATUS_OK;
}

BOOL MTIconServiceReadRuntimeStatus(
    MTIconServiceRuntimeStatus *statusOut) {
    if (statusOut == NULL) return NO;
    *statusOut = (MTIconServiceRuntimeStatus){0};
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_check(
        MTIconServiceRuntimeStatusNotificationName.UTF8String, &token);
    if (registration != NOTIFY_STATUS_OK ||
        token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t status = 0;
    int readResult = notify_get_state(token, &status);
    notify_cancel(token);
    if (readResult != NOTIFY_STATUS_OK || status == 0) return NO;
    statusOut->runtimeBuild = (uint32_t)(
        (status >> MTIconServiceStatusBuildShift) &
        MTIconServiceStatusBuildMask);
    statusOut->processIdentifier = (uint32_t)(
        (status >> MTIconServiceStatusPIDShift) &
        MTIconServiceStatusPIDMask);
    statusOut->stage = (MTIconServiceRuntimeStage)(
        (status >> MTIconServiceStatusStageShift) &
        MTIconServiceStatusByteMask);
    statusOut->detail = (uint8_t)(status & MTIconServiceStatusByteMask);
    return statusOut->runtimeBuild > 0 &&
        statusOut->processIdentifier > 1 &&
        statusOut->stage != MTIconServiceRuntimeStageUnknown;
}

BOOL MTIconServiceRuntimeStatusIsCurrentAndLive(
    MTIconServiceRuntimeStatus status) {
    if (status.runtimeBuild != MARKTHEME_RUNTIME_BUILD_NUMBER ||
        status.processIdentifier <= 1 ||
        status.processIdentifier > INT32_MAX) {
        return NO;
    }
    if (kill((pid_t)status.processIdentifier, 0) == 0) return YES;
    return errno == EPERM;
}

BOOL MTIconServiceRuntimeStatusCanReceiveTransactions(
    MTIconServiceRuntimeStatus status) {
    return MTIconServiceRuntimeStatusIsCurrentAndLive(status) &&
        (status.stage == MTIconServiceRuntimeStageReady ||
         status.stage == MTIconServiceRuntimeStageTransactionFailed ||
         status.stage == MTIconServiceRuntimeStageGenerationNotObserved ||
         status.stage == MTIconServiceRuntimeStageReplacementNotProduced);
}

NSString *MTIconServiceRuntimeStageName(
    MTIconServiceRuntimeStage stage) {
    switch (stage) {
        case MTIconServiceRuntimeStageUnknown:
            return @"unknown";
        case MTIconServiceRuntimeStageStarting:
            return @"starting";
        case MTIconServiceRuntimeStageSnapshotReady:
            return @"snapshot-ready";
        case MTIconServiceRuntimeStageStoreControlReady:
            return @"store-control-ready";
        case MTIconServiceRuntimeStageReady:
            return @"ready";
        case MTIconServiceRuntimeStageTransactionFailed:
            return @"transaction-failed";
        case MTIconServiceRuntimeStageGenerationNotObserved:
            return @"generation-not-observed";
        case MTIconServiceRuntimeStageReplacementNotProduced:
            return @"replacement-not-produced";
        case MTIconServiceRuntimeStageDisabled:
            return @"disabled";
        case MTIconServiceRuntimeStageSnapshotLoaderFailed:
            return @"snapshot-loader-failed";
        case MTIconServiceRuntimeStageStoreControlFailed:
            return @"store-control-failed";
        case MTIconServiceRuntimeStageGenerationAdapterFailed:
            return @"generation-adapter-failed";
    }
    return @"invalid";
}

static BOOL MTPostNotificationAndWaitForAcknowledgement(
    NSString *notificationName,
    NSString *acknowledgementName,
    int64_t timeoutNanoseconds,
    uint64_t expectedAcknowledgementState) {
    if (notificationName.length == 0 || acknowledgementName.length == 0) {
        return NO;
    }
    dispatch_semaphore_t acknowledgement = dispatch_semaphore_create(0);
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_dispatch(
        acknowledgementName.UTF8String,
        &token,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(__unused int callbackToken) {
            dispatch_semaphore_signal(acknowledgement);
        });
    if (registration != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t state = 0;
    BOOL received = expectedAcknowledgementState != 0 &&
        notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
        state == expectedAcknowledgementState;
    BOOL posted = notify_post(notificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
    if (!received && posted) {
        BOOL callbackReceived = dispatch_semaphore_wait(
            acknowledgement,
            dispatch_time(DISPATCH_TIME_NOW,
                          timeoutNanoseconds)) == 0;
        if (callbackReceived && expectedAcknowledgementState == 0) {
            received = YES;
        }
    }
    if (!received && expectedAcknowledgementState != 0) {
        state = 0;
        received = notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
            state == expectedAcknowledgementState;
    }
    notify_cancel(token);
    return received;
}

static BOOL MTPostAcknowledgementNamed(NSString *name,
                                       uint64_t acknowledgementState) {
    if (name.length == 0) return NO;
    if (acknowledgementState == 0) {
        return notify_post(name.UTF8String) == NOTIFY_STATUS_OK;
    }
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_check(name.UTF8String, &token);
    if (registration != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    BOOL statePublished = notify_set_state(
        token, acknowledgementState) == NOTIFY_STATUS_OK;
    BOOL posted = notify_post(name.UTF8String) == NOTIFY_STATUS_OK;
    notify_cancel(token);
    return statePublished && posted;
}

BOOL MTIconServicePostInvalidation(void) {
    return notify_post(MTIconServiceInvalidationNotificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
}

NSString *MTIconServiceAcknowledgementNotificationName(uint64_t sequence) {
    return [NSString stringWithFormat:
        @"com.hmmzzz.marktheme.icon-service-applied.b%llu.s%llu",
        (unsigned long long)MARKTHEME_RUNTIME_BUILD_NUMBER,
        (unsigned long long)sequence];
}

BOOL MTIconServicePostInvalidationAndWaitForAcknowledgement(
    uint64_t sequence) {
    MTIconServiceRuntimeStatus status = {0};
    if (!MTIconServiceReadRuntimeStatus(&status) ||
        !MTIconServiceRuntimeStatusCanReceiveTransactions(status)) {
        return NO;
    }
    return MTPostNotificationAndWaitForAcknowledgement(
        MTIconServiceInvalidationNotificationName,
        MTIconServiceAcknowledgementNotificationName(sequence),
        MTIconServiceAcknowledgementTimeoutNanoseconds,
        status.processIdentifier);
}

BOOL MTIconServicePostAcknowledgement(uint64_t sequence) {
    NSString *name = MTIconServiceAcknowledgementNotificationName(sequence);
    return MTPostAcknowledgementNamed(name, (uint64_t)getpid());
}
