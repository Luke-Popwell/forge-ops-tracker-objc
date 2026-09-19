#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * The bounded, ordered trail of recent events ForgeOpsTracker's +addBreadcrumb: methods append to,
 * attached to whatever gets reported next. Entries are plain dictionaries in the wire shape
 * (category/message/level/timestamp/data), the same "everything here is already a dictionary"
 * choice FOTEventBuilder itself makes. Thread-safe: unlike a server handling one request per
 * thread, a mobile app adds breadcrumbs from whatever thread happens to be running (main, a
 * network callback, a background queue) into the one shared trail, so every access here is
 * serialized behind a lock.
 *
 * Also persisted to disk once -startPersisting is called (ForgeOpsTracker +installHandlers does
 * that), and this is the one thing here with no counterpart in the server-side SDKs: a fatal
 * signal's handler can never safely read this in-memory trail (see FOTSignalHandler.h's own class
 * comment on what's safe to touch there), and the process it lived in is gone by the time the raw
 * signal report is uploaded on the next launch, so without a copy on disk the most common kind of
 * crash would always report an empty trail. Every mutation schedules an asynchronous, atomic write
 * of the (PII-scrubbed, when Configuration's scrubPII is on) trail to a sibling file of the crash
 * reports directory. At -startPersisting time, whatever the previous run left behind is read back
 * first and held in memory as the previous run's trail, before this run's own writes can replace it.
 */
@interface FOTBreadcrumbBuffer : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Does nothing when the configuration's trackBreadcrumbs is NO. Drops the oldest entries past maxBreadcrumbs. */
- (void)addBreadcrumbWithMessage:(NSString *)message
                         category:(NSString *)category
                            level:(NSString *)level
                             data:(nullable NSDictionary<NSString *, id> *)data;

- (void)clear;

/** A copy of the current trail, oldest first. */
- (NSArray<NSDictionary<NSString *, id> *> *)all;

/** Reads the previous run's persisted trail (if any) into memory, then begins persisting this run's. Idempotent. */
- (void)startPersisting;

/**
 * The previous run's trail, if it could plausibly belong to a crash that happened at
 * `crashDate`: the persisted file's last write must not be later than the crash itself, or a
 * later run (one that didn't crash, or crashed differently) has already replaced the trail that
 * crash left behind, and attaching it would be misleading rather than helpful. nil otherwise.
 */
- (nullable NSArray<NSDictionary<NSString *, id> *> *)previousRunBreadcrumbsForCrashOccurringAt:(NSDate *)crashDate;

/** @internal not part of the public API: blocks until every scheduled persistence write has finished (for tests). */
- (void)_waitForPendingWrites;

@end

NS_ASSUME_NONNULL_END
