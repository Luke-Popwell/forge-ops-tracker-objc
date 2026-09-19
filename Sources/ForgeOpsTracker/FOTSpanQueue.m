#import "FOTSpanQueue.h"

static const NSUInteger FOTSpanQueueLimit = 100;

@implementation FOTSpanQueue {
    FOTConfiguration *_configuration;
    FOTClient *_client;
    dispatch_queue_t _queue;
    NSLock *_lock;
    NSUInteger _pending;
    BOOL _discarded;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration client:(FOTClient *)client {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _client = client;
        _queue = dispatch_queue_create("com.forgeops.tracker.spans", DISPATCH_QUEUE_SERIAL);
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)push:(NSDictionary<NSString *, id> *)trace {
    [_lock lock];
    if (_pending >= FOTSpanQueueLimit) {
        [_lock unlock];
        return NO;
    }
    _pending++;
    [_lock unlock];

    dispatch_async(_queue, ^{
        [self->_lock lock];
        BOOL discarded = self->_discarded;
        [self->_lock unlock];
        if (!discarded) {
            @try {
                [self->_client deliverSpans:trace];
            } @catch (NSException *exception) {
                // One bad delivery must not stop every trace queued after it.
            }
        }
        [self->_lock lock];
        self->_pending--;
        [self->_lock unlock];
    });
    return YES;
}

- (void)waitUntilDelivered {
    dispatch_sync(_queue, ^{});
}

- (void)discard {
    [_lock lock];
    _discarded = YES;
    [_lock unlock];
}

@end
