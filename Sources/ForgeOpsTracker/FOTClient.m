#import "FOTClient.h"

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
    return [self postJSONObject:payload toURL:[_configuration ingestionURL]];
}

- (BOOL)deliverPerformanceSamples:(NSArray<NSDictionary<NSString *, id> *> *)samples {
    return [self postJSONObject:@{ @"samples": samples } toURL:[_configuration performanceSamplesURL]];
}

- (BOOL)deliverMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return [self postJSONObject:@{ @"metrics": entries } toURL:[_configuration customMetricsURL]];
}

- (BOOL)deliverInfrastructureMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries {
    return [self postJSONObject:@{ @"metrics": entries } toURL:[_configuration infrastructureMetricsURL]];
}

- (BOOL)deliverSpans:(NSDictionary<NSString *, id> *)trace {
    return [self postJSONObject:trace toURL:[_configuration spansURL]];
}

- (BOOL)postJSONObject:(id)payload toURL:(nullable NSURL *)url {
    NSString *apiKey = [_configuration apiKey];
    if (url == nil || apiKey == nil) {
        return NO;
    }

    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (body == nil) {
        return NO;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;

    __block BOOL success = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error == nil && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            success = (status >= 200 && status < 300);
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];

    // -deliver: is documented as synchronous (see FOTClient.h); a hard timeout guard here
    // regardless of the request's own timeoutIntervalForRequest, since a caller relying on this
    // being bounded shouldn't also have to trust that every possible NSURLSession failure mode
    // still calls the completion handler.
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((_configuration.timeout + 1.0) * NSEC_PER_SEC)));

    return success;
}

@end
