#import "MTIconServiceABIDiagnostics.h"

#import <dlfcn.h>
#import <notify.h>
#import <os/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef MARKTHEME_RUNTIME_BUILD_NUMBER
#error "Diagnostics must identify the Runtime source build"
#endif

static NSString *MTDiagnosticString(const char *value) {
    return value == NULL ? @"" : ([NSString stringWithUTF8String:value] ?: @"");
}

static NSDictionary *MTMethodMetadata(Method method) {
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    Dl_info info = {0};
    BOOL resolved = implementation != NULL &&
        dladdr((const void *)implementation, &info) != 0;
    return @{
        @"exists" : @(method != NULL),
        @"selector" : method == NULL ? @"" : NSStringFromSelector(method_getName(method)),
        @"encoding" : MTDiagnosticString(method == NULL ? NULL : method_getTypeEncoding(method)),
        @"implementationPresent" : @(implementation != NULL),
        @"implementation" : [NSString stringWithFormat:@"%p", (void *)implementation],
        @"imageResolved" : @(resolved && info.dli_fname != NULL),
        @"image" : MTDiagnosticString(info.dli_fname),
        @"symbol" : MTDiagnosticString(info.dli_sname),
    };
}

NSDictionary<NSString *, id> *MTIconServiceMethodDiagnostic(
    Class cls, NSString *selectorName, BOOL classMethod,
    const char *expectedEncoding, NSString *expectedImage) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : (classMethod
        ? class_getClassMethod(cls, selector)
        : class_getInstanceMethod(cls, selector));
    NSMutableDictionary *result = [MTMethodMetadata(method) mutableCopy];
    result[@"class"] = MTDiagnosticString(cls == Nil ? NULL : class_getName(cls));
    result[@"classImage"] = MTDiagnosticString(cls == Nil ? NULL : class_getImageName(cls));
    result[@"selector"] = selectorName;
    result[@"kind"] = classMethod ? @"class" : @"instance";
    result[@"expectedEncoding"] = MTDiagnosticString(expectedEncoding);
    result[@"expectedImage"] = expectedImage;
    NSMutableArray *failures = [NSMutableArray array];
    if (cls == Nil) [failures addObject:@"class-missing"];
    if (method == NULL) {
        [failures addObject:classMethod ? @"class-method-missing" : @"instance-method-missing"];
    } else {
        const char *actual = method_getTypeEncoding(method);
        if (actual == NULL || expectedEncoding == NULL || strcmp(actual, expectedEncoding) != 0) {
            [failures addObject:@"type-encoding-mismatch"];
        }
        if (![result[@"implementationPresent"] boolValue]) {
            [failures addObject:@"implementation-missing"];
        } else if (![result[@"imageResolved"] boolValue]) {
            [failures addObject:@"implementation-image-unresolved"];
        } else if (![result[@"image"] isEqualToString:expectedImage]) {
            [failures addObject:@"implementation-image-mismatch"];
        }
    }
    result[@"failures"] = failures;
    result[@"matchesExistingValidation"] = @(failures.count == 0);
    return result;
}

static NSArray *MTClassHierarchy(Class cls) {
    NSMutableArray *hierarchy = [NSMutableArray array];
    // Include inherited declarations so a moved getter is distinguishable
    // from a removed getter. No private method is invoked.
    for (NSUInteger depth = 0; cls != Nil && depth < 16; depth++, cls = class_getSuperclass(cls)) {
        if (strcmp(class_getName(cls), "NSObject") == 0) break;
        NSMutableDictionary *entry = [@{
            @"class" : MTDiagnosticString(class_getName(cls)),
            @"image" : MTDiagnosticString(class_getImageName(cls)),
        } mutableCopy];
        for (NSUInteger kind = 0; kind < 2; kind++) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(kind == 0 ? cls : object_getClass(cls), &count);
            NSMutableArray *metadata = [NSMutableArray array];
            for (unsigned int index = 0; index < count; index++) {
                [metadata addObject:MTMethodMetadata(methods[index])];
            }
            free(methods);
            entry[kind == 0 ? @"instanceMethods" : @"classMethods"] = metadata;
        }
        [hierarchy addObject:entry];
    }
    return hierarchy;
}

