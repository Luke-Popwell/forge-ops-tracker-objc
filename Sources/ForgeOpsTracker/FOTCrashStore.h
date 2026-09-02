#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Persists crash event payloads to disk and reads them back -- the "queue" for this SDK, in the
 * sense every other SDK's DeliveryQueue is its own queue, except this one survives the process
 * dying (which, for a crash reporter, is the one guarantee that actually matters: the app is
 * about to terminate, possibly abnormally, so anything not already durably written before that
 * happens is lost). Each payload is one JSON file under Configuration#crashReportsDirectory,
 * named by a UUID so concurrent writes (unlikely, but not impossible if multiple threads crash
 * near-simultaneously) never collide.
 */
@interface FOTCrashStore : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Writes payload to disk synchronously. Returns NO (and never throws) if the write fails for any reason. */
- (BOOL)writePayload:(NSDictionary<NSString *, id> *)payload;

/** The file URL of every pending payload currently on disk, oldest first. */
- (NSArray<NSURL *> *)pendingPayloadURLs;

- (nullable NSDictionary<NSString *, id> *)payloadAtURL:(NSURL *)url;

- (void)deletePayloadAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
