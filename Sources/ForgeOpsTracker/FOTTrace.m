#import "FOTTrace.h"

static const NSUInteger FOTMaxSpans = 500;

static NSString *FOTRandomHex(NSUInteger bytes) {
    uint8_t raw[16];
    arc4random_buf(raw, bytes);
    NSMutableString *out = [NSMutableString stringWithCapacity:bytes * 2];
    for (NSUInteger i = 0; i < bytes; i++) {
        [out appendFormat:@"%02x", raw[i]];
    }
    return out;
}

static NSString *FOTTimestamp(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    });
    @synchronized(formatter) {
        return [formatter stringFromDate:date];
    }
}

static NSString *FOTNormalizedKind(NSString *kind) {
    static NSSet<NSString *> *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kinds = [NSSet setWithObjects:@"controller", @"service", @"database", @"redis", @"http", @"job", @"other", nil];
    });
    return [kinds containsObject:kind] ? kind : @"other";
}

@implementation FOTTrace {
    NSString *_name;
    FOTConfiguration *_configuration;
    void (^_deliver)(NSDictionary<NSString *, id> *);
    NSString *_traceId;
    NSString *_rootSpanId;
    NSDate *_startedAt;
    CFAbsoluteTime _timer;
    NSLock *_lock;
    NSMutableArray<NSDictionary<NSString *, id> *> *_spans;
    BOOL _finished;
    NSString *_stackKey;
}

- (instancetype)initWithName:(NSString *)name
               configuration:(FOTConfiguration *)configuration
                     deliver:(void (^)(NSDictionary<NSString *, id> *))deliver {
    self = [super init];
    if (self) {
        _name = [name copy];
        _configuration = configuration;
        _deliver = [deliver copy];
        _traceId = FOTRandomHex(16);
        _rootSpanId = FOTRandomHex(8);
        _startedAt = [NSDate date];
        _timer = CFAbsoluteTimeGetCurrent();
        _lock = [[NSLock alloc] init];
        _spans = [NSMutableArray array];
        _stackKey = [@"com.forgeops.tracker.open-spans." stringByAppendingString:_traceId];
    }
    return self;
}

// The open-span stack for this trace on the calling thread. Kept in the thread's own dictionary,
// keyed by this trace's id, so two traces in flight on one thread never see each other's spans.
- (NSMutableArray<NSString *> *)openSpansOnThreadCreating:(BOOL)create {
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    NSMutableArray<NSString *> *stack = threadDictionary[_stackKey];
    if (stack == nil && create) {
        stack = [NSMutableArray array];
        threadDictionary[_stackKey] = stack;
    }
    return stack;
}

- (NSString *)currentParent {
    return [self openSpansOnThreadCreating:NO].lastObject ?: _rootSpanId;
}

- (NSDictionary<NSString *, id> *)spanWithId:(NSString *)spanId
                                       parent:(nullable NSString *)parent
                                         name:(NSString *)name
                                         kind:(NSString *)kind
                                    startedAt:(NSDate *)startedAt
                                   durationMs:(double)durationMs
                                         data:(nullable NSDictionary<NSString *, id> *)data {
    return @{
        @"span_id": spanId,
        @"parent_span_id": parent ?: [NSNull null],
        @"name": name,
        @"kind": FOTNormalizedKind(kind),
        @"started_at": FOTTimestamp(startedAt),
        @"duration_ms": @(round(durationMs * 100.0) / 100.0),
        @"environment": _configuration.environment ?: @"",
        @"release": _configuration.releaseVersion ?: [NSNull null],
        @"data": data ?: @{},
    };
}

- (void)storeSpan:(NSDictionary<NSString *, id> *)span {
    [_lock lock];
    if (!_finished && _spans.count < FOTMaxSpans - 1) { // leave room for the root
        [_spans addObject:span];
    }
    [_lock unlock];
}

- (void)measureSpan:(NSString *)name kind:(NSString *)kind block:(NS_NOESCAPE void (^)(void))block {
    [self measureSpan:name kind:kind data:nil block:block];
}

- (void)measureSpan:(NSString *)name kind:(NSString *)kind data:(NSDictionary<NSString *, id> *)data block:(NS_NOESCAPE void (^)(void))block {
    NSString *spanId = FOTRandomHex(8);
    NSString *parent = [self currentParent];
    NSMutableArray<NSString *> *stack = [self openSpansOnThreadCreating:YES];
    [stack addObject:spanId];
    NSDate *startedAt = [NSDate date];
    CFAbsoluteTime timer = CFAbsoluteTimeGetCurrent();
    @try {
        block();
    } @finally {
        double durationMs = (CFAbsoluteTimeGetCurrent() - timer) * 1000.0;
        [stack removeObject:spanId];
        [self storeSpan:[self spanWithId:spanId parent:parent name:name kind:kind startedAt:startedAt durationMs:durationMs data:data]];
    }
}

- (void)recordSpan:(NSString *)name kind:(NSString *)kind startedAt:(NSDate *)startedAt durationMs:(double)durationMs data:(NSDictionary<NSString *, id> *)data {
    [self storeSpan:[self spanWithId:FOTRandomHex(8) parent:[self currentParent] name:name kind:kind startedAt:startedAt durationMs:durationMs data:data]];
}

- (void)finish {
    [_lock lock];
    if (_finished) {
        [_lock unlock];
        return;
    }
    _finished = YES;
    NSArray<NSDictionary<NSString *, id> *> *spans = [_spans copy];
    [_lock unlock];

    double durationMs = (CFAbsoluteTimeGetCurrent() - _timer) * 1000.0;
    if (durationMs < _configuration.traceCaptureThreshold * 1000.0) {
        return;
    }

    NSMutableArray *all = [NSMutableArray arrayWithCapacity:spans.count + 1];
    [all addObject:[self spanWithId:_rootSpanId parent:nil name:_name kind:@"controller" startedAt:_startedAt durationMs:durationMs data:nil]];
    [all addObjectsFromArray:spans];
    _deliver(@{ @"trace_id": _traceId, @"spans": all });
}

@end
