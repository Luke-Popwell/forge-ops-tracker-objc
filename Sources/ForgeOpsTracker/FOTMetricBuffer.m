#import "FOTMetricBuffer.h"

const NSUInteger FOTMetricBufferMaxEntries = 1000;

@implementation FOTMetricBuffer {
    FOTConfiguration *_configuration;
    BOOL (^_deliver)(NSArray<NSDictionary<NSString *, id> *> *);
    NSTimeInterval (^_interval)(void);
    NSLock *_lock;
    NSMutableArray<NSDictionary<NSString *, id> *> *_entries;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration
                              deliver:(BOOL (^)(NSArray<NSDictionary<NSString *, id> *> *))deliver
                             interval:(NSTimeInterval (^)(void))interval {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _deliver = [deliver copy];
        _interval = [interval copy];
        _lock = [[NSLock alloc] init];
        _entries = [NSMutableArray array];
        _queue = dispatch_queue_create("com.forgeops.tracker.metrics", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)record:(NSDictionary<NSString *, id> *)entry {
    id value = entry[@"value"];
    if (![value isKindOfClass:[NSNumber class]] || isnan([value doubleValue]) || isinf([value doubleValue])) {
        return NO;
    }

    NSMutableDictionary<NSString *, id> *stamped = [entry mutableCopy];
    stamped[@"recorded_at"] = [FOTMetricBuffer timestamp];

    [_lock lock];
    if (_entries.count >= FOTMetricBufferMaxEntries) {
        [_lock unlock];
        return NO;
    }
    [_entries addObject:stamped];
    BOOL needsTimer = _timer == nil;
    [_lock unlock];

    if (needsTimer) {
        [self startTimer];
    }
    return YES;
}

+ (NSString *)timestamp {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; // no fractional seconds, matches every other SDK's payload
    });
    @synchronized(formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

- (void)startTimer {
    [_lock lock];
    if (_timer != nil) {
        [_lock unlock];
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    _timer = timer;
    [_lock unlock];

    __weak FOTMetricBuffer *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        FOTMetricBuffer *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        @try {
            [strongSelf flush];
        } @catch (NSException *failure) {
            NSLog(@"[forge-ops-tracker] metric flush failed: %@", failure);
        }
        [strongSelf armTimer];
    });
    [self armTimer];
    dispatch_resume(timer);
}

// Re-read on every arm, not captured once: a change to the interval after the first record takes
// effect from the next flush on.
- (void)armTimer {
    [_lock lock];
    dispatch_source_t timer = _timer;
    [_lock unlock];
    if (timer == nil) {
        return;
    }
    NSTimeInterval interval = MAX(_interval(), 0.001);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (uint64_t)(interval * 0.1 * NSEC_PER_SEC));
}

- (void)flush {
    [_lock lock];
    if (_entries.count == 0) {
        [_lock unlock];
        return;
    }
    NSArray<NSDictionary<NSString *, id> *> *snapshot = [_entries copy];
    void (^hook)(void) = self.beforeDeliveryHook;
    [_lock unlock];

    if (hook != nil) {
        hook();
    }

    if (!_deliver(snapshot)) {
        return;
    }

    [_lock lock];
    // Exactly the entries just delivered: anything recorded while the request was in flight sits
    // after them and stays for the next flush.
    [_entries removeObjectsInRange:NSMakeRange(0, MIN(snapshot.count, _entries.count))];
    [_lock unlock];
}

- (void)discard {
    [_lock lock];
    dispatch_source_t timer = _timer;
    _timer = nil;
    [_entries removeAllObjects];
    [_lock unlock];
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

- (NSUInteger)count {
    [_lock lock];
    NSUInteger count = _entries.count;
    [_lock unlock];
    return count;
}

@end
