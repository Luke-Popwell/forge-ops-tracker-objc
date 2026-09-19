#import <XCTest/XCTest.h>
#import "FOTTestHTTPServer.h"
#import "FOTBreadcrumbBuffer.h"
#import "ForgeOpsTracker.h"

@interface ForgeOpsTrackerTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation ForgeOpsTrackerTests

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
    [[NSFileManager defaultManager] removeItemAtPath:[self.tempDirectory stringByAppendingString:@".breadcrumbs.json"] error:nil];
    [ForgeOpsTracker _resetForTesting];
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

- (void)testConfigureWithBlockConfiguresAndReturnsTheConfiguration {
    FOTConfiguration *config = [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *c) {
        c.dsn = @"https://key@tracker.example.com/api/v1/events";
        c.releaseVersion = @"abc123";
    }];

    XCTAssertEqualObjects(config.dsn, @"https://key@tracker.example.com/api/v1/events");
    XCTAssertEqualObjects(config.releaseVersion, @"abc123");
}

- (void)testCaptureExceptionDeliversThroughTheFullStack {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    NSException *exception = [NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil];
    [ForgeOpsTracker captureException:exception context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    XCTAssertEqualObjects(self.server.requests.lastObject[@"headers"][@"Authorization"], @"Bearer key");
}

- (void)testSetUserAttachesTheUserToALaterCaptureExceptionCall {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker setUser:@{ @"id": @42, @"email": @"alice@example.com" }];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    XCTAssertTrue([self.server.requests.lastObject[@"body"] containsString:@"alice@example.com"]);
}

- (void)testAnExplicitUserArgumentOverridesWhateverSetUserLastSet {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker setUser:@{ @"id": @42 }];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil]
                               context:nil
                                  user:@{ @"id": @99 }];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    XCTAssertTrue([self.server.requests.lastObject[@"body"] containsString:@"\"id\":99"]);
}

- (void)testResetForTestingClearsTheCurrentUser {
    [ForgeOpsTracker setUser:@{ @"id": @42 }];
    [ForgeOpsTracker _resetForTesting];

    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    XCTAssertFalse([self.server.requests.lastObject[@"body"] containsString:@"\"user\""]);
}

- (void)testAddBreadcrumbAttachesTheTrailToALaterCaptureExceptionCall {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker addBreadcrumb:@"charging card" category:@"payment" level:@"info" data:@{ @"order_id": @42 }];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    NSString *body = self.server.requests.lastObject[@"body"];
    XCTAssertTrue([body containsString:@"charging card"]);
    XCTAssertTrue([body containsString:@"\"category\":\"payment\""]);
}

- (void)testAddBreadcrumbDefaultsToTheCustomCategoryAndInfoLevel {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker addBreadcrumb:@"something happened"];

    NSDictionary *crumb = [ForgeOpsTracker currentBreadcrumbs][0];
    XCTAssertEqualObjects(crumb[@"category"], @"custom");
    XCTAssertEqualObjects(crumb[@"level"], @"info");
}

- (void)testClearBreadcrumbsEmptiesTheTrail {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker addBreadcrumb:@"first"];
    [ForgeOpsTracker clearBreadcrumbs];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 1; } timeout:2.0]);
    XCTAssertFalse([self.server.requests.lastObject[@"body"] containsString:@"\"breadcrumbs\""]);
}

- (void)testResetForTestingClearsTheBreadcrumbTrail {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    [ForgeOpsTracker addBreadcrumb:@"leftover"];
    [ForgeOpsTracker _resetForTesting];

    XCTAssertEqual([ForgeOpsTracker currentBreadcrumbs].count, 0u);
}

- (void)testARawSignalCrashReportCarriesThePreviousRunsPersistedTrail {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
    }];

    // The crashed run: persisting, breadcrumbs added, then it dies (nothing else to simulate: the
    // trail is already on disk). Raw signal report as FOTSignalHandler leaves it.
    FOTBreadcrumbBuffer *crashedRun = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[ForgeOpsTracker configureWithBlock:^(FOTConfiguration *c) {}]];
    [crashedRun startPersisting];
    [crashedRun addBreadcrumbWithMessage:@"charging card" category:@"payment" level:@"info" data:nil];
    [crashedRun _waitForPendingWrites];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"Segmentation fault: 11\n0   libsystem_c.dylib  0x0000000000001 abort + 1\n"
        writeToFile:[self.tempDirectory stringByAppendingPathComponent:@"signal-11-1.txt"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];

    // The next launch.
    [ForgeOpsTracker _startBreadcrumbPersistence];
    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"Unrelated" reason:@"triggers an upload" userInfo:nil] context:nil];

    XCTAssertTrue([self waitUntil:^BOOL { return self.server.requests.count >= 2; } timeout:3.0]);
    NSString *signalBody = nil;
    for (NSDictionary *request in self.server.requests) {
        if ([request[@"body"] containsString:@"Uncaught fatal signal"]) {
            signalBody = request[@"body"];
        }
    }
    XCTAssertNotNil(signalBody);
    XCTAssertTrue([signalBody containsString:@"charging card"]);
}

- (void)testRecordPerformanceAndFlushPerformanceDeliverThroughTheFullStack {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
        config.performanceFlushInterval = 3600; // flushed by hand below
    }];

    [ForgeOpsTracker recordPerformance:@"GET /users/:id" durationMs:10];
    [ForgeOpsTracker recordPerformance:@"GET /users/:id" durationMs:30];
    [ForgeOpsTracker flushPerformance];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)1);
    NSString *body = self.server.requests.lastObject[@"body"];
    XCTAssertTrue([body containsString:@"\"transaction_name\":\"GET \\/users\\/:id\""] || [body containsString:@"GET /users/:id"]);
    XCTAssertTrue([body containsString:@"\"request_count\":2"]);
}

- (void)testMeasureTransactionRunsTheBlockAndRecordsHowLongItTook {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
        config.performanceFlushInterval = 3600; // flushed by hand below
    }];

    __block BOOL ran = NO;
    [ForgeOpsTracker measureTransaction:@"timed" block:^{
        [NSThread sleepForTimeInterval:0.03];
        ran = YES;
    }];
    [ForgeOpsTracker flushPerformance];

    XCTAssertTrue(ran);
    NSData *data = [self.server.requests.lastObject[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *sample = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"samples"][0];
    XCTAssertEqualObjects(sample[@"transaction_name"], @"timed");
    XCTAssertGreaterThanOrEqual([sample[@"duration_sum_ms"] doubleValue], 25.0);
}

- (void)testMeasureTransactionRecordsEvenWhenTheBlockRaisesAndLetsItPropagate {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
        config.performanceFlushInterval = 3600; // flushed by hand below
    }];

    XCTAssertThrowsSpecificNamed(
        [ForgeOpsTracker measureTransaction:@"timed raises" block:^{
            @throw [NSException exceptionWithName:@"FOTTestException" reason:@"inside" userInfo:nil];
        }],
        NSException, @"FOTTestException");
    [ForgeOpsTracker flushPerformance];

    XCTAssertTrue([self.server.requests.lastObject[@"body"] containsString:@"timed raises"]);
}

- (void)testTrackPerformanceOffRecordsAndDeliversNothing {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
        config.trackPerformance = NO;
    }];

    [ForgeOpsTracker recordPerformance:@"never recorded" durationMs:10];
    [ForgeOpsTracker flushPerformance];

    XCTAssertEqual(self.server.requests.count, (NSUInteger)0);
}

@end
