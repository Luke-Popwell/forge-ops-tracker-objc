#import <XCTest/XCTest.h>
#import "FOTClient.h"
#import "FOTConfiguration.h"
#import "FOTTestHTTPServer.h"

@interface FOTClientTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@end

@implementation FOTClientTests

- (void)setUp {
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    // The accept loop runs on its own thread and starts polling immediately, but give it a brief
    // moment to actually be listening before the first request -- real, observed flakiness
    // without this, not a hypothetical.
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [self.server stop];
}

- (FOTConfiguration *)configurationWithPath:(NSString *)path {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = [NSString stringWithFormat:@"http://secret-key@127.0.0.1:%lu%@", (unsigned long)self.server.port, path];
    config.timeout = 2.0;
    return config;
}

- (void)testReturnsTrueAndSendsApiKeyAsBearerTokenPayloadAsJSON {
    FOTClient *client = [[FOTClient alloc] initWithConfiguration:[self configurationWithPath:@"/api/v1/events"]];

    BOOL ok = [client deliver:@{ @"exception_class": @"RuntimeError", @"message": @"boom" }];

    XCTAssertTrue(ok);
    NSArray *requests = self.server.requests;
    XCTAssertEqual(requests.count, (NSUInteger)1);
    NSDictionary *headers = requests[0][@"headers"];
    XCTAssertEqualObjects(headers[@"Authorization"], @"Bearer secret-key");
    XCTAssertEqualObjects(requests[0][@"path"], @"/api/v1/events");

    NSData *bodyData = [requests[0][@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    XCTAssertEqualObjects(body[@"exception_class"], @"RuntimeError");
    XCTAssertEqualObjects(body[@"message"], @"boom");
}

- (void)testReturnsFalseOnNon2xxResponse {
    FOTClient *client = [[FOTClient alloc] initWithConfiguration:[self configurationWithPath:@"/unauthorized"]];

    XCTAssertFalse([client deliver:@{ @"exception_class": @"RuntimeError" }]);
}

- (void)testReturnsFalseWithoutThrowingWhenThereIsNoReachableServer {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"http://secret-key@127.0.0.1:1/api/v1/events";
    config.timeout = 1.0;
    FOTClient *client = [[FOTClient alloc] initWithConfiguration:config];

    XCTAssertFalse([client deliver:@{ @"exception_class": @"RuntimeError" }]);
}

- (void)testReturnsFalseWhenThereIsNoDSNConfigured {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = nil;
    FOTClient *client = [[FOTClient alloc] initWithConfiguration:config];

    XCTAssertFalse([client deliver:@{ @"exception_class": @"RuntimeError" }]);
}

@end
