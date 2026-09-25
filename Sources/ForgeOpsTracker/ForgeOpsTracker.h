#import <Foundation/Foundation.h>
#import "FOTChange.h"
#import "FOTConfiguration.h"
#import "FOTRequestSpan.h"
#import "FOTSqlStatement.h"
#import "FOTTrace.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Public entry point. Typical usage, as early as possible in app startup
 * (application:didFinishLaunchingWithOptions: or your SwiftUI App's init):
 *
 *   [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
 *       config.dsn = @"https://<api_key>@getforgeops.net/api/v1/events";
 *       config.environment = @"production";
 *   }];
 *   [ForgeOpsTracker installHandlers];
 *
 * See sdks/objc/README.md for what installHandlers actually covers (an uncaught NSException, and
 * the common fatal signals), what it deliberately doesn't (this is a crash reporter, not a web
 * framework's request-exception hook: there's no equivalent to the Django/Express/Servlet-style
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

/**
 * Report an exception you've already caught, e.g. from your own @try/@catch. The affected user
 * defaults to whatever +setUser: last set, if anything; use captureException:context:user: to
 * override that for this one report.
 */
+ (void)captureException:(NSException *)exception context:(nullable NSDictionary<NSString *, id> *)context;

/**
 * Same as captureException:context:, for an exception caused by a database call: pass the SQL that
 * ran. With captureSqlObjects on (the default), the names of the stored procedure, table and view
 * the statement touched are sent, so an issue says where to start looking. With captureSqlStatement
 * on too (off by default), the statement itself is sent as well, with every string and number
 * replaced by "?" first. The raw statement never leaves the process either way. You can instead
 * attach it to the exception itself under FOTSqlStatementKey in its userInfo and call the plain
 * captureException:context:.
 */
+ (void)captureException:(NSException *)exception sql:(NSString *)sql context:(nullable NSDictionary<NSString *, id> *)context;

/** Same as captureException:context:, with an explicit user overriding whatever +setUser: last set. */
+ (void)captureException:(NSException *)exception
                  context:(nullable NSDictionary<NSString *, id> *)context
                     user:(nullable NSDictionary<NSString *, id> *)user;

/**
 * Same as captureException:context:user:, linked to trace: the event carries its trace_id, so
 * ForgeOps shows it next to a backend error from the same request (see
 * -[FOTTrace startRequestSpan:]). Without one (nil, or any of the other capture methods), the trace
 * whose synchronous block is running on this thread (+traceNamed:block:, -measureSpan:kind:block:)
 * is used, if any; code in a completion handler or on another queue should pass it explicitly. No
 * trace, no trace_id: the event is exactly what it was before. An uncaught NSException raised
 * inside such a block carries that trace's id too.
 */
+ (void)captureException:(NSException *)exception
                  context:(nullable NSDictionary<NSString *, id> *)context
                     user:(nullable NSDictionary<NSString *, id> *)user
                    trace:(nullable FOTTrace *)trace;

/**
 * Manually attaches an affected user to whatever gets reported from here on: an explicit
 * captureException:context: call, an uncaught NSException, or a fatal signal. There's no way to
 * automatically detect "the current user" on iOS/macOS the way a server-side framework's session
 * middleware can, so call this yourself, e.g. right after sign-in. id/email/username are all
 * independently optional; pass nil (or an empty dictionary) to clear whatever was set, e.g. on
 * sign-out. A mobile app install is effectively single-user (unlike a server handling many
 * concurrent requests at once), so this is a plain class-level property, not thread-local storage.
 */
+ (void)setUser:(nullable NSDictionary<NSString *, id> *)user;

/**
 * Records one breadcrumb: an entry in a small, bounded trail of recent events attached to whatever
 * gets reported next (an explicit captureException:context: call, an uncaught NSException, or a
 * fatal signal), so an issue's detail page can show what led up to it. category/level default to
 * @"custom"/@"info"; data is any small dictionary of extra detail. Only the most recent
 * FOTConfiguration.maxBreadcrumbs (30) are kept, oldest dropped first; a no-op when
 * FOTConfiguration.trackBreadcrumbs is NO. Safe to call from any thread.
 *
 * Nothing records one automatically: there's no request/controller lifecycle in a crash reporter
 * to time one from, so every breadcrumb is one you add by hand, wherever it's meaningful (a screen
 * appearing, a network call starting). Once +installHandlers has run, the trail is also written to
 * disk as it changes, so a fatal signal's report (which can only be uploaded on the next launch,
 * by a different process) still carries the trail that led up to it. See FOTBreadcrumbBuffer.h.
 */
+ (void)addBreadcrumb:(NSString *)message;
+ (void)addBreadcrumb:(NSString *)message category:(NSString *)category;
+ (void)addBreadcrumb:(NSString *)message
              category:(NSString *)category
                 level:(NSString *)level
                  data:(nullable NSDictionary<NSString *, id> *)data;

/**
 * Empties the breadcrumb trail. A mobile app is effectively single-flow (one shared trail, like
 * +setUser:'s one shared user), so this is only needed to start a new logical unit of work (say, a
 * new sign-in session) with a fresh trail.
 */
