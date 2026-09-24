#import "MTIconServiceRuntimeTests.h"

#import "MTIconServiceABI.h"
#import "MTIconServiceABIDiagnostics.h"
#import <dlfcn.h>
#import "MTIconServiceImageResolver.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

static NSUInteger MTIconServiceAssertionCount;

static void MTIconServiceAssert(BOOL condition, NSString *message) {
    MTIconServiceAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

@interface MTTestIconServiceDescriptor : NSObject
@property(nonatomic, copy) NSArray<NSString *> *moduleIDs;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@end
@implementation MTTestIconServiceDescriptor
@end

@interface MTTestIconServiceGeneration : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) id descriptor;
@property(nonatomic, assign) NSUInteger lookupCount;
@property(nonatomic, copy) NSDictionary<NSString *, id> *resources;
@property(nonatomic, strong) NSMutableArray<NSString *> *requestedKeys;
// Runs on the first resource lookup, letting a test interleave a Generation
// swap in the exact window between capturing the snapshot and storing a
// composite decision.
@property(nonatomic, copy, nullable) void (^duringFirstLookup)(void);
@end

@implementation MTTestIconServiceGeneration

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _requestedKeys = [NSMutableArray array];
    return self;
}

- (id)resourceForCanonicalResourceKey:(NSString *)key error:(NSError **)error {
    self.lookupCount++;
    [self.requestedKeys addObject:key];
    if (error != NULL) *error = nil;
    void (^interleaved)(void) = self.duringFirstLookup;
    if (interleaved != nil) {
        self.duringFirstLookup = nil;
        interleaved();
    }
    return self.resources[key];
}

@end

static CGImageRef MTIconServiceTestCreateStockImage(uint32_t dimension) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) return NULL;
    CGContextRef context = CGBitmapContextCreate(
        NULL, dimension, dimension, 8, (size_t)dimension * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) return NULL;
    CGContextSetRGBFillColor(context, 0.2, 0.4, 0.6, 1);
    CGContextFillRect(context, CGRectMake(0, 0, dimension, dimension));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

// An unthemed application must resolve to the stock appearance exactly once.
// Repeating the identical request may not re-enter the Generation resolver,
// and a new content-addressed Generation must use a separate namespace.
static void MTIconServiceRunStockCacheTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[];
    descriptor.moduleConfigurations = @{};

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    generation.descriptor = descriptor;

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Icon service stock cache fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    __block MTRuntimeSnapshot *currentSnapshot = snapshot;
    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return currentSnapshot;
        }];
    MTIconServiceAssert(resolver != nil,
        @"The icon service resolver must construct for a ready snapshot");

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef first = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(first == NULL && error == nil,
        @"An unthemed application must be a clean stock miss");
    NSUInteger lookupsAfterFirst = generation.lookupCount;
    MTIconServiceAssert(lookupsAfterFirst > 0,
        @"The first stock miss must consult the Generation resolver");

    error = nil;
    CGImageRef second = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(second == NULL && error == nil,
        @"A cached stock decision must still return the stock appearance");
    MTIconServiceAssert(generation.lookupCount == lookupsAfterFirst,
        @"A repeated unthemed request must not re-enter the Generation resolver");

    // A different stock digest is a different request and must be resolved.
    error = nil;
    CGImageRef changed = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-b" stockCGImage:stock error:&error];
    MTIconServiceAssert(changed == NULL && error == nil,
        @"A new stock digest must still resolve to the stock appearance");
    MTIconServiceAssert(generation.lookupCount > lookupsAfterFirst,
        @"A distinct stock digest must not reuse another request's decision");

    MTTestIconServiceGeneration *nextGeneration =
        [[MTTestIconServiceGeneration alloc] init];
    nextGeneration.generationIdentifier =
        @"g1-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    nextGeneration.descriptor = descriptor;
    nextGeneration.resources = @{};
    MTRuntimeState *nextState = [[MTRuntimeState alloc]
        initWithSequence:2
        runtimeEnabled:YES
        activeGenerationIdentifier:nextGeneration.generationIdentifier
        previousGenerationIdentifier:generation.generationIdentifier
        error:&stateError];
    currentSnapshot = [[MTRuntimeSnapshot alloc]
        initWithState:nextState generation:(id)nextGeneration];
    error = nil;
    CGImageRef afterSwap = [resolver
        copyReplacementForBundleIdentifier:@"com.example.unthemed"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(nextState != nil && afterSwap == NULL && error == nil,
        @"A new Generation stock decision must resolve cleanly");
    MTIconServiceAssert(nextGeneration.lookupCount > 0,
        @"A new Generation ID must not reuse the previous namespace");

    CGImageRelease(stock);
}

