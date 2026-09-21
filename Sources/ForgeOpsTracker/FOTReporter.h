#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Ties Configuration, EventBuilder, and FOTCrashStore together. Mirrors every other SDK's own
 * Reporter/ErrorSubscriber in spirit: never lets reporting itself throw back into the host app,
 * but split into two halves (capture now, upload later) rather than one report() call, because
 * a crash reporter's two real responsibilities happen at two different, unrelated moments: the
 * crash itself (capture, write to disk, nothing else: see FOTEventBuilder.h for why a live
 * network call has no place here), and the *next* app launch (read whatever's pending, try to
 * upload it, same as any other SDK's own delivery).
 */
@interface FOTReporter : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Called from the uncaught exception handler (or explicitly, for a caught-but-notable exception). */
- (void)reportException:(NSException *)exception context:(nullable NSDictionary<NSString *, id> *)context;

/**
 * Same as -reportException:context:, with an affected user attached. Callers resolve whatever
 * "current user" fallback applies (see ForgeOpsTracker.h's own -setUser:/+currentUser) before
 * calling this; this method itself does no such resolution, it just passes whatever it's given
 * straight through to FOTEventBuilder.
 */
- (void)reportException:(NSException *)exception
                 context:(nullable NSDictionary<NSString *, id> *)context
                    user:(nullable NSDictionary<NSString *, id> *)user;

/**
 * Same as -reportException:context:user:, with the breadcrumb trail leading up to this report
 * attached (see ForgeOpsTracker.h's +addBreadcrumb:). Like the user, callers resolve what
 * "current" means (ForgeOpsTracker +currentBreadcrumbs) before calling this.
 */
- (void)reportException:(NSException *)exception
                 context:(nullable NSDictionary<NSString *, id> *)context
                    user:(nullable NSDictionary<NSString *, id> *)user
             breadcrumbs:(nullable NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs;

/**
 * Uploads every pending crash report left over from a previous launch, deleting each on success
 * and leaving a failed one in place for the next attempt. Deliberately synchronous: call this
 * from a background queue at startup, not the main thread.
 */
/** The same as the above, plus the raw SQL statement behind the exception (nil to look for it on the
 * exception itself): see FOTEventBuilder's own sql: method. */
- (void)reportException:(NSException *)exception
                 context:(nullable NSDictionary<NSString *, id> *)context
                    user:(nullable NSDictionary<NSString *, id> *)user
             breadcrumbs:(nullable NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs
                     sql:(nullable NSString *)sql;

- (void)uploadPendingReports;

@end

NS_ASSUME_NONNULL_END
