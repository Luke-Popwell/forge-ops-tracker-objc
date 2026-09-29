#import <XCTest/XCTest.h>
#import "FOTConfiguration.h"
#import "FOTEventBuilder.h"
#import "FOTSqlStatement.h"

@interface FOTSqlStatementTests : XCTestCase
@end

@implementation FOTSqlStatementTests

- (FOTConfiguration *)configuration {
    FOTConfiguration *config = [[FOTConfiguration alloc] init];
    config.environment = @"production";
    return config;
}

- (NSException *)exceptionWithSQL:(NSString *)sql {
    return [NSException exceptionWithName:@"DatabaseError" reason:@"boom" userInfo:sql ? @{ FOTSqlStatementKey: sql } : nil];
}

- (void)testFindsTheStatementInUserInfoAnUnderlyingErrorAndSqliteText {
    XCTAssertEqualObjects([FOTSqlStatement statementInException:[self exceptionWithSQL:@"SELECT 1"]], @"SELECT 1");

    NSError *inner = [NSError errorWithDomain:@"db" code:1 userInfo:@{ @"sql": @"CALL x(1)" }];
    NSException *wrapped = [NSException exceptionWithName:@"Outer" reason:@"failed" userInfo:@{ NSUnderlyingErrorKey: inner }];
    XCTAssertEqualObjects([FOTSqlStatement statementInException:wrapped], @"CALL x(1)");

    NSException *sqlite = [NSException exceptionWithName:@"Sqlite" reason:@"no such table: t (code 1 SQLITE_ERROR): , while compiling: SELECT * FROM t" userInfo:nil];
    XCTAssertEqualObjects([FOTSqlStatement statementInException:sqlite], @"SELECT * FROM t");

    XCTAssertNil([FOTSqlStatement statementInException:[self exceptionWithSQL:nil]]);
    XCTAssertNil([FOTSqlStatement statementInException:[self exceptionWithSQL:@"  "]]);
}

- (void)testMasksStringsAndNumbersButNotIdentifiersOrPlaceholders {
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"SELECT * FROM orders2 WHERE email = 'a@b.co' AND id = 42 AND x = $1"],
                          @"SELECT * FROM orders2 WHERE email = ? AND id = ? AND x = $1");
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"SELECT price * 1.5 FROM t WHERE a IN (1,2,3)"], @"SELECT price * ? FROM t WHERE a IN (?,?,?)");
}

- (void)testMasksAnEscapedQuoteACutOffStringAndADollarQuotedBody {
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"EXEC sp_x @t = 'it''s'"], @"EXEC sp_x @t = ?");
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"SELECT 1 WHERE n = 'oops"], @"SELECT ? WHERE n = ?");
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"DO $b$ BEGIN PERFORM 1; END $b$"], @"DO ?");
}

- (void)testIsIdempotentTruncatesAndReturnsNilForBlank {
    NSString *once = [FOTSqlStatement maskedStatement:@"SELECT * FROM t WHERE a = 'x' AND b = 9"];
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:once], once);
    NSString *longSql = [@"SELECT " stringByAppendingString:[[@"" stringByPaddingToLength:9000 withString:@"a, " startingAtIndex:0] stringByAppendingString:@" b"]];
    XCTAssertEqual([FOTSqlStatement maskedStatement:longSql].length, (NSUInteger)4003);
    XCTAssertNil([FOTSqlStatement maskedStatement:@"  "]);
    XCTAssertNil([FOTSqlStatement maskedStatement:nil]);
}

// The shared masking corpus: the same cases, with the same expected output, are checked in every
// SDK and against the server's SqlStatementMasker. Each case is input, system (NSNull for none),
// expected.
static NSArray<NSArray *> *FOTSqlMaskCorpus(void) {
    return @[
        @[@"SELECT * FROM orders WHERE email = 'a@b.co' AND id = 42 LIMIT 10", [NSNull null], @"SELECT * FROM orders WHERE email = ? AND id = ? LIMIT ?"],
        @[@"EXEC sp_note @text = 'it''s broken'", [NSNull null], @"EXEC sp_note @text = ?"],
        @[@"SELECT 1 WHERE name = 'unterminated", [NSNull null], @"SELECT ? WHERE name = ?"],
        @[@"DO $body$ BEGIN PERFORM 1; END $body$", [NSNull null], @"DO ?"],
        @[@"SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)", [NSNull null], @"SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)"],
        @[@"SELECT price * 1.5 FROM t", [NSNull null], @"SELECT price * ? FROM t"],
        @[@"SELECT * FROM users WHERE name = E'o\\'brien' AND id = 1", [NSNull null], @"SELECT * FROM users WHERE name = ? AND id = ?"],
        @[@"SELECT * FROM users WHERE name = 'o\\'brien' AND id = 1", [NSNull null], @"SELECT * FROM users WHERE name = ? AND id = ?"],
        @[@"SELECT * FROM t WHERE b = X'DEADBEEF' AND s = N'uni' AND u = U&'d\\0061t' AND e = e'x'", [NSNull null], @"SELECT * FROM t WHERE b = ? AND s = ? AND u = ? AND e = ?"],
        @[@"SELECT * FROM t WHERE a LIKE'%secret%'", [NSNull null], @"SELECT * FROM t WHERE a LIKE?"],
        @[@"SELECT * FROM t WHERE f = 0x1F AND b = 0b101 AND n = 3e10 AND m = 1.5E-3 AND k = .5", [NSNull null], @"SELECT * FROM t WHERE f = ? AND b = ? AND n = ? AND m = ? AND k = ?"],
        @[@"SELECT e, t.col, 1e5e FROM t", [NSNull null], @"SELECT e, t.col, 1e5e FROM t"],
        @[@"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", @"mysql", @"SELECT ? FROM t WHERE token = ?"],
        @[@"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", @"MariaDB", @"SELECT ? FROM t WHERE token = ?"],
        @[@"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", @"postgresql", @"SELECT \"user id\" FROM t WHERE token = \"abc123secret\""],
        @[@"SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", [NSNull null], @"SELECT \"user id\" FROM t WHERE token = \"abc123secret\""],
        @[@"SELECT * FROM t WHERE a = 'x' AND b = 9", [NSNull null], @"SELECT * FROM t WHERE a = ? AND b = ?"],
        @[@"SELECT * FROM t WHERE a = ? AND b = ?", [NSNull null], @"SELECT * FROM t WHERE a = ? AND b = ?"],
        @[@"SELECT * FROM t WHERE path = 'C:\\\\dir\\\\' AND n = 5", [NSNull null], @"SELECT * FROM t WHERE path = ? AND n = ?"],
        @[@"INSERT INTO t (a, b) VALUES (-5, +3.25e+2)", [NSNull null], @"INSERT INTO t (a, b) VALUES (-?, +?)"],
        @[@"SELECT * FROM t WHERE a = 'secret\\", [NSNull null], @"SELECT * FROM t WHERE a = ?"],
        @[@"SELECT * FROM t WHERE a = \"secret\\", @"mysql", @"SELECT * FROM t WHERE a = ?"],
    ];
}

