#import "FOTPerformanceFlusher.h"
#import "FOTHistogramBucketer.h"

@interface FOTPerformanceBucket : NSObject
@property (nonatomic) NSUInteger count;
@property (nonatomic) double durationSumMs;
@property (nonatomic) double maxDurationMs;
// A count per latency bucket label, see FOTHistogramBucketer.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *histogram;
@end

@implementation FOTPerformanceBucket
- (instancetype)init {
    self = [super init];
    if (self) {
        _histogram = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation FOTPerformanceFlusher {
    FOTConfiguration *_configuration;
    FOTClient *_client;
    NSLock *_lock;
    NSMutableDictionary<NSString *, FOTPerformanceBucket *> *_buckets;
    NSDate *_periodStartedAt;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration client:(FOTClient *)client {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _client = client;
        _lock = [[NSLock alloc] init];
        _buckets = [NSMutableDictionary dictionary];
        _periodStartedAt = [NSDate date];
        _queue = dispatch_queue_create("com.forgeops.tracker.performance", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)recordTransaction:(NSString *)transactionName durationMs:(double)durationMs {
    if (!_configuration.trackPerformance || ![_configuration isEnabled]) {
        return;
    }

    [_lock lock];
    FOTPerformanceBucket *bucket = _buckets[transactionName];
    if (bucket == nil) {
        bucket = [[FOTPerformanceBucket alloc] init];
        _buckets[transactionName] = bucket;
    }
    bucket.count++;
    bucket.durationSumMs += durationMs;
    if (durationMs > bucket.maxDurationMs) {
        bucket.maxDurationMs = durationMs;
    }
    // The distribution count/sum/max can't reconstruct: see FOTHistogramBucketer for why the server
    // approximates a percentile from these bucket counts.
    NSString *label = [FOTHistogramBucketer bucketForDuration:durationMs];
    bucket.histogram[label] = @(bucket.histogram[label].unsignedIntegerValue + 1);
    BOOL needsTimer = _timer == nil;
    [_lock unlock];

    if (needsTimer) {
        [self startTimer];
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

    __weak FOTPerformanceFlusher *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        FOTPerformanceFlusher *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        @try {
            [strongSelf flush];
        } @catch (NSException *failure) {
            // One bad flush must not stop every flush after it.
            NSLog(@"[forge-ops-tracker] performance flush failed: %@", failure);
        }
        [strongSelf armTimer];
    });
    [self armTimer];
    dispatch_resume(timer);
}

// Re-read on every arm, not captured once: a change to performanceFlushInterval after the first
// record takes effect from the next flush on.
- (void)armTimer {
    [_lock lock];
    dispatch_source_t timer = _timer;
    [_lock unlock];
    if (timer == nil) {
        return;
    }
    NSTimeInterval interval = MAX(_configuration.performanceFlushInterval, 0.001);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (uint64_t)(interval * 0.1 * NSEC_PER_SEC));
}

- (void)flush {
    [_lock lock];
    if (_buckets.count == 0) {
        [_lock unlock];
        return;
    }
    NSMutableDictionary<NSString *, FOTPerformanceBucket *> *snapshot = [NSMutableDictionary dictionaryWithCapacity:_buckets.count];
    [_buckets enumerateKeysAndObjectsUsingBlock:^(NSString *name, FOTPerformanceBucket *bucket, BOOL *stop) {
        FOTPerformanceBucket *copy = [[FOTPerformanceBucket alloc] init];
        copy.count = bucket.count;
        copy.durationSumMs = bucket.durationSumMs;
        copy.maxDurationMs = bucket.maxDurationMs;
        copy.histogram = [bucket.histogram mutableCopy];
        snapshot[name] = copy;
    }];
    NSDate *periodStart = _periodStartedAt;
    NSDate *periodEnd = [NSDate date];
    void (^hook)(void) = self.beforeDeliveryHook;
    [_lock unlock];

    if (hook != nil) {
        hook();
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; // no fractional seconds, matches every other SDK's payload
    NSMutableArray<NSDictionary<NSString *, id> *> *samples = [NSMutableArray arrayWithCapacity:snapshot.count];
    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *name, FOTPerformanceBucket *bucket, BOOL *stop) {
        [samples addObject:@{
            @"transaction_name": name,
            @"environment": self->_configuration.environment,
            @"release": self->_configuration.releaseVersion ?: [NSNull null],
            @"period_started_at": [formatter stringFromDate:periodStart],
            @"period_ended_at": [formatter stringFromDate:periodEnd],
            @"request_count": @(bucket.count),
            @"duration_sum_ms": @(bucket.durationSumMs),
            @"max_duration_ms": @(bucket.maxDurationMs),
            @"histogram": [bucket.histogram copy],
        }];
    }];

    if (![_client deliverPerformanceSamples:samples]) {
        return;
    }

    [_lock lock];
    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *name, FOTPerformanceBucket *sent, BOOL *stop) {
        FOTPerformanceBucket *current = self->_buckets[name];
        if (current == nil) {
            return;
        }
        current.count = current.count > sent.count ? current.count - sent.count : 0;
        current.durationSumMs = MAX(0.0, current.durationSumMs - sent.durationSumMs);
        [sent.histogram enumerateKeysAndObjectsUsingBlock:^(NSString *label, NSNumber *sentCount, BOOL *innerStop) {
            NSInteger remaining = current.histogram[label].integerValue - sentCount.integerValue;
            if (remaining > 0) {
                current.histogram[label] = @(remaining);
            } else {
                [current.histogram removeObjectForKey:label];
            }
        }];
        // maxDurationMs is deliberately left as whatever is currently on the bucket, sent or not:
        // unlike count/durationSumMs, a max can't be correctly "subtracted" back out (the true max
        // of what's left is anything at or below it, not knowable from the two numbers alone), and
        // leaving it never overstates the next period's own max, only potentially understates how
        // far back it was actually set.
        if (current.count == 0) {
            [self->_buckets removeObjectForKey:name];
        }
    }];
    _periodStartedAt = periodEnd;
    [_lock unlock];
}

- (void)discard {
    [_lock lock];
    dispatch_source_t timer = _timer;
    _timer = nil;
    [_buckets removeAllObjects];
    [_lock unlock];
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

- (NSDictionary<NSString *, NSNumber *> *)tallyForTransaction:(NSString *)transactionName {
    [_lock lock];
    FOTPerformanceBucket *bucket = _buckets[transactionName];
    NSDictionary<NSString *, NSNumber *> *tally = bucket == nil ? nil : @{
        @"count": @(bucket.count),
        @"duration_sum_ms": @(bucket.durationSumMs),
        @"max_duration_ms": @(bucket.maxDurationMs),
    };
    [_lock unlock];
    return tally;
}

@end
