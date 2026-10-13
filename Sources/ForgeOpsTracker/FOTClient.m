#import "FOTClient.h"

FOTDeliveryOutcome FOTDeliveryOutcomeForStatus(NSInteger status) {
    if (status >= 200 && status < 300) {
        return FOTDeliveryOutcomeDelivered;
    }
    if (status >= 400 && status < 500 && status != 408 && status != 429) {
        return FOTDeliveryOutcomeRejected;
    }
    return FOTDeliveryOutcomeFailed;
}

NSString *FOTDeliveryDropReasonForStatus(NSInteger status) {
    if (FOTDeliveryOutcomeForStatus(status) == FOTDeliveryOutcomeRejected) {
        return [NSString stringWithFormat:@"rejected by the server (HTTP %ld)", (long)status];
    }
    if (status == 0) {
        return @"the server could not be reached";
    }
    return [NSString stringWithFormat:@"the server answered HTTP %ld", (long)status];
}

@implementation FOTClient {
    FOTConfiguration *_configuration;
    NSURLSession *_session;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = configuration.timeout;
        _session = [NSURLSession sessionWithConfiguration:sessionConfig];
    }
    return self;
}

- (BOOL)deliver:(NSDictionary<NSString *, id> *)payload {
    return FOTDeliveryOutcomeForStatus([self statusOfDelivering:payload]) == FOTDeliveryOutcomeDelivered;
}

- (BOOL)deliverPerformanceSamples:(NSArray<NSDictionary<NSString *, id> *> *)samples {
    return FOTDeliveryOutcomeForStatus([self statusOfDeliveringPerformanceSamples:samples]) == FOTDeliveryOutcomeDelivered;
}

- (BOOL)deliverMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return FOTDeliveryOutcomeForStatus([self statusOfDeliveringMetrics:entries]) == FOTDeliveryOutcomeDelivered;
}

- (BOOL)deliverInfrastructureMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return FOTDeliveryOutcomeForStatus([self statusOfDeliveringInfrastructureMetrics:entries]) == FOTDeliveryOutcomeDelivered;
}

- (BOOL)deliverSpans:(NSDictionary<NSString *, id> *)trace {
    return FOTDeliveryOutcomeForStatus([self postJSONObject:trace toURL:[_configuration spansURL]]) == FOTDeliveryOutcomeDelivered;
}

- (BOOL)deliverChange:(NSDictionary<NSString *, id> *)change {
    return FOTDeliveryOutcomeForStatus([self postJSONObject:change toURL:[_configuration changesURL]]) == FOTDeliveryOutcomeDelivered;
}

- (NSInteger)statusOfDelivering:(NSDictionary<NSString *, id> *)payload {
    return [self postJSONObject:payload toURL:[_configuration ingestionURL]];
}

- (NSInteger)statusOfDeliveringPerformanceSamples:(NSArray<NSDictionary<NSString *, id> *> *)samples {
    return [self postJSONObject:@{ @"samples": samples } toURL:[_configuration performanceSamplesURL]];
}

- (NSInteger)statusOfDeliveringMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return [self postJSONObject:@{ @"metrics": entries } toURL:[_configuration customMetricsURL]];
}

- (NSInteger)statusOfDeliveringInfrastructureMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return [self postJSONObject:@{ @"metrics": entries } toURL:[_configuration infrastructureMetricsURL]];
}

// The HTTP status of the response, or 0 when there was none (no DSN, a network error, a timeout).
- (NSInteger)postJSONObject:(id)payload toURL:(nullable NSURL *)url {
    NSString *apiKey = [_configuration apiKey];
    if (url == nil || apiKey == nil) {
        return 0;
    }

    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (body == nil) {
        return 0;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;

    __block NSInteger status = 0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];

    // -deliver: is documented as synchronous (see FOTClient.h); a hard timeout guard here
    // regardless of the request's own timeoutIntervalForRequest, since a caller relying on this
    // being bounded shouldn't also have to trust that every possible NSURLSession failure mode
    // still calls the completion handler.
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((_configuration.timeout + 1.0) * NSEC_PER_SEC)));

    return status;
}

@end
