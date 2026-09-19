#import <XCTest/XCTest.h>
#import "FOTConfiguration.h"
#import "FOTCrashStore.h"

@interface FOTCrashStoreTests : XCTestCase
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTCrashStoreTests

- (void)setUp {
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
}

- (FOTCrashStore *)newStore {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.crashReportsDirectory = self.tempDirectory;
    return [[FOTCrashStore alloc] initWithConfiguration:config];
}

- (void)testWritesAndReadsBackAPayload {
    FOTCrashStore *store = [self newStore];
    // Built as a local first, not passed as @{ ...multiple keys... } directly to XCTAssertTrue:
    // confirmed directly (not assumed): the C preprocessor only tracks parenthesis nesting when
    // splitting a macro call's arguments, not brace nesting, so a multi-key dictionary literal's
    // own internal commas get misread as separating macro arguments when it isn't itself wrapped
    // in an extra layer of parens or, as here, pulled out entirely.
    NSDictionary *toWrite = @{ @"exception_class": @"RuntimeError", @"message": @"boom" };

    XCTAssertTrue([store writePayload:toWrite]);

    NSArray<NSURL *> *pending = [store pendingPayloadURLs];
    XCTAssertEqual(pending.count, (NSUInteger)1);
    NSDictionary *payload = [store payloadAtURL:pending.firstObject];
    XCTAssertEqualObjects(payload[@"exception_class"], @"RuntimeError");
    XCTAssertEqualObjects(payload[@"message"], @"boom");
}

- (void)testAccumulatesMultiplePayloadsAsSeparateFiles {
    FOTCrashStore *store = [self newStore];

    [store writePayload:@{ @"exception_class": @"First" }];
    [store writePayload:@{ @"exception_class": @"Second" }];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)2);
}

- (void)testDeletePayloadRemovesItFromPending {
    FOTCrashStore *store = [self newStore];
    [store writePayload:@{ @"exception_class": @"RuntimeError" }];
    NSURL *url = [store pendingPayloadURLs].firstObject;

    [store deletePayloadAtURL:url];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)0);
}

- (void)testPendingPayloadURLsIsEmptyWhenNothingHasBeenWritten {
    FOTCrashStore *store = [self newStore];

    XCTAssertEqual([store pendingPayloadURLs].count, (NSUInteger)0);
}

- (void)testPayloadAtURLReturnsNilForAMissingFile {
    FOTCrashStore *store = [self newStore];

    XCTAssertNil([store payloadAtURL:[NSURL fileURLWithPath:@"/definitely/not/a/real/file.json"]]);
}

@end
