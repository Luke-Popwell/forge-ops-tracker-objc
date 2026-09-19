#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

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
 */
@interface FOTTrace : NSObject

- (instancetype)init NS_UNAVAILABLE;

/** Times block as a span (a child of whatever span is open on this thread, or of the root), recording it even if block raises an NSException, which then propagates unchanged. */
- (void)measureSpan:(NSString *)name kind:(NSString *)kind block:(NS_NOESCAPE void (^)(void))block;
- (void)measureSpan:(NSString *)name kind:(NSString *)kind data:(nullable NSDictionary<NSString *, id> *)data block:(NS_NOESCAPE void (^)(void))block;

/** Records a span you timed yourself, under whatever is open on this thread (or the root). */
- (void)recordSpan:(NSString *)name kind:(NSString *)kind startedAt:(NSDate *)startedAt durationMs:(double)durationMs data:(nullable NSDictionary<NSString *, id> *)data;

/**
 * Ends the trace and sends it if the root took long enough. Idempotent: a second call does nothing,
 * and spans recorded after it are dropped.
 */
- (void)finish;

/** @internal not part of the public API: builds a trace that is delivered through the given block on -finish. */
- (instancetype)initWithName:(NSString *)name
               configuration:(FOTConfiguration *)configuration
                     deliver:(void (^)(NSDictionary<NSString *, id> *payload))deliver NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