static NSDictionary *MTImageConstructionCapability(NSArray *checks) {
    BOOL cacheInitializer = NO;
    BOOL dataInitializer = NO;
    for (NSDictionary *check in checks) {
        if ([check[@"class"] isEqual:@"IFCacheImage"]) {
            cacheInitializer = [check[@"matchesExistingValidation"] boolValue];
        } else if ([check[@"class"] isEqual:@"IFImage"]) {
            dataInitializer = [check[@"matchesExistingValidation"] boolValue];
        }
    }
    // These are consecutive serializer/rehydrator stages, not alternatives.
    // Metadata can identify a candidate path, not prove its transaction ran.
    return @{
        @"selectionScope" : @"constructor ABI only; not runtime readiness",
        @"selectedPath" : cacheInitializer && dataInitializer
            ? @"legacy-cache-image-bitmap-data" : @"unavailable",
        @"cacheImageInitializerAvailable" : @(cacheInitializer),
        @"imageDataInitializerAvailable" : @(dataInitializer),
        @"requiresBitmapDataSerializer" : @YES,
    };
}

NSDictionary<NSString *, id> *MTIconServiceImageConstructionDiagnosticReport(void) {
    NSString *foundation = @"/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation";
    NSArray *expectations = @[
        @[@"IFCacheImage", @"initWithCGImage:scale:minimumSize:placeholder:iconSize:", @"@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52"],
        @[@"IFImage", @"initWithData:uuid:validationToken:", @"@40@0:8@16@24@32"],
    ];
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    NSMutableArray *checks = [NSMutableArray array];
    for (NSArray<NSString *> *expected in expectations) {
        Class cls = objc_lookUpClass(expected[0].UTF8String);
        classes[expected[0]] = @{
            @"exists" : @(cls != Nil), @"hierarchy" : MTClassHierarchy(cls),
        };
        NSMutableDictionary *check = [MTIconServiceMethodDiagnostic(
            cls, expected[1], NO, expected[2].UTF8String, foundation) mutableCopy];
        check[@"classMethodAlternative"] = MTIconServiceMethodDiagnostic(
            cls, expected[1], YES, expected[2].UTF8String, foundation);
        [checks addObject:check];
    }
    return @{
        @"schemaVersion" : @1,
        @"scope" : @"image-construction",
        @"compiledRuntimeBuild" : @(MARKTHEME_RUNTIME_BUILD_NUMBER),
        @"processIdentifier" : @(getpid()),
        @"processName" : NSProcessInfo.processInfo.processName,
        @"osVersion" : NSProcessInfo.processInfo.operatingSystemVersionString,
        @"serviceName" : MTDiagnosticString(getenv("XPC_SERVICE_NAME")),
        @"checks" : checks,
        @"classes" : classes,
        @"imageConstruction" : MTImageConstructionCapability(checks),
    };
}

