#import "FOTCrashStore.h"

const NSUInteger FOTCrashStoreMaxPendingPayloads = 20;
const NSTimeInterval FOTCrashStoreMaxPendingPayloadAge = 7 * 24 * 60 * 60;

@implementation FOTCrashStore {
    FOTConfiguration *_configuration;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
    }
    return self;
}

- (BOOL)writePayload:(NSDictionary<NSString *, id> *)payload {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:_configuration.crashReportsDirectory
        withIntermediateDirectories:YES
                         attributes:nil
                              error:&error]) {
        return NO;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil) {
        return NO;
    }

    NSString *filename = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"json"];
    NSString *path = [_configuration.crashReportsDirectory stringByAppendingPathComponent:filename];
    return [json writeToFile:path options:NSDataWritingAtomic error:&error];
}

- (NSArray<NSURL *> *)pendingPayloadURLs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *dir = [NSURL fileURLWithPath:_configuration.crashReportsDirectory isDirectory:YES];

    NSArray<NSURL *> *urls = [fm contentsOfDirectoryAtURL:dir
                                includingPropertiesForKeys:@[ NSURLCreationDateKey ]
                                                   options:0
                                                     error:nil];
    if (urls == nil) {
        return @[];
    }

    // Both extensions: "json" is a full event payload written by FOTReporter after an uncaught
    // NSException; "txt" is a raw signal-crash report written by FOTSignalHandler (see its own
    // class comment for why that path can't safely build JSON inline). FOTReporter's
    // -uploadPendingReports branches on which one it's looking at.
    NSArray<NSURL *> *reportFiles = [urls filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            return [url.pathExtension isEqualToString:@"json"] || [url.pathExtension isEqualToString:@"txt"];
        }]];

    NSArray<NSURL *> *sorted = [reportFiles sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil;
        NSDate *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLCreationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLCreationDateKey error:nil];
        if (dateA == nil || dateB == nil) {
            return NSOrderedSame;
        }
        return [dateA compare:dateB];
    }];
    return [self prune:sorted];
}

// A file whose creation date can't be read is never counted as too old, only toward the cap.
- (NSArray<NSURL *> *)prune:(NSArray<NSURL *> *)sorted {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-FOTCrashStoreMaxPendingPayloadAge];
    NSMutableArray<NSURL *> *kept = [NSMutableArray arrayWithCapacity:sorted.count];
    NSUInteger expired = 0;
    for (NSURL *url in sorted) {
        NSDate *created = nil;
        [url getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
        if (created != nil && [created compare:cutoff] == NSOrderedAscending) {
            [self deletePayloadAtURL:url];
            expired += 1;
        } else {
            [kept addObject:url];
        }
    }

    NSUInteger excess = kept.count > FOTCrashStoreMaxPendingPayloads ? kept.count - FOTCrashStoreMaxPendingPayloads : 0;
    for (NSUInteger i = 0; i < excess; i++) {
        [self deletePayloadAtURL:kept[i]];
    }
    [kept removeObjectsInRange:NSMakeRange(0, excess)];

    if (expired > 0) {
        NSLog(@"[forge-ops-tracker] dropped %lu crash reports older than 7 days that could not be delivered", (unsigned long)expired);
    }
    if (excess > 0) {
        NSLog(@"[forge-ops-tracker] dropped the %lu oldest crash reports: more than %lu were waiting to be delivered", (unsigned long)excess, (unsigned long)FOTCrashStoreMaxPendingPayloads);
    }
    return kept;
}

- (nullable NSDictionary<NSString *, id> *)payloadAtURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data == nil) {
        return nil;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

- (void)deletePayloadAtURL:(NSURL *)url {
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end
