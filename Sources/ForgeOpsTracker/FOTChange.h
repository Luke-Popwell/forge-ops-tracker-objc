#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/** The kinds +[ForgeOpsTracker recordChange:title:] accepts; anything else is sent as FOTChangeKindOther. */
extern NSString *const FOTChangeKindFeatureFlag;
extern NSString *const FOTChangeKindConfig;
extern NSString *const FOTChangeKindMigration;
extern NSString *const FOTChangeKindDependency;
extern NSString *const FOTChangeKindInfrastructure;
extern NSString *const FOTChangeKindOther;

/** The server's own limit on a change's title; a longer one is truncated instead of rejected. */
extern const NSUInteger FOTChangeMaxTitleLength;

/**
 * Builds the POST /api/v1/changes body for +[ForgeOpsTracker recordChange:...]. Separate from the
 * facade so the payload shape can be tested without a network round trip.
 */
@interface FOTChange : NSObject

/** kind itself when it is one of the six FOTChangeKind values, FOTChangeKindOther otherwise. */
+ (NSString *)normalizedKind:(nullable NSString *)kind;

/**
 * nil for a change with no title, the one field the server can't do without. details that
 * NSJSONSerialization can't encode (a NaN, an NSDate, any non-JSON type) are left out rather than
 * sent, since encoding one raises an exception; a url that isn't http(s) is left out too.
 * environment nil means configuration.environment; occurredAt nil means now.
 */
+ (nullable NSDictionary<NSString *, id> *)payloadWithKind:(nullable NSString *)kind
                                                     title:(nullable NSString *)title
                                                   details:(nullable NSDictionary<NSString *, id> *)details
                                               environment:(nullable NSString *)environment
                                                   service:(nullable NSString *)service
                                                     actor:(nullable NSString *)actor
                                                       url:(nullable NSString *)url
                                                identifier:(nullable NSString *)identifier
                                                occurredAt:(nullable NSDate *)occurredAt
                                             configuration:(FOTConfiguration *)configuration;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