+ (void)clearBreadcrumbs;

/**
 * @internal not part of the public API: the trail as it stands right now, read by the uncaught
 * exception handler and captureException.
 */
+ (NSArray<NSDictionary<NSString *, id> *> *)currentBreadcrumbs;

/**
 * @internal not part of the public API: the previous run's persisted trail, if it plausibly
 * belongs to a crash that happened at crashDate, read by FOTReporter when completing a raw signal
 * report at upload time. See FOTBreadcrumbBuffer.h.
 */
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)previousRunBreadcrumbsForCrashOccurringAt:(NSDate *)crashDate;

/**
 * Records one timed call's duration, in milliseconds, under transactionName: tallied in-process
 * (count, total, max) and flushed every FOTConfiguration.performanceFlushInterval (60s) as one small
 * aggregate report per transaction, for the Performance page's per-transaction table, not one
 * network call per call. A no-op when FOTConfiguration.trackPerformance is NO or reporting isn't
 * enabled for this environment. Safe to call from any thread.
 *
 * This client has no web framework integration, so nothing is timed automatically: wrap whatever
 * you want on the Performance page yourself, with +measureTransaction:block:, or call this directly
 * with a duration you measured. Keep transactionName low-cardinality (@"GET /users/:id", not
 * @"GET /users/42"): every distinct name is its own row.
 */
+ (void)recordPerformance:(NSString *)transactionName durationMs:(double)durationMs;

/**
 * Runs block, records how long it took under transactionName (see +recordPerformance:durationMs:),
 * and returns once it has. Recorded even if block raises an NSException (which then propagates
 * unchanged): a handler that fails is exactly one worth seeing on the Performance page. Use a
 * __block variable to get a value out of block.
 */
+ (void)measureTransaction:(NSString *)transactionName block:(NS_NOESCAPE void (^)(void))block;

/**
 * Delivers whatever has been tallied so far right now (synchronously: blocks the calling thread on
 * the network), instead of waiting for the next timer tick. A GCD timer flushes on its own every
 * performanceFlushInterval, but an iOS app is suspended shortly after it goes to the background and
 * nothing is flushed at exit, so call this from applicationDidEnterBackground:/sceneDidEnterBackground:
 * (on a background queue if you'd rather not block the main thread) or before a command-line tool quits.
 */
+ (void)flushPerformance;

/**
 * Custom metrics and infrastructure monitoring: two explicit calls (nothing is automatic, so there is
 * no trackMetrics flag). +captureMetric:value: records a named business event (a signup, a payment,
 * anything you want to name): pass 1 for a bare counter or a real magnitude; it may be negative (a
 * refund). +captureInfrastructureMetric:value:hostname: records one reading (cpu, memory, disk,
 * anything else a program of yours reads) from one of your own hosts; hostname nil means
 * FOTConfiguration.serverName, so a tool running on the box it reports about needs none. Both are
 * buffered and flushed as one batch every FOTConfiguration.metricFlushInterval /
 * infrastructureMetricFlushInterval (60s) on a private serial queue, off the calling thread. Every
 * entry is stored as captured (a signup is a row, not a running total), so a count or sum computed
 * later is exact. Both are a no-op when reporting isn't enabled for this environment, and a NaN or
 * infinite value is dropped. A buffer holds at most FOTMetricBufferMaxEntries entries and drops
 * further ones until a flush succeeds; a failed delivery keeps every entry, and one captured while a
 * delivery is in flight is kept too.
 */
+ (void)captureMetric:(NSString *)name value:(double)value;
+ (void)captureMetric:(NSString *)name;
+ (void)captureInfrastructureMetric:(NSString *)name value:(double)value hostname:(nullable NSString *)hostname;

/**
 * Delivers every buffered metric and infrastructure reading right now (synchronously: blocks the
 * calling thread on the network). An iOS app is suspended shortly after it goes to the background and
 * nothing is flushed at exit, so call this from applicationDidEnterBackground: (on a background
 * queue if you'd rather not block the main thread) or before a command-line tool quits.
 */
+ (void)flushMetrics;

/**
 * Records one change to what the app is running: a feature flag flipped, a remote config value
 * updated, anything that could explain a shift in crashes or errors. ForgeOps shows it on the
 * timeline next to the errors around it. kind is one of the FOTChangeKind constants (anything else
 * is sent as FOTChangeKindOther); title is required and cut to 200 characters. details is a small
 * JSON-serializable dictionary; environment nil means FOTConfiguration.environment; url must be
 * http(s); identifier is an idempotency key (the "id" the server dedupes on); occurredAt nil means now.
 *
 * Returns immediately: the change is sent on a private serial queue, off the calling thread, and
 * nothing here ever raises, whether the request fails or the plan doesn't include change tracking.
 * A no-op when reporting isn't enabled for this environment.
 *
 *   [flagClient onFlagChanged:^(NSString *key, BOOL oldValue, BOOL newValue) {
 *       [ForgeOpsTracker recordChange:FOTChangeKindFeatureFlag
 *                               title:[NSString stringWithFormat:@"%@ turned %@", key, newValue ? @"on" : @"off"]
 *                             details:@{ @"key": key, @"from": @(oldValue), @"to": @(newValue) }];
 *   }];
 */
