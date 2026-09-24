#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <os/log.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import "MTIconServiceABIDiagnostics.h"

static BOOL MTWriteAll(int fd, NSData *data) {
    const unsigned char *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += written;
        remaining -= (size_t)written;
    }
    return YES;
}

static void MTCapture(NSString *phase) {
    @autoreleasepool {
        NSMutableDictionary *report = [MTIconServiceABIDiagnosticReport(nil) mutableCopy];
        report[@"probeVersion"] = @"0.1.0";
        report[@"capturePhase"] = phase;
        report[@"capturedAt"] = @([NSDate.date timeIntervalSince1970]);
        // Capture time may precede or follow MarkTheme's constructor. An IMP
        // in MarkTheme's image can therefore be an already-installed Hook.
        report[@"captureIsValidationFailureSite"] = @NO;
        MTIconServiceLogABIDiagnosticReport(report);
        NSData *data = [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        if (data == nil) return;

        // Use the agent's sandbox-selected temporary directory. A fresh 0700
        // directory and O_EXCL/O_NOFOLLOW file avoid symlink replacement.
        NSString *template = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"marktheme-iconservices-abi.XXXXXX"];
        char *path = strdup(template.fileSystemRepresentation);
        if (path == NULL) return;
        if (mkdtemp(path) == NULL) {
            os_log_error(OS_LOG_DEFAULT, "MarkTheme ABI probe: report directory failed errno=%d; use icon-service-abi logs", errno);
            free(path);
            return;
        }
        NSString *file = [[NSFileManager.defaultManager
            stringWithFileSystemRepresentation:path length:strlen(path)]
            stringByAppendingPathComponent:@"marktheme-iconservices-abi.json"];
        int fd = open(file.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        BOOL written = fd >= 0 && MTWriteAll(fd, data);
        if (fd >= 0 && close(fd) != 0) written = NO;
        if (!written) {
            os_log_error(OS_LOG_DEFAULT, "MarkTheme ABI probe: report write failed errno=%d; use icon-service-abi logs", errno);
        } else {
            os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
                "MarkTheme ABI probe report: %{public}@", file);
        }
        free(path);
    }
}

__attribute__((constructor)) static void MTProbeStart(void) {
    @autoreleasepool {
        char executable[PATH_MAX];
        uint32_t size = sizeof(executable);
        if (_NSGetExecutablePath(executable, &size) != 0 ||
            strcmp(executable, "/System/Library/CoreServices/iconservicesagent") != 0) return;
        MTCapture(@"constructor");
        // One bounded second sample distinguishes lazy class registration and
        // records MarkTheme's published status after constructors complete.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                MTCapture(@"after-startup");
            });
    }
}
