#import <XCTest/XCTest.h>
#import "FOTTestHTTPServer.h"
#import "FOTTrace.h"
#import "ForgeOpsTracker.h"

@interface FOTTraceTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTTraceTests

- (void)setUp {
    [ForgeOpsTracker _resetForTesting];
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
    [ForgeOpsTracker _resetForTesting];
}

- (void)configureWithThreshold:(NSTimeInterval)threshold tracing:(BOOL)tracing {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.releaseVersion = @"a1b2c3d";
        config.crashReportsDirectory = self.tempDirectory;
        config.traceCaptureThreshold = threshold;
        config.trackTracing = tracing;
    }];
}

- (NSDictionary *)deliveredTrace {
    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    NSData *data = [self.server.requests.lastObject[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (NSDictionary *)span:(NSString *)name inTrace:(NSDictionary *)trace {
    for (NSDictionary *span in trace[@"spans"]) {
        if ([span[@"name"] isEqualToString:name]) {
            return span;
        }
    }
    return nil;
}

- (void)testASlowTraceIsDeliveredToSpansWithNestedSpansAndTheWireShape {
    [self configureWithThreshold:0.01 tracing:YES];

    [ForgeOpsTracker traceNamed:@"load home screen" block:^(FOTTrace *trace) {
        [trace measureSpan:@"fetch feed" kind:@"http" data:@{ @"status": @200 } block:^{
            [trace recordSpan:@"SELECT feed" kind:@"database" startedAt:[NSDate dateWithTimeIntervalSince1970:1700000000.123] durationMs:3 data:nil];
            [NSThread sleepForTimeInterval:0.03];
        }];
        [trace recordSpan:@"sibling" kind:@"service" startedAt:[NSDate date] durationMs:1 data:nil];
    }];
    [ForgeOpsTracker flushSpans];

    XCTAssertEqualObjects(self.server.requests.lastObject[@"path"], @"/api/v1/spans");
    NSDictionary *trace = [self deliveredTrace];
    XCTAssertEqual([trace[@"trace_id"] length], (NSUInteger)32);
    NSDictionary *root = [self span:@"load home screen" inTrace:trace];
    NSDictionary *fetch = [self span:@"fetch feed" inTrace:trace];
    XCTAssertEqualObjects(root[@"parent_span_id"], [NSNull null]);
    XCTAssertEqualObjects(root[@"kind"], @"controller");
    XCTAssertEqual([root[@"span_id"] length], (NSUInteger)16);
    XCTAssertEqualObjects(fetch[@"parent_span_id"], root[@"span_id"]);
    XCTAssertEqualObjects([self span:@"SELECT feed" inTrace:trace][@"parent_span_id"], fetch[@"span_id"]);
    XCTAssertEqualObjects([self span:@"sibling" inTrace:trace][@"parent_span_id"], root[@"span_id"]);
    XCTAssertEqualObjects([self span:@"SELECT feed" inTrace:trace][@"started_at"], @"2023-11-14T22:13:20.123Z");
    XCTAssertEqualObjects(fetch[@"environment"], @"production");
    XCTAssertEqualObjects(fetch[@"release"], @"a1b2c3d");
    XCTAssertEqualObjects(fetch[@"data"], @{ @"status": @200 });
}

- (void)testAnUnknownKindIsSentAsOtherSinceTheServerWouldRejectTheWholeTrace {
    [self configureWithThreshold:0.01 tracing:YES];

    [ForgeOpsTracker traceNamed:@"t" block:^(FOTTrace *trace) {
        [trace recordSpan:@"q" kind:@"db" startedAt:[NSDate date] durationMs:1 data:nil];
        [trace recordSpan:@"r" kind:@"database" startedAt:[NSDate date] durationMs:1 data:nil];
        [NSThread sleepForTimeInterval:0.03];
    }];
    [ForgeOpsTracker flushSpans];

    NSDictionary *trace = [self deliveredTrace];
    XCTAssertEqualObjects([self span:@"q" inTrace:trace][@"kind"], @"other");
    XCTAssertEqualObjects([self span:@"r" inTrace:trace][@"kind"], @"database");
}

- (void)testADatabaseSpanSendsItsStatementMaskedAsDbStatementWithDbSystem {
    [self configureWithThreshold:0.01 tracing:YES];

    [ForgeOpsTracker traceNamed:@"t" block:^(FOTTrace *trace) {
        [trace measureSpan:@"Load orders"
                      kind:@"database"
                      data:@{ @"rows": @3 }
                 statement:@"SELECT * FROM orders WHERE email = 'a@b.co' AND total > 4200"
                  dbSystem:@"SQLite"
                     block:^{
                         [NSThread sleepForTimeInterval:0.03];
                     }];
        [trace recordSpan:@"Count"
                     kind:@"database"
                startedAt:[NSDate date]
               durationMs:1
                     data:@{ @"db.statement": @"SELECT count(*) FROM carts WHERE token = 'secret-token'" }];
        [trace recordSpan:@"Not db" kind:@"service" startedAt:[NSDate date] durationMs:1 data:nil statement:@"SELECT 'x'" dbSystem:@"sqlite"];
    }];
    [ForgeOpsTracker flushSpans];

    NSDictionary *trace = [self deliveredTrace];
    XCTAssertEqualObjects([self span:@"Load orders" inTrace:trace][@"data"], (@{
        @"rows": @3,
        @"db.statement": @"SELECT * FROM orders WHERE email = ? AND total > ?",
        @"db.system": @"sqlite",
    }));
    XCTAssertEqualObjects([self span:@"Count" inTrace:trace][@"data"], @{ @"db.statement": @"SELECT count(*) FROM carts WHERE token = ?" });
    XCTAssertEqualObjects([self span:@"Not db" inTrace:trace][@"data"], @{});
    NSString *wire = self.server.requests.lastObject[@"body"];
    XCTAssertFalse([wire containsString:@"a@b.co"]);
    XCTAssertFalse([wire containsString:@"secret-token"]);
}

- (void)testADatabaseStatementIsCutAt4000Characters {
    NSMutableString *sql = [NSMutableString stringWithString:@"SELECT "];
    for (int i = 0; i < 3000; i++) {
        [sql appendString:@"a, "];
    }
    [sql appendString:@"b FROM t"];
    NSString *statement = [FOTTrace spanDataForKind:@"database" data:nil statement:sql dbSystem:nil][@"db.statement"];
    XCTAssertEqual(statement.length, (NSUInteger)4003);
    XCTAssertTrue([statement hasSuffix:@"..."]);
}

- (void)testABlockThatRaisesStillRecordsItsSpanSendsTheTraceAndRethrowsUnchanged {
    [self configureWithThreshold:0.01 tracing:YES];

    XCTAssertThrowsSpecificNamed(
        [ForgeOpsTracker traceNamed:@"boom" block:^(FOTTrace *trace) {
            [trace measureSpan:@"bad" kind:@"service" block:^{
                [NSThread sleepForTimeInterval:0.03];
                @throw [NSException exceptionWithName:@"BoomError" reason:@"boom" userInfo:nil];
            }];
        }],
        NSException, @"BoomError");
    [ForgeOpsTracker flushSpans];

    XCTAssertNotNil([self span:@"bad" inTrace:[self deliveredTrace]]);
}

- (void)testAFastTraceSendsNothing {
    [self configureWithThreshold:60 tracing:YES];

    [ForgeOpsTracker traceNamed:@"fast" block:^(FOTTrace *trace) {
        [trace recordSpan:@"q" kind:@"database" startedAt:[NSDate date] durationMs:1 data:nil];
    }];
    [ForgeOpsTracker flushSpans];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testTrackTracingOffOrReportingDisabledStartsNoTraceAndMessagingNilIsHarmless {
    [self configureWithThreshold:0.01 tracing:NO];
    XCTAssertNil([ForgeOpsTracker startTrace:@"x"]);
    [ForgeOpsTracker traceNamed:@"x" block:^(FOTTrace *trace) {
        XCTAssertNil(trace);
        [trace measureSpan:@"y" kind:@"service" block:^{ [NSThread sleepForTimeInterval:0.03]; }];
        [trace recordSpan:@"z" kind:@"database" startedAt:[NSDate date] durationMs:1 data:nil];
        [trace finish];
    }];

    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.trackTracing = YES;
        config.environment = @"development";
    }];
    XCTAssertNil([ForgeOpsTracker startTrace:@"x"]);
    [ForgeOpsTracker flushSpans];
    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

- (void)testASpanRecordedFromAnotherThreadParentsUnderTheRootNotTheOpenSpanOnThisOne {
    [self configureWithThreshold:0.01 tracing:YES];

    [ForgeOpsTracker traceNamed:@"t" block:^(FOTTrace *trace) {
        [trace measureSpan:@"outer" kind:@"service" block:^{
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [trace recordSpan:@"background" kind:@"job" startedAt:[NSDate date] durationMs:1 data:nil];
                dispatch_semaphore_signal(done);
            });
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
            [NSThread sleepForTimeInterval:0.03];
        }];
    }];
    [ForgeOpsTracker flushSpans];

    NSDictionary *trace = [self deliveredTrace];
    XCTAssertEqualObjects([self span:@"background" inTrace:trace][@"parent_span_id"], [self span:@"t" inTrace:trace][@"span_id"]);
}

- (void)testFinishIsIdempotentAndSpansAfterItAreDropped {
    [self configureWithThreshold:0.01 tracing:YES];

    FOTTrace *trace = [ForgeOpsTracker startTrace:@"t"];
    [NSThread sleepForTimeInterval:0.03];
    [trace finish];
    [trace finish];
    [trace recordSpan:@"late" kind:@"service" startedAt:[NSDate date] durationMs:1 data:nil];
    [trace finish];
    [ForgeOpsTracker flushSpans];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    XCTAssertNil([self span:@"late" inTrace:[self deliveredTrace]]);
}

- (void)testATraceHoldsAtMost500SpansIncludingTheRoot {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"http://key@127.0.0.1:1/api/v1/events";
    config.enabledEnvironments = [NSSet setWithObject:@"production"];
    config.traceCaptureThreshold = 0;
    __block NSDictionary *delivered = nil;
    FOTTrace *trace = [[FOTTrace alloc] initWithName:@"root" configuration:config deliver:^(NSDictionary *payload) {
        delivered = payload;
    }];
    for (int i = 0; i < 700; i++) {
        [trace recordSpan:@"q" kind:@"database" startedAt:[NSDate date] durationMs:1 data:nil];
    }
    [trace finish];

    XCTAssertEqual([delivered[@"spans"] count], (NSUInteger)500);
}

- (void)testSpansURLSwapsTheTrailingEventsSegment {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";
    XCTAssertEqualObjects([config spansURL].absoluteString, @"https://tracker.example.com/api/v1/spans");
}

@end
