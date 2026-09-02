#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Public entry point. Typical usage, as early as possible in app startup
 * (application:didFinishLaunchingWithOptions: or your SwiftUI App's init):
 *
 *   [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
 *       config.dsn = @"https://<api_key>@your-forgeops-host/api/v1/events";
 *       config.environment = @"production";
 *   }];
 *   [ForgeOpsTracker installHandlers];
 *
 * See sdks/objc/README.md for what installHandlers actually covers (an uncaught NSException, and
 * the common fatal signals), what it deliberately doesn't (this is a crash reporter, not a web
 * framework's request-exception hook -- there's no equivalent to the Django/Express/Servlet-style
 * integrations elsewhere in this repo, since that's not how Objective-C apps are shaped), and why
 * a crash report always uploads on the *next* launch rather than live during the crash itself.
 */
@interface ForgeOpsTracker : NSObject

+ (FOTConfiguration *)configureWithBlock:(void (^)(FOTConfiguration *config))block;

/**
 * Installs the uncaught-exception handler and the fatal-signal handlers, then uploads any crash
 * reports left over from a previous launch on a background queue. Call once, after configure:.
 */
+ (void)installHandlers;

/** Report an exception you've already caught, e.g. from your own @try/@catch. */
+ (void)captureException:(NSException *)exception context:(nullable NSDictionary<NSString *, id> *)context;

/** @internal not part of the public API -- resets module state between test cases */
+ (void)_resetForTesting;

@end

NS_ASSUME_NONNULL_END
