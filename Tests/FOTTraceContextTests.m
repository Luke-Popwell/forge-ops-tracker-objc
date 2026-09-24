#import <XCTest/XCTest.h>
#import "FOTEventBuilder.h"
#import "FOTRequestSpan.h"
#import "FOTTestHTTPServer.h"
#import "ForgeOpsTracker.h"

// W3C trace context: ids, the traceparent header on outgoing requests, the http span it names, the
// two propagation options, and trace_id on errors captured with a trace.
@interface FOTTraceContextTests : XCTestCase
@property (nonatomic, strong) FOTTestHTTPServer *server;
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTTraceContextTests

- (void)setUp {
    [ForgeOpsTracker _resetForTesting];
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    self.server = [[FOTTestHTTPServer alloc] init];
    [self.server start];
    [NSThread sleepForTimeInterval:0.05];
}

- (void)tearDown {
    [self.server stop];
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
    [ForgeOpsTracker _resetForTesting];
}

- (void)configure:(void (^)(FOTConfiguration *config))extra {
    [ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
        config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)self.server.port];
        config.enabledEnvironments = [NSSet setWithObject:@"production"];
        config.environment = @"production";
        config.crashReportsDirectory = self.tempDirectory;
        config.traceCaptureThreshold = 0;
        if (extra) {
            extra(config);
        }
    }];
}

// A trace built directly, delivering into the returned box instead of the network.
- (FOTTrace *)traceWithConfiguration:(FOTConfiguration *)config delivered:(NSMutableArray *)delivered {
    config.traceCaptureThreshold = 0;
    return [[FOTTrace alloc] initWithName:@"root" configuration:config deliver:^(NSDictionary *payload) {
        [delivered addObject:payload];
    }];
}

- (NSDictionary *)span:(NSString *)name inTrace:(NSDictionary *)trace {
    for (NSDictionary *span in trace[@"spans"]) {
        if ([span[@"name"] isEqualToString:name]) {
            return span;
        }
    }
    return nil;
}

- (BOOL)waitUntil:(BOOL (^)(void))predicate timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (predicate()) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.02];
    }
    return NO;
}

- (NSArray<NSDictionary *> *)requestsToPath:(NSString *)path {
    NSMutableArray *matching = [NSMutableArray array];
    for (NSDictionary *request in self.server.requests) {
        if ([request[@"path"] isEqualToString:path]) {
            [matching addObject:request];
        }
    }
    return matching;
}

