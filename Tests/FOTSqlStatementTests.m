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
