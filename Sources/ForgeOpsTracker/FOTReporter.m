#import "FOTReporter.h"
#import "FOTClient.h"
#import "FOTCrashStore.h"
#import "FOTEventBuilder.h"
#import "FOTSignalHandler.h"
#import "ForgeOpsTracker.h"

@interface FOTReporter ()
- (nullable NSDictionary<NSString *, id> *)completeSignalPayload:(nullable NSDictionary<NSString *, id> *)parsed reportURL:(NSURL *)url;
@end

@implementation FOTReporter {
    FOTConfiguration *_configuration;
    FOTEventBuilder *_eventBuilder;
    FOTCrashStore *_crashStore;
    FOTClient *_client;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _eventBuilder = [[FOTEventBuilder alloc] initWithConfiguration:configuration];
        _crashStore = [[FOTCrashStore alloc] initWithConfiguration:configuration];
        _client = [[FOTClient alloc] initWithConfiguration:configuration];
    }
    return self;
}

- (void)reportException:(NSException *)exception context:(NSDictionary<NSString *, id> *)context {
    [self reportException:exception context:context user:nil];
}

- (void)reportException:(NSException *)exception
                 context:(NSDictionary<NSString *, id> *)context
                    user:(NSDictionary<NSString *, id> *)user {
    [self reportException:exception context:context user:user breadcrumbs:nil];
}

- (void)reportException:(NSException *)exception
                 context:(NSDictionary<NSString *, id> *)context
                    user:(NSDictionary<NSString *, id> *)user
             breadcrumbs:(NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs {
    [self reportException:exception context:context user:user breadcrumbs:breadcrumbs sql:nil];
}

- (void)reportException:(NSException *)exception
                 context:(NSDictionary<NSString *, id> *)context
                    user:(NSDictionary<NSString *, id> *)user
             breadcrumbs:(NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs
                     sql:(NSString *)sql {
    @try {
        if (![_configuration isEnabled]) {
            return;
        }
        NSDictionary<NSString *, id> *payload = [_eventBuilder buildEventForException:exception context:context user:user breadcrumbs:breadcrumbs sql:sql];
        [_crashStore writePayload:payload];
    } @catch (NSException *reportingFailure) {
        // Deliberately swallowed: an error reporter that itself throws while reporting a crash is
        // the worst possible failure mode, same invariant every other SDK in this repo holds to.
        NSLog(@"[forge-ops-tracker] reportException: failed: %@", reportingFailure);
    }
}

- (void)uploadPendingReports {
    @try {
        if (![_configuration isEnabled]) {
            return;
        }
        for (NSURL *url in [_crashStore pendingPayloadURLs]) {
            NSDictionary<NSString *, id> *payload;
            if ([url.pathExtension isEqualToString:@"txt"]) {
                // A raw signal-crash report: fill in the standard fields FOTSignalHandler
                // couldn't safely build inline (see its own class comment), now that it's safe to
                // use Foundation freely again.
                NSDictionary<NSString *, id> *parsed = [FOTSignalHandler parseRawSignalReportAtURL:url];
                payload = [self completeSignalPayload:parsed reportURL:url];
            } else {
                payload = [_crashStore payloadAtURL:url];
            }

            if (payload == nil) {
                // Unreadable/corrupt file: delete rather than retry forever.
                [_crashStore deletePayloadAtURL:url];
                continue;
            }
            if ([_client deliver:payload]) {
                [_crashStore deletePayloadAtURL:url];
            }
            // On failure, leave it in place; the next launch's uploadPendingReports retries it.
        }
    } @catch (NSException *uploadFailure) {
        NSLog(@"[forge-ops-tracker] uploadPendingReports failed: %@", uploadFailure);
    }
}

- (nullable NSDictionary<NSString *, id> *)completeSignalPayload:(NSDictionary<NSString *, id> *)parsed reportURL:(NSURL *)url {
    if (parsed == nil) {
        return nil;
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;

    NSMutableDictionary<NSString *, id> *payload = [parsed mutableCopy];
    payload[@"occurred_at"] = [formatter stringFromDate:[NSDate date]]; // upload time, not crash time: the raw file has no safely-capturable timestamp of its own beyond its filename
    payload[@"environment"] = _configuration.environment;
    payload[@"release"] = _configuration.releaseVersion ?: [NSNull null];
    payload[@"server_name"] = _configuration.serverName ?: [NSNull null];
    payload[@"context"] = @{};
    payload[@"tags"] = @{};

    // Filled in with whoever is "current" at *upload* time (this next launch), not necessarily
    // who was signed in the moment the signal actually fired: the signal handler itself can never
    // safely read this (see FOTSignalHandler.h's own comment on what's safe to touch there), the
    // same "best effort, filled in later" treatment this raw report's environment/release/
    // server_name above already get.
    NSDictionary<NSString *, id> *user = [ForgeOpsTracker currentUser];
    if (user.count > 0) {
        payload[@"user"] = user;
    }

    // The trail the *crashed* run left behind on disk (see FOTBreadcrumbBuffer.h): this process's
    // own in-memory trail only starts after the crash, so it has nothing to say about it. Only
    // attached when it plausibly belongs to this specific crash, judged by the raw report file's
    // own creation time; already PII-scrubbed when it was written, so not scrubbed again here.
    NSDate *crashDate = nil;
    [url getResourceValue:&crashDate forKey:NSURLCreationDateKey error:nil];
    NSArray<NSDictionary<NSString *, id> *> *breadcrumbs =
        crashDate ? [ForgeOpsTracker previousRunBreadcrumbsForCrashOccurringAt:crashDate] : nil;
    if (breadcrumbs.count > 0) {
        payload[@"breadcrumbs"] = breadcrumbs;
    }
    return payload;
}

@end
