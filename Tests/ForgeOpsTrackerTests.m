#import <XCTest/XCTest.h>
#import "FOTTestHTTPServer.h"
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

@end
