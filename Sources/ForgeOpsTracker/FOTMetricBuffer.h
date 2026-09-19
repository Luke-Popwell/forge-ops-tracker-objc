#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Collects individual +captureMetric:... / +captureInfrastructureMetric:... calls in-process and
 * periodically flushes them as one batch, rather than one network call per capture. Unlike
 * FOTPerformanceFlusher this keeps a list of individually meaningful entries instead of summing them
 * into buckets: a customer's own signup or payment is exactly the kind of thing they will want a
 * genuinely accurate count/sum of later, so the server stores one row per entry as-is. Ported from
 * gems/forge_ops_tracker's metric_buffer.rb and infrastructure_metric_buffer.rb, which are the same
 * class twice; here it is one class instantiated twice, told which delivery block and flush interval
 * to use.
 *
 * Three deliberate differences from the Ruby buffers:
 *
 *  - A flush snapshots the first N entries and, on success, removes exactly those N, instead of
 *    resetting the whole list, so an entry recorded while the request is in flight (the lock is
 *    released around the network call) is kept for the next flush rather than lost.
 *  - The buffer is capped at FOTMetricBufferMaxEntries, and once full further entries are dropped
 *    until a flush succeeds: a plan without the feature answers 403 on every flush, and an uncapped
 *    buffer would then grow for as long as the process lives. Dropping the newest rather than the
 *    oldest keeps the entries a flush is delivering at the front of the array, which is what makes
 *    removing exactly them afterward exact.
 *  - A NaN or infinite value is dropped at record time: NSJSONSerialization raises an exception for
 *    one, and one bad entry would make every batch behind it fail to send.
 *
 * The same lazily created GCD timer as FOTPerformanceFlusher. Nothing is flushed at exit and an
 * iOS/macOS app is suspended shortly after it backgrounds, so call +[ForgeOpsTracker flushMetrics]
 * from applicationDidEnterBackground: or before a command-line tool quits.
 */
FOUNDATION_EXPORT const NSUInteger FOTMetricBufferMaxEntries;

@interface FOTMetricBuffer : NSObject

/** deliver takes a batch and returns whether delivery succeeded; interval is read on every arm of the timer. */
- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration
                              deliver:(BOOL (^)(NSArray<NSDictionary<NSString *, id> *> *entries))deliver
                             interval:(NSTimeInterval (^)(void))interval NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Adds one entry (everything but recorded_at, which is stamped here). Returns whether it was kept. */
- (BOOL)record:(NSDictionary<NSString *, id> *)entry;

/** Delivers everything buffered so far as one batch (synchronously: blocks the calling thread on the network). A failed delivery keeps every entry. */
- (void)flush;

/** Cancels the timer and drops every entry without delivering anything. */
- (void)discard;

/** @internal not part of the public API: how many entries are currently buffered. */
- (NSUInteger)count;

/** @internal not part of the public API: called between the snapshot and the delivery inside -flush, with no lock held, so a test can record "concurrently" at exactly the moment the race window is open. */
@property (nonatomic, copy, nullable) void (^beforeDeliveryHook)(void);

@end

NS_ASSUME_NONNULL_END
