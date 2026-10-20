#import "FOTStrictPrivacy.h"
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger FOTFingerprintLength = 32;
static const NSUInteger FOTMaxPathSegmentLength = 40;

// Explicit ASCII classes and lookarounds throughout, never \d, \w or \b: ICU's versions of those are
// Unicode-aware, and the rule (see FOTStrictPrivacy.h) is ASCII only. NSRegularExpression matches
// over UTF-16 units, which is fine here: no ASCII character is ever half of a surrogate pair.
static NSRegularExpression *FOTRegex(NSString *pattern, NSRegularExpressionOptions options) {
    return [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
}

static NSRegularExpression *FOTHexObjectIdRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@"0x[0-9a-fA-F]{4,}", 0);
    });
    return regex;
}

static NSRegularExpression *FOTUuidRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@"(?<![A-Za-z0-9_])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9_])", 0);
    });
    return regex;
}

static NSRegularExpression *FOTNumberRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@"(?<![A-Za-z0-9_])[0-9]+(?![A-Za-z0-9_])", 0);
    });
    return regex;
}

// Ruby's \s and \S, which are ASCII whitespace only, unlike ICU's.
static NSRegularExpression *FOTHttpMethodRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)[ \\t\\r\\n\\f\\v]+([^ \\t\\r\\n\\f\\v]+)", NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

// Any scheme, any case: "https://", "postgres://", "Grpc+TLS://".
static NSRegularExpression *FOTSchemeRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@"^[a-z][a-z0-9+.-]*://", NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

static NSRegularExpression *FOTPortRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTRegex(@":[0-9]+$", 0);
    });
    return regex;
}

static NSString *FOTReplace(NSRegularExpression *regex, NSString *string, NSString *template) {
    return [regex stringByReplacingMatchesInString:string options:0 range:NSMakeRange(0, string.length) withTemplate:template];
}

static NSString *FOTValidFingerprint(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *fingerprint = [(NSString *)value lowercaseString];
    if (fingerprint.length != FOTFingerprintLength) {
        return nil;
    }
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [fingerprint rangeOfCharacterFromSet:notHex].location == NSNotFound ? fingerprint : nil;
}

static BOOL FOTIsBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

@implementation FOTStrictPrivacy

+ (NSString *)normalizedMessage:(NSString *)message {
    NSString *text = [message isKindOfClass:[NSString class]] ? message : @"";
    text = FOTReplace(FOTHexObjectIdRegex(), text, @"0x");
    text = FOTReplace(FOTUuidRegex(), text, @"<uuid>");
    return FOTReplace(FOTNumberRegex(), text, @"<n>");
}

