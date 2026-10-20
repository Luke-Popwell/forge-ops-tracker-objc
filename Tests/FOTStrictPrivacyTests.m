#import <XCTest/XCTest.h>
#import "FOTBreadcrumbBuffer.h"
#import "FOTConfiguration.h"
#import "FOTCrashStore.h"
#import "FOTEventBuilder.h"
#import "FOTReporter.h"
#import "FOTRequestSpan.h"
#import "FOTStrictPrivacy.h"
#import "FOTTestHTTPServer.h"
#import "FOTTrace.h"

@interface FOTStrictPrivacyTests : XCTestCase
@property (nonatomic, copy) NSString *tempDirectory;
@end

@implementation FOTStrictPrivacyTests

- (void)setUp {
    self.tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDirectory error:nil];
}

// A byte-identical copy of sdks/strict_privacy_vectors.json, found next to this file: `make test`
// compiles it by its path relative to sdks/objc and runs from there, so __FILE__ resolves either way.
- (NSDictionary *)vectors {
    NSString *path = [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Fixtures/strict_privacy_vectors.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(data, @"missing fixture at %@", path);
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
}

- (FOTConfiguration *)strictConfiguration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.releaseVersion = @"abc123";
    config.serverName = @"web-1";
    config.crashReportsDirectory = self.tempDirectory;
    config.captureSqlStatement = YES;
    config.strictPrivacy = YES;
    config.privacyAllowedFields = @[ @"error_code", @"feature", @"nested" ];
    return config;
}

- (NSException *)raiseAndCatch:(NSString *)reason {
    @try {
        @throw [NSException exceptionWithName:@"FOTTestException" reason:reason userInfo:nil];
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

#pragma mark - Shared vectors

- (void)testEveryFingerprintVectorNormalizesAndHashesExactly {
    NSArray *entries = [self vectors][@"fingerprint"];
    XCTAssertGreaterThan(entries.count, 0u);
    for (NSDictionary *entry in entries) {
        XCTAssertEqualObjects([FOTStrictPrivacy normalizedMessage:entry[@"message"]], entry[@"normalized"], @"normalizing %@", entry[@"message"]);
        XCTAssertEqualObjects([FOTStrictPrivacy messageFingerprint:entry[@"message"]], entry[@"fingerprint"], @"fingerprinting %@", entry[@"message"]);
    }
}

- (void)testEveryPathVectorLosesItsIds {
    NSArray *entries = [self vectors][@"path"];
    XCTAssertGreaterThan(entries.count, 0u);
    for (NSDictionary *entry in entries) {
        XCTAssertEqualObjects([FOTStrictPrivacy pathWithoutIds:entry[@"path"]], entry[@"strict"], @"path %@", entry[@"path"]);
    }
}

- (void)testEverySpanNameVectorKeepsOnlyMethodAndHost {
    NSArray *entries = [self vectors][@"span_name"];
    XCTAssertGreaterThan(entries.count, 0u);
    for (NSDictionary *entry in entries) {
        XCTAssertEqualObjects([FOTStrictPrivacy spanName:entry[@"name"]], entry[@"strict"], @"span name %@", entry[@"name"]);
    }
}

- (void)testAnAbsentMessageFingerprintsAsTheEmptyString {
    XCTAssertEqualObjects([FOTStrictPrivacy messageFingerprint:nil], @"e3b0c44298fc1c149afbf4c8996fb924");
}

- (void)testAPathKeepsInteriorEmptySegmentsAndDropsTrailingOnes {
    XCTAssertEqualObjects([FOTStrictPrivacy pathWithoutIds:@"/a/"], @"/a");
    XCTAssertEqualObjects([FOTStrictPrivacy pathWithoutIds:@"/a//b"], @"/a//b");
    XCTAssertEqualObjects([FOTStrictPrivacy pathWithoutIds:@"?q=1"], @"/");
}

- (void)testASpanNameMethodIsUpcasedAndMatchedCaseInsensitively {
    XCTAssertEqualObjects([FOTStrictPrivacy spanName:@"get https://api.example.com/x"], @"GET api.example.com");
    XCTAssertEqualObjects([FOTStrictPrivacy spanName:@"GETTING things"], @"GETTING things");
}

#pragma mark - Configuration

- (void)testStrictPrivacyIsOffWithNoAllowedFieldsByDefault {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];

    XCTAssertFalse(config.strictPrivacy);
    XCTAssertEqualObjects(config.privacyAllowedFields, @[]);
}

#pragma mark - Error events

- (void)testAStrictEventCarriesNoFreeText {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self strictConfiguration]];
    NSException *exception = [self raiseAndCatch:@"Couldn't find Invoice with id=8821"];
    NSArray *crumbs = @[ @{ @"category": @"custom", @"message": @"opened Jane's chart", @"level": @"info", @"timestamp": @"2024-01-15T10:29:58Z", @"data": @{} } ];

    NSDictionary *payload = [builder buildEventForException:exception
                                                       context:@{ @"error_code": @"E42", @"feature": @7, @"nested": @{ @"a": @"b" }, @"patient": @"Jane Doe" }
                                                          user:@{ @"id": @42, @"email": @"ada@example.com", @"username": @"ada" }
                                                   breadcrumbs:crumbs
                                                           sql:@"SELECT * FROM patients WHERE name = 'Jane'"
                                                       traceId:@"0af7651916cd43dd8448eb211c80319c"];

    XCTAssertEqualObjects(payload[@"message"], @"");
    XCTAssertEqualObjects(payload[@"message_fingerprint"], @"b6959809369b97323c7852eaeb67d4ef");
    XCTAssertNil(payload[@"breadcrumbs"]);
    XCTAssertNil(payload[@"endpoint"]);
    XCTAssertNil(payload[@"sql_statement"]);
    XCTAssertEqualObjects(payload[@"sql_objects"][@"relations"], @[ @"patients" ]); // names stay, the statement doesn't
    XCTAssertEqualObjects(payload[@"context"], (@{ @"error_code": @"E42", @"feature": @7 }));
    XCTAssertNil(payload[@"tags"]); // nothing allowed was in it: omitted, not sent empty
    XCTAssertEqualObjects(payload[@"user"], @{ @"id": @"42" });
    XCTAssertEqualObjects(payload[@"exception_class"], @"FOTTestException");
    XCTAssertEqualObjects(payload[@"trace_id"], @"0af7651916cd43dd8448eb211c80319c");
    XCTAssertEqualObjects(payload[@"release"], @"abc123");
    XCTAssertEqualObjects(payload[@"server_name"], @"web-1");
    XCTAssertGreaterThan([payload[@"backtrace"] count], 0u);
    for (NSDictionary *frame in payload[@"backtrace"]) {
        XCTAssertNil(frame[@"context_line"]);
        XCTAssertNil(frame[@"pre_context"]);
        XCTAssertNil(frame[@"post_context"]);
        XCTAssertNotNil(frame[@"method"]);
    }
}

