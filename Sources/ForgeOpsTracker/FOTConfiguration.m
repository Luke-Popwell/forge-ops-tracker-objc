#import "FOTConfiguration.h"

@implementation FOTConfiguration

- (instancetype)init {
    self = [super init];
    if (self) {
        _environment = @"production";
        _enabledEnvironments = [NSSet setWithObjects:@"production", @"staging", nil];
        _timeout = 5.0; // seconds: longer than the other SDKs' ~2s default: this fires on the
                         // *next* launch after a crash (see FOTCrashStore), not inline with a live
                         // request, so there's no user-facing latency to protect.
        _scrubPII = YES;
        _captureSourceContext = YES;
        _trackBreadcrumbs = YES;
        _maxBreadcrumbs = 30;
        _trackPerformance = YES;
        _performanceFlushInterval = 60.0;
        _trackTracing = YES;
        _metricFlushInterval = 60.0;
        _infrastructureMetricFlushInterval = 60.0;
        _traceCaptureThreshold = 1.0;

        NSArray<NSString *> *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *base = caches.firstObject ?: NSTemporaryDirectory();
        _crashReportsDirectory = [base stringByAppendingPathComponent:@"com.forgeops.tracker/pending-crash-reports"];
    }
    return self;
}

- (nullable NSURLComponents *)parsedDSN {
    if (self.dsn.length == 0) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:self.dsn];
    if (components == nil || components.host == nil) {
        return nil;
    }
    return components;
}

- (nullable NSString *)apiKey {
    NSURLComponents *components = [self parsedDSN];
    if (components == nil || components.user.length == 0) {
        return nil;
    }
    // NSURLComponents already percent-decodes .user for us, unlike .percentEncodedUser.
    return components.user;
}

- (nullable NSURL *)ingestionURL {
    NSURLComponents *components = [self parsedDSN];
    if (components == nil) {
        return nil;
    }
    NSURLComponents *stripped = [components copy];
    stripped.user = nil;
    stripped.password = nil;
    return stripped.URL;
}

- (nullable NSURL *)performanceSamplesURL {
    NSURL *url = [self ingestionURL];
    if (url == nil) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components.path hasSuffix:@"/events"]) {
        return url;
    }
    components.path = [[components.path substringToIndex:components.path.length - @"/events".length] stringByAppendingString:@"/performance_samples"];
    return components.URL;
}

- (nullable NSURL *)swapEventsSuffixWith:(NSString *)replacement {
    NSURL *url = [self ingestionURL];
    if (url == nil) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components.path hasSuffix:@"/events"]) {
        return url;
    }
    components.path = [[components.path substringToIndex:components.path.length - @"/events".length] stringByAppendingString:replacement];
    return components.URL;
}

- (nullable NSURL *)customMetricsURL {
    return [self swapEventsSuffixWith:@"/custom_metrics"];
}

- (nullable NSURL *)infrastructureMetricsURL {
    return [self swapEventsSuffixWith:@"/infrastructure_metrics"];
}

- (nullable NSURL *)spansURL {
    NSURL *url = [self ingestionURL];
    if (url == nil) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components.path hasSuffix:@"/events"]) {
        return url;
    }
    components.path = [[components.path substringToIndex:components.path.length - @"/events".length] stringByAppendingString:@"/spans"];
    return components.URL;
}

- (BOOL)isEnabled {
    if (self.dsn.length == 0) {
        return NO;
    }
    if ([self apiKey] == nil) {
        return NO;
    }
    return [self.enabledEnvironments containsObject:self.environment];
}

@end
