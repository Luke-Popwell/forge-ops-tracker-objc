#import "FOTBreadcrumbBuffer.h"
#import "FOTPiiScrubber.h"

@implementation FOTBreadcrumbBuffer {
    FOTConfiguration *_configuration;
    NSMutableArray<NSDictionary<NSString *, id> *> *_entries;
    NSLock *_lock;
    dispatch_queue_t _writeQueue;
    BOOL _persisting;
    NSArray<NSDictionary<NSString *, id> *> *_previousRunEntries;
    NSDate *_previousRunModifiedAt;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _entries = [NSMutableArray array];
        _lock = [[NSLock alloc] init];
        _writeQueue = dispatch_queue_create("com.forgeops.tracker.breadcrumbs", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)persistedPath {
    // A sibling of the crash reports directory, not a file inside it: FOTCrashStore treats every
    // .json/.txt file in that directory as a pending crash report to upload.
    return [_configuration.crashReportsDirectory stringByAppendingString:@".breadcrumbs.json"];
}

- (void)addBreadcrumbWithMessage:(NSString *)message
                         category:(NSString *)category
                            level:(NSString *)level
                             data:(NSDictionary<NSString *, id> *)data {
    if (!_configuration.trackBreadcrumbs) {
        return;
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; // no fractional seconds, matches every other SDK's payload
    NSDictionary<NSString *, id> *entry = @{
        @"category": category,
        @"message": message,
        @"level": level,
        @"timestamp": [formatter stringFromDate:[NSDate date]],
        @"data": data ?: @{},
    };

    [_lock lock];
    [_entries addObject:entry];
    while (_entries.count > _configuration.maxBreadcrumbs) {
        [_entries removeObjectAtIndex:0];
    }
    [_lock unlock];

    [self schedulePersist];
}

- (void)clear {
    [_lock lock];
    [_entries removeAllObjects];
    [_lock unlock];

    [self schedulePersist];
}

- (NSArray<NSDictionary<NSString *, id> *> *)all {
    [_lock lock];
    NSArray<NSDictionary<NSString *, id> *> *copy = [_entries copy];
    [_lock unlock];
    return copy;
}

- (void)startPersisting {
    [_lock lock];
    BOOL alreadyPersisting = _persisting;
    _persisting = YES;
    [_lock unlock];
    if (alreadyPersisting) {
        return;
    }

    // Read whatever the previous run left behind before this run's first write can replace it.
    NSString *path = [self persistedPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([parsed isKindOfClass:[NSArray class]] && [(NSArray *)parsed count] > 0 && attributes[NSFileModificationDate] != nil) {
        [_lock lock];
        _previousRunEntries = parsed;
        _previousRunModifiedAt = attributes[NSFileModificationDate];
        [_lock unlock];
    }

    [self schedulePersist];
}

- (NSArray<NSDictionary<NSString *, id> *> *)previousRunBreadcrumbsForCrashOccurringAt:(NSDate *)crashDate {
    [_lock lock];
    NSArray<NSDictionary<NSString *, id> *> *entries = _previousRunEntries;
    NSDate *modifiedAt = _previousRunModifiedAt;
    [_lock unlock];

    if (entries == nil || modifiedAt == nil) {
        return nil;
    }
    // One second of slack: file timestamps aren't guaranteed finer-grained than that everywhere.
    if ([modifiedAt timeIntervalSinceDate:crashDate] > 1.0) {
        return nil;
    }
    return entries;
}

- (void)schedulePersist {
    [_lock lock];
    BOOL persisting = _persisting;
    NSArray<NSDictionary<NSString *, id> *> *snapshot = persisting ? [_entries copy] : nil;
    [_lock unlock];
    if (!persisting) {
        return;
    }

    BOOL scrub = _configuration.scrubPII;
    NSString *path = [self persistedPath];
    dispatch_async(_writeQueue, ^{
        @try {
            NSMutableArray *toWrite = [NSMutableArray arrayWithCapacity:snapshot.count];
            for (NSDictionary<NSString *, id> *entry in snapshot) {
                [toWrite addObject:scrub ? [FOTPiiScrubber scrub:entry key:nil] : entry];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:toWrite options:0 error:nil];
            if (json == nil) {
                return;
            }
            [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:nil];
            [json writeToFile:path options:NSDataWritingAtomic error:nil];
        } @catch (NSException *failure) {
            // Best effort: never let breadcrumb persistence take down the host app.
        }
    });
}

- (void)_waitForPendingWrites {
    dispatch_sync(_writeQueue, ^{});
}

@end