- (NSString *)header:(NSString *)name inRequest:(NSDictionary *)request {
    NSDictionary<NSString *, NSString *> *headers = request[@"headers"];
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return [headers[key] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

- (NSDictionary *)jsonBodyOf:(NSDictionary *)request {
    return [NSJSONSerialization JSONObjectWithData:[request[@"body"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

- (BOOL)string:(NSString *)value matches:(NSString *)pattern {
    return [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

#pragma mark - ids

- (void)testIdsAreW3CLowercaseHexAndNeverAllZeros {
    for (int i = 0; i < 200; i++) {
        XCTAssertTrue([self string:[FOTTrace generateTraceId] matches:@"^(?!0{32}$)[0-9a-f]{32}$"]);
        XCTAssertTrue([self string:[FOTTrace generateSpanId] matches:@"^(?!0{16}$)[0-9a-f]{16}$"]);
    }
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    FOTTrace *trace = [self traceWithConfiguration:config delivered:[NSMutableArray array]];
    XCTAssertTrue([self string:trace.traceId matches:@"^[0-9a-f]{32}$"]);
}

#pragma mark - request spans

- (void)testStartRequestSpanAddsTraceparentNamingTheHttpSpanItRecords {
    NSMutableArray *delivered = [NSMutableArray array];
    FOTTrace *trace = [self traceWithConfiguration:[[FOTConfiguration alloc] init] delivered:delivered];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/orders/42"]];
    request.HTTPMethod = @"POST";

    FOTRequestSpan *span = [trace startRequestSpan:request];
    NSString *expected = [NSString stringWithFormat:@"00-%@-%@-01", trace.traceId, span.spanId];
    XCTAssertEqualObjects([span.request valueForHTTPHeaderField:@"traceparent"], expected);
    XCTAssertEqualObjects(span.traceparent, expected);
    XCTAssertNil([request valueForHTTPHeaderField:@"traceparent"], @"the caller's own request is never mutated");

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:201 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    [span finishWithResponse:response error:nil];
    [trace finish];

    NSDictionary *root = [self span:@"root" inTrace:delivered.firstObject];
    NSDictionary *http = [self span:@"POST api.example.com" inTrace:delivered.firstObject];
    XCTAssertEqualObjects(http[@"span_id"], span.spanId);
    XCTAssertEqualObjects(http[@"parent_span_id"], root[@"span_id"]);
    XCTAssertEqualObjects(http[@"kind"], @"http");
    XCTAssertEqualObjects(http[@"data"], @{ @"status": @201 });
    XCTAssertEqualObjects(delivered.firstObject[@"trace_id"], trace.traceId);
}

- (void)testARequestSpanStartedInsideMeasureSpanParentsUnderThatSpanAndHonorsAName {
    NSMutableArray *delivered = [NSMutableArray array];
    FOTTrace *trace = [self traceWithConfiguration:[[FOTConfiguration alloc] init] delivered:delivered];
    __block FOTRequestSpan *span;
    [trace measureSpan:@"checkout" kind:@"service" block:^{
        span = [trace startRequestSpan:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/x"]] name:@"create order"];
    }];
    [span finishWithResponse:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
    [span finishWithResponse:nil error:nil];
    [trace finish];

    NSArray *spans = delivered.firstObject[@"spans"];
    XCTAssertEqual(spans.count, (NSUInteger)3, @"finish is idempotent: one http span, not two");
    NSDictionary *http = [self span:@"create order" inTrace:delivered.firstObject];
    XCTAssertEqualObjects(http[@"parent_span_id"], [self span:@"checkout" inTrace:delivered.firstObject][@"span_id"]);
    XCTAssertEqualObjects(http[@"data"], @{}, @"a failed call is recorded without a status");
}

- (void)testATraceparentTheAppAlreadySetIsLeftAloneButTheSpanIsStillRecorded {
    NSMutableArray *delivered = [NSMutableArray array];
    FOTTrace *trace = [self traceWithConfiguration:[[FOTConfiguration alloc] init] delivered:delivered];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/"]];
    NSString *own = @"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    [request setValue:own forHTTPHeaderField:@"traceparent"];

    FOTRequestSpan *span = [trace startRequestSpan:request];
    XCTAssertEqualObjects([span.request valueForHTTPHeaderField:@"traceparent"], own);
    XCTAssertNil(span.traceparent);
    [span finishWithResponse:nil error:nil];
    [trace finish];

    XCTAssertNotNil([self span:@"GET api.example.com" inTrace:delivered.firstObject]);
}

- (void)testPropagateTracesOffStopsTheHeaderButStillRecordsTheSpan {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.propagateTraces = NO;
    NSMutableArray *delivered = [NSMutableArray array];
    FOTTrace *trace = [self traceWithConfiguration:config delivered:delivered];

    FOTRequestSpan *span = [trace startRequestSpan:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/"]]];
    XCTAssertNil([span.request valueForHTTPHeaderField:@"traceparent"]);
    XCTAssertNil(span.traceparent);
    XCTAssertNotNil(span.spanId);
    [span finishWithResponse:nil error:nil];
    [trace finish];

    XCTAssertNotNil([self span:@"GET api.example.com" inTrace:delivered.firstObject]);
}

- (void)testTracePropagationTargetsLimitWhichHostsGetTheHeader {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.tracePropagationTargets = @[ @"example.com" ];
    FOTTrace *trace = [self traceWithConfiguration:config delivered:[NSMutableArray array]];

    XCTAssertNotNil([trace startRequestSpan:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/"]]].traceparent);
    XCTAssertNil([trace startRequestSpan:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://third-party.test/"]]].traceparent);
}

- (void)testWithNoTraceTheRequestGoesOutUnchangedAndNothingIsRecorded {
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/"]];
    FOTRequestSpan *span = [FOTRequestSpan startWithRequest:request trace:nil name:nil];

    XCTAssertEqualObjects(span.request, request);
    XCTAssertNil(span.spanId);
    XCTAssertNil(span.traceparent);
    [span finishWithResponse:nil error:nil]; // harmless

    FOTTrace *noTrace = nil;
    XCTAssertNil([noTrace startRequestSpan:request], @"messaging nil is nil: the reason startWithRequest:trace:name: exists");
}

- (void)testDataTaskWithSessionSendsTheHeaderAndRecordsTheSpanBeforeTheCompletionHandler {
    [self configure:nil];
    FOTTrace *trace = [ForgeOpsTracker startTrace:@"checkout"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/orders", (unsigned long)self.server.port]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSInteger status = 0;

    [[ForgeOpsTracker dataTaskWithSession:[NSURLSession sharedSession]
                                  request:[NSURLRequest requestWithURL:url]
                                    trace:trace
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            status = ((NSHTTPURLResponse *)response).statusCode;
                            dispatch_semaphore_signal(done);
                        }] resume];
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    [trace finish];
    [ForgeOpsTracker flushSpans];

    XCTAssertEqual(status, 202);
    NSDictionary *sent = [self requestsToPath:@"/orders"].firstObject;
    NSString *traceparent = [self header:@"traceparent" inRequest:sent];
    NSString *expected = [NSString stringWithFormat:@"^00-%@-[0-9a-f]{16}-01$", trace.traceId];
    XCTAssertTrue([self string:traceparent matches:expected]);

    NSDictionary *delivered = [self jsonBodyOf:[self requestsToPath:@"/api/v1/spans"].firstObject];
    NSDictionary *http = [self span:@"GET 127.0.0.1" inTrace:delivered];
    XCTAssertEqualObjects(http[@"span_id"], [traceparent componentsSeparatedByString:@"-"][2]);
    XCTAssertEqualObjects(http[@"data"], @{ @"status": @202 });
}

- (void)testDataTaskWithSessionAndANilTraceIsAPlainRequest {
    [self configure:nil];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/orders", (unsigned long)self.server.port]];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    [[ForgeOpsTracker dataTaskWithSession:[NSURLSession sharedSession]
                                  request:[NSURLRequest requestWithURL:url]
                                    trace:nil
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            dispatch_semaphore_signal(done);
                        }] resume];
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);

    XCTAssertNil([self header:@"traceparent" inRequest:[self requestsToPath:@"/orders"].firstObject]);
}

#pragma mark - configuration

- (void)testPropagationDefaultsToEveryHost {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    XCTAssertTrue(config.propagateTraces);
    XCTAssertNil(config.tracePropagationTargets);
    XCTAssertTrue([config shouldPropagateTraceToHost:@"anything.test"]);
    XCTAssertTrue([config shouldPropagateTraceToHost:nil]);
}

- (void)testAHostTargetMatchesExactlyOrAsASubdomainOnADotBoundaryIgnoringCaseAndALeadingDot {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.tracePropagationTargets = @[ @"Example.com", @".internal.test" ];

    XCTAssertTrue([config shouldPropagateTraceToHost:@"example.com"]);
    XCTAssertTrue([config shouldPropagateTraceToHost:@"api.EXAMPLE.com"]);
    XCTAssertFalse([config shouldPropagateTraceToHost:@"badexample.com"]);
    XCTAssertFalse([config shouldPropagateTraceToHost:@"example.com.evil.test"]);
    XCTAssertTrue([config shouldPropagateTraceToHost:@"internal.test"]);
    XCTAssertTrue([config shouldPropagateTraceToHost:@"db.internal.test"]);
    XCTAssertFalse([config shouldPropagateTraceToHost:nil], @"no host only gets the header when every host does");
    XCTAssertFalse([config shouldPropagateTraceToHost:@""]);
}

- (void)testARegularExpressionTargetIsMatchedAgainstTheLowercasedHost {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.tracePropagationTargets = @[ [NSRegularExpression regularExpressionWithPattern:@"^api[0-9]+\\.corp$" options:0 error:nil], @42 ];

    XCTAssertTrue([config shouldPropagateTraceToHost:@"API7.corp"]);
    XCTAssertFalse([config shouldPropagateTraceToHost:@"api.corp"]);
    XCTAssertFalse([config shouldPropagateTraceToHost:@"42"], @"an entry of any other type matches nothing");
}

- (void)testAnEmptyTargetListOrPropagationOffMatchesNothing {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.tracePropagationTargets = @[];
    XCTAssertFalse([config shouldPropagateTraceToHost:@"example.com"]);

    config.tracePropagationTargets = nil;
    config.propagateTraces = NO;
    XCTAssertFalse([config shouldPropagateTraceToHost:@"example.com"]);
}

#pragma mark - errors

- (void)testTheEventBuilderAddsTraceIdAfterScrubbingAndOmitsItWhenNil {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[[FOTConfiguration alloc] init]];
    NSException *exception = [NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil];
    NSString *traceId = @"4bf92f3577b34da6a3ce929d0e0e4736";

    XCTAssertEqualObjects([builder buildEventForException:exception context:nil user:nil breadcrumbs:nil sql:nil traceId:traceId][@"trace_id"], traceId);
    XCTAssertFalse([[builder buildEventForException:exception context:nil user:nil breadcrumbs:nil sql:nil traceId:nil].allKeys containsObject:@"trace_id"]);
    XCTAssertFalse([[builder buildEventForException:exception context:nil].allKeys containsObject:@"trace_id"]);
}

- (void)testCaptureExceptionWithATraceCarriesItsTraceId {
    [self configure:nil];
    FOTTrace *trace = [ForgeOpsTracker startTrace:@"checkout"];

    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"FOTTestException" reason:@"boom" userInfo:nil] context:nil user:nil trace:trace];

    XCTAssertTrue([self waitUntil:^BOOL { return [self requestsToPath:@"/api/v1/events"].count >= 1; } timeout:2.0]);
    XCTAssertEqualObjects([self jsonBodyOf:[self requestsToPath:@"/api/v1/events"].firstObject][@"trace_id"], trace.traceId);
}

- (void)testCaptureExceptionInsideTraceNamedUsesTheCurrentTraceAndOutsideItHasNone {
    [self configure:nil];
    __block NSString *traceId;

    [ForgeOpsTracker traceNamed:@"checkout" block:^(FOTTrace *trace) {
        traceId = trace.traceId;
        [trace measureSpan:@"charge" kind:@"http" block:^{
            XCTAssertEqual([FOTTrace current], trace);
            [ForgeOpsTracker captureException:[NSException exceptionWithName:@"Inside" reason:@"boom" userInfo:nil] context:nil];
        }];
        XCTAssertEqual([FOTTrace current], trace);
    }];
    XCTAssertNil([FOTTrace current]);
    XCTAssertTrue([self waitUntil:^BOOL { return [self requestsToPath:@"/api/v1/events"].count >= 1; } timeout:2.0]);

    [ForgeOpsTracker captureException:[NSException exceptionWithName:@"Outside" reason:@"boom" userInfo:nil] context:nil];
    XCTAssertTrue([self waitUntil:^BOOL { return [self requestsToPath:@"/api/v1/events"].count >= 2; } timeout:2.0]);

    for (NSDictionary *request in [self requestsToPath:@"/api/v1/events"]) {
        NSDictionary *event = [self jsonBodyOf:request];
        if ([event[@"exception_class"] isEqualToString:@"Inside"]) {
            XCTAssertEqualObjects(event[@"trace_id"], traceId);
        } else {
            XCTAssertNil(event[@"trace_id"]);
        }
    }
}

- (void)testTheCurrentTraceIsClearedEvenWhenTheBlockRaises {
    [self configure:nil];

    XCTAssertThrows([ForgeOpsTracker traceNamed:@"boom" block:^(FOTTrace *trace) {
        [trace measureSpan:@"bad" kind:@"service" block:^{
            @throw [NSException exceptionWithName:@"BoomError" reason:@"boom" userInfo:nil];
        }];
    }]);
    XCTAssertNil([FOTTrace current]);
}

@end