- (void)testTheFingerprintIsOfTheMessageAfterPiiScrubbing {
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:[self strictConfiguration]];

    NSDictionary *payload = [builder buildEventForException:[self raiseAndCatch:@"failed for user@example.com"] context:nil];

    XCTAssertEqualObjects(payload[@"message_fingerprint"], [FOTStrictPrivacy messageFingerprint:@"failed for [EMAIL FILTERED]"]);
}

- (void)testNoAllowedFieldsMeansNoContextAndAUserWithNoIdIsOmitted {
    FOTConfiguration *config = [self strictConfiguration];
    config.privacyAllowedFields = @[];
    FOTEventBuilder *builder = [[FOTEventBuilder alloc] initWithConfiguration:config];

    NSDictionary *payload = [builder buildEventForException:[self raiseAndCatch:@"boom"] context:@{ @"error_code": @"E42" } user:@{ @"email": @"ada@example.com" }];

    XCTAssertNil(payload[@"context"]);
    XCTAssertNil(payload[@"user"]);
    XCTAssertEqualObjects(payload[@"message_fingerprint"], @"81f52337ebb4cb1669bb802c708807dd");
}

- (void)testReducingAnEventDropsEndpointAndSourceContextAndIsIdempotent {
    NSDictionary *raw = @{
        @"exception_class": @"RuntimeError",
        @"message": @"boom",
        @"endpoint": @"/patients/42",
        @"tags": @{ @"feature": @YES, @"email": @"ada@example.com" },
        @"backtrace": @[ @{ @"file": @"app.rb", @"line": @3, @"method": @"x", @"in_app": @YES, @"context_line": @"secret", @"pre_context": @[ @"a" ], @"post_context": @[ @"b" ] } ],
    };

    NSDictionary *once = [FOTStrictPrivacy event:raw allowedFields:@[ @"feature" ]];
    NSDictionary *twice = [FOTStrictPrivacy event:once allowedFields:@[ @"feature" ]];

    XCTAssertNil(once[@"endpoint"]);
    XCTAssertEqualObjects(once[@"tags"], @{ @"feature": @YES });
    XCTAssertEqualObjects(once[@"backtrace"], (@[ @{ @"file": @"app.rb", @"line": @3, @"method": @"x", @"in_app": @YES } ]));
    XCTAssertEqualObjects(once[@"message_fingerprint"], @"81f52337ebb4cb1669bb802c708807dd");
    XCTAssertEqualObjects(twice, once);
}

