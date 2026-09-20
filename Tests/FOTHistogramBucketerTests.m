#import <XCTest/XCTest.h>
#import "FOTHistogramBucketer.h"

@interface FOTHistogramBucketerTests : XCTestCase
@end

@implementation FOTHistogramBucketerTests

- (void)testReturnsTheSmallestBoundaryADurationFitsUnderAsAString {
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:10], @"50");
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:50], @"50");
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:50.5], @"100");
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:4999], @"5000");
}

- (void)testReturnsInfForAnythingLargerThanTheLargestBoundary {
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:10001], @"inf");
    XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:1000000], @"inf");
}

- (void)testPutsADurationExactlyOnABoundaryIntoThatBoundarysOwnBucket {
    for (NSNumber *boundary in [FOTHistogramBucketer boundariesMs]) {
        XCTAssertEqualObjects([FOTHistogramBucketer bucketForDuration:boundary.doubleValue], boundary.stringValue);
    }
}

- (void)testBoundariesMatchTheServersHistogramPercentile {
    // app/services/histogram_percentile.rb and every other SDK must agree on this exact list.
    NSArray *expected = @[@50, @100, @250, @500, @1000, @2500, @5000, @10000];
    XCTAssertEqualObjects([FOTHistogramBucketer boundariesMs], expected);
}

@end
