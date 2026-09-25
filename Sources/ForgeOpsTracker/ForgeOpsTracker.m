#import "ForgeOpsTracker.h"
#import "FOTBreadcrumbBuffer.h"
#import "FOTMetricBuffer.h"
#import "FOTPerformanceFlusher.h"
#import "FOTReporter.h"
#import "FOTSignalHandler.h"
#import "FOTSpanQueue.h"

static FOTConfiguration *FOTSharedConfiguration = nil;
static FOTReporter *FOTSharedReporter = nil;
static NSUncaughtExceptionHandler *FOTPreviousUncaughtExceptionHandler = NULL;
static BOOL FOTHandlersInstalled = NO;
static NSDictionary<NSString *, id> *FOTCurrentUser = nil;
static FOTBreadcrumbBuffer *FOTSharedBreadcrumbs = nil;
static FOTPerformanceFlusher *FOTSharedPerformanceFlusher = nil;
static FOTSpanQueue *FOTSharedSpanQueue = nil;
static FOTMetricBuffer *FOTSharedMetricBuffer = nil;
static FOTMetricBuffer *FOTSharedInfrastructureMetricBuffer = nil;
static FOTClient *FOTSharedChangeClient = nil;

// Serial, so changes are sent in the order they were recorded, and off the caller's thread, since
// FOTClient's delivery blocks on the network.
static dispatch_queue_t FOTChangeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.forgeops.tracker.changes", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void FOTHandleUncaughtException(NSException *exception) {
    // The handler runs on the raising thread, so a trace whose synchronous block raised is still
    // current here.
    [FOTSharedReporter reportException:exception context:nil user:FOTCurrentUser breadcrumbs:[FOTSharedBreadcrumbs all] sql:nil traceId:[FOTTrace current].traceId];
    // Chain to whatever handler (if any) was already installed: another crash reporter, a
    // debugger, or the host app's own: rather than silently replacing it, the same "rethrow,
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

+ (FOTBreadcrumbBuffer *)breadcrumbBuffer {
    @synchronized(self) {
        if (FOTSharedBreadcrumbs == nil) {
            FOTSharedBreadcrumbs = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[self configuration]];
        }
        return FOTSharedBreadcrumbs;
    }
}

+ (FOTPerformanceFlusher *)performanceFlusher {
    @synchronized(self) {
        if (FOTSharedPerformanceFlusher == nil) {
            FOTSharedPerformanceFlusher = [[FOTPerformanceFlusher alloc] initWithConfiguration:[self configuration]
                                                                                          client:[[FOTClient alloc] initWithConfiguration:[self configuration]]];
        }
        return FOTSharedPerformanceFlusher;
    }
}

+ (FOTSpanQueue *)spanQueue {
    @synchronized(self) {
        if (FOTSharedSpanQueue == nil) {
            FOTSharedSpanQueue = [[FOTSpanQueue alloc] initWithConfiguration:[self configuration]
                                                                      client:[[FOTClient alloc] initWithConfiguration:[self configuration]]];
        }
        return FOTSharedSpanQueue;
    }
}

// The two metric buffers, created together on first use: independent of each other (a program may
// only ever call one), but cheap enough that creating both is simpler than tracking which.
+ (void)ensureMetricBuffers {
    @synchronized(self) {
        if (FOTSharedMetricBuffer == nil) {
            FOTConfiguration *config = [self configuration];
            FOTClient *client = [[FOTClient alloc] initWithConfiguration:config];
            FOTSharedMetricBuffer = [[FOTMetricBuffer alloc] initWithConfiguration:config
                                                                           deliver:^BOOL(NSArray *entries) { return [client deliverMetrics:entries]; }
                                                                          interval:^NSTimeInterval { return config.metricFlushInterval; }];
            FOTSharedInfrastructureMetricBuffer = [[FOTMetricBuffer alloc] initWithConfiguration:config
                                                                                          deliver:^BOOL(NSArray *entries) { return [client deliverInfrastructureMetrics:entries]; }
                                                                                         interval:^NSTimeInterval { return config.infrastructureMetricFlushInterval; }];
        }
    }
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

    // Before the signal handlers, and before anything else can add a breadcrumb that would
    // replace the previous run's persisted trail: see FOTBreadcrumbBuffer.h.
    [self _startBreadcrumbPersistence];

    FOTPreviousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&FOTHandleUncaughtException);

    [FOTSignalHandler installSignalHandlersInDirectory:[self configuration].crashReportsDirectory];

    // Deliberately not the main thread: see FOTClient.h's own comment on -deliver: being
    // synchronous; a background queue is what keeps that from ever blocking app launch.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[self reporter] uploadPendingReports];
    });
}