- (void)testAJobFailureLosesItsErrorMessageButKeepsItsClass {
    NSDictionary *reduced = [FOTStrictPrivacy failureEvent:@{ @"error_class": @"PaymentError", @"error_message": @"card for Jane declined", @"job_class": @"ChargeJob" }];

    XCTAssertEqualObjects(reduced, (@{ @"error_class": @"PaymentError", @"job_class": @"ChargeJob" }));
}

- (void)testATransactionNameKeepsARouteAndLosesARawPathsIds {
    XCTAssertEqualObjects([FOTStrictPrivacy transactionName:@"OrdersController#create"], @"OrdersController#create");
    XCTAssertEqualObjects([FOTStrictPrivacy transactionName:@"GET /users/:id"], @"GET /users/:id");
    XCTAssertEqualObjects([FOTStrictPrivacy transactionName:@"/patients/42"], @"/patients/:id");
    XCTAssertEqualObjects([FOTStrictPrivacy transactionName:@"GET /patients/42/notes"], @"GET /patients/:id/notes");
    XCTAssertEqualObjects([FOTStrictPrivacy transactionName:@""], @"");
    XCTAssertNil([FOTStrictPrivacy transactionName:nil]);
}

- (void)testAnEventAndAJobFailureCarryAReducedTransactionName {
    NSDictionary *route = [FOTStrictPrivacy event:@{ @"message": @"boom", @"transaction_name": @"patients#show" } allowedFields:nil];
    NSDictionary *path = [FOTStrictPrivacy event:@{ @"message": @"boom", @"transaction_name": @"/patients/42" } allowedFields:nil];
    NSDictionary *failure = [FOTStrictPrivacy failureEvent:@{ @"error_class": @"PaymentError", @"error_message": @"x", @"transaction_name": @"/patients/42/charge" }];

    XCTAssertEqualObjects(route[@"transaction_name"], @"patients#show");
    XCTAssertEqualObjects(path[@"transaction_name"], @"/patients/:id");
    XCTAssertEqualObjects(failure, (@{ @"error_class": @"PaymentError", @"transaction_name": @"/patients/:id/charge" }));
}

- (void)testStrictPrivacyOffLeavesTheEventExactlyAsBefore {
    FOTConfiguration *before = [[FOTConfiguration alloc] init];
    before.captureSqlStatement = YES;
    FOTConfiguration *off = [[FOTConfiguration alloc] init];
    off.captureSqlStatement = YES;
    off.strictPrivacy = NO;
    off.privacyAllowedFields = @[ @"error_code" ]; // ignored while strict privacy is off
    NSException *exception = [self raiseAndCatch:@"Couldn't find Invoice with id=8821"];
    NSArray *crumbs = @[ @{ @"category": @"custom", @"message": @"opened", @"level": @"info", @"timestamp": @"2024-01-15T10:29:58Z", @"data": @{} } ];

    NSMutableDictionary *expected = [[[[FOTEventBuilder alloc] initWithConfiguration:before] buildEventForException:exception context:@{ @"patient": @"Jane" } user:@{ @"id": @42, @"email": @"ada@example.com" } breadcrumbs:crumbs sql:@"SELECT * FROM t WHERE a = 1" traceId:nil] mutableCopy];
    NSMutableDictionary *actual = [[[[FOTEventBuilder alloc] initWithConfiguration:off] buildEventForException:exception context:@{ @"patient": @"Jane" } user:@{ @"id": @42, @"email": @"ada@example.com" } breadcrumbs:crumbs sql:@"SELECT * FROM t WHERE a = 1" traceId:nil] mutableCopy];
    [expected removeObjectForKey:@"occurred_at"]; // the clock, not the configuration
    [actual removeObjectForKey:@"occurred_at"];

    XCTAssertEqualObjects(actual, expected);
    XCTAssertEqualObjects(actual[@"message"], @"Couldn't find Invoice with id=8821");
    XCTAssertNil(actual[@"message_fingerprint"]);
    XCTAssertNotNil(actual[@"breadcrumbs"]);
    XCTAssertNotNil(actual[@"sql_statement"]);
    XCTAssertEqualObjects(actual[@"user"][@"email"], @"ada@example.com");
}

#pragma mark - Breadcrumbs and crash reports

- (void)testNoBreadcrumbIsRecordedUnderStrictPrivacy {
    FOTBreadcrumbBuffer *buffer = [[FOTBreadcrumbBuffer alloc] initWithConfiguration:[self strictConfiguration]];

    [buffer addBreadcrumbWithMessage:@"opened Jane's chart" category:@"custom" level:@"info" data:nil];

    XCTAssertEqual([buffer all].count, 0u);
}