// An application with no static icon of its own must still be evaluated for
// the global mask and overlay. The stock decision may only be cached once
// those decorations have themselves been resolved and found absent, so a
// themed mask or overlay can never be short-circuited by a cached miss.
static void MTIconServiceRunDecorationWithoutStaticIconTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[ @"icons.mask", @"icons.overlay" ];
    descriptor.moduleConfigurations = @{
        @"icons.mask" : @{ @"enabled" : @YES },
    };

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    generation.descriptor = descriptor;
    generation.resources = @{};

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Decoration fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    MTIconServiceAssert(resolver != nil,
        @"The decoration resolver fixture must initialise");

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef result = [resolver
        copyReplacementForBundleIdentifier:@"com.example.nostatic"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(result == NULL && error == nil,
        @"An absent mask and overlay must still resolve to the stock appearance");

    // The decision may only be cached after the global mask and overlay were
    // actually probed. If either were skipped, an authored decoration would
    // silently stop applying to applications that ship no themed icon.
    BOOL probedMask = NO;
    BOOL probedOverlay = NO;
    for (NSString *requested in generation.requestedKeys) {
        if ([requested containsString:@"icons.mask"]) probedMask = YES;
        if ([requested containsString:@"icons.overlay"]) probedOverlay = YES;
    }
    MTIconServiceAssert(probedMask,
        @"An enabled icon mask must be resolved even without a themed static icon");
    MTIconServiceAssert(probedOverlay,
        @"An enabled icon overlay must be resolved even without a themed static icon");

    CGImageRelease(stock);
}

