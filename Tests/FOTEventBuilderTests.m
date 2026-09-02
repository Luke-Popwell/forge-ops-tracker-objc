#import <XCTest/XCTest.h>
#import "FOTConfiguration.h"
#import "FOTEventBuilder.h"

@interface FOTEventBuilderTests : XCTestCase
@end

@implementation FOTEventBuilderTests

- (FOTConfiguration *)newConfiguration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.environment = @"production";
    config.releaseVersion = @"abc123";
    config.serverName = @"web-1";
    return config;
}

- (NSException *)raiseAndCatch {
    @try {
        @throw [NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil];
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

- (void)testBuildsPayloadWithExceptionClassMessageAndConfiguredMetadata {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self newConfiguration]];
    NSException *exception = [self raiseAndCatch];

    NSDictionary *payload = [builder buildEventForException:exception context:@{ @"url": @"https://example.com" }];

    XCTAssertEqualObjects(payload[@"exception_class"], @"FOTTestException");
    XCTAssertEqualObjects(payload[@"message"], @"boom");
    XCTAssertEqualObjects(payload[@"environment"], @"production");
    XCTAssertEqualObjects(payload[@"release"], @"abc123");
    XCTAssertEqualObjects(payload[@"server_name"], @"web-1");
    XCTAssertEqualObjects(payload[@"context"], @{ @"url": @"https://example.com" });
    XCTAssertTrue([payload[@"occurred_at"] isKindOfClass:[NSString class]]);
}

- (void)testParsesRealStackFramesWithImageAndSymbol {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self newConfiguration]];
    NSException *exception = [self raiseAndCatch];

    NSArray *frames = [builder buildEventForException:exception context:nil][@"backtrace"];

    XCTAssertGreaterThanOrEqual(frames.count, (NSUInteger)1);
    NSDictionary *frame = frames.firstObject;
    XCTAssertTrue([frame[@"file"] isKindOfClass:[NSString class]]); // the binary image name -- see FOTEventBuilder.h
    XCTAssertEqualObjects(frame[@"line"], [NSNull null]); // no line-level info at runtime, documented in FOTEventBuilder.h
    XCTAssertTrue([frame[@"method"] isKindOfClass:[NSString class]]);
}

- (void)testMarksAFrameFromThisTestBinaryAsInApp {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self newConfiguration]];
    NSException *exception = [self raiseAndCatch];

    NSArray *frames = [builder buildEventForException:exception context:nil][@"backtrace"];

    BOOL anyInApp = NO;
    for (NSDictionary *frame in frames) {
        if ([frame[@"in_app"] boolValue]) {
            anyInApp = YES;
            break;
        }
    }
    XCTAssertTrue(anyInApp, @"the frame that raised the exception should be in this test bundle's own binary");
}

- (void)testScrubsLikelyPiiOutOfMessageAndContextByDefault {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self newConfiguration]];
    NSException *exception = [NSException exceptionWithName:@"FOTTestException" reason:@"failed for user@example.com" userInfo:nil];

    NSDictionary *payload = [builder buildEventForException:exception
                                                       context:@{ @"user": @{ @"email": @"ada@example.com", @"password": @"hunter2" } }];

    XCTAssertEqualObjects(payload[@"message"], @"failed for [EMAIL FILTERED]");
    XCTAssertEqualObjects(payload[@"context"], (@{ @"user": @{ @"email": @"[EMAIL FILTERED]", @"password": @"[FILTERED]" } }));
}

- (void)testLeavesPayloadUntouchedWhenScrubPiiIsDisabled {
    FOTConfiguration *config = [self newConfiguration];
    config.scrubPII = NO;
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:config];
    NSException *exception = [NSException exceptionWithName:@"FOTTestException" reason:@"failed for user@example.com" userInfo:nil];

    NSDictionary *payload = [builder buildEventForException:exception context:@{ @"email": @"ada@example.com" }];

    XCTAssertEqualObjects(payload[@"message"], @"failed for user@example.com");
    XCTAssertEqualObjects(payload[@"context"], @{ @"email": @"ada@example.com" });
}

- (void)testNeverAttachesSourceContextRegardlessOfConfiguration {
    // captureSourceContext defaults to YES (see FOTConfigurationTests), but a frame here never
    // carries a real file+line pair to key a disk read off of (-callStackSymbols only ever gives an
    // image name + symbol), so no frame should ever come back with context_line/pre_context/
    // post_context, whether the flag is left at its default or explicitly toggled off.
    for (NSNumber *captureSourceContext in @[ @YES, @NO ]) {
        FOTConfiguration *config = [self newConfiguration];
        config.captureSourceContext = captureSourceContext.boolValue;
        FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:config];
        NSException *exception = [self raiseAndCatch];

        NSArray *frames = [builder buildEventForException:exception context:nil][@"backtrace"];

        for (NSDictionary *frame in frames) {
            XCTAssertNil(frame[@"context_line"]);
            XCTAssertNil(frame[@"pre_context"]);
            XCTAssertNil(frame[@"post_context"]);
        }
    }
}

@end
