#import "FOTSignalHandler.h"
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

static const int FOTFatalSignals[] = { SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP };
static const size_t FOTFatalSignalCount = sizeof(FOTFatalSignals) / sizeof(FOTFatalSignals[0]);

// Prepared once, at installation time, so the handler itself never allocates or calls into
// Objective-C -- see FOTSignalHandler.h's class comment for why that matters here.
static char FOTCrashDirectory[PATH_MAX];

static void FOTHandleFatalSignal(int signalNumber) {
    char path[PATH_MAX];
    // snprintf and time() aren't on POSIX's strict async-signal-safe list, but both are widely
    // relied on in practice by real-world signal handlers (this repo takes the same pragmatic
    // stance rather than hand-rolling an integer-to-string formatter) -- documented here as a
    // deliberate, informed tradeoff, not an oversight.
    snprintf(path, sizeof(path), "%s/signal-%d-%ld.txt", FOTCrashDirectory, signalNumber, (long)time(NULL));

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *name = strsignal(signalNumber);
        if (name != NULL) {
            write(fd, name, strlen(name));
            write(fd, "\n", 1);
        }

        void *frames[64];
        int frameCount = backtrace(frames, 64);
        // backtrace_symbols_fd(), unlike backtrace_symbols(), writes directly to a file
        // descriptor without allocating a string array first -- specifically documented by both
        // glibc and Darwin's own libc as the signal-safer of the two for exactly this reason.
        backtrace_symbols_fd(frames, frameCount, fd);

        close(fd);
    }

    // Restore the default disposition and re-raise, rather than swallowing the signal -- the
    // process should still actually crash (and produce a real OS-level core dump/crash log) the
    // same way it would without this handler installed, same "rethrow, don't swallow" invariant
    // every other framework integration in this repo holds to.
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

@implementation FOTSignalHandler

+ (void)installSignalHandlersInDirectory:(NSString *)crashReportsDirectory {
    [[NSFileManager defaultManager] createDirectoryAtPath:crashReportsDirectory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];

    strlcpy(FOTCrashDirectory, crashReportsDirectory.fileSystemRepresentation, sizeof(FOTCrashDirectory));

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = FOTHandleFatalSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;

    for (size_t i = 0; i < FOTFatalSignalCount; i++) {
        sigaction(FOTFatalSignals[i], &action, NULL);
    }
}

+ (NSDictionary<NSString *, id> *)parseRawSignalReportAtURL:(NSURL *)url {
    NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (contents == nil) {
        return nil;
    }

    NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
    NSString *signalName = lines.firstObject ?: @"unknown signal";

    NSMutableArray<NSDictionary<NSString *, id> *> *backtrace = [NSMutableArray array];
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, MAX(0, (NSInteger)lines.count - 1))]) {
        if (line.length == 0) {
            continue;
        }
        [backtrace addObject:@{
            @"file": [NSNull null],
            @"line": [NSNull null],
            @"method": line,
            @"in_app": @NO, // signal-handler frames aren't classified -- see the class comment
        }];
    }

    return @{
        @"exception_class": [NSString stringWithFormat:@"Signal: %@", signalName],
        @"message": [NSString stringWithFormat:@"Uncaught fatal signal: %@", signalName],
        @"backtrace": backtrace,
    };
}

@end
