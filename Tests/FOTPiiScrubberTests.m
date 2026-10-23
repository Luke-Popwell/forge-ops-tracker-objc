#import <XCTest/XCTest.h>
#import "FOTPiiScrubber.h"

@interface FOTPiiScrubberTests : XCTestCase
@end

@implementation FOTPiiScrubberTests

// A byte-identical copy of sdks/pii_scrubbing_vectors.json, found next to this file: `make test`
// compiles it by its path relative to sdks/objc and runs from there, so __FILE__ resolves either way.
- (NSDictionary *)vectors {
    NSString *path = [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Fixtures/pii_scrubbing_vectors.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(data, @"missing fixture at %@", path);
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
}

- (void)testScrubsEverySharedCardNumberAndIbanVectorExactlyAsTheServerDoes {
    NSArray *entries = [self vectors][@"strings"];
    XCTAssertTrue(entries.count > 0);
    for (NSDictionary *entry in entries) {
        XCTAssertEqualObjects([FOTPiiScrubber scrubString:entry[@"input"]], entry[@"scrubbed"], @"scrubbing %@", entry[@"input"]);
    }
}

- (void)testRedactsEverySharedBankDetailKeyVectorExactlyAsTheServerDoes {
    NSArray *entries = [self vectors][@"keys"];
    XCTAssertTrue(entries.count > 0);
    for (NSDictionary *entry in entries) {
        NSString *key = entry[@"key"];
        NSString *expected = [entry[@"redacted"] boolValue] ? FOTRedacted : @"x";
        XCTAssertEqualObjects([FOTPiiScrubber scrub:@{ key: @"x" } key:nil], (@{ key: expected }), @"key %@", key);
    }
}

- (void)testRedactsAnEmailAddressEmbeddedInFreeText {
    XCTAssertEqualObjects(
        [FOTPiiScrubber scrubString:@"undefined method 'name' for user@example.com"],
        @"undefined method 'name' for [EMAIL FILTERED]");
}

- (void)testRedactsFormattedCreditCardButLeavesOrdinaryLongNumericIdAlone {
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"card 4111-1111-1111-1111 declined"],
                           @"card [CREDIT CARD FILTERED] declined");
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"Couldn't find Invoice with id=8821445199"],
                           @"Couldn't find Invoice with id=8821445199");
}

- (void)testRedactsFormattedSSN {
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"ssn on file: 123-45-6789"], @"ssn on file: [SSN FILTERED]");
}

- (void)testRedactsKnownApiKeyAndTokenFormats {
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"using sk_live_4eC39HqLyjWDarjtT1zdp7dc"],
                           @"using [STRIPE KEY FILTERED]");
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"Authorization: Bearer abc123.def456"],
                           @"Authorization: [BEARER TOKEN FILTERED]");
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"key AKIAIOSFODNN7EXAMPLE in use"],
                           @"key [AWS KEY FILTERED] in use");
    XCTAssertEqualObjects([FOTPiiScrubber scrubString:@"token ghp_1234567890abcdefghijklmnopqrstuv"],
                           @"token [GITHUB TOKEN FILTERED]");
}

- (void)testRedactsWholeValueUnderSensitiveKeyRegardlessOfTypeOrCasing {
    NSDictionary *scrubbed = [FOTPiiScrubber scrub:@{ @"password": @"hunter2", @"API-Key": @"sk_live_abc", @"count": @3 } key:nil];

    XCTAssertEqualObjects(scrubbed, (@{ @"password": @"[FILTERED]", @"API-Key": @"[FILTERED]", @"count": @3 }));
}

- (void)testRecursesIntoNestedDictionariesAndArrays {
    NSDictionary *scrubbed = [FOTPiiScrubber scrub:@{ @"user": @{ @"email": @"ada@example.com" }, @"notes": @[@"no PII here"] } key:nil];

    XCTAssertEqualObjects(scrubbed, (@{ @"user": @{ @"email": @"[EMAIL FILTERED]" }, @"notes": @[@"no PII here"] }));
}

- (void)testDoesNotRedactKeyBasedMatchForUnrelatedShortSubstringLikePin {
    NSDictionary *scrubbed = [FOTPiiScrubber scrub:@{ @"opinion": @"strong", @"pinned_at": @"2026-01-01" } key:nil];

    XCTAssertEqualObjects(scrubbed, (@{ @"opinion": @"strong", @"pinned_at": @"2026-01-01" }));
}

@end
