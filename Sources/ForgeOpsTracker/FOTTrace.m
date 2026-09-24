#import "FOTTrace.h"
#import "FOTRequestSpan.h"

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

// The W3C spec reserves all zeros as invalid, and a receiver discards a header carrying one, so that
// one value in 2^64 (or 2^128) is drawn again rather than sent.
static NSString *FOTNonZeroHex(NSUInteger bytes) {
    while (YES) {
        NSString *hex = FOTRandomHex(bytes);
        if ([hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0"] invertedSet]].location != NSNotFound) {
            return hex;
        }
    }
}

// The traces current on the calling thread, innermost last: see +[FOTTrace current].
static NSString *const FOTCurrentTracesKey = @"com.forgeops.tracker.current-traces";

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
    void (^_deliver)(NSDictionary<NSString *, id> *);
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
        _traceId = [FOTTrace generateTraceId];
        _rootSpanId = [FOTTrace generateSpanId];
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
    NSString *spanId = [FOTTrace generateSpanId];
    NSString *parent = [self currentParent];
    NSMutableArray<NSString *> *stack = [self openSpansOnThreadCreating:YES];
    [stack addObject:spanId];
    [FOTTrace pushCurrent:self];
    NSDate *startedAt = [NSDate date];
    CFAbsoluteTime timer = CFAbsoluteTimeGetCurrent();
    @try {
        block();
    } @finally {
        double durationMs = (CFAbsoluteTimeGetCurrent() - timer) * 1000.0;
        [FOTTrace popCurrent:self];
        [stack removeObject:spanId];
        [self storeSpan:[self spanWithId:spanId parent:parent name:name kind:kind startedAt:startedAt durationMs:durationMs data:data]];
    }
}

- (void)recordSpan:(NSString *)name kind:(NSString *)kind startedAt:(NSDate *)startedAt durationMs:(double)durationMs data:(NSDictionary<NSString *, id> *)data {
    [self storeSpan:[self spanWithId:[FOTTrace generateSpanId] parent:[self currentParent] name:name kind:kind startedAt:startedAt durationMs:durationMs data:data]];
}

- (void)recordSpanWithId:(NSString *)spanId
                  parent:(NSString *)parent
                    name:(NSString *)name
                    kind:(NSString *)kind
               startedAt:(NSDate *)startedAt
              durationMs:(double)durationMs
                    data:(NSDictionary<NSString *, id> *)data {
    [self storeSpan:[self spanWithId:spanId parent:parent name:name kind:kind startedAt:startedAt durationMs:durationMs data:data]];
}

- (FOTRequestSpan *)startRequestSpan:(NSURLRequest *)request {
    return [self startRequestSpan:request name:nil];
}

- (FOTRequestSpan *)startRequestSpan:(NSURLRequest *)request name:(NSString *)name {
    return [FOTRequestSpan startWithRequest:request trace:self name:name];
}

+ (FOTTrace *)current {
    return [[NSThread currentThread].threadDictionary[FOTCurrentTracesKey] lastObject];
}

+ (void)pushCurrent:(FOTTrace *)trace {
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    NSMutableArray<FOTTrace *> *stack = threadDictionary[FOTCurrentTracesKey];
    if (stack == nil) {
        stack = [NSMutableArray array];
        threadDictionary[FOTCurrentTracesKey] = stack;
    }
    [stack addObject:trace];
}

+ (void)popCurrent:(FOTTrace *)trace {
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    NSMutableArray<FOTTrace *> *stack = threadDictionary[FOTCurrentTracesKey];
    NSUInteger index = [stack indexOfObjectWithOptions:NSEnumerationReverse passingTest:^BOOL(FOTTrace *candidate, NSUInteger i, BOOL *stop) {
        return candidate == trace;
    }];
    if (index == NSNotFound) {
        return;
    }
    [stack removeObjectAtIndex:index];
    if (stack.count == 0) {
        [threadDictionary removeObjectForKey:FOTCurrentTracesKey];
    }
}

+ (NSString *)generateTraceId {
    return FOTNonZeroHex(16);
}

+ (NSString *)generateSpanId {
    return FOTNonZeroHex(8);
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
