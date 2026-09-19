#import <XCTest/XCTest.h>
#import "FOTMetricBuffer.h"
#import "FOTTestHTTPServer.h"
#import "ForgeOpsTracker.h"

@interface FOTMetricBufferTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, strong) NSMutableArray<FOTMetricBuffer *> *buffers;
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTMetricBufferTests

- (void)setUp {
    [ForgeOpsTracker _resetForTesting];
    self.buffers = [NSMutableArray array];
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    for (FOTMetricBuffer *buffer in self.buffers) {
        [buffer discard];
    }
    [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
    [ForgeOpsTracker _resetForTesting];
}

- (FOTConfiguration *)configuration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
    config.enabledEnvironments = [NSSet setWithObject:@"production"];
    config.environment = @"production";
    config.releaseVersion = @"a1b2c3d";
    config.serverName = @"web-1";
    config.crashReportsDirectory = self.tempDirectory;
    config.metricFlushInterval = 3600;
    config.infrastructureMetricFlushInterval = 3600;
    return config;
}

- (FOTMetricBuffer *)bufferWithConfiguration:(FOTConfiguration *)config deliver:(BOOL (^)(NSArray *))deliver {
    FOTMetricBuffer *buffer = [[FOTMetricBuffer alloc] initWithConfiguration:config deliver:deliver interval:^NSTimeInterval { return config.metricFlushInterval; }];
    [self.buffers addObject:buffer];
    return buffer;
}

- (NSArray<NSString *> *)names:(NSArray *)entries {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        [names addObject:entry[@"metric_name"]];
    }
    return names;
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

- (void)testDeliversEveryEntryAsOneBatchStampedWithRecordedAt {
    NSMutableArray *delivered = [NSMutableArray array];
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:[self configuration] deliver:^BOOL(NSArray *entries) { [delivered addObject:entries]; return YES; }];

    XCTAssertTrue(([buffer record:@{ @"metric_name": @"signup", @"value": @1 }]));
    XCTAssertTrue(([buffer record:@{ @"metric_name": @"refund", @"value": @(-12.5) }]));
    [buffer flush];

    XCTAssertEqual(delivered.count, (NSUInteger)1);
    XCTAssertEqualObjects([self names:delivered[0]], (@[ @"signup", @"refund" ]));
    XCTAssertEqualObjects(delivered[0][1][@"value"], @(-12.5));
    XCTAssertTrue([delivered[0][0][@"recorded_at"] rangeOfString:@"^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$" options:NSRegularExpressionSearch].location != NSNotFound);
    XCTAssertEqual([buffer count], (NSUInteger)0);
}

- (void)testDropsNaNInfiniteAndNonNumericValues {
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:[self configuration] deliver:^BOOL(NSArray *entries) { return YES; }];
    XCTAssertFalse(([buffer record:@{ @"metric_name": @"nan", @"value": @(NAN) }]));
    XCTAssertFalse(([buffer record:@{ @"metric_name": @"inf", @"value": @(INFINITY) }]));
    XCTAssertFalse(([buffer record:@{ @"metric_name": @"str", @"value": @"12" }]));
    XCTAssertFalse(([buffer record:@{ @"metric_name": @"missing" }]));
    XCTAssertTrue(([buffer record:@{ @"metric_name": @"ok", @"value": @3 }]));
}

- (void)testAFailedDeliveryKeepsEveryEntryForTheNextFlush {
    NSMutableArray *delivered = [NSMutableArray array];
    __block int calls = 0;
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:[self configuration] deliver:^BOOL(NSArray *entries) {
        [delivered addObject:[self names:entries]];
        return ++calls > 1;
    }];

    [buffer record:@{ @"metric_name": @"a", @"value": @1 }];
    [buffer flush];
    [buffer record:@{ @"metric_name": @"b", @"value": @2 }];
    [buffer flush];
    [buffer flush]; // nothing left: no third delivery

    XCTAssertEqualObjects(delivered, (@[ @[ @"a" ], @[ @"a", @"b" ] ]));
}

- (void)testAnEntryRecordedWhileDeliveryIsInFlightIsNeverLost {
    NSMutableArray *delivered = [NSMutableArray array];
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:[self configuration] deliver:^BOOL(NSArray *entries) { [delivered addObject:[self names:entries]]; return YES; }];
    [buffer record:@{ @"metric_name": @"first", @"value": @1 }];
    __weak FOTMetricBuffer *weakBuffer = buffer;
    buffer.beforeDeliveryHook = ^{
        [weakBuffer record:@{ @"metric_name": @"during", @"value": @2 }];
    };

    [buffer flush];
    buffer.beforeDeliveryHook = nil;
    [buffer flush];

    XCTAssertEqualObjects(delivered, (@[ @[ @"first" ], @[ @"during" ] ]));
}