+ (void)captureException:(NSException *)exception context:(NSDictionary<NSString *, id> *)context {
    [self captureException:exception context:context user:nil];
}

+ (void)captureException:(NSException *)exception sql:(NSString *)sql context:(NSDictionary<NSString *, id> *)context {
    [[self reporter] reportException:exception context:context user:FOTCurrentUser breadcrumbs:[[self breadcrumbBuffer] all] sql:sql traceId:[FOTTrace current].traceId];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[self reporter] uploadPendingReports];
    });
}

+ (void)captureException:(NSException *)exception
                  context:(NSDictionary<NSString *, id> *)context
                     user:(NSDictionary<NSString *, id> *)user {
    [self captureException:exception context:context user:user trace:nil];
}

+ (void)captureException:(NSException *)exception
                  context:(NSDictionary<NSString *, id> *)context
                     user:(NSDictionary<NSString *, id> *)user
                    trace:(FOTTrace *)trace {
    NSString *traceId = (trace ?: [FOTTrace current]).traceId;
    [[self reporter] reportException:exception context:context user:user ?: FOTCurrentUser breadcrumbs:[[self breadcrumbBuffer] all] sql:nil traceId:traceId];
    // Unlike an uncaught exception, this one didn't crash the process: upload it now rather
    // than waiting for a next launch that (having not crashed) has no particular reason to come
    // soon. Still off the calling thread, for the same reason as installHandlers above.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[self reporter] uploadPendingReports];
    });
}

+ (void)addBreadcrumb:(NSString *)message {
    [self addBreadcrumb:message category:@"custom"];
}

+ (void)addBreadcrumb:(NSString *)message category:(NSString *)category {
    [self addBreadcrumb:message category:category level:@"info" data:nil];
}

+ (void)addBreadcrumb:(NSString *)message
              category:(NSString *)category
                 level:(NSString *)level
                  data:(NSDictionary<NSString *, id> *)data {
    [[self breadcrumbBuffer] addBreadcrumbWithMessage:message category:category level:level data:data];
}

+ (void)clearBreadcrumbs {
    [[self breadcrumbBuffer] clear];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)currentBreadcrumbs {
    return [[self breadcrumbBuffer] all];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)previousRunBreadcrumbsForCrashOccurringAt:(NSDate *)crashDate {
    return [[self breadcrumbBuffer] previousRunBreadcrumbsForCrashOccurringAt:crashDate];
}

+ (void)_startBreadcrumbPersistence {
    [[self breadcrumbBuffer] startPersisting];
}

+ (void)_waitForBreadcrumbWrites {
    [[self breadcrumbBuffer] _waitForPendingWrites];
}

+ (void)recordPerformance:(NSString *)transactionName durationMs:(double)durationMs {
    [[self performanceFlusher] recordTransaction:transactionName durationMs:durationMs];
}

+ (void)measureTransaction:(NSString *)transactionName block:(void (^)(void))block {
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    @try {
        block();
    } @finally {
        [self recordPerformance:transactionName durationMs:(CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0];
    }
}

+ (void)captureMetric:(NSString *)name {
    [self captureMetric:name value:1.0];
}

+ (void)captureMetric:(NSString *)name value:(double)value {
    FOTConfiguration *config = [self configuration];
    if (![config isEnabled]) {
        return;
    }
    [self ensureMetricBuffers];
    [FOTSharedMetricBuffer record:@{
        @"metric_name": name,
        @"value": @(value),
        @"environment": config.environment,
        @"release": config.releaseVersion ?: [NSNull null],
    }];
}

+ (void)captureInfrastructureMetric:(NSString *)name value:(double)value hostname:(NSString *)hostname {
    FOTConfiguration *config = [self configuration];
    if (![config isEnabled]) {
        return;
    }
    NSString *resolved = hostname ?: config.serverName;
    if (resolved.length == 0) {
        // The endpoint requires a hostname and skips a row without one: say so here instead of sending it.
        NSLog(@"[forge-ops-tracker] dropped an infrastructure metric with no hostname: pass one or set serverName");
        return;
    }
    [self ensureMetricBuffers];
    [FOTSharedInfrastructureMetricBuffer record:@{
        @"metric_name": name,
        @"value": @(value),
        @"hostname": resolved,
    }];
}

+ (void)flushMetrics {
    FOTMetricBuffer *custom;
    FOTMetricBuffer *infrastructure;
    @synchronized(self) {
        custom = FOTSharedMetricBuffer;
        infrastructure = FOTSharedInfrastructureMetricBuffer;
    }
    [custom flush];
    [infrastructure flush];
}

+ (FOTTrace *)startTrace:(NSString *)name {
    FOTConfiguration *config = [self configuration];
    if (!config.trackTracing || ![config isEnabled]) {
        return nil;
    }
    FOTSpanQueue *queue = [self spanQueue];
    return [[FOTTrace alloc] initWithName:name configuration:config deliver:^(NSDictionary<NSString *, id> *payload) {
        [queue push:payload];
    }];
}

+ (void)traceNamed:(NSString *)name block:(NS_NOESCAPE void (^)(FOTTrace *_Nullable))block {
    FOTTrace *trace = [self startTrace:name];
    if (trace != nil) {
        [FOTTrace pushCurrent:trace];
    }
    @try {
        block(trace);
    } @finally {
        if (trace != nil) {
            [FOTTrace popCurrent:trace];
        }
        [trace finish];
    }
}

+ (NSURLSessionDataTask *)dataTaskWithSession:(NSURLSession *)session
                                      request:(NSURLRequest *)request
                                        trace:(FOTTrace *)trace
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    FOTRequestSpan *span = [FOTRequestSpan startWithRequest:request trace:trace name:nil];
    return [session dataTaskWithRequest:span.request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [span finishWithResponse:response error:error];
        completionHandler(data, response, error);
    }];
}

