#import <XCTest/XCTest.h>
#import "FOTConfiguration.h"

@interface FOTConfigurationTests : XCTestCase
@end

@implementation FOTConfigurationTests

- (FOTConfiguration *)newConfiguration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.dsn = nil;
    config.enabledEnvironments = [NSSet setWithObjects:@"production", @"staging", nil];
    config.environment = @"production";
    return config;
}

- (void)testExtractsApiKeyAndCredentialFreeIngestionURLFromDSN {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"https://secret-key@tracker.example.com/api/v1/events";

    XCTAssertEqualObjects([config apiKey], @"secret-key");
    XCTAssertEqualObjects([config ingestionURL].absoluteString, @"https://tracker.example.com/api/v1/events");
}

- (void)testPercentDecodesTheApiKey {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"https://secret%2Bkey@tracker.example.com/api/v1/events";

    XCTAssertEqualObjects([config apiKey], @"secret+key");
}

- (void)testReturnsNilForBothWhenThereIsNoDSN {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = nil;

    XCTAssertNil([config apiKey]);
    XCTAssertNil([config ingestionURL]);
}

- (void)testReturnsNilForBothWhenTheDSNIsMalformed {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"";

    XCTAssertNil([config apiKey]);
    XCTAssertNil([config ingestionURL]);
}

- (void)testIsEnabledIsTrueWithValidDSNInEnabledEnvironment {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";
    config.environment = @"production";

    XCTAssertTrue([config isEnabled]);
}

- (void)testIsEnabledIsFalseWithNoDSNConfigured {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = nil;

    XCTAssertFalse([config isEnabled]);
}

- (void)testIsEnabledIsFalseWhenDSNHasNoApiKey {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"https://tracker.example.com/api/v1/events";

    XCTAssertFalse([config isEnabled]);
}

- (void)testIsEnabledIsFalseOutsideConfiguredEnabledEnvironments {
    FOTConfiguration *config = [self newConfiguration];
    config.dsn = @"https://key@tracker.example.com/api/v1/events";
    config.environment = @"development";

    XCTAssertFalse([config isEnabled]);
}

- (void)testCaptureSourceContextDefaultsToYes {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];

    XCTAssertTrue(config.captureSourceContext);
}

@end
