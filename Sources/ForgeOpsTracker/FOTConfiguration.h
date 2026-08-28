#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Holds a single ForgeOps DSN plus everything else the client needs to build and deliver events.
 * Mirrors gems/forge_ops_tracker/lib/forge_ops_tracker/configuration.rb -- a single Sentry-style
 * DSN string carries both the ingestion URL and the project's api_key:
 * "https://<api_key>@host/api/v1/events". Parsed with NSURLComponents rather than a hand-rolled
 * regex -- Foundation already has a real, well-tested URL parser that handles the DSN's userinfo
 * segment directly, so there's no reason to duplicate that logic the way the non-Foundation SDKs
 * in this repo have to.
 */
@interface FOTConfiguration : NSObject

@property (nonatomic, copy, nullable) NSString *dsn;
@property (nonatomic, copy) NSString *environment;
// Named releaseVersion, not "release" -- under ARC, a property literally named "release" is
// unusable via dot-syntax: `config.release` compiles as an explicit call to NSObject's own
// -release memory-management method instead of this property's getter, which ARC forbids
// outright. Confirmed directly (a real build error, not a hypothetical) before renaming.
@property (nonatomic, copy, nullable) NSString *releaseVersion;
@property (nonatomic, copy, nullable) NSString *serverName;
@property (nonatomic, strong) NSSet<NSString *> *enabledEnvironments;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) BOOL scrubPII;

/** Where pending (not-yet-uploaded) crash reports are written -- see FOTCrashStore. */
@property (nonatomic, copy) NSString *crashReportsDirectory;

- (nullable NSString *)apiKey;

/** The ingestion URL with credentials stripped out (they travel as the Authorization header instead). */
- (nullable NSURL *)ingestionURL;

- (BOOL)isEnabled;

@end

NS_ASSUME_NONNULL_END