- (void)testARawSignalReportIsReducedOnUpload {
    FOTTestHTTPServer *server = [[FOTTestHTTPServer alloc] init];
    [server start];
    [NSThread sleepForTimeInterval:0.05];
    FOTConfiguration *config = [self strictConfiguration];
    config.dsn = [NSString stringWithFormat:@"http://key@127.0.0.1:%lu/api/v1/events", (unsigned long)server.port];
    config.enabledEnvironments = [NSSet setWithObject:@"production"];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"Segmentation fault: 11\n0   libsystem_c.dylib  0x0000000000001 abort + 1\n"
        writeToFile:[self.tempDirectory stringByAppendingPathComponent:@"signal-11-1.txt"]
         atomically:YES
           encoding:NSUTF8StringEncoding
              error:nil];

    [[[FOTReporter alloc] initWithConfiguration:config] uploadPendingReports];
    [server stop];

    XCTAssertEqual(server.requests.count, 1u);
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:[server.requests.lastObject[@"body"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqualObjects(body[@"message"], @"");
    XCTAssertEqualObjects(body[@"message_fingerprint"], [FOTStrictPrivacy messageFingerprint:@"Uncaught fatal signal: Segmentation fault: 11"]);
    XCTAssertEqualObjects(body[@"exception_class"], @"Signal: Segmentation fault: 11");
    XCTAssertNil(body[@"context"]);
    XCTAssertNil(body[@"tags"]);
}

#pragma mark - Spans

- (void)testASpanKeepsOnlyItsStatementAndDatabaseSystem {
    NSDictionary *reduced = [FOTStrictPrivacy span:@{ @"name": @"SELECT orders", @"kind": @"database", @"data": @{ @"db.statement": @"SELECT * FROM orders WHERE id = ?", @"db.system": @"sqlite", @"url": @"https://x" } }];
    NSDictionary *http = [FOTStrictPrivacy span:@{ @"name": @"GET https://api.example.com/patients/42?x=1", @"kind": @"http", @"data": @{ @"status": @200 } }];

    XCTAssertEqualObjects(reduced[@"data"], (@{ @"db.statement": @"SELECT * FROM orders WHERE id = ?", @"db.system": @"sqlite" }));
    XCTAssertEqualObjects(reduced[@"name"], @"SELECT orders");
    XCTAssertEqualObjects(http[@"name"], @"GET api.example.com");
    XCTAssertNil(http[@"data"]);
    XCTAssertEqualObjects(http[@"kind"], @"http");
}

- (void)testAStrictTraceReducesEverySpanIncludingARootNamedByItsPath {
    FOTConfiguration *config = [self strictConfiguration];
    config.traceCaptureThreshold = 0;
    __block NSDictionary *delivered = nil;
    FOTTrace *trace = [[FOTTrace alloc] initWithName:@"GET /patients/42/notes" configuration:config deliver:^(NSDictionary *payload) {
        delivered = payload;
    }];

    FOTRequestSpan *span = [trace startRequestSpan:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://api.example.com/patients/42"]] name:@"GET https://api.example.com/patients/42?q=jane"];
    [span finishWithResponse:[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://api.example.com/"] statusCode:200 HTTPVersion:nil headerFields:nil] error:nil];
    [trace recordSpan:@"SELECT notes" kind:@"database" startedAt:[NSDate date] durationMs:1 data:@{ @"rows": @3 } statement:@"SELECT * FROM notes WHERE patient = 'Jane'" dbSystem:@"SQLite"];
    [trace finish];

    NSArray *spans = delivered[@"spans"];
    XCTAssertEqual(spans.count, 3u);
    XCTAssertEqualObjects(spans[0][@"name"], @"GET /patients/:id/notes");
    XCTAssertEqualObjects(spans[1][@"name"], @"GET api.example.com");
    XCTAssertNil(spans[1][@"data"]);
    XCTAssertEqualObjects(spans[2][@"name"], @"SELECT notes");
    XCTAssertEqualObjects(spans[2][@"data"], (@{ @"db.statement": @"SELECT * FROM notes WHERE patient = ?", @"db.system": @"sqlite" }));
}

- (void)testATraceWithStrictPrivacyOffIsUnchanged {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.traceCaptureThreshold = 0;
    __block NSDictionary *delivered = nil;
    FOTTrace *trace = [[FOTTrace alloc] initWithName:@"GET /patients/42/notes" configuration:config deliver:^(NSDictionary *payload) {
        delivered = payload;
    }];

    [trace recordSpan:@"GET https://api.example.com/patients/42" kind:@"http" startedAt:[NSDate date] durationMs:1 data:@{ @"status": @200 }];
    [trace finish];

    NSArray *spans = delivered[@"spans"];
    XCTAssertEqualObjects(spans[0][@"name"], @"GET /patients/42/notes");
    XCTAssertEqualObjects(spans[1][@"name"], @"GET https://api.example.com/patients/42");
    XCTAssertEqualObjects(spans[1][@"data"], @{ @"status": @200 });
}

@end
