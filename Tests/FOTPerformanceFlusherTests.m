#import <XCTest/XCTest.h>
#import "FOTClient.h"
#import "FOTConfiguration.h"
#import "FOTPerformanceFlusher.h"
#import "FOTTestHTTPServer.h"

@interface FOTPerformanceFlusherTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, strong) FOTPerformanceFlusher *flusher;
@end

@implementation FOTPerformanceFlusherTests

- (void)setUp {
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [self.flusher discard];
    [self.server stop];
}

- (FOTConfiguration *)configurationWithPath:(NSString *)path {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu%@", (unsigned long)self.server.port, path];
    config.environment = @"production";
    config.performanceFlushInterval = 3600; // tests flush by hand unless they say otherwise
    config.timeout = 2.0;
    return config;
}

- (FOTPerformanceFlusher *)flusherForConfiguration:(FOTConfiguration *)config {
    self.flusher = [[FOTPerformanceFlusher alloc] initWithConfiguration:config client:[[FOTClient alloc] initWithConfiguration:config]];
    return self.flusher;
}

- (BOOL)waitUntil:(BOOL (^)(void))predicate timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (predicate()) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    return NO;
}

- (NSDictionary *)lastRequestBody {
    NSData *data = [self.server.requests.lastObject[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (void)testBucketsByTransactionNameWithCountSumAndMax {
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:[self configurationWithPath:@"/api/v1/events"]];

    [flusher recordTransaction:@"GET /users/:id" durationMs:10];
    [flusher recordTransaction:@"GET /users/:id" durationMs:30];
    [flusher recordTransaction:@"POST /orders" durationMs:5];

    NSDictionary *users = [flusher tallyForTransaction:@"GET /users/:id"];
    XCTAssertEqualObjects(users[@"count"], @2);
    XCTAssertEqualObjects(users[@"duration_sum_ms"], @40);
    XCTAssertEqualObjects(users[@"max_duration_ms"], @30);
    XCTAssertEqualObjects([flusher tallyForTransaction:@"POST /orders"][@"count"], @1);
}

- (void)testRecordDoesNothingWhenTrackPerformanceIsOff {
    FOTConfiguration *config = [self configurationWithPath:@"/api/v1/events"];
    config.trackPerformance = NO;
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];

    [flusher recordTransaction:@"GET /x" durationMs:10];

    XCTAssertNil([flusher tallyForTransaction:@"GET /x"]);
}

- (void)testRecordDoesNothingWhenReportingIsNotEnabledForThisEnvironment {
    FOTConfiguration *config = [self configurationWithPath:@"/api/v1/events"];
    config.environment = @"development";
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];

    [flusher recordTransaction:@"GET /x" durationMs:10];

    XCTAssertNil([flusher tallyForTransaction:@"GET /x"]);
}

- (void)testFlushDeliversOneBatchToPerformanceSamplesAndEmptiesTheBuckets {
    FOTConfiguration *config = [self configurationWithPath:@"/api/v1/events"];
    config.releaseVersion = @"a1b2c3d";
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];
    [flusher recordTransaction:@"GET /users/:id" durationMs:10];
    [flusher recordTransaction:@"GET /users/:id" durationMs:30];

    [flusher flush];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    XCTAssertEqualObjects(self.server.requests[0][@"path"], @"/api/v1/performance_samples");
    NSDictionary *sample = [self lastRequestBody][@"samples"][0];
    XCTAssertEqualObjects(sample[@"transaction_name"], @"GET /users/:id");
    XCTAssertEqualObjects(sample[@"request_count"], @2);
    XCTAssertEqualObjects(sample[@"duration_sum_ms"], @40);
    XCTAssertEqualObjects(sample[@"max_duration_ms"], @30);
    XCTAssertEqualObjects(sample[@"environment"], @"production");
    XCTAssertEqualObjects(sample[@"release"], @"a1b2c3d");
    XCTAssertTrue([sample[@"period_started_at"] hasSuffix:@"Z"]);
    XCTAssertNil([flusher tallyForTransaction:@"GET /users/:id"]);
}

- (void)testFlushDoesNothingWhenThereIsNothingToSend {
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:[self configurationWithPath:@"/api/v1/events"]];

    [flusher flush];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testAFailedDeliveryKeepsEveryBucketSoTheNextFlushCarriesMore {
    // /unauthorized answers 401 (and does not end in /events, so the URL is left as-is): a failed
    // delivery. Pointing the DSN at the normal path afterward is the retry that succeeds.
    FOTConfiguration *config = [self configurationWithPath:@"/unauthorized"];
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];
    [flusher recordTransaction:@"GET /x" durationMs:10];

    [flusher flush];
    XCTAssertEqualObjects([flusher tallyForTransaction:@"GET /x"][@"count"], @1);

    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
    [flusher recordTransaction:@"GET /x" durationMs:20];
    [flusher flush];

    XCTAssertEqualObjects([self lastRequestBody][@"samples"][0][@"request_count"], @2);
    XCTAssertNil([flusher tallyForTransaction:@"GET /x"]);
}