- (void)testIsCappedAndDropsFurtherEntriesUntilAFlushSucceeds {
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:[self configuration] deliver:^BOOL(NSArray *entries) { return NO; }];
    NSUInteger accepted = 0;
    for (NSUInteger i = 0; i < FOTMetricBufferMaxEntries + 50; i++) {
        if ([buffer record:@{ @"metric_name": @"m", @"value": @1 }]) {
            accepted++;
        }
    }
    XCTAssertEqual(accepted, FOTMetricBufferMaxEntries);
}

- (void)testTheTimerFlushesOnItsOwnInterval {
    FOTConfiguration *config = [self configuration];
    config.metricFlushInterval = 0.05;
    NSMutableArray *delivered = [NSMutableArray array];
    FOTMetricBuffer *buffer = [self bufferWithConfiguration:config deliver:^BOOL(NSArray *entries) {
        @synchronized(delivered) { [delivered addObject:entries]; }
        return YES;
    }];

    [buffer record:@{ @"metric_name": @"tick", @"value": @1 }];

    XCTAssertTrue([self waitUntil:^BOOL { @synchronized(delivered) { return delivered.count >= 1; } } timeout:3.0]);
}

- (void)testCaptureMetricAndCaptureInfrastructureMetricDeliverToTheirOwnEndpointsThroughTheFullStack {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.releaseVersion = @"a1b2c3d";
        config.serverName = @"web-1";
        config.crashReportsDirectory = self.tempDirectory;
        config.metricFlushInterval = 3600;
        config.infrastructureMetricFlushInterval = 3600;
    }];

    [ForgeOpsTracker captureMetric:@"signup"];
    [ForgeOpsTracker captureMetric:@"payment" value:49];
    [ForgeOpsTracker captureInfrastructureMetric:@"cpu" value:0.42 hostname:@"db-1"];
    [ForgeOpsTracker captureInfrastructureMetric:@"memory" value:0.7 hostname:nil];
    [ForgeOpsTracker flushMetrics];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)2);
    NSDictionary *byPath = @{ self.server.requests[0][@"path"]: self.server.requests[0], self.server.requests[1][@"path"]: self.server.requests[1] };
    NSDictionary *custom = [NSJSONSerialization JSONObjectWithData:[byPath[@"/api/v1/custom_metrics"][@"body"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqualObjects([self names:custom[@"metrics"]], (@[ @"signup", @"payment" ]));
    XCTAssertEqualObjects(custom[@"metrics"][0][@"value"], @1);
    XCTAssertEqualObjects(custom[@"metrics"][1][@"value"], @49);
    XCTAssertEqualObjects(custom[@"metrics"][0][@"environment"], @"production");
    XCTAssertEqualObjects(custom[@"metrics"][0][@"release"], @"a1b2c3d");
    NSDictionary *infrastructure = [NSJSONSerialization JSONObjectWithData:[byPath[@"/api/v1/infrastructure_metrics"][@"body"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqualObjects(infrastructure[@"metrics"][0][@"hostname"], @"db-1");
    XCTAssertEqualObjects(infrastructure[@"metrics"][1][@"hostname"], @"web-1");
}

- (void)testCapturesAreANoOpWhenReportingIsNotEnabledForThisEnvironment {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.environment = @"development";
        config.crashReportsDirectory = self.tempDirectory;
    }];
    [ForgeOpsTracker captureMetric:@"signup"];
    [ForgeOpsTracker captureInfrastructureMetric:@"cpu" value:1 hostname:nil];
    [ForgeOpsTracker flushMetrics];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testAnInfrastructureReadingWithNoHostnameIsDroppedRatherThanSent {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];
    [ForgeOpsTracker captureInfrastructureMetric:@"cpu" value:1 hostname:nil];
    [ForgeOpsTracker flushMetrics];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testTheMetricURLsSwapTheTrailingEventsSegment {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";
    XCTAssertEqualObjects([config customMetricsURL].absoluteString, @"https://tracker.example.com/api/v1/custom_metrics");
    XCTAssertEqualObjects([config infrastructureMetricsURL].absoluteString, @"https://tracker.example.com/api/v1/infrastructure_metrics");
}

@end
