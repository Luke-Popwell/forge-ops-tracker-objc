#import <Foundation/Foundation.h>
#import "FOTClient.h"
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Times work in-process, bucketed by transaction name (see ForgeOpsTracker +recordPerformance:
 * durationMs: and +measureTransaction:block:), and periodically flushes each distinct bucket as one
 * small aggregate report, rather than one network call per timed call. Ported from
 * gems/forge_ops_tracker/lib/forge_ops_tracker/performance_flusher.rb and sdks/go's own port of it,
 * including the one thing both of those learned the hard way: see -flush's own comment on why it
 * subtracts what it delivered instead of clearing the buckets.
 *
 * The periodic flush is a GCD timer on a private serial queue, created on the first recorded
 * duration. A dispatch source never keeps a process alive, so unlike a run-loop Timer it can't hold
 * a command-line tool open; and unlike this SDK's crash path (written now, uploaded next launch),
 * there is no next launch to wait for here, so an iOS/macOS app that is about to be suspended or
 * quit should call ForgeOpsTracker +flushPerformance itself (see README.md). Nothing is flushed at
 * exit: an iOS app has no normal exit to hook.
 */
@interface FOTPerformanceFlusher : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration client:(FOTClient *)client NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Does nothing (and starts no timer) when trackPerformance is NO or reporting isn't enabled for this environment. */
- (void)recordTransaction:(NSString *)transactionName durationMs:(double)durationMs;

/**
 * Snapshots the buffered buckets and delivers them as one batch (synchronously: blocks the calling
 * thread on the network). A failed delivery keeps every bucket where it is, so the next flush's
 * batch just grows instead of losing what was already tallied: there's no other copy of this data
 * anywhere.
 *
 * Only exactly what this snapshot delivered is removed afterward, subtracted from whatever is in
 * each bucket by then, never the whole set cleared outright. -recordTransaction:durationMs: can run
 * on another thread while delivery is in flight (the lock is deliberately released around the
 * network call), so a record for a transaction already in the snapshot, or a brand-new one, can
 * land in the exact window between the snapshot and delivery succeeding. Clearing afterward, as if
 * delivery had covered everything now in the set, would silently discard that data forever. This is
 * a real bug sdks/go had and fixed, and that gems/forge_ops_tracker's reference implementation still
 * has; see this SDK's own test for a deterministic reproduction.
 */
- (void)flush;

/** Cancels the timer and drops every bucket without delivering anything. */
- (void)discard;

/** @internal not part of the public API: (count, sum, max) for one transaction as @{@"count":, @"duration_sum_ms":, @"max_duration_ms":}, or nil. */
- (nullable NSDictionary<NSString *, NSNumber *> *)tallyForTransaction:(NSString *)transactionName;

/**
 * @internal not part of the public API: called between the snapshot and the delivery inside -flush,
 * with no lock held, so a test can record "concurrently" at exactly the moment the race window is
 * open without needing a second thread.
 */
@property (nonatomic, copy, nullable) void (^beforeDeliveryHook)(void);

@end

NS_ASSUME_NONNULL_END
