#import "FOTEventBuilder.h"
#import "FOTSqlStatement.h"
#import "FOTPiiScrubber.h"

static const NSUInteger FOTMaxFrames = 500;

// Would be the source-context window size and per-line truncation length (see other SDKs' own
// EventBuilder for the real version of this), if a frame here ever carried a real file+line pair
// to key a disk read off of. It doesn't (see FOTEventBuilder.h's own header comment) so these
// exist unused here purely as a documented placeholder, named consistently with FOTMaxFrames
// above, rather than silently having no trace of the concept at all.
__attribute__((unused)) static const NSUInteger FOTContextLines = 5;
__attribute__((unused)) static const NSUInteger FOTMaxContextLineLength = 500;

// Identifies this client to the server's auto language-detection on the project the event lands
// in (see Project#note_sdk_platform server-side); matches this repo's own sdks/objc directory
// name, the same convention every other language's client follows.
static NSString *const FOTSdkName = @"objc";

// e.g. "12  MyApp    0x0000000100abcd12 -[MyClass myMethod] + 82": frame index, image name,
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
    return [self buildEventForException:exception context:context user:nil];
}

- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(NSDictionary<NSString *, id> *)context
                                                      user:(NSDictionary<NSString *, id> *)user {
    return [self buildEventForException:exception context:context user:user breadcrumbs:nil];
}

- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(NSDictionary<NSString *, id> *)context
                                                      user:(NSDictionary<NSString *, id> *)user
                                               breadcrumbs:(NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs {
    return [self buildEventForException:exception context:context user:user breadcrumbs:breadcrumbs sql:nil];
}

- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(NSDictionary<NSString *, id> *)context
                                                      user:(NSDictionary<NSString *, id> *)user
                                               breadcrumbs:(NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs
                                                       sql:(NSString *)sql {
    return [self buildEventForException:exception context:context user:user breadcrumbs:breadcrumbs sql:sql traceId:nil];
}

- (NSDictionary<NSString *, id> *)buildEventForException:(NSException *)exception
                                                   context:(NSDictionary<NSString *, id> *)context
                                                      user:(NSDictionary<NSString *, id> *)user
                                               breadcrumbs:(NSArray<NSDictionary<NSString *, id> *> *)breadcrumbs
                                                       sql:(NSString *)sql
                                                   traceId:(NSString *)traceId {
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
    payload[@"sdk_name"] = FOTSdkName;
    if (breadcrumbs.count > 0) {
        payload[@"breadcrumbs"] = breadcrumbs;
    }

    // See FOTSqlStatement.h. The statement itself only goes out when captureSqlStatement is on; the
    // extracted names go out on their own (captureSqlObjects) so an issue can still name the
    // procedure or view involved. Scrubbed with everything else below, like every other field.
    if (_configuration.captureSqlObjects || _configuration.captureSqlStatement) {
        NSString *masked = [FOTSqlStatement maskedStatement:sql ?: [FOTSqlStatement statementInException:exception]];
        if (masked != nil) {
            NSDictionary<NSString *, id> *objects = _configuration.captureSqlObjects ? [FOTSqlStatement objectsInMaskedStatement:masked] : nil;
            if (objects != nil) {
                payload[@"sql_objects"] = objects;
            }
            if (_configuration.captureSqlStatement) {
                payload[@"sql_statement"] = masked;
            }
        }
    }

    NSDictionary<NSString *, id> *scrubbed = _configuration.scrubPII ? [FOTPiiScrubber scrub:payload key:nil] : payload;

    // Merged in after scrubbing, never before: see this method's own header comment on why. The
    // trace id likewise: a structured id, exempt from scrubbing like every SDK's trace_id.
    if (user.count > 0 || traceId != nil) {
        NSMutableDictionary<NSString *, id> *withExtras = [scrubbed mutableCopy];
        if (user.count > 0) {
            withExtras[@"user"] = user;
        }
        if (traceId != nil) {
            withExtras[@"trace_id"] = traceId;
        }
        return withExtras;
    }
    return scrubbed;
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
            continue; // an unparseable line is skipped, not an error: see PHP's own client for the same philosophy
        }

        NSString *image = [line substringWithRange:[match rangeAtIndex:1]];
        NSString *symbol = [line substringWithRange:[match rangeAtIndex:2]];

        NSDictionary<NSString *, id> *frame = @{
            @"file": image,
            @"line": [NSNull null], // no line-level info at runtime: see FOTEventBuilder.h's own header comment
            @"method": symbol,
            @"in_app": @([self isInAppImage:image]),
        };
        [frames addObject:[self attachSourceContextToFrame:frame]];
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

// Deliberately a no-op: see FOTEventBuilder.h's own header comment. The gating logic every other
// SDK applies here is: the config option is on, AND the frame is in-app, AND a real file path +
// line number is actually available. The third condition can never be true on this SDK's own
// capture path: callStackSymbols gives a binary image name and a resolved symbol, never a source
// file or a line number (frame[@"line"] above is always [NSNull null]): so there is nothing
// _configuration.captureSourceContext could ever gate here even though it exists (see
// FOTConfiguration.h's own comment) for API-shape consistency with every other SDK. No disk read is
// ever attempted, regardless of what that flag is set to.
- (NSDictionary<NSString *, id> *)attachSourceContextToFrame:(NSDictionary<NSString *, id> *)frame {
    return frame;
}

@end
