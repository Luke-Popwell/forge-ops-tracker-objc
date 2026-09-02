#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Ties Configuration, EventBuilder, and FOTCrashStore together. Mirrors every other SDK's own
 * Reporter/ErrorSubscriber in spirit -- never lets reporting itself throw back into the host app
 * -- but split into two halves (capture now, upload later) rather than one report() call, because
 * a crash reporter's two real responsibilities happen at two different, unrelated moments: the
 * crash itself (capture, write to disk, nothing else -- see FOTEventBuilder.h for why a live
 * network call has no place here), and the *next* app launch (read whatever's pending, try to
 * upload it, same as any other SDK's own delivery).
 */
@interface FOTReporter : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Called from the uncaught exception handler (or explicitly, for a caught-but-notable exception). */
- (void)reportException:(NSException *)exception context:(nullable NSDictionary<NSString *, id> *)context;

/**
 * Uploads every pending crash report left over from a previous launch, deleting each on success
 * and leaving a failed one in place for the next attempt. Deliberately synchronous -- call this
 * from a background queue at startup, not the main thread.
 */
- (void)uploadPendingReports;

@end

NS_ASSUME_NONNULL_END
