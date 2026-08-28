#import "FOTEventBuilder.h"
#import "FOTPiiScrubber.h"

static const NSUInteger FOTMaxFrames = 500;

// e.g. "12  MyApp    0x0000000100abcd12 -[MyClass myMethod] + 82" -- frame index, image name,
// address, symbol, "+ offset". Verified directly against real -callStackSymbols output from a
// real raised-and-caught NSException before relying on this shape, not assumed from Apple's own
// (informal, undocumented) format alone.
static NSRegularExpression *FOTFrameRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d+\\s+(\\S+)\\s+0x[0-9a-fA-F]+\\s+(.+?)\\s+\\+\\s+\\d+\\s*$"
                                                            options:0
                                                              error:nil];
    });
    return regex;
}

@implementation FOTEventBuilder {
    FOTConfiguration *_configuration;
}

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(NSDictionary<NSString *, id> *)context {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; // no fractional seconds, matches every other SDK's payload

    NSMutableDictionary<NSString *, id> *payload = [NSMutableDictionary dictionary];
    payload[@"exception_class"] = exception.name ?: @"NSException";
    payload[@"message"] = exception.reason ?: @"";
    payload[@"backtrace"] = [self backtraceForException:exception];
    payload[@"occurred_at"] = [formatter stringFromDate:[NSDate date]];
    payload[@"environment"] = _configuration.environment;
    payload[@"release"] = _configuration.releaseVersion ?: [NSNull null];
    payload[@"server_name"] = _configuration.serverName ?: [NSNull null];
    payload[@"context"] = context ?: @{};
    payload[@"tags"] = @{};

    return _configuration.scrubPII ? [FOTPiiScrubber scrub:payload key:nil] : payload;
}

- (NSArray<NSDictionary<NSString *, id> *> *)backtraceForException:(NSException *)exception {
    NSMutableArray<NSDictionary<NSString *, id> *> *frames = [NSMutableArray array];
    NSRegularExpression *regex = FOTFrameRegex();

    for (NSString *line in exception.callStackSymbols) {
        if (frames.count >= FOTMaxFrames) {
            break;
        }
        NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (match == nil) {
            continue; // an unparseable line is skipped, not an error -- see PHP's own client for the same philosophy
        }

        NSString *image = [line substringWithRange:[match rangeAtIndex:1]];
        NSString *symbol = [line substringWithRange:[match rangeAtIndex:2]];

        [frames addObject:@{
            @"file": image,
            @"line": [NSNull null], // no line-level info at runtime -- see FOTEventBuilder.h's own header comment
            @"method": symbol,
            @"in_app": @([self isInAppImage:image]),
        }];
    }

    return frames;
}

- (BOOL)isInAppImage:(NSString *)image {
    NSString *executableName = [NSBundle mainBundle].executablePath.lastPathComponent;
    if (executableName == nil) {
        return NO;
    }
    return [image isEqualToString:executableName];
}

@end
