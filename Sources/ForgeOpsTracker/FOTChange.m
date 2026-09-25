#import "FOTChange.h"

NSString *const FOTChangeKindFeatureFlag = @"feature_flag";
NSString *const FOTChangeKindConfig = @"config";
NSString *const FOTChangeKindMigration = @"migration";
NSString *const FOTChangeKindDependency = @"dependency";
NSString *const FOTChangeKindInfrastructure = @"infrastructure";
NSString *const FOTChangeKindOther = @"other";

const NSUInteger FOTChangeMaxTitleLength = 200;

@implementation FOTChange

+ (NSString *)normalizedKind:(NSString *)kind {
    static NSSet<NSString *> *kinds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kinds = [NSSet setWithObjects:FOTChangeKindFeatureFlag, FOTChangeKindConfig, FOTChangeKindMigration,
                                      FOTChangeKindDependency, FOTChangeKindInfrastructure, FOTChangeKindOther, nil];
    });
    return (kind != nil && [kinds containsObject:kind]) ? kind : FOTChangeKindOther;
}

+ (NSDictionary<NSString *, id> *)payloadWithKind:(NSString *)kind
                                            title:(NSString *)title
                                          details:(NSDictionary<NSString *, id> *)details
                                      environment:(NSString *)environment
                                          service:(NSString *)service
                                            actor:(NSString *)actor
                                              url:(NSString *)url
                                       identifier:(NSString *)identifier
                                       occurredAt:(NSDate *)occurredAt
                                    configuration:(FOTConfiguration *)configuration {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }
    if (trimmed.length > FOTChangeMaxTitleLength) {
        // Cut before the character straddling the limit, so an emoji there isn't split in half.
        trimmed = [trimmed substringToIndex:[trimmed rangeOfComposedCharacterSequenceAtIndex:FOTChangeMaxTitleLength].location];
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;

    NSMutableDictionary<NSString *, id> *payload = [@{
        @"kind": [self normalizedKind:kind],
        @"title": trimmed,
        @"environment": environment ?: configuration.environment,
        @"occurred_at": [formatter stringFromDate:occurredAt ?: [NSDate date]],
    } mutableCopy];

    if (details != nil && [NSJSONSerialization isValidJSONObject:details]) {
        payload[@"details"] = details;
    }
    if (service.length > 0) {
        payload[@"service"] = service;
    }
    if (actor.length > 0) {
        payload[@"actor"] = actor;
    }
    NSString *scheme = [NSURL URLWithString:url ?: @""].scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        payload[@"url"] = url;
    }
    if (identifier.length > 0) {
        payload[@"id"] = identifier;
    }
    return payload;
}

@end
