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

- (void)backdate:(NSURL *)url by:(NSTimeInterval)interval {
    NSDate *date = [NSDate dateWithTimeIntervalSinceNow:-interval];
    NSDictionary *attributes = @{ NSFileCreationDate: date, NSFileModificationDate: date };
    XCTAssertTrue([[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:url.path error:nil]);
}

- (void)testPendingPayloadURLsKeepsOnlyTheNewestTwentyAndDeletesTheRest {
    FOTCrashStore *store = [self newStore];
    NSUInteger total = FOTCrashStoreMaxPendingPayloads + 3;
    for (NSUInteger i = 0; i < total; i++) {
        XCTAssertTrue([store writePayload:@{ @"n": @(i) }]);
    }
    // Spread the creation times out by hand: oldest first, an hour apart.
    NSMutableDictionary<NSNumber *, NSURL *> *byNumber = [NSMutableDictionary dictionary];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.tempDirectory error:nil]) {
        NSURL *url = [NSURL fileURLWithPath:[self.tempDirectory stringByAppendingPathComponent:name]];
        NSNumber *n = [store payloadAtURL:url][@"n"];
        byNumber[n] = url;
        [self backdate:url by:(NSTimeInterval)((total - n.unsignedIntegerValue) * 3600)];
    }

    NSArray<NSURL *> *pending = [store pendingPayloadURLs];

    XCTAssertEqual(pending.count, FOTCrashStoreMaxPendingPayloads);
    XCTAssertEqualObjects([store payloadAtURL:pending.firstObject][@"n"], @3);
    XCTAssertEqualObjects([store payloadAtURL:pending.lastObject][@"n"], @(total - 1));
    XCTAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.tempDirectory error:nil].count, FOTCrashStoreMaxPendingPayloads);
    for (NSUInteger i = 0; i < 3; i++) {
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:byNumber[@(i)].path]);
    }
}

- (void)testPendingPayloadURLsDeletesAnythingOlderThanSevenDays {
    FOTCrashStore *store = [self newStore];
    [store writePayload:@{ @"n": @"old" }];
    NSURL *old = [store pendingPayloadURLs].firstObject;
    [store writePayload:@{ @"n": @"almost" }];
    NSURL *almost = nil;
    for (NSURL *url in [store pendingPayloadURLs]) {
        if (![url isEqual:old]) {
            almost = url;
        }
    }
    [store writePayload:@{ @"n": @"new" }];
    [self backdate:old by:FOTCrashStoreMaxPendingPayloadAge + 3600];
    [self backdate:almost by:FOTCrashStoreMaxPendingPayloadAge - 3600];

    NSArray<NSURL *> *pending = [store pendingPayloadURLs];

    XCTAssertEqual(pending.count, (NSUInteger)2);
    XCTAssertEqualObjects([store payloadAtURL:pending[0]][@"n"], @"almost");
    XCTAssertEqualObjects([store payloadAtURL:pending[1]][@"n"], @"new");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:old.path]);
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
