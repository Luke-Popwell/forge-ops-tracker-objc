#import <XCTest/XCTest.h>
#import "FOTBreadcrumbBuffer.h"
#import "FOTConfiguration.h"
#import "FOTCrashStore.h"

@interface FOTBreadcrumbBufferTests : XCTestCase
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTBreadcrumbBufferTests

- (void)setUp {
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self.tempDirectory stringByAppendingString:@".breadcrumbs.json"] error:nil];
}

- (FOTConfiguration *)configuration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.crashReportsDirectory = self.tempDirectory;
    return config;
}

- (void)testRecordsEntriesInOrderWithTheWireShape {
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[self configuration]];

    [buffer addBreadcrumbWithMessage:@"first" category:@"custom" level:@"info" data:nil];
    [buffer addBreadcrumbWithMessage:@"second" category:@"payment" level:@"warning" data:@{ @"order_id": @42 }];

    NSArray *all = [buffer all];
    XCTAssertEqual(all.count, 2u);
    XCTAssertEqualObjects(all[0][@"message"], @"first");
    XCTAssertEqualObjects(all[0][@"data"], @{});
    XCTAssertEqualObjects(all[1][@"category"], @"payment");
    XCTAssertEqualObjects(all[1][@"level"], @"warning");
    XCTAssertEqualObjects(all[1][@"data"], @{ @"order_id": @42 });
    XCTAssertNotNil(all[1][@"timestamp"]);
    XCTAssertTrue([all[1][@"timestamp"] hasSuffix:@"Z"]);
}

- (void)testDropsTheOldestEntriesPastMaxBreadcrumbs {
    FOTConfiguration *config = [self configuration];
    config.maxBreadcrumbs = 2;
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];

    for (NSString *message in @[ @"first", @"second", @"third" ]) {
        [buffer addBreadcrumbWithMessage:message category:@"custom" level:@"info" data:nil];
    }

    XCTAssertEqualObjects([[buffer all] valueForKey:@"message"], (@[ @"second", @"third" ]));
}

- (void)testRecordsNothingWhenTrackBreadcrumbsIsOff {
    FOTConfiguration *config = [self configuration];
    config.trackBreadcrumbs = NO;
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];

    [buffer addBreadcrumbWithMessage:@"nope" category:@"custom" level:@"info" data:nil];

    XCTAssertEqual([buffer all].count, 0u);
}

- (void)testClearEmptiesTheTrail {
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[self configuration]];
    [buffer addBreadcrumbWithMessage:@"first" category:@"custom" level:@"info" data:nil];

    [buffer clear];

    XCTAssertEqual([buffer all].count, 0u);
}

- (void)testIsSafeToAddFromManyThreadsAtOnce {
    FOTConfiguration *config = [self configuration];
    config.maxBreadcrumbs = 50;
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];

    dispatch_apply(200, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
        [buffer addBreadcrumbWithMessage:[NSString stringWithFormat:@"crumb %zu", i] category:@"custom" level:@"info" data:nil];
        [buffer all];
    });

    XCTAssertEqual([buffer all].count, 50u, @"exactly the cap, no lost or duplicated slots");
}

- (void)testNothingIsWrittenToDiskUntilPersistingStarts {
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[self configuration]];

    [buffer addBreadcrumbWithMessage:@"first" category:@"custom" level:@"info" data:nil];
    [buffer _waitForPendingWrites];

    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.tempDirectory stringByAppendingString:@".breadcrumbs.json"]]);
}

- (void)testAPersistedTrailSurvivesIntoTheNextRunAsThePreviousRunsTrail {
    FOTConfiguration *config = [self configuration];
    FOTBreadcrumbBuffer *crashedRun = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [crashedRun startPersisting];
    [crashedRun addBreadcrumbWithMessage:@"charging card" category:@"payment" level:@"info" data:@{ @"order_id": @42 }];
    [crashedRun _waitForPendingWrites];

    // A brand-new instance over the same configuration stands in for the next launch.
    FOTBreadcrumbBuffer *nextRun = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [nextRun startPersisting];

    NSArray *previous = [nextRun previousRunBreadcrumbsForCrashOccurringAt:[NSDate dateWithTimeIntervalSinceNow:1]];
    XCTAssertEqual(previous.count, 1u);
    XCTAssertEqualObjects(previous[0][@"message"], @"charging card");
    XCTAssertEqual([nextRun all].count, 0u, @"the new run's own trail starts empty");
}

- (void)testThePreviousRunsTrailIsNotAttachedToACrashThatHappenedBeforeItsLastWrite {
    FOTConfiguration *config = [self configuration];
    FOTBreadcrumbBuffer *earlierRun = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [earlierRun startPersisting];
    [earlierRun addBreadcrumbWithMessage:@"written after that crash" category:@"custom" level:@"info" data:nil];
    [earlierRun _waitForPendingWrites];

    FOTBreadcrumbBuffer *nextRun = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [nextRun startPersisting];

    // A crash a minute before that trail was last written: a later run replaced whatever trail
    // that crash left behind, so this one would be misleading.
    XCTAssertNil([nextRun previousRunBreadcrumbsForCrashOccurringAt:[NSDate dateWithTimeIntervalSinceNow:-60]]);
}

- (void)testThePersistedTrailIsPiiScrubbedOnDisk {
    FOTConfiguration *config = [self configuration];
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [buffer startPersisting];
    [buffer addBreadcrumbWithMessage:@"emailed alice@example.com" category:@"custom" level:@"info" data:@{ @"password": @"hunter2" }];
    [buffer _waitForPendingWrites];

    NSString *onDisk = [NSString stringWithContentsOfFile:[self.tempDirectory stringByAppendingString:@".breadcrumbs.json"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    XCTAssertFalse([onDisk containsString:@"alice@example.com"]);
    XCTAssertFalse([onDisk containsString:@"hunter2"]);
    XCTAssertTrue([[buffer all][0][@"message"] containsString:@"alice@example.com"], @"the in-memory copy is untouched");
}

- (void)testThePersistedFileIsNeverMistakenForAPendingCrashReport {
    FOTConfiguration *config = [self configuration];
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:config];
    [buffer startPersisting];
    [buffer addBreadcrumbWithMessage:@"first" category:@"custom" level:@"info" data:nil];
    [buffer _waitForPendingWrites];

    FOTCrashStore *store = [[FOTCrashStore alloc] initWithConfiguration:config];
    XCTAssertEqual([store pendingPayloadURLs].count, 0u);
}

@end
