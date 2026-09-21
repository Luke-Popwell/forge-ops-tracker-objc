#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Holds a single ForgeOps DSN plus everything else the client needs to build and deliver events.
 * Mirrors gems/forge_ops_tracker/lib/forge_ops_tracker/configuration.rb: a single DSN string
 * carries both the ingestion URL and the project's api_key:
 * "https://<api_key>@host/api/v1/events". Parsed with NSURLComponents rather than a hand-rolled
 * regex: Foundation already has a real, well-tested URL parser that handles the DSN's userinfo
 * segment directly, so there's no reason to duplicate that logic the way the non-Foundation SDKs
 * in this repo have to.
 */
@interface FOTConfiguration : NSObject

@property (nonatomic, copy, nullable) NSString *dsn;
@property (nonatomic, copy) NSString *environment;
// Named releaseVersion, not "release": under ARC, a property literally named "release" is
// unusable via dot-syntax: `config.release` compiles as an explicit call to NSObject's own
// -release memory-management method instead of this property's getter, which ARC forbids
// outright. Confirmed directly (a real build error, not a hypothetical) before renaming.
@property (nonatomic, copy, nullable) NSString *releaseVersion;
@property (nonatomic, copy, nullable) NSString *serverName;
@property (nonatomic, strong) NSSet<NSString *> *enabledEnvironments;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) BOOL scrubPII;

/**
 * Whether FOTEventBuilder would read a few lines of source off disk around an in-app frame's
 * culprit line, the same way the Ruby/Python/Node/etc. clients in this repo do. Defaults to YES,
 * mirroring every other SDK, but this flag alone isn't the real protection against sending source
 * code somewhere it shouldn't go: ForgeOps' own per-project setting is the durable, server-enforced
 * off switch, since it applies regardless of what this flag happens to be set to on any given
 * install. Kept here purely for API-shape consistency across every SDK in this repo: see
 * FOTEventBuilder.h's own header comment for why this specific client's capture path is a
 * documented no-op regardless of this value: -callStackSymbols never produces a real file+line pair
 * to read in the first place.
 */
@property (nonatomic, assign) BOOL captureSourceContext;

/**
 * When an exception carries the SQL behind a failed database call (attached under FOTSqlStatementKey
 * in its userInfo, or passed to +[ForgeOpsTracker captureException:sql:context:], or SQLite's own
 * `while compiling:` text), send the names of the stored procedure, table and view that SQL touched,
 * so an issue says where to start looking. Names are identifiers, never values, which is why this
 * defaults to YES. captureSqlStatement is the separate, opt-in step (default NO) of also sending the
 * statement itself, with every string and number replaced by "?"; off by default because even a
 * masked statement describes your schema, and ForgeOps' own per-project setting is what durably
 * governs whether the server stores it. See FOTSqlStatement.h.
 */
@property (nonatomic, assign) BOOL captureSqlObjects;
@property (nonatomic, assign) BOOL captureSqlStatement;

/** Whether +addBreadcrumb: methods record anything at all. Defaults to YES, matching every other client in this repo. */
@property (nonatomic, assign) BOOL trackBreadcrumbs;

/** How many of the most recent breadcrumbs are kept, oldest dropped first. 30, matching every other client's default. */
@property (nonatomic, assign) NSUInteger maxBreadcrumbs;

/**
 * Whether +recordPerformance:durationMs: and +measureTransaction:block: time anything at all.
 * Defaults to YES, the same "on unless you turn it off" posture error reporting itself already has.
 * This client has no web framework integration, so nothing is timed automatically: this only gates
 * the manual API.
 */
@property (nonatomic, assign) BOOL trackPerformance;

/**
 * How often the in-process tallies are flushed as one small aggregate report, in seconds, rather
 * than one network call per timed call. 60, matching gems/forge_ops_tracker's own default.
 */
@property (nonatomic, assign) NSTimeInterval performanceFlushInterval;

/**
 * Whether +startTrace: and +traceNamed:block: start a trace at all, and so whether spans are
 * recorded and slow traces sent. Defaults to YES. This client has no web framework integration, so
 * nothing starts a trace automatically: this only gates the manual API.
 */
@property (nonatomic, assign) BOOL trackTracing;

/** A trace is only sent when its root took at least this many seconds. 1, matching every other client's default. */
@property (nonatomic, assign) NSTimeInterval traceCaptureThreshold;

/**
 * How often the buffered +captureMetric:/+captureInfrastructureMetric: entries are flushed as one
 * batch, in seconds (60 by default). There is no trackMetrics flag the way trackPerformance has one:
 * these are explicit calls the host app's own code makes, not automatic instrumentation, so there is
 * nothing to turn off that simply not calling them doesn't already do.
 */
@property (nonatomic, assign) NSTimeInterval metricFlushInterval;
@property (nonatomic, assign) NSTimeInterval infrastructureMetricFlushInterval;

/** Where pending (not-yet-uploaded) crash reports are written: see FOTCrashStore. */
@property (nonatomic, copy) NSString *crashReportsDirectory;

- (nullable NSString *)apiKey;

/** The ingestion URL with credentials stripped out (they travel as the Authorization header instead). */
- (nullable NSURL *)ingestionURL;

/**
 * Same derivation as -ingestionURL, with the trailing "/events" swapped for "/performance_samples":
 * one DSN, two endpoints, matching the Ruby gem's own Configuration#performance_samples_uri.
 */
- (nullable NSURL *)performanceSamplesURL;

/** Same derivation again, swapping the trailing "/events" for "/custom_metrics" and "/infrastructure_metrics". */
- (nullable NSURL *)customMetricsURL;
- (nullable NSURL *)infrastructureMetricsURL;

/** Same derivation again, swapping the trailing "/events" for "/spans". */
- (nullable NSURL *)spansURL;

- (BOOL)isEnabled;

@end

NS_ASSUME_NONNULL_END
