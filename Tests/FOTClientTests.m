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
    // moment to actually be listening before the first request: real, observed flakiness
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

- (void)testStatusOfDeliveringReturnsTheHTTPStatusAndZeroWhenThereIsNoResponse {
    NSDictionary *payload = @{ @"exception_class": @"RuntimeError" };

    XCTAssertEqual([[[FOTClient alloc] initWithConfiguration:[self configurationWithPath:@"/api/v1/events"]] statusOfDelivering:payload], (NSInteger)202);
    XCTAssertEqual([[[FOTClient alloc] initWithConfiguration:[self configurationWithPath:@"/unauthorized"]] statusOfDelivering:payload], (NSInteger)401);
    XCTAssertEqual([[[FOTClient alloc] initWithConfiguration:[self configurationWithPath:@"/unavailable"]] statusOfDelivering:payload], (NSInteger)503);

    FOTConfiguration *unreachable = [[FOTConfiguration alloc] init];
    unreachable.dsn = @"http://key@127.0.0.1:1/api/v1/events";
    unreachable.timeout = 0.5;
    XCTAssertEqual([[[FOTClient alloc] initWithConfiguration:unreachable] statusOfDelivering:payload], (NSInteger)0);
}

- (void)testA4xxIsRejectedExcept408And429WhichLikeA5xxFailForNow {
    for (NSNumber *status in @[ @400, @401, @403, @404, @413, @422 ]) {
        XCTAssertEqual(FOTDeliveryOutcomeForStatus(status.integerValue), FOTDeliveryOutcomeRejected, @"status %@", status);
    }
    for (NSNumber *status in @[ @0, @408, @429, @500, @502, @503, @301 ]) {
        XCTAssertEqual(FOTDeliveryOutcomeForStatus(status.integerValue), FOTDeliveryOutcomeFailed, @"status %@", status);
    }
    for (NSNumber *status in @[ @200, @201, @202, @204 ]) {
        XCTAssertEqual(FOTDeliveryOutcomeForStatus(status.integerValue), FOTDeliveryOutcomeDelivered, @"status %@", status);
    }
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