// A Generation swap that lands after this request captured its snapshot may
// finish the old request, but its decision must remain in the old Generation
// namespace and never hide the new snapshot.
static void MTIconServiceRunGenerationSwapRaceTests(void) {
    MTTestIconServiceDescriptor *descriptor =
        [[MTTestIconServiceDescriptor alloc] init];
    descriptor.moduleIDs = @[];
    descriptor.moduleConfigurations = @{};

    MTTestIconServiceGeneration *generation =
        [[MTTestIconServiceGeneration alloc] init];
    generation.generationIdentifier =
        @"g1-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    generation.descriptor = descriptor;
    generation.resources = @{};

    NSError *stateError = nil;
    MTRuntimeState *state = [[MTRuntimeState alloc]
        initWithSequence:1
        runtimeEnabled:YES
        activeGenerationIdentifier:generation.generationIdentifier
        previousGenerationIdentifier:nil
        error:&stateError];
    MTIconServiceAssert(state != nil && stateError == nil,
        @"Generation swap fixtures require canonical Runtime state");
    MTRuntimeSnapshot *snapshot = [[MTRuntimeSnapshot alloc]
        initWithState:state generation:(id)generation];

    MTTestIconServiceGeneration *nextGeneration =
        [[MTTestIconServiceGeneration alloc] init];
    nextGeneration.generationIdentifier =
        @"g1-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    nextGeneration.descriptor = descriptor;
    nextGeneration.resources = @{};
    MTRuntimeState *nextState = [[MTRuntimeState alloc]
        initWithSequence:2
        runtimeEnabled:YES
        activeGenerationIdentifier:nextGeneration.generationIdentifier
        previousGenerationIdentifier:generation.generationIdentifier
        error:&stateError];
    MTRuntimeSnapshot *nextSnapshot = [[MTRuntimeSnapshot alloc]
        initWithState:nextState generation:(id)nextGeneration];
    __block MTRuntimeSnapshot *currentSnapshot = snapshot;
    generation.duringFirstLookup = ^{
        currentSnapshot = nextSnapshot;
    };
    MTIconServiceImageResolver *resolver = [[MTIconServiceImageResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return currentSnapshot;
        }];
    MTIconServiceAssert(nextState != nil && resolver != nil,
        @"The Generation swap fixture must initialise");

    const uint32_t dimension = 120;
    CGImageRef stock = MTIconServiceTestCreateStockImage(dimension);
    MTIconServiceAssert(stock != NULL,
        @"The stock icon fixture must be constructible");

    NSError *error = nil;
    CGImageRef raced = [resolver
        copyReplacementForBundleIdentifier:@"com.example.raced"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(raced == NULL && error == nil,
        @"A raced request must still return its own correct result");

    // The next request runs entirely under the new generation. If the raced
    // request had published its decision, this lookup would be served from
    // that stale entry and never consult the Generation again.
    error = nil;
    CGImageRef afterSwap = [resolver
        copyReplacementForBundleIdentifier:@"com.example.raced"
        pointSize:CGSizeMake(60, 60) scale:2
        pixelWidth:dimension pixelHeight:dimension
        stockImageDigest:@"stock-digest-a" stockCGImage:stock error:&error];
    MTIconServiceAssert(afterSwap == NULL && error == nil,
        @"The post-swap request must resolve cleanly");
    MTIconServiceAssert(nextGeneration.lookupCount > 0,
        @"An old in-flight decision must not enter the new Generation namespace");

    CGImageRelease(stock);
}

static NSUInteger MTDiagnosticPrivateCalls;

static void MTDiagnosticMethodMustNotRun(__unused id object, __unused SEL selector) {
    MTDiagnosticPrivateCalls++;
}

static void MTIconServiceRunABIDiagnosticTests(void) {
    Class fixture = objc_allocateClassPair(NSObject.class, "MTIconServiceDiagnosticFixture", 0);
    MTIconServiceAssert(fixture != Nil, @"Diagnostic fixture must be unique");
    if (fixture == Nil) return;
    IMP stub = (IMP)MTDiagnosticMethodMustNotRun;
    class_addMethod(fixture, sel_registerName("run"), stub, "v16@0:8");
    class_addMethod(fixture, sel_registerName("operation"), stub, "Q16@0:8");
    class_addMethod(fixture, sel_registerName("cache"), stub, "@16@0:8");
    class_addMethod(fixture, sel_registerName("incompatibleRun:"), stub, "v24@0:8@16");
    class_addMethod(object_getClass(fixture), sel_registerName("classOnlyRun"), stub, "v16@0:8");
    objc_registerClassPair(fixture);
    Dl_info info = {0};
    MTIconServiceAssert(dladdr((const void *)stub, &info) != 0 && info.dli_fname != NULL,
        @"Fixture implementation image must resolve");
    NSString *image = info.dli_fname == NULL ? @"" : [NSString stringWithUTF8String:info.dli_fname];
    NSArray *expected = @[@[@"run", @"v16@0:8"], @[@"operation", @"Q16@0:8"], @[@"cache", @"@16@0:8"]];
    for (NSArray<NSString *> *entry in expected) {
        NSDictionary *report = MTIconServiceMethodDiagnostic(fixture, entry[0], NO, entry[1].UTF8String, image);
        MTIconServiceAssert([report[@"matchesExistingValidation"] boolValue] &&
            [report[@"encoding"] isEqual:entry[1]] && [report[@"kind"] isEqual:@"instance"],
            @"Existing expected ABI must be reported exactly");
    }
    NSDictionary *incompatible = MTIconServiceMethodDiagnostic(fixture, @"incompatibleRun:", NO, "v16@0:8", image);
    MTIconServiceAssert(![incompatible[@"matchesExistingValidation"] boolValue] &&
        [incompatible[@"failures"] containsObject:@"type-encoding-mismatch"],
        @"Changed argument ABI must be identified, never treated as compatible");
    NSDictionary *signedResult = MTIconServiceMethodDiagnostic(fixture, @"operation", NO, "q16@0:8", image);
    MTIconServiceAssert([signedResult[@"failures"] containsObject:@"type-encoding-mismatch"],
        @"No speculative signed/unsigned compatibility must enter diagnostics");
    NSDictionary *wrongImage = MTIconServiceMethodDiagnostic(fixture, @"run", NO, "v16@0:8", @"/not-the-agent");
    MTIconServiceAssert([wrongImage[@"failures"] containsObject:@"implementation-image-mismatch"],
        @"A matching encoding in the wrong image must be diagnosed independently");
    NSDictionary *wrongKind = MTIconServiceMethodDiagnostic(fixture, @"classOnlyRun", NO, "v16@0:8", image);
    NSDictionary *classKind = MTIconServiceMethodDiagnostic(fixture, @"classOnlyRun", YES, "v16@0:8", image);
    MTIconServiceAssert([wrongKind[@"failures"] containsObject:@"instance-method-missing"] &&
        [classKind[@"matchesExistingValidation"] boolValue],
        @"Class methods must not masquerade as instance methods");
    NSDictionary *missing = MTIconServiceMethodDiagnostic(Nil, @"run", NO, "v16@0:8", image);
    MTIconServiceAssert([missing[@"failures"] containsObject:@"class-missing"],
        @"Missing classes must produce explicit diagnostic evidence");
    for (NSString *domain in @[@"com.hmmzzz.marktheme.icon-service-abi",
                               @"com.hmmzzz.marktheme.icon-service-store-invalidator"]) {
        NSError *failure = [NSError errorWithDomain:domain code:3 userInfo:nil];
        NSDictionary *report = MTIconServiceABIDiagnosticReport(failure);
        MTIconServiceAssert([report[@"failure"][@"domain"] isEqual:domain] &&
            [report[@"failure"][@"code"] isEqual:@3] &&
            [NSJSONSerialization isValidJSONObject:report],
            @"Both meanings of error 3 must retain their error domain in valid JSON");
    }
    MTIconServiceAssert(MTDiagnosticPrivateCalls == 0,
        @"Metadata diagnostics must never invoke private methods");
}

NSUInteger MTRunIconServiceRuntimeTests(void) {
    MTIconServiceAssertionCount = 0;
    MTIconServiceRunABIDiagnosticTests();
    MTIconServiceAssert(
        MTIconServiceConfiguredRuntimeMode() ==
            MTIconServiceRuntimeModeDisabled &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeDisabled)
            isEqualToString:@"disabled"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeObserve)
            isEqualToString:@"service-observe"] &&
        [MTIconServiceRuntimeModeName(MTIconServiceRuntimeModeSource)
            isEqualToString:@"service-source"],
        @"Host tests must use the fail-closed IconServices default while preserving stable runtime-mode names");

    MTIconServiceImageGeometry proven = {
        .pixelSize = CGSizeMake(128, 128),
        .minimumSize = CGSizeMake(61, 61),
        .iconSize = CGSizeMake(64, 64),
        .scale = 2,
        .placeholder = NO,
        .largest = NO,
    };
    MTIconServiceAssert(MTIconServiceImageGeometryIsSupported(proven),
        @"The exact 21D61 IFCacheImage proof geometry must be accepted");
    MTIconServiceImageGeometry nonSquare = proven;
    nonSquare.pixelSize.height = 127;
    MTIconServiceImageGeometry placeholder = proven;
    placeholder.placeholder = YES;
    MTIconServiceImageGeometry mismatchedScale = proven;
    mismatchedScale.iconSize = CGSizeMake(63, 63);
    MTIconServiceAssert(
        !MTIconServiceImageGeometryIsSupported(nonSquare) &&
        !MTIconServiceImageGeometryIsSupported(placeholder) &&
        !MTIconServiceImageGeometryIsSupported(mismatchedScale),
        @"Unsupported IFImage geometry must fail closed before private construction");

    MTIconServiceRunStockCacheTests();
    MTIconServiceRunDecorationWithoutStaticIconTests();
    MTIconServiceRunGenerationSwapRaceTests();

    return MTIconServiceAssertionCount;
}
