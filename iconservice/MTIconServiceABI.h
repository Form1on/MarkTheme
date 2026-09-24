#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "MTIconServiceImageConstruction.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceABIErrorDomain;

typedef struct MTIconServiceImageGeometry {
    CGSize pixelSize;
    CGSize minimumSize;
    CGSize iconSize;
    double scale;
    BOOL placeholder;
    BOOL largest;
} MTIconServiceImageGeometry;

@interface MTIconServiceRequestContext : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, assign, readonly) CGSize pointSize;
@property(nonatomic, assign, readonly) double scale;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Shared process boundary only. Store control validates its own methods and
// must not depend on the generation adapter's image serialization ABI.
FOUNDATION_EXPORT BOOL MTIconServiceABIValidateProcess(NSError **error);

FOUNDATION_EXPORT BOOL MTIconServiceABIValidateRuntime(
    Method _Nullable *_Nullable generationMethodOut,
    NSError **error);

FOUNDATION_EXPORT MTIconServiceRequestContext *_Nullable
    MTIconServiceABIContextForRequest(id request, NSError **error);

FOUNDATION_EXPORT BOOL MTIconServiceABIReadImageGeometry(
    id image,
    MTIconServiceImageGeometry *_Nullable geometryOut);

FOUNDATION_EXPORT BOOL MTIconServiceImageGeometryIsSupported(
    MTIconServiceImageGeometry geometry);

FOUNDATION_EXPORT CGImageRef _Nullable MTIconServiceABICopyImageCGImage(
    id image) CF_RETURNS_RETAINED;

FOUNDATION_EXPORT NSString *_Nullable MTIconServiceABIImageDigest(id image);

FOUNDATION_EXPORT id _Nullable MTIconServiceABICreateReplacementImage(
    CGImageRef image,
    id originalImage,
    MTIconServiceImageGeometry geometry,
    NSError **error);

FOUNDATION_EXPORT NSString *MTIconServiceABISelectedImageConstructionPath(void);

#if defined(MT_HOST_TESTING)
// Exercise the production resolver and construction sequence with host-owned
// fixture classes. These entry points do not exist in device builds.
FOUNDATION_EXPORT MTIconServiceImageConstructionPath
    MTIconServiceABITestImageConstructionPath(Class cacheClass, Class imageClass,
                                             NSString *expectedImage);
FOUNDATION_EXPORT id _Nullable MTIconServiceABITestCreateReplacementImage(
    Class cacheClass, Class imageClass, NSString *expectedImage,
    CGImageRef image, id originalImage, MTIconServiceImageGeometry geometry,
    NSError **error);
#endif

NS_ASSUME_NONNULL_END