+ (void)recordChange:(NSString *)kind title:(NSString *)title;
+ (void)recordChange:(NSString *)kind title:(NSString *)title details:(nullable NSDictionary<NSString *, id> *)details;
+ (void)recordChange:(NSString *)kind
               title:(NSString *)title
             details:(nullable NSDictionary<NSString *, id> *)details
         environment:(nullable NSString *)environment
             service:(nullable NSString *)service
               actor:(nullable NSString *)actor
                 url:(nullable NSString *)url
          identifier:(nullable NSString *)identifier
          occurredAt:(nullable NSDate *)occurredAt;

/** @internal not part of the public API: blocks until every change recorded so far has been sent (for tests). */
+ (void)_waitForChanges;

/**
 * Distributed tracing: one flow's own call tree (a screen load, a sign-in, a network round trip and
 * what it triggered), sent to ForgeOps only when the whole thing took at least
 * FOTConfiguration.traceCaptureThreshold (1s), so fast flows cost nothing on the wire. An outgoing
 * request made through -[FOTTrace startRequestSpan:] (or +dataTaskWithSession:request:trace:
 * completionHandler:) carries a W3C traceparent header, so a backend that also reports to ForgeOps
 * continues the trace, and an error captured with the trace carries its trace_id.
 *
 *   [ForgeOpsTracker traceNamed:@"load home screen" block:^(FOTTrace *trace) {
 *       [trace measureSpan:@"fetch feed" kind:@"http" block:^{ [self fetchFeed]; }];
 *       [trace measureSpan:@"decode" kind:@"service" block:^{ [self decode]; }];
 *   }];
 *
 * Or hold the trace yourself across queues and finish it when the flow ends:
 *
 *   FOTTrace *trace = [ForgeOpsTracker startTrace:@"checkout"];
 *   ...                       // any thread: [trace measureSpan:... block:...]
 *   [trace finish];
 *
 * Returns nil when FOTConfiguration.trackTracing is NO or reporting isn't enabled for this
 * environment; messaging nil is a harmless no-op in Objective-C, so callers never need to check.
 * kind is one of controller, service, database, redis, http, job, other (anything else is sent as
 * "other"). This client has no web framework integration, so nothing starts a trace or records a
 * span automatically. Delivery runs on a private serial queue, bounded, off the calling thread.
 */
+ (nullable FOTTrace *)startTrace:(NSString *)name;

/** Runs block with a new trace and finishes it afterward, even if block raises an NSException (which then propagates unchanged). block receives nil when tracing is off, so it is always safe to message. While block runs, the trace is current on this thread, so captureException: there links to it. */
+ (void)traceNamed:(NSString *)name block:(NS_NOESCAPE void (^)(FOTTrace *_Nullable trace))block;

/**
 * An NSURLSession data task (not yet resumed) for request, sent inside trace: the request carries a
 * traceparent header and an http span is recorded when it completes, before completionHandler runs
 * (see -[FOTTrace startRequestSpan:]). With a nil trace it is a plain data task for request, so
 * callers never need to check whether tracing is on.
 *
 *   [[ForgeOpsTracker dataTaskWithSession:NSURLSession.sharedSession request:request trace:trace
 *                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
 *       ...
 *   }] resume];
 */
+ (NSURLSessionDataTask *)dataTaskWithSession:(NSURLSession *)session
                                      request:(NSURLRequest *)request
                                        trace:(nullable FOTTrace *)trace
                            completionHandler:(void (^)(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error))completionHandler;

/**
 * Delivers every finished trace that is still queued right now (synchronously: blocks the calling
 * thread on the network). An iOS app is suspended shortly after it goes to the background and
 * nothing is flushed at exit, so call this from applicationDidEnterBackground: (on a background
 * queue if you'd rather not block the main thread) or before a command-line tool quits.
 */
+ (void)flushSpans;

/**
 * @internal not part of the public API: reads the previous run's persisted trail and begins
 * persisting this run's. +installHandlers calls this itself; exposed separately so it can be
 * exercised without installing real process-wide signal handlers.
 */
+ (void)_startBreadcrumbPersistence;

/** @internal not part of the public API: blocks until breadcrumb persistence writes have finished (for tests). */
+ (void)_waitForBreadcrumbWrites;

/**
 * @internal not part of the public API: the user set via +setUser:, read by FOTReporter to fill in
 * a raw signal-crash report's user at upload time (a signal handler itself can never safely read
 * this; see FOTSignalHandler.h's own comment on what's safe to touch there).
 */
+ (nullable NSDictionary<NSString *, id> *)currentUser;

/** @internal not part of the public API: resets module state between test cases */
+ (void)_resetForTesting;

@end

NS_ASSUME_NONNULL_END