+ (NSString *)messageFingerprint:(NSString *)message {
    // Lossy so a lone surrogate (invalid UTF-8) still hashes, the way the server replaces it.
    NSData *bytes = [[self normalizedMessage:message] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:FOTFingerprintLength];
    for (NSUInteger i = 0; i < FOTFingerprintLength / 2; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (NSString *)pathWithoutIds:(NSString *)path {
    NSString *text = [path isKindOfClass:[NSString class]] ? path : @"";
    NSRange cut = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
    if (cut.location != NSNotFound) {
        text = [text substringToIndex:cut.location];
    }

    NSMutableArray<NSString *> *segments = [[text componentsSeparatedByString:@"/"] mutableCopy];
    // Ruby's split drops trailing empty segments, so "/" and "/a/" end up as "" and "/a".
    while (segments.count > 0 && segments.lastObject.length == 0) {
        [segments removeLastObject];
    }
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    for (NSUInteger i = 0; i < segments.count; i++) {
        NSString *segment = segments[i];
        // Length in characters (code points), not UTF-16 units, the same as the server counts it.
        NSUInteger length = [segment lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4;
        if ([segment rangeOfCharacterFromSet:digits].location != NSNotFound || length > FOTMaxPathSegmentLength) {
            segments[i] = @":id";
        }
    }
    NSString *joined = [segments componentsJoinedByString:@"/"];
    return joined.length > 0 ? joined : @"/";
}

+ (NSString *)spanName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) {
        return name;
    }
    if ([name hasPrefix:@"/"]) {
        return [self pathWithoutIds:name]; // a span named by a raw path
    }
    NSTextCheckingResult *match = [FOTHttpMethodRegex() firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (match == nil) {
        return name;
    }
    NSString *method = [[name substringWithRange:[match rangeAtIndex:1]] uppercaseString];
    NSString *target = [name substringWithRange:[match rangeAtIndex:2]];
    if ([target hasPrefix:@"/"]) {
        return [NSString stringWithFormat:@"%@ %@", method, [self pathWithoutIds:target]];
    }
    return [NSString stringWithFormat:@"%@ %@", method, [self hostOf:target] ?: [self pathWithoutIds:target]];
}

// Read by hand, never with a URL parser: a parser that rejects an address ("pat<ients") must not
// make the whole address fall through to being sent. Whatever comes before the first "/", "?" or
// "#", without a scheme, credentials or port; a host only when the address had a scheme or a port,
// or the name has a dot or is "localhost". Otherwise (a relative path) nil.
+ (nullable NSString *)hostOf:(NSString *)target {
    NSRange scheme = [FOTSchemeRegex() rangeOfFirstMatchInString:target options:0 range:NSMakeRange(0, target.length)];
    NSString *authority = scheme.location == NSNotFound ? target : [target substringFromIndex:NSMaxRange(scheme)];
    NSRange cut = [authority rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    if (cut.location != NSNotFound) {
        authority = [authority substringToIndex:cut.location];
    }
    NSRange at = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound) {
        authority = [authority substringFromIndex:NSMaxRange(at)];
    }
    NSRange port = [FOTPortRegex() rangeOfFirstMatchInString:authority options:0 range:NSMakeRange(0, authority.length)];
    NSString *host = port.location == NSNotFound ? authority : [authority substringToIndex:port.location];
    if (host.length == 0) {
        return nil;
    }
    BOOL isHost = scheme.location != NSNotFound || port.location != NSNotFound || [host containsString:@"."] ||
        [host caseInsensitiveCompare:@"localhost"] == NSOrderedSame;
    return isHost ? host : nil;
}

+ (id)transactionName:(id)name {
    if (![name isKindOfClass:[NSString class]] || [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return name;
    }
    return [self spanName:name];
}

+ (NSDictionary<NSString *, id> *)allowedFields:(id)fields from:(NSArray<NSString *> *)allowedFields {
    if (allowedFields.count == 0 || ![fields isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary<NSString *, id> *kept = [NSMutableDictionary dictionary];
    for (NSString *key in allowedFields) {
        id value = [(NSDictionary *)fields objectForKey:key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
            kept[key] = value;
        }
    }
    return kept.count > 0 ? kept : nil;
}

+ (NSDictionary<NSString *, id> *)userIdOnly:(id)user {
    if (![user isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id identifier = [(NSDictionary *)user objectForKey:@"id"];
    NSString *string = nil;
    if (FOTIsBoolean(identifier)) {
        string = [identifier boolValue] ? @"true" : nil; // false is blank to the server, as is a missing id
    } else if ([identifier isKindOfClass:[NSNumber class]]) {
        string = [identifier stringValue];
    } else if ([identifier isKindOfClass:[NSString class]]) {
        string = identifier;
    }
    if ([string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return nil;
    }
    return @{ @"id": string };
}

+ (NSDictionary<NSString *, id> *)event:(NSDictionary<NSString *, id> *)payload allowedFields:(NSArray<NSString *> *)allowedFields {
    NSMutableDictionary<NSString *, id> *result = [payload mutableCopy];
    result[@"message_fingerprint"] = FOTValidFingerprint(payload[@"message_fingerprint"]) ?: [self messageFingerprint:payload[@"message"]];
    result[@"message"] = @"";
    [result removeObjectsForKeys:@[ @"breadcrumbs", @"endpoint", @"sql_statement" ]];
    result[@"context"] = [self allowedFields:payload[@"context"] from:allowedFields];
    result[@"tags"] = [self allowedFields:payload[@"tags"] from:allowedFields];
    result[@"user"] = [self userIdOnly:payload[@"user"]];
    result[@"transaction_name"] = [self transactionName:payload[@"transaction_name"]];

    if ([payload[@"backtrace"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *frames = [NSMutableArray array];
        for (id frame in payload[@"backtrace"]) {
            if (![frame isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSMutableDictionary *stripped = [frame mutableCopy];
            [stripped removeObjectsForKeys:@[ @"context_line", @"pre_context", @"post_context" ]];
            [frames addObject:stripped];
        }
        result[@"backtrace"] = frames;
    }
    return result;
}

+ (NSDictionary<NSString *, id> *)failureEvent:(NSDictionary<NSString *, id> *)payload {
    NSMutableDictionary<NSString *, id> *result = [payload mutableCopy];
    [result removeObjectForKey:@"error_message"];
    result[@"transaction_name"] = [self transactionName:payload[@"transaction_name"]];
    return result;
}

+ (NSDictionary<NSString *, id> *)span:(NSDictionary<NSString *, id> *)payload {
    NSMutableDictionary<NSString *, id> *result = [payload mutableCopy];
    result[@"name"] = [self spanName:payload[@"name"]];
    NSMutableDictionary<NSString *, id> *data = [NSMutableDictionary dictionary];
    if ([payload[@"data"] isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[ @"db.statement", @"db.system" ]) {
            data[key] = payload[@"data"][key];
        }
    }
    result[@"data"] = data.count > 0 ? data : nil;
    return result;
}

@end