+ (void)flushSpans {
    [[self spanQueue] waitUntilDelivered];
}

+ (void)flushPerformance {
    [[self performanceFlusher] flush];
}

+ (void)setUser:(NSDictionary<NSString *, id> *)user {
    FOTCurrentUser = user.count > 0 ? user : nil;
}

+ (NSDictionary<NSString *, id> *)currentUser {
    return FOTCurrentUser;
}

+ (void)recordChange:(NSString *)kind title:(NSString *)title {
    [self recordChange:kind title:title details:nil];
}

+ (void)recordChange:(NSString *)kind title:(NSString *)title details:(NSDictionary<NSString *, id> *)details {
    [self recordChange:kind title:title details:details environment:nil service:nil actor:nil url:nil identifier:nil occurredAt:nil];
}

+ (void)recordChange:(NSString *)kind
               title:(NSString *)title
             details:(NSDictionary<NSString *, id> *)details
         environment:(NSString *)environment
             service:(NSString *)service
               actor:(NSString *)actor
                 url:(NSString *)url
          identifier:(NSString *)identifier
          occurredAt:(NSDate *)occurredAt {
    @try {
        FOTConfiguration *config = [self configuration];
        if (![config isEnabled]) {
            return;
        }
        NSDictionary<NSString *, id> *payload = [FOTChange payloadWithKind:kind
                                                                     title:title
                                                                   details:details
                                                               environment:environment
                                                                   service:service
                                                                     actor:actor
                                                                       url:url
                                                                identifier:identifier
                                                                occurredAt:occurredAt
                                                             configuration:config];
        if (payload == nil) {
            NSLog(@"[forge-ops-tracker] dropped a change with no title");
            return;
        }

        FOTClient *client;
        @synchronized(self) {
            if (FOTSharedChangeClient == nil) {
                FOTSharedChangeClient = [[FOTClient alloc] initWithConfiguration:config];
            }
            client = FOTSharedChangeClient;
        }
        dispatch_async(FOTChangeQueue(), ^{
            @try {
                [client deliverChange:payload];
            } @catch (NSException *exception) {
                NSLog(@"[forge-ops-tracker] change delivery failed: %@", exception.reason);
            }
        });
    } @catch (NSException *exception) {
        // A change report must never take the app down, whatever the caller passed in.
        NSLog(@"[forge-ops-tracker] recordChange failed: %@", exception.reason);
    }
}

+ (void)_waitForChanges {
    dispatch_sync(FOTChangeQueue(), ^{});
}

+ (void)_resetForTesting {
    FOTSharedConfiguration = nil;
    FOTSharedReporter = nil;
    FOTHandlersInstalled = NO;
    FOTCurrentUser = nil;
    FOTSharedBreadcrumbs = nil;
    [FOTSharedPerformanceFlusher discard];
    FOTSharedPerformanceFlusher = nil;
    [FOTSharedSpanQueue discard];
    FOTSharedSpanQueue = nil;
    [FOTSharedMetricBuffer discard];
    [FOTSharedInfrastructureMetricBuffer discard];
    FOTSharedMetricBuffer = nil;
    FOTSharedInfrastructureMetricBuffer = nil;
    [self _waitForChanges];
    @synchronized(self) {
        FOTSharedChangeClient = nil;
    }
    // Deliberately not touching the real NSUncaughtExceptionHandler/signal dispositions here:
    // resetting those between test runs would risk leaving the *test process itself* without a
    // safety net if a later, unrelated test genuinely crashes.
}

@end
