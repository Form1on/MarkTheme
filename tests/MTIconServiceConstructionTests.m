#import "MTIconServiceABI.h"
#import <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

// These fixtures exercise the production method validator and construction
// function. Explicit device encodings also work on Intel macOS, where the
// compiler would otherwise encode BOOL as 'c' instead of the device's 'B'.
static NSUInteger MTConstructionAssertions;
static NSMutableArray<NSString *> *MTConstructionEvents;
static NSData *MTFixtureBitmap;
static NSUUID *MTFixtureUUID;
static NSData *MTFixtureToken;
static CGImageRef MTFixtureRaster;
static MTIconServiceImageGeometry MTFixtureGeometry;

static void MTConstructionAssert(BOOL value, NSString *message) {
    MTConstructionAssertions++;
    if (value) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static id MTFixtureSplitInit(__attribute__((ns_consumed)) id self,
    __unused SEL selector, CGImageRef image, double scale, CGSize minimumSize,
    BOOL placeholder) __attribute__((ns_returns_retained)) {
    [MTConstructionEvents addObject:@"init4"];
    MTConstructionAssert(image == MTFixtureRaster && scale == MTFixtureGeometry.scale &&
        CGSizeEqualToSize(minimumSize, MTFixtureGeometry.minimumSize) &&
        placeholder == MTFixtureGeometry.placeholder, @"Split init must preserve raster and geometry");
    return self;
}

static id MTFixtureLegacyInit(__attribute__((ns_consumed)) id self,
    __unused SEL selector, CGImageRef image, double scale, CGSize minimumSize,
    BOOL placeholder, CGSize iconSize) __attribute__((ns_returns_retained)) {
    [MTConstructionEvents addObject:@"init5"];
    MTConstructionAssert(image == MTFixtureRaster && scale == MTFixtureGeometry.scale &&
        CGSizeEqualToSize(minimumSize, MTFixtureGeometry.minimumSize) &&
        placeholder == MTFixtureGeometry.placeholder &&
        CGSizeEqualToSize(iconSize, MTFixtureGeometry.iconSize),
        @"Legacy init must retain its original arguments");
    return self;
}

static void MTFixtureSetIconSize(__unused id self, __unused SEL selector, CGSize size) {
    [MTConstructionEvents addObject:@"setIconSize"];
    MTConstructionAssert(CGSizeEqualToSize(size, MTFixtureGeometry.iconSize),
        @"Split setter must receive original iconSize before serialization");
}

static id MTFixtureBitmapData(__unused id self, __unused SEL selector) {
    [MTConstructionEvents addObject:@"bitmapData"];
    return MTFixtureBitmap;
}

static id MTFixtureDataInit(__attribute__((ns_consumed)) id self,
    __unused SEL selector, id data, id uuid, id token) __attribute__((ns_returns_retained)) {
    [MTConstructionEvents addObject:@"rehydrate"];
    MTConstructionAssert(data == MTFixtureBitmap && uuid == MTFixtureUUID && token == MTFixtureToken,
        @"Rehydration must use native bitmapData and original identity/token");
    return self;
}

static id MTFixtureGetUUID(__unused id self, __unused SEL selector) { return MTFixtureUUID; }
static id MTFixtureGetToken(__unused id self, __unused SEL selector) { return MTFixtureToken; }
static void MTFixtureSetLargest(__unused id self, __unused SEL selector, BOOL largest) {
    [MTConstructionEvents addObject:@"largest"];
    MTConstructionAssert(largest == MTFixtureGeometry.largest, @"Largest must be restored last");
}

typedef struct MTConstructionFixture {
    Class image;
    Class concrete;
    Class cache;
} MTConstructionFixture;

static Class MTConstructionClass(Class parent) {
    static NSUInteger next;
    NSString *name = [NSString stringWithFormat:@"MTConstructionFixture%lu", (unsigned long)++next];
    Class cls = objc_allocateClassPair(parent, name.UTF8String, 0);
    MTConstructionAssert(cls != Nil, @"Fixture class must be unique");
    objc_registerClassPair(cls);
    return cls;
}

static const char *const MTFixtureSelectors[] = {
    "initWithCGImage:scale:minimumSize:placeholder:",
    "setIconSize:", "bitmapData", "initWithData:uuid:validationToken:",
};
static const char *const MTFixtureEncodings[] = {
    "@52@0:8^{CGImage=}16d24{CGSize=dd}32B48",
    "v32@0:8{CGSize=dd}16", "@16@0:8", "@40@0:8@16@24@32",
};

static MTConstructionFixture MTMakeConstructionFixture(BOOL legacy, unsigned requiredMask) {
    MTConstructionFixture f = {0};
    f.image = MTConstructionClass(NSObject.class);
    f.concrete = MTConstructionClass(f.image);
    f.cache = MTConstructionClass(f.concrete);
    IMP implementations[] = {(IMP)MTFixtureSplitInit, (IMP)MTFixtureSetIconSize,
        (IMP)MTFixtureBitmapData, (IMP)MTFixtureDataInit};
    for (unsigned i = 0; i < 4; i++) {
        if ((requiredMask & (1u << i)) != 0) {
            class_addMethod(i == 1 ? f.concrete : f.image,
                sel_registerName(MTFixtureSelectors[i]), implementations[i], MTFixtureEncodings[i]);
        }
    }
    if (legacy) class_addMethod(f.cache,
        sel_registerName("initWithCGImage:scale:minimumSize:placeholder:iconSize:"),
        (IMP)MTFixtureLegacyInit, "@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52");
    class_addMethod(f.image, sel_registerName("uuid"), (IMP)MTFixtureGetUUID, "@16@0:8");
    class_addMethod(f.image, sel_registerName("validationToken"), (IMP)MTFixtureGetToken, "@16@0:8");
    class_addMethod(f.image, sel_registerName("setLargest:"), (IMP)MTFixtureSetLargest, "v20@0:8B16");
    return f;
}

static void MTAssertConstructionRejected(MTConstructionFixture f, NSString *image) {
    [MTConstructionEvents removeAllObjects];
    MTConstructionAssert(MTIconServiceABITestImageConstructionPath(f.cache, f.image, image) ==
        MTIconServiceImageConstructionUnavailable, @"Unsupported construction ABI must be rejected");
    NSError *error = nil;
    id result = MTIconServiceABITestCreateReplacementImage(f.cache, f.image, image,
        MTFixtureRaster, [[f.image alloc] init], MTFixtureGeometry, &error);
    MTConstructionAssert(result == nil && error.code == 7 && MTConstructionEvents.count == 0,
        @"Rejected ABI must not execute any candidate method");
}

NSUInteger MTRunIconServiceConstructionTests(void) {
    MTConstructionAssertions = 0;
    MTConstructionEvents = [NSMutableArray array];
    MTFixtureBitmap = [@"native-serializer-sentinel" dataUsingEncoding:NSUTF8StringEncoding];
    MTFixtureUUID = [NSUUID UUID];
    MTFixtureToken = [NSMutableData dataWithLength:40];
    MTFixtureGeometry = (MTIconServiceImageGeometry){
        .pixelSize = {128, 128}, .minimumSize = {61, 61}, .iconSize = {64, 64},
        .scale = 2, .placeholder = NO, .largest = YES,
    };
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 128, 128, 8, 512, color,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    MTConstructionAssert(context != NULL, @"Fixture bitmap context must allocate");
    MTFixtureRaster = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    MTConstructionAssert(MTFixtureRaster != NULL, @"Fixture CGImage must allocate");
    Dl_info info = {0};
    MTConstructionAssert(dladdr((const void *)MTFixtureSplitInit, &info) != 0 && info.dli_fname != NULL,
        @"Fixture implementation image must resolve");
    NSString *image = [NSString stringWithUTF8String:info.dli_fname];

    for (NSUInteger legacy = 0; legacy < 2; legacy++) {
        MTConstructionFixture f = MTMakeConstructionFixture(legacy != 0, 15);
        MTConstructionAssert(MTIconServiceABITestImageConstructionPath(f.cache, f.image, image) ==
            (legacy ? MTIconServiceImageConstructionLegacy : MTIconServiceImageConstructionSplit),
            @"Exact inherited split ABI must work; legacy must win when both exist");
        [MTConstructionEvents removeAllObjects];
        NSError *error = nil;
        id result = MTIconServiceABITestCreateReplacementImage(f.cache, f.image, image,
            MTFixtureRaster, [[f.image alloc] init], MTFixtureGeometry, &error);
        NSArray *order = legacy ? @[@"init5", @"bitmapData", @"rehydrate", @"largest"] :
            @[@"init4", @"setIconSize", @"bitmapData", @"rehydrate", @"largest"];
        MTConstructionAssert(result != nil && error == nil && [MTConstructionEvents isEqual:order],
            @"Production construction must execute the exact selected order");
    }
    // The legacy path does not acquire a new dependency on the split methods.
    MTConstructionFixture legacyOnly = MTMakeConstructionFixture(YES, 12);
    MTConstructionAssert(MTIconServiceABITestImageConstructionPath(
        legacyOnly.cache, legacyOnly.image, image) == MTIconServiceImageConstructionLegacy,
        @"Legacy without split initializer or setter must remain accepted");
    MTConstructionFixture badLegacy = MTMakeConstructionFixture(NO, 15);
    class_addMethod(badLegacy.cache,
        sel_registerName("initWithCGImage:scale:minimumSize:placeholder:iconSize:"),
        (IMP)MTFixtureLegacyInit, "@16@0:8");
    MTConstructionAssert(MTIconServiceABITestImageConstructionPath(
        badLegacy.cache, badLegacy.image, image) == MTIconServiceImageConstructionSplit,
        @"An invalid legacy initializer must not mask a fully validated split path");

    IMP foreign = class_getMethodImplementation(NSObject.class, @selector(description));
    for (unsigned i = 0; i < 4; i++) {
        MTConstructionFixture missing = MTMakeConstructionFixture(NO, 15u & ~(1u << i));
        MTAssertConstructionRejected(missing, image);

        MTConstructionFixture wrong = MTMakeConstructionFixture(NO, 15);
        Class owner = i == 1 ? wrong.concrete : wrong.image;
        SEL selector = sel_registerName(MTFixtureSelectors[i]);
        IMP existing = method_getImplementation(class_getInstanceMethod(owner, selector));
        // A new override is necessary: class_replaceMethod does not update the
        // encoding of an existing declaration on every Objective-C runtime.
        Class badCache = MTConstructionClass(wrong.cache);
        Class badImage = MTConstructionClass(wrong.image);
        class_addMethod(i == 3 ? badImage : badCache, selector, existing, "v16@0:8");
        wrong.cache = badCache;
        wrong.image = badImage;
        MTAssertConstructionRejected(wrong, image);

        MTConstructionFixture outside = MTMakeConstructionFixture(NO, 15);
        class_replaceMethod(i == 1 ? outside.concrete : outside.image, selector,
            foreign, MTFixtureEncodings[i]);
        MTAssertConstructionRejected(outside, image);

        MTConstructionFixture classOnly = MTMakeConstructionFixture(NO, 15u & ~(1u << i));
        class_addMethod(object_getClass(i == 1 ? classOnly.concrete : classOnly.image),
            selector, existing, MTFixtureEncodings[i]);
        MTAssertConstructionRejected(classOnly, image);
        if (i >= 2) {
            // Serializer and rehydrator are mandatory for the legacy path too.
            MTAssertConstructionRejected(MTMakeConstructionFixture(YES, 15u & ~(1u << i)), image);
            MTConstructionFixture legacyOutside = MTMakeConstructionFixture(YES, 15);
            class_replaceMethod(legacyOutside.image, selector, foreign, MTFixtureEncodings[i]);
            MTAssertConstructionRejected(legacyOutside, image);
        }
    }
    MTAssertConstructionRejected(MTMakeConstructionFixture(NO, 0), image);
    MTAssertConstructionRejected(MTMakeConstructionFixture(NO, 15), @"/not-IconFoundation");
    MTAssertConstructionRejected(MTMakeConstructionFixture(YES, 15), @"/not-IconFoundation");
    CGImageRelease(MTFixtureRaster);
    MTFixtureRaster = NULL;
    MTConstructionEvents = nil;
    MTFixtureBitmap = nil;
    MTFixtureUUID = nil;
    MTFixtureToken = nil;
    return MTConstructionAssertions;
}
