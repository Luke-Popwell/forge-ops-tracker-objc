#import <XCTest/XCTest.h>
#import <signal.h>
#import "FOTSignalHandler.h"

@interface FOTSignalHandlerTests : XCTestCase
@end

@implementation FOTSignalHandlerTests

// Actually raising SIGABRT/SIGSEGV/etc. to test the handler's own body would crash this test
// process: the same reason every real crash reporter's signal path is validated by manual
// crash testing, not a unit test (see FOTSignalHandler.h's own class comment). What's tested here
// instead: that installation itself succeeds and genuinely registers a handler via sigaction,
// confirmed directly by reading the disposition back, not just asserting no exception was thrown.
- (void)testInstallingRegistersARealHandlerForFatalSignals {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [FOTSignalHandler installSignalHandlersInDirectory:dir];

    struct sigaction current;
    sigaction(SIGABRT, NULL, &current);
    XCTAssertNotEqual((void *)current.sa_handler, (void *)SIG_DFL);
    XCTAssertNotEqual((void *)current.sa_handler, (void *)SIG_IGN);

    sigaction(SIGSEGV, NULL, &current);
    XCTAssertNotEqual((void *)current.sa_handler, (void *)SIG_DFL);

    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

- (void)testParseRawSignalReportParsesTheSignalNameAndBacktraceLines {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"signal-6-123.txt"];
    NSString *contents = @"Abort trap\n0   MyApp    0x0000000100abcd12 -[MyClass crash] + 12\n1   MyApp    0x0000000100abce01 main + 45\n";
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSDictionary *event = [FOTSignalHandler parseRawSignalReportAtURL:[NSURL fileURLWithPath:path]];

    XCTAssertEqualObjects(event[@"exception_class"], @"Signal: Abort trap");
    NSArray *backtrace = event[@"backtrace"];
    XCTAssertEqual(backtrace.count, (NSUInteger)2);
    XCTAssertEqualObjects(backtrace[0][@"method"], @"0   MyApp    0x0000000100abcd12 -[MyClass crash] + 12");
    XCTAssertEqualObjects(backtrace[0][@"file"], [NSNull null]);

    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

@end
