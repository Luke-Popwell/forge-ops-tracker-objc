#import "ForgeOpsTracker.h"
#import "FOTReporter.h"
#import "FOTSignalHandler.h"

static FOTConfiguration *FOTSharedConfiguration = nil;
static FOTReporter *FOTSharedReporter = nil;
static NSUncaughtExceptionHandler *FOTPreviousUncaughtExceptionHandler = NULL;
static BOOL FOTHandlersInstalled = NO;

static void FOTHandleUncaughtException(NSException *exception) {
    [FOTSharedReporter reportException:exception context:nil];
    // Chain to whatever handler (if any) was already installed -- another crash reporter, a
    // debugger, or the host app's own -- rather than silently replacing it, the same "rethrow,
    // don't swallow" invariant every other framework integration in this repo holds to.
    if (FOTPreviousUncaughtExceptionHandler != NULL) {
        FOTPreviousUncaughtExceptionHandler(exception);
    }
}

@implementation ForgeOpsTracker

+ (FOTConfiguration *)configuration {
    if (FOTSharedConfiguration == nil) {
        FOTSharedConfiguration = [[FOTConfiguration alloc] init];
    }
    return FOTSharedConfiguration;
}

+ (FOTReporter *)reporter {
    if (FOTSharedReporter == nil) {
        FOTSharedReporter = [[FOTReporter alloc] initWithConfiguration:[self configuration]];
    }
    return FOTSharedReporter;
}

+ (FOTConfiguration *)configureWithBlock:(void (^)(FOTConfiguration *config))block {
    FOTConfiguration *config = [self configuration];
    block(config);
    return config;
}

+ (void)installHandlers {
    if (FOTHandlersInstalled) {
        return;
    }
    FOTHandlersInstalled = YES;

    FOTPreviousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&FOTHandleUncaughtException);

    [FOTSignalHandler installSignalHandlersInDirectory:[self configuration].crashReportsDirectory];

    // Deliberately not the main thread -- see FOTClient.h's own comment on -deliver: being
    // synchronous; a background queue is what keeps that from ever blocking app launch.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[self reporter] uploadPendingReports];
    });
}

+ (void)captureException:(NSException *)exception context:(NSDictionary<NSString *, id> *)context {
    [[self reporter] reportException:exception context:context];
    // Unlike an uncaught exception, this one didn't crash the process -- upload it now rather
    // than waiting for a next launch that (having not crashed) has no particular reason to come
    // soon. Still off the calling thread, for the same reason as installHandlers above.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[self reporter] uploadPendingReports];
    });
}

+ (void)_resetForTesting {
    FOTSharedConfiguration = nil;
    FOTSharedReporter = nil;
    FOTHandlersInstalled = NO;
    // Deliberately not touching the real NSUncaughtExceptionHandler/signal dispositions here --
    // resetting those between test runs would risk leaving the *test process itself* without a
    // safety net if a later, unrelated test genuinely crashes.
}

@end
