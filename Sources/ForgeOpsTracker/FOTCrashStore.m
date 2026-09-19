#import "FOTCrashStore.h"

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

    return [reportFiles sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil;
        NSDate *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLCreationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLCreationDateKey error:nil];
        if (dateA == nil || dateB == nil) {
            return NSOrderedSame;
        }
        return [dateA compare:dateB];
    }];
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
