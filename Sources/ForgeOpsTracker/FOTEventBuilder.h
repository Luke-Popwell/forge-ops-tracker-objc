#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface FOTEventBuilder : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/**
 * Builds the payload shape the ingestion API expects out of an NSException. Note what's
 * different here versus every other SDK in this repo: an NSException's -callStackSymbols is a
 * *binary symbol table* dump, not source locations -- there's no file/line the way a source-level
 * language's exception carries, because that information simply doesn't exist in a compiled,
 * stripped release binary at runtime. Real line-level symbolication needs an offline pass against
 * the app's own dSYM after the fact (exactly how Crashlytics/Sentry-cocoa-style crash reporters
 * work) -- out of scope for a client SDK that has to work standalone, with no external
 * symbolication service to call. `backtrace` frames here carry the binary image name (closest
 * available analog to "file") and the parsed symbol (closest analog to "method"); `line` is
 * always nil.
 */
- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(nullable NSDictionary<NSString *, id> *)context;

@end

NS_ASSUME_NONNULL_END
