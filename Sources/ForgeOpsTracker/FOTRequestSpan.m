#import "FOTRequestSpan.h"

NSString *const FOTTraceParentHeader = @"traceparent";

@implementation FOTRequestSpan {
    FOTTrace *_trace;
    NSString *_parentSpanId;
    NSString *_name;
    NSDate *_startedAt;
    CFAbsoluteTime _timer;
    NSLock *_lock;
    BOOL _finished;
}

+ (instancetype)startWithRequest:(NSURLRequest *)request trace:(FOTTrace *)trace name:(NSString *)name {
    return [[self alloc] initWithRequest:request trace:trace name:name];
}

- (instancetype)initWithRequest:(NSURLRequest *)request trace:(FOTTrace *)trace name:(NSString *)name {
    self = [super init];
    if (self) {
        NSString *host = request.URL.host;
        _trace = trace;
        _name = [name copy] ?: [NSString stringWithFormat:@"%@ %@", request.HTTPMethod ?: @"GET", host ?: @"unknown host"];
        _startedAt = [NSDate date];
        _timer = CFAbsoluteTimeGetCurrent();
        _lock = [[NSLock alloc] init];
        if (trace == nil) {
            _request = [request copy];
            return self;
        }

        _spanId = [FOTTrace generateSpanId];
        _parentSpanId = [trace currentParent];
        // Leaves a traceparent the caller already set alone: whoever set it explicitly knows better
        // than this SDK which trace the call belongs to.
        if ([trace.configuration shouldPropagateTraceToHost:host] && [request valueForHTTPHeaderField:FOTTraceParentHeader] == nil) {
            NSMutableURLRequest *withHeader = [request mutableCopy];
            _traceparent = [NSString stringWithFormat:@"00-%@-%@-01", trace.traceId, _spanId];
            [withHeader setValue:_traceparent forHTTPHeaderField:FOTTraceParentHeader];
            _request = [withHeader copy];
        } else {
            _request = [request copy];
        }
    }
    return self;
}

- (void)finishWithResponse:(NSURLResponse *)response error:(NSError *)error {
    [_lock lock];
    if (_finished) {
        [_lock unlock];
        return;
    }
    _finished = YES;
    [_lock unlock];

    if (_trace == nil) {
        return;
    }
    double durationMs = (CFAbsoluteTimeGetCurrent() - _timer) * 1000.0;
    NSDictionary<NSString *, id> *data = @{};
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        data = @{ @"status": @(((NSHTTPURLResponse *)response).statusCode) };
    }
    [_trace recordSpanWithId:_spanId parent:_parentSpanId name:_name kind:@"http" startedAt:_startedAt durationMs:durationMs data:data];
}

@end
