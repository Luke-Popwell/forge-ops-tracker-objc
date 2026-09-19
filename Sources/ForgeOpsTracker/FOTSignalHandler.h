#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Installs handlers for the common fatal signals (SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS,
 * SIGTRAP) that write a raw backtrace to disk. Deliberately separate from FOTReporter/
 * FOTEventBuilder: inside an actual signal handler, only async-signal-safe functions are safe to
 * call at all (POSIX is explicit about this): no malloc, no Objective-C message sends in
 * general (they can allocate, take locks another thread might already hold, etc.). This class's
 * handler is written to stay as close to that constraint as a real-world crash reporter
 * practically can: everything it touches (the target file path, a stack buffer) is prepared
 * *before* installation, not inside the handler, and the actual backtrace capture uses
 * backtrace_symbols_fd() specifically because (unlike backtrace_symbols()) it writes directly
 * to a file descriptor without allocating a string array first.
 *
 * What this can't do, honestly: produce a full JSON event the way FOTEventBuilder does (building
 * one safely from inside a signal handler isn't practical), or resolve `in_app`/file/line the way
 * an uncaught-exception report can. It writes one raw text file per crash instead; FOTReporter
 * wraps that into a minimal event on the *next* launch, once it's safe to use Foundation again.
 * This path also isn't exercised by this SDK's own automated test suite: deliberately: actually
 * raising a fatal signal to test it would crash the test process itself, the same reason every
 * real crash reporter's signal path is validated by manual/integration crash testing, not a unit
 * test. -installSignalHandlersInDirectory: itself (registration succeeding) is tested; the
 * handler's own body is not.
 */
@interface FOTSignalHandler : NSObject

+ (void)installSignalHandlersInDirectory:(NSString *)crashReportsDirectory;

/** Reads a raw signal-crash text file (see the class comment) back into event-shaped fields. */
+ (NSDictionary<NSString *, id> *)parseRawSignalReportAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