NSDictionary<NSString *, id> *MTIconServiceABIDiagnosticReport(NSError *failure) {
    NSString *agent = @"/System/Library/CoreServices/iconservicesagent";
    NSString *icons = @"/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
    NSString *foundation = @"/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation";
    // Keep generation and store-control requirements identifiable separately.
    NSArray *expectations = @[
        @[@"ISGenerationRequest", @"generateImageReturningRecordIdentifiers:", @"@24@0:8^@16", icons],
        @[@"IFCacheImage", @"initWithCGImage:scale:minimumSize:placeholder:iconSize:", @"@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52", foundation],
        @[@"IFImage", @"initWithData:uuid:validationToken:", @"@40@0:8@16@24@32", foundation],
        @[@"IconCacheService", @"initWithServiceName:", @"@24@0:8@16", agent],
        @[@"ClearCacheOperation", @"run", @"v16@0:8", agent],
        @[@"ClearCacheOperation", @"operation", @"Q16@0:8", agent],
        @[@"ClearCacheOperation", @"cache", @"@16@0:8", agent],
        @[@"IconCacheService", @"iconCache", @"@16@0:8", agent],
        @[@"IconCacheService", @"scheduleCacheOperation:", @"v24@0:8Q16", agent],
    ];
    NSMutableArray *checks = [NSMutableArray array];
    for (NSArray<NSString *> *expected in expectations) {
        Class cls = objc_lookUpClass(expected[0].UTF8String);
        NSMutableDictionary *check = [MTIconServiceMethodDiagnostic(
            cls, expected[1], NO, expected[2].UTF8String, expected[3]) mutableCopy];
        check[@"expectedClass"] = expected[0];
        // The opposite method kind is evidence, never an accepted fallback.
        check[@"classMethodAlternative"] = MTIconServiceMethodDiagnostic(
            cls, expected[1], YES, expected[2].UTF8String, expected[3]);
        [checks addObject:check];
    }
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"ClearCacheOperation", @"IconCacheService",
                            @"ISMutableIconCache", @"ISBundleIdentifierIcon", @"ISImageDescriptor"]) {
        Class cls = objc_lookUpClass(name.UTF8String);
        classes[name] = @{@"exists" : @(cls != Nil), @"hierarchy" : MTClassHierarchy(cls)};
    }
    NSMutableArray *candidates = [NSMutableArray array];
    unsigned int count = 0;
    Class *loadedClasses = objc_copyClassList(&count);
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = MTDiagnosticString(class_getName(loadedClasses[index]));
        if ([name containsString:@"ClearCache"] || [name containsString:@"IconCacheService"]) {
            [candidates addObject:@{@"class" : name, @"image" : MTDiagnosticString(class_getImageName(loadedClasses[index]))}];
        }
    }
    free(loadedClasses);
    NSMutableDictionary *report = [@{
        @"schemaVersion" : @1,
        @"compiledRuntimeBuild" : @(MARKTHEME_RUNTIME_BUILD_NUMBER),
        @"processIdentifier" : @(getpid()),
        @"processName" : NSProcessInfo.processInfo.processName,
        @"osVersion" : NSProcessInfo.processInfo.operatingSystemVersionString,
        @"serviceName" : MTDiagnosticString(getenv("XPC_SERVICE_NAME")),
        @"checks" : checks,
        @"classes" : classes,
        @"candidateClasses" : candidates,
        @"imageConstruction" : MTImageConstructionCapability(checks),
    } mutableCopy];
    // Read the installed MarkTheme build independently of the probe's build.
    // This is advisory metadata, never an acknowledgement or readiness write.
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check("com.hmmzzz.marktheme.icon-service-runtime-status", &token) == NOTIFY_STATUS_OK) {
        uint64_t status = 0;
        if (notify_get_state(token, &status) == NOTIFY_STATUS_OK && status != 0) {
            uint32_t pid = (uint32_t)((status >> 24) & 0xffffff);
            report[@"observedRuntimeStatus"] = @{
                @"runtimeBuild" : @((status >> 48) & 0xffff),
                @"processIdentifier" : @(pid),
                @"belongsToThisProcess" : @(pid == (uint32_t)getpid()),
                @"stage" : @((status >> 16) & 0xff),
                @"detail" : @(status & 0xff),
            };
        }
        notify_cancel(token);
    }
    if (failure != nil) report[@"failure"] = @{
        @"domain" : failure.domain, @"code" : @(failure.code),
        @"description" : failure.localizedDescription,
    };
    return report;
}

void MTIconServiceLogABIDiagnosticReport(NSDictionary<NSString *, id> *report) {
    os_log_t log = os_log_create("com.hmmzzz.marktheme", "icon-service-abi");
    NSMutableDictionary *summary = [report mutableCopy];
    [summary removeObjectsForKeys:@[@"checks", @"classes"]];
    NSMutableArray *records = [NSMutableArray arrayWithObject:summary];
    for (NSDictionary *check in report[@"checks"]) {
        // Keep each record short enough for unified logging's message limit.
        NSMutableDictionary *instance = [check mutableCopy];
        [instance removeObjectForKey:@"classMethodAlternative"];
        [records addObject:instance];
        if (check[@"classMethodAlternative"] != nil) {
            [records addObject:check[@"classMethodAlternative"]];
        }
    }
    if ([report[@"scope"] isEqual:@"image-construction"]) {
        NSDictionary *classes = report[@"classes"];
        for (NSString *rootClass in classes) {
            for (NSDictionary *entry in classes[rootClass][@"hierarchy"]) {
                for (NSString *kind in @[@"instanceMethods", @"classMethods"]) {
                    for (NSDictionary *method in entry[kind]) {
                        NSMutableDictionary *record = [method mutableCopy];
                        record[@"rootClass"] = rootClass;
                        record[@"declaringClass"] = entry[@"class"];
                        record[@"kind"] = kind;
                        [records addObject:record];
                    }
                }
            }
        }
    }
    for (NSDictionary *record in records) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
        NSString *text = data == nil ? @"JSON serialization failed" :
            [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "ABI diagnostic %{public}@", text);
    }
}
