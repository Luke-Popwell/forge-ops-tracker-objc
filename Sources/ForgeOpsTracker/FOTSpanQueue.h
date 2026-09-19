#import <Foundation/Foundation.h>
#import "FOTClient.h"
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Delivers finished traces to the spans endpoint, one at a time on a private serial queue, so
 * finishing a slow trace never blocks the caller on the network. Bounded: once FOTSpanQueueLimit
 * traces are waiting, a new one is dropped rather than queued, since a flow slow enough to be traced
 * must not also grow this app's memory. Nothing is delivered at exit and an iOS app is suspended
 * shortly after it backgrounds, so a flow that ends right before that should call
 * +[ForgeOpsTracker flushSpans] (see README.md).
 */
@interface FOTSpanQueue : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration client:(FOTClient *)client NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Returns NO (dropping the trace) when the queue is full. */
- (BOOL)push:(NSDictionary<NSString *, id> *)trace;

/** Blocks until every queued trace has been delivered (or has failed). */
- (void)waitUntilDelivered;

/** Drops whatever is still waiting without delivering it. */
- (void)discard;

@end

NS_ASSUME_NONNULL_END
