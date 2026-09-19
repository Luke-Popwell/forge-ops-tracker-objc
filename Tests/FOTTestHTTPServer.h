#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A real local HTTP server for FOTClient tests to POST against, in the same spirit as
 * sdks/php/tests/fixtures/echo_server.php: built on plain BSD sockets (accept/read/write) on a
 * background thread within the test process itself, since that's cheap and needs no extra
 * tooling beyond what's already linked (Foundation + libc). Every accepted request is parsed
 * (method, path, headers, body) and recorded for the test to assert against; responds 401 for
 * /unauthorized, 202 otherwise.
 */
@interface FOTTestHTTPServer : NSObject

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *requests;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
