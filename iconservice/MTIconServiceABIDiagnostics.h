#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// Metadata only: these functions never send messages to private objects,
// resolve forwarding methods, install Hooks, or execute cache operations.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MTIconServiceMethodDiagnostic(
    Class _Nullable cls, NSString *selectorName, BOOL classMethod,
    const char *expectedEncoding, NSString *expectedImage);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MTIconServiceABIDiagnosticReport(
    NSError *_Nullable failure);
// Focused follow-up for the missing bitmap serializer. Lists only IFCacheImage
// and IFImage (including inherited declarations), without invoking candidates.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
    MTIconServiceImageConstructionDiagnosticReport(void);
FOUNDATION_EXPORT void MTIconServiceLogABIDiagnosticReport(
    NSDictionary<NSString *, id> *report);

NS_ASSUME_NONNULL_END
