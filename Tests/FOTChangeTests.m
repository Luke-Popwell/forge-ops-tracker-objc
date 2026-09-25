#import <XCTest/XCTest.h>
#import "FOTChange.h"
#import "FOTClient.h"
#import "FOTTestHTTPServer.h"
#import "ForgeOpsTracker.h"

@interface FOTChangeTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTChangeTests

- (void)setUp {
    [ForgeOpsTracker _resetForTesting];
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [ForgeOpsTracker _resetForTesting];
    [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
}

- (void)configureWithEnvironment:(NSString *)environment path:(NSString *)path port:(NSUInteger)port {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu%@", (unsigned long)port, path];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = environment;
        config.crashReportsDirectory = self.tempDirectory;
    }];
}

- (void)configure {
    [self configureWithEnvironment:@"production" path:@"/api/v1/events" port:self.server.port];
}

- (NSDictionary *)bodyOf:(NSDictionary *)request {
    return [NSJSONSerialization JSONObjectWithData:[request[@"body"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

- (void)testRecordChangePostsThePayloadToTheChangesEndpoint {
    [self configure];

    [ForgeOpsTracker recordChange:FOTChangeKindFeatureFlag
                            title:@"new_checkout turned on"
                          details:@{ @"key": @"new_checkout", @"from": @NO, @"to": @YES }
                      environment:nil
                          service:@"ios-app"
                            actor:@"flag-service"
                              url:@"https://flags.example.com/new_checkout"
                       identifier:@"flag-123"
                       occurredAt:[NSDate dateWithTimeIntervalSince1970:1790000000]];
    [ForgeOpsTracker _waitForChanges];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    NSDictionary *request = self.server.requests.firstObject;
    XCTAssertEqualObjects(request[@"method"], @"POST");
    XCTAssertEqualObjects(request[@"path"], @"/api/v1/changes");
    XCTAssertEqualObjects(request[@"headers"][@"Authorization"], @"Bearer key");

    NSDictionary *sent = [self bodyOf:request];
    XCTAssertEqualObjects(sent[@"kind"], @"feature_flag");
    XCTAssertEqualObjects(sent[@"title"], @"new_checkout turned on");
    XCTAssertEqualObjects(sent[@"environment"], @"production");
    XCTAssertEqualObjects(sent[@"service"], @"ios-app");
    XCTAssertEqualObjects(sent[@"actor"], @"flag-service");
    XCTAssertEqualObjects(sent[@"url"], @"https://flags.example.com/new_checkout");
    XCTAssertEqualObjects(sent[@"id"], @"flag-123");
    XCTAssertEqualObjects(sent[@"occurred_at"], @"2026-09-21T14:13:20.000Z");
    XCTAssertEqualObjects(sent[@"details"][@"key"], @"new_checkout");
    XCTAssertEqualObjects(sent[@"details"][@"to"], @YES);
}

- (void)testOptionalFieldsAreLeftOutAndOccurredAtDefaultsToNow {
    [self configure];

    [ForgeOpsTracker recordChange:FOTChangeKindConfig title:@"checkout timeout raised"];
    [ForgeOpsTracker _waitForChanges];

    NSDictionary *sent = [self bodyOf:self.server.requests.firstObject];
    XCTAssertEqualObjects([NSSet setWithArray:sent.allKeys], ([NSSet setWithObjects:@"kind", @"title", @"environment", @"occurred_at", nil]));
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    XCTAssertNotNil([formatter dateFromString:sent[@"occurred_at"]]);
}

- (void)testAnUnknownKindIsSentAsOther {
    for (NSString *kind in @[ @"feature_flag", @"config", @"migration", @"dependency", @"infrastructure", @"other" ]) {
        XCTAssertEqualObjects([FOTChange normalizedKind:kind], kind);
    }
    XCTAssertEqualObjects([FOTChange normalizedKind:@"flag"], @"other");
    XCTAssertEqualObjects([FOTChange normalizedKind:nil], @"other");
}

- (void)testTitleIsTruncatedAndABlankTitleIsDropped {
    NSString *longTitle = [@"" stringByPaddingToLength:250 withString:@"a" startingAtIndex:0];
    NSDictionary *payload = [FOTChange payloadWithKind:@"other" title:longTitle details:nil environment:nil service:nil actor:nil url:nil identifier:nil occurredAt:nil configuration:[[FOTConfiguration alloc] init]];
    XCTAssertEqual([payload[@"title"] length], (NSUInteger)200);

    [self configure];
    [ForgeOpsTracker recordChange:FOTChangeKindOther title:@"   "];
    [ForgeOpsTracker _waitForChanges];
    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testDetailsJSONCannotEncodeAndANonHTTPURLAreLeftOutInsteadOfRaising {
    NSDictionary *payload = [FOTChange payloadWithKind:@"config"
                                                 title:@"x"
                                               details:@{ @"ratio": @(NAN), @"when": [NSDate date] }
                                           environment:@"qa"
                                               service:nil
                                                 actor:nil
                                                   url:@"javascript:alert(1)"
                                            identifier:nil
                                            occurredAt:nil
                                         configuration:[[FOTConfiguration alloc] init]];
    XCTAssertNil(payload[@"details"]);
    XCTAssertNil(payload[@"url"]);
    XCTAssertEqualObjects(payload[@"environment"], @"qa");
}

- (void)testIsANoOpWhenReportingIsNotEnabled {
    [self configureWithEnvironment:@"development" path:@"/api/v1/events" port:self.server.port];

    [ForgeOpsTracker recordChange:FOTChangeKindFeatureFlag title:@"ignored"];
    [ForgeOpsTracker _waitForChanges];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testNeverRaisesWhenTheServerRejectsTheChangeOrIsUnreachable {
    // The test server answers 401 for this path, standing in for a 403 from a plan without change tracking.
    [self configureWithEnvironment:@"production" path:@"/unauthorized" port:self.server.port];
    XCTAssertNoThrow([ForgeOpsTracker recordChange:FOTChangeKindFeatureFlag title:@"rejected"]);
    [ForgeOpsTracker _waitForChanges];
    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    FOTClient *client = [[FOTClient alloc] initWithConfiguration:[ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {}]];
    XCTAssertFalse(([client deliverChange:@{ @"kind": @"other", @"title": @"x" }]));

    NSUInteger closedPort = self.server.port;
    [self.server stop];
    [self configureWithEnvironment:@"production" path:@"/api/v1/events" port:closedPort];
    XCTAssertNoThrow([ForgeOpsTracker recordChange:FOTChangeKindFeatureFlag title:@"unreachable"]);
    [ForgeOpsTracker _waitForChanges];
}

- (void)testTheChangesURLSwapsTheTrailingEventsSegment {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";
    XCTAssertEqualObjects(config.changesURL.absoluteString, @"https://tracker.example.com/api/v1/changes");
}

@end
