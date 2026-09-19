#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface FOTEventBuilder : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/**
 * Builds the payload shape the ingestion API expects out of an NSException. Note what's
 * different here versus every other SDK in this repo: an NSException's -callStackSymbols is a
 * *binary symbol table* dump, not source locations: there's no file/line the way a source-level
 * language's exception carries, because that information simply doesn't exist in a compiled,
 * stripped release binary at runtime. Real line-level symbolication needs an offline pass against
 * the app's own dSYM after the fact (exactly how native crash reporters
 * work): out of scope for a client SDK that has to work standalone, with no external
 * symbolication service to call. `backtrace` frames here carry the binary image name (closest
 * available analog to "file") and the parsed symbol (closest analog to "method"); `line` is
 * always nil.
 *
 * No source context, ever, for the same reason: every other SDK in this repo (that has real
 * file/line info at all) attaches a few lines of source around an in-app frame's culprit line,
 * read off disk at capture-time, but that needs a real file path and line number to key the disk
 * read off of, and `line` here is always nil. `FOTConfiguration.captureSourceContext` still exists,
 * defaulting to YES like every other SDK, purely so a host app configuring this client sees the
 * same option every other SDK has; the underlying capture step is a documented no-op, not a
 * partial implementation of something that can never actually run.
 */
- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(nullable NSDictionary<NSString *, id> *)context;

/**
 * Same as -buildEventForException:context:, with an affected user attached under a top-level
 * "user" key (omitted entirely when nil/empty). See ForgeOpsTracker.h's own -setUser: comment for
 * where this typically comes from. Merged in *after* FOTPiiScrubber runs, never before: unlike
 * most of this repo's other SDKs, FOTPiiScrubber.scrub: recurses over an entire payload by
 * value-pattern alone, with no key-name exemption list at all, so a "user" key present before that
 * call would have its own email value redacted by the EMAIL pattern the same as any other string;
 * merging it in afterward is what keeps it exempt from scrubbing, matching every other SDK's
 * "the user field is deliberately never redacted" precedent.
 */
- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(nullable NSDictionary<NSString *, id> *)context
                                                      user:(nullable NSDictionary<NSString *, id> *)user;

/**
 * Same as -buildEventForException:context:user:, with a breadcrumb trail attached under a
 * top-level "breadcrumbs" key (omitted entirely when nil/empty, never sent as an empty array).
 * Each entry is a category/message/level/timestamp/data dictionary. Goes through FOTPiiScrubber
 * along with everything else in the payload: that scrubber has no per-field exemption list at all
 * (see the user note above), and a breadcrumb's structured category/level/timestamp values never
 * match any of its patterns in practice, so the same blanket treatment is the consistent choice
 * here rather than a carve-out of its own.
 */
- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(nullable NSDictionary<NSString *, id> *)context
                                                      user:(nullable NSDictionary<NSString *, id> *)user
                                               breadcrumbs:(nullable NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs;

@end

NS_ASSUME_NONNULL_END
