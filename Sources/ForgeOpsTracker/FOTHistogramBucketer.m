#import "FOTHistogramBucketer.h"

@implementation FOTHistogramBucketer

+ (NSArray<NSNumber *> *)boundariesMs {
    return @[@50, @100, @250, @500, @1000, @2500, @5000, @10000];
}

+ (NSString *)bucketForDuration:(double)durationMs {
    for (NSNumber *boundary in [self boundariesMs]) {
        if (durationMs <= boundary.doubleValue) {
            return boundary.stringValue;
        }
    }
    return @"inf";
}

@end
