#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@class FOTRequestSpan;

/**
 * One trace: a tree of timed spans (a screen load, a sign-in flow, one network round trip and what
 * it triggered) that is sent to ForgeOps only when the whole thing took at least
 * FOTConfiguration.traceCaptureThreshold (1s), so fast flows cost nothing on the wire. Start one
 * with +[ForgeOpsTracker startTrace:] or +[ForgeOpsTracker traceNamed:block:], never directly.
 *
 * Unlike the server SDKs, where one request owns one thread, a mobile flow hops between the main
 * queue and background queues, so a trace is an explicit object you pass around (or capture in a
 * block) rather than ambient per-thread state, and it is safe to use from any thread. Nesting is
 * tracked per thread: a span opened by -measureSpan:kind:block: becomes the parent of any span
 * recorded on the same thread inside that block, and a span recorded from another thread parents
 * under the trace's root.
 *
 * Kinds are the closed set the ingestion API accepts (controller, service, database, redis, http,
 * job, other): anything else is sent as "other", since one bad kind would make the server reject
 * the whole trace. A trace holds at most 500 spans including the root.
 *
 * Ids are W3C trace context ids (https://www.w3.org/TR/trace-context/): a 32 lowercase hex trace id
 * and 16 lowercase hex span ids, never all zeros. That is what lets -startRequestSpan: hand the
 * trace to a backend as a traceparent header, and what an error captured with the trace carries as
 * its trace_id, so ForgeOps can show the two sides of one request together.
 */
@interface FOTTrace : NSObject

- (instancetype)init NS_UNAVAILABLE;

/** This trace's W3C trace id: 32 lowercase hex characters, never all zeros. */
@property (nonatomic, copy, readonly) NSString *traceId;

/** Times block as a span (a child of whatever span is open on this thread, or of the root), recording it even if block raises an NSException, which then propagates unchanged. */
- (void)measureSpan:(NSString *)name kind:(NSString *)kind block:(NS_NOESCAPE void (^)(void))block;
- (void)measureSpan:(NSString *)name kind:(NSString *)kind data:(nullable NSDictionary<NSString *, id> *)data block:(NS_NOESCAPE void (^)(void))block;

/**
 * The same, for a "database" span that also carries the SQL it ran (a local SQLite query, say) and
 * which database it was ("sqlite"): sent in the span's data as db.statement, with every string and
 * number literal replaced by "?" first (so values never leave the device) and cut at 4000
 * characters, and db.system, lowercased. Both are ignored on any other kind, and either may be nil.
 *
 *     [trace measureSpan:@"Load orders" kind:@"database" data:nil statement:sql dbSystem:@"sqlite" block:^{
 *         rows = [db query:sql];
 *     }];
 */
- (void)measureSpan:(NSString *)name
               kind:(NSString *)kind
               data:(nullable NSDictionary<NSString *, id> *)data
          statement:(nullable NSString *)statement
           dbSystem:(nullable NSString *)dbSystem
              block:(NS_NOESCAPE void (^)(void))block;

/** Records a span you timed yourself, under whatever is open on this thread (or the root). */
- (void)recordSpan:(NSString *)name kind:(NSString *)kind startedAt:(NSDate *)startedAt durationMs:(double)durationMs data:(nullable NSDictionary<NSString *, id> *)data;

/** The same, with a "database" span's SQL and database system, sent as described on -measureSpan:kind:data:statement:dbSystem:block:. */
- (void)recordSpan:(NSString *)name
              kind:(NSString *)kind
         startedAt:(NSDate *)startedAt
        durationMs:(double)durationMs
              data:(nullable NSDictionary<NSString *, id> *)data
         statement:(nullable NSString *)statement
          dbSystem:(nullable NSString *)dbSystem;

/**
 * @internal not part of the public API: a span's data with a "database" span's SQL added as
 * db.statement (masked) and db.system. A db.statement passed in data directly is masked too, so raw
 * SQL can never go out on a span.
 */
+ (nullable NSDictionary<NSString *, id> *)spanDataForKind:(NSString *)kind
                                                       data:(nullable NSDictionary<NSString *, id> *)data
                                                  statement:(nullable NSString *)statement
                                                   dbSystem:(nullable NSString *)dbSystem;

/**
 * Starts an http span for one outgoing request and returns it with the request to send:
 * span.request carries a traceparent header whose parent id is this span's own id (unless
 * FOTConfiguration.propagateTraces is NO, the host isn't in tracePropagationTargets, or the
 * request already had one), so a backend that continues the trace nests its root span under this
 * one. Call -[FOTRequestSpan finishWithResponse:error:] when the call completes, from any thread.
 * The span is named "<method> <host>" (never the path, which can carry ids) unless you pass name.
 *
 * Messaging a nil trace returns nil, so where the trace may be nil (tracing off) use
 * +[FOTRequestSpan startWithRequest:trace:name:] or
 * +[ForgeOpsTracker dataTaskWithSession:request:trace:completionHandler:], which send the request
 * unchanged in that case.
 */
- (FOTRequestSpan *)startRequestSpan:(NSURLRequest *)request;
- (FOTRequestSpan *)startRequestSpan:(NSURLRequest *)request name:(nullable NSString *)name;

/**
 * Ends the trace and sends it if the root took long enough. Idempotent: a second call does nothing,
 * and spans recorded after it are dropped.
 */
- (void)finish;

/** @internal not part of the public API: builds a trace that is delivered through the given block on -finish. */
- (instancetype)initWithName:(NSString *)name
               configuration:(FOTConfiguration *)configuration
                     deliver:(void (^)(NSDictionary<NSString *, id> *payload))deliver NS_DESIGNATED_INITIALIZER;

/** @internal not part of the public API: the configuration this trace was started with. */
@property (nonatomic, strong, readonly) FOTConfiguration *configuration;

/** @internal not part of the public API: the id of the span open on this thread, or the root's. */
- (NSString *)currentParent;

/**
 * @internal not part of the public API: records a span whose id was chosen before it started (an
 * FOTRequestSpan, whose id already went out in a header).
 */
- (void)recordSpanWithId:(NSString *)spanId
                  parent:(NSString *)parent
                    name:(NSString *)name
                    kind:(NSString *)kind
               startedAt:(NSDate *)startedAt
              durationMs:(double)durationMs
                    data:(nullable NSDictionary<NSString *, id> *)data;

/**
 * @internal not part of the public API: the innermost trace whose synchronous block is running on
 * this thread (+[ForgeOpsTracker traceNamed:block:], -measureSpan:kind:block:), which an error
 * captured there without an explicit trace links to. Only ever pushed and popped around a
 * synchronous block on one thread, so the two always balance.
 */
+ (nullable FOTTrace *)current;
+ (void)pushCurrent:(FOTTrace *)trace;
+ (void)popCurrent:(FOTTrace *)trace;

/** @internal not part of the public API: 32 and 16 lowercase hex characters, never all zeros. */
+ (NSString *)generateTraceId;
+ (NSString *)generateSpanId;

@end

NS_ASSUME_NONNULL_END
