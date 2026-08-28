#import <XCTest/XCTest.h>
#import "FOTConfiguration.h"
#import "FOTCrashStore.h"
#import "FOTReporter.h"
#import "FOTTestHTTPServer.h"

@interface FOTReporterTests : XCTestCase
@property (nonatomic, copy) NSString *tempDirectory;
@property (nonatomic, strong) FOTTestHTTPServer *server;
@end

@implementation FOTReporterTests

- (void)setUp {
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
}

- (FOTConfiguration *)enabledConfiguration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
    config.enabledEnvironments = [NSSet setWithObject:@"production"];
    config.environment = @"production";
    config.crashReportsDirectory = self.tempDirectory;
    return config;
}

- (void)testReportExceptionWritesAPendingCrashReport {
    FOTConfiguration *config = [self enabledConfiguration];
    FOTReporter *reporter = [[FOTReporter alloc] initWithConfiguration:config];
    FOTCrashStore *store = [[FOTCrashStore alloc] initWithConfiguration:config];

    NSException *exception = [NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil];
    [reporter reportException:exception context:nil];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)1);
}

- (void)testReportExceptionDoesNothingWhenDisabled {
    FOTConfiguration *config = [self enabledConfiguration];
    config.environment = @"development"; // not in enabledEnvironments
    FOTReporter *reporter = [[FOTReporter alloc] initWithConfiguration:config];
    FOTCrashStore *store = [[FOTCrashStore alloc] initWithConfiguration:config];

    [reporter reportException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)0);
}

- (void)testUploadPendingReportsDeliversAndDeletesOnSuccess {
    FOTConfiguration *config = [self enabledConfiguration];
    FOTReporter *reporter = [[FOTReporter alloc] initWithConfiguration:config];
    FOTCrashStore *store = [[FOTCrashStore alloc] initWithConfiguration:config];

    [reporter reportException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];
    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)1);

    [reporter uploadPendingReports];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)0, @"delivered successfully, so the file should be gone");
    NSArray *requests = self.server.requests;
    XCTAssertEqual(requests.count, (NSUInteger)1);
    XCTAssertEqualObjects(requests[0][@"headers"][@"Authorization"], @"Bearer key");
}

- (void)testUploadPendingReportsLeavesAFileInPlaceOnDeliveryFailure {
    FOTConfiguration *config = [self enabledConfiguration];
    config.dsn = @"http://key@127.0.0.1:1/api/v1/events"; // nothing listening there
    config.timeout = 1.0;
    FOTReporter *reporter = [[FOTReporter alloc] initWithConfiguration:config];
    FOTCrashStore *store = [[FOTCrashStore alloc] initWithConfiguration:config];

    [reporter reportException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil];
    [reporter uploadPendingReports];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)1, @"a failed delivery must not delete the pending file");
}

@end