- (void)testARecordThatLandsDuringDeliveryIsNeverLost {
    // Deterministic reproduction of the race -flush's own comment describes: the hook runs
    // strictly between the snapshot and delivery succeeding, exactly where a record from another
    // thread could land.
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:[self configurationWithPath:@"/api/v1/events"]];
    [flusher recordTransaction:@"GET /x" durationMs:10];
    __weak FOTPerformanceFlusher *weakFlusher = flusher;
    flusher.beforeDeliveryHook = ^{
        [weakFlusher recordTransaction:@"GET /x" durationMs:25];   // same transaction, mid-delivery
        [weakFlusher recordTransaction:@"GET /new" durationMs:7];  // a brand-new one, mid-delivery
    };

    [flusher flush];

    NSDictionary *x = [flusher tallyForTransaction:@"GET /x"];
    XCTAssertEqualObjects(x[@"count"], @1);
    XCTAssertEqualObjects(x[@"duration_sum_ms"], @25);
    XCTAssertEqualObjects(x[@"max_duration_ms"], @25);
    XCTAssertEqualObjects([flusher tallyForTransaction:@"GET /new"][@"count"], @1);
}

- (void)testDeliversALatencyHistogramPerBucketAlongsideCountSumAndMax {
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:[self configurationWithPath:@"/api/v1/events"]];
    for (NSNumber *duration in @[@10, @40, @120, @700, @12000]) {
        [flusher recordTransaction:@"GET /posts" durationMs:duration.doubleValue];
    }

    [flusher flush];

    NSDictionary *sample = [self lastRequestBody][@"samples"][0];
    NSDictionary *expected = @{@"50": @2, @"250": @1, @"1000": @1, @"inf": @1};
    XCTAssertEqualObjects(sample[@"histogram"], expected);
    XCTAssertEqualObjects(sample[@"request_count"], @5);
}

- (void)testKeepsHistogramCountsForTheNextFlushWhenDeliveryFails {
    FOTConfiguration *config = [self configurationWithPath:@"/unauthorized"]; // answers 401: a failed delivery
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];
    [flusher recordTransaction:@"GET /posts" durationMs:10];
    [flusher flush];

    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
    [flusher recordTransaction:@"GET /posts" durationMs:300];
    [flusher flush];

    NSDictionary *expected = @{@"50": @1, @"500": @1};
    XCTAssertEqualObjects([self lastRequestBody][@"samples"][0][@"histogram"], expected);
}

- (void)testAHistogramCountRecordedDuringDeliveryIsSentOnTheNextFlush {
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:[self configurationWithPath:@"/api/v1/events"]];
    [flusher recordTransaction:@"GET /posts" durationMs:10];
    __weak FOTPerformanceFlusher *weakFlusher = flusher;
    flusher.beforeDeliveryHook = ^{
        weakFlusher.beforeDeliveryHook = nil;
        [weakFlusher recordTransaction:@"GET /posts" durationMs:300]; // same transaction, mid-delivery
        [weakFlusher recordTransaction:@"GET /new" durationMs:5];     // a brand-new one, mid-delivery
    };

    [flusher flush];
    NSDictionary *firstExpected = @{@"50": @1};
    XCTAssertEqualObjects([self lastRequestBody][@"samples"][0][@"histogram"], firstExpected);

    [flusher flush];
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *sample in [self lastRequestBody][@"samples"]) {
        byName[sample[@"transaction_name"]] = sample;
    }
    NSDictionary *postsExpected = @{@"500": @1};
    NSDictionary *newExpected = @{@"50": @1};
    XCTAssertEqualObjects(byName[@"GET /posts"][@"histogram"], postsExpected);
    XCTAssertEqualObjects(byName[@"GET /new"][@"histogram"], newExpected);
}

- (void)testTheTimerFlushesOnItsOwnInterval {
    FOTConfiguration *config = [self configurationWithPath:@"/api/v1/events"];
    config.performanceFlushInterval = 0.05;
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];

    [flusher recordTransaction:@"GET /x" durationMs:10];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:3.0]);
    XCTAssertEqualObjects([self lastRequestBody][@"samples"][0][@"transaction_name"], @"GET /x");
}

- (void)testDiscardCancelsTheTimerAndDeliversNothing {
    FOTConfiguration *config = [self configurationWithPath:@"/api/v1/events"];
    config.performanceFlushInterval = 0.05;
    FOTPerformanceFlusher *flusher = [self flusherForConfiguration:config];
    [flusher recordTransaction:@"GET /x" durationMs:10];

    [flusher discard];
    [NSThread sleepForTimeInterval:0.3];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testPerformanceSamplesURLSwapsTheTrailingEventsSegment {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";

    XCTAssertEqualObjects(config.performanceSamplesURL.absoluteString, @"https://tracker.example.com/api/v1/performance_samples");

    config.dsn = nil;
    XCTAssertNil(config.performanceSamplesURL);
}

@end