- (void)testMasksTheSharedCorpusExactlyLikeTheServer {
    for (NSArray *testCase in FOTSqlMaskCorpus()) {
        NSString *input = testCase[0];
        NSString *system = testCase[1] == [NSNull null] ? nil : testCase[1];
        NSString *expected = testCase[2];
        XCTAssertEqualObjects([FOTSqlStatement maskedStatement:input system:system], expected, @"%@ (%@)", input, system);
        XCTAssertEqualObjects([FOTSqlStatement maskedStatement:expected system:system], expected, @"%@ (%@)", expected, system);
    }
}

- (void)testMaskedStatementWithoutASystemLeavesDoubleQuotesAlone {
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"SELECT \"a\" FROM t"], @"SELECT \"a\" FROM t");
    XCTAssertEqualObjects([FOTSqlStatement maskedStatement:@"SELECT \"a\" FROM t" system:@"MYSQL"], @"SELECT ? FROM t");
    XCTAssertNil([FOTSqlStatement maskedStatement:@" " system:@"mysql"]);
}

- (void)testFindsAStoredProcedureWithItsSchema {
    NSDictionary *found = [FOTSqlStatement objectsInMaskedStatement:@"EXEC dbo.sp_refund_order @id = ?"];
    XCTAssertEqualObjects(found, (@{ @"operation": @"EXEC", @"procedures": @[@"dbo.sp_refund_order"], @"relations": @[] }));
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"CALL refund_order(?, ?)"][@"procedures"], @[@"refund_order"]);
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"SELECT refund_order(?, ?)"][@"procedures"], @[@"refund_order"]);
}

- (void)testFindsViewsJoinedTablesAndTableFunctions {
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"SELECT * FROM v_totals t JOIN public.customers c ON c.id = t.id"][@"relations"],
                          (@[@"v_totals", @"public.customers"]));
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"SELECT * FROM get_open_orders(?) o"][@"procedures"], @[@"get_open_orders"]);
}

- (void)testDoesNotMisreadColumnListsBuiltinsOrFromInsideExtractAndReturnsNilForGarbage {
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"INSERT INTO audit_log (a) VALUES (?)"][@"procedures"], @[]);
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"SELECT count(*) FROM orders"][@"procedures"], @[]);
    XCTAssertEqualObjects([FOTSqlStatement objectsInMaskedStatement:@"SELECT 1 FROM orders WHERE extract(year FROM created_at) = ?"][@"relations"], @[@"orders"]);
    XCTAssertNil([FOTSqlStatement objectsInMaskedStatement:@"garbage"]);
}

- (void)testEventBuilderSendsTheProcedureNameByDefaultAndTheStatementOnlyWhenOptedIn {
    NSString *sql = @"EXEC dbo.sp_refund_order @order_id = 8814, @note = 'a@b.co'";
    FOTConfiguration *config = [self configuration];
    NSException *error = [self exceptionWithSQL:sql];

    NSDictionary *payload = [[[FOTEventBuilder alloc] initWithConfiguration:config] buildEventForException:error context:nil];
    XCTAssertEqualObjects(payload[@"sql_objects"][@"procedures"], @[@"dbo.sp_refund_order"]);
    XCTAssertNil(payload[@"sql_statement"]);

    config.captureSqlStatement = YES;
    payload = [[[FOTEventBuilder alloc] initWithConfiguration:config] buildEventForException:[self exceptionWithSQL:nil] context:nil user:nil breadcrumbs:nil sql:sql];
    XCTAssertEqualObjects(payload[@"sql_statement"], @"EXEC dbo.sp_refund_order @order_id = ?, @note = ?");

    config.captureSqlObjects = NO;
    config.captureSqlStatement = NO;
    payload = [[[FOTEventBuilder alloc] initWithConfiguration:config] buildEventForException:error context:nil];
    XCTAssertNil(payload[@"sql_objects"]);
    XCTAssertNil(payload[@"sql_statement"]);

    payload = [[[FOTEventBuilder alloc] initWithConfiguration:[self configuration]] buildEventForException:[self exceptionWithSQL:nil] context:nil];
    XCTAssertNil(payload[@"sql_objects"]);
}

@end
