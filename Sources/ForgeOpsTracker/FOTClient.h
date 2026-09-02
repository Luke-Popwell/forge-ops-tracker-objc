#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Delivers one payload over HTTP. Every failure mode -- DNS, connection, timeout, a non-2xx
 * response -- is caught here and turned into a NO return rather than a thrown exception, since a
 * broken or unreachable tracker must never be able to break the host app. Uses NSURLSession, not
 * a third-party dependency -- same reasoning as every other SDK in this repo (see e.g.
 * sdks/node/src/client.js): this has to work in any host app without adding a dependency of its
 * own for something as simple as one POST request.
 *
 * -deliver: is synchronous (blocks the calling thread until the request completes or times out),
 * deliberately -- crash report upload here always happens on the *next* app launch (see
 * FOTCrashStore), from a background queue this SDK controls itself, not inline with anything
 * user-facing; there's no live request to avoid blocking the way the other SDKs' async delivery
 * queues exist to protect.
 */
@interface FOTClient : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)deliver:(NSDictionary<NSString *, id> *)payload;

@end

NS_ASSUME_NONNULL_END
