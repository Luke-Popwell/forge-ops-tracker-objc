#import "FOTPiiScrubber.h"

NSString *const FOTRedacted = @"[FILTERED]";

static NSArray<NSString *> *FOTSensitiveKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"password", @"passwd", @"pwd",
            @"secret", @"apisecret", @"clientsecret", @"secretkey",
            @"token", @"accesstoken", @"refreshtoken", @"apikey", @"apitoken", @"authorization", @"authtoken", @"bearer", @"sessiontoken", @"csrftoken",
            @"creditcard", @"cardnumber", @"cardnum", @"cvv", @"cvv2", @"cvc",
            @"ssn", @"socialsecuritynumber", @"socialsecurity",
            @"privatekey",
        ];
    });
    return keys;
}

// label -> compiled NSRegularExpression, built once. NSRegularExpression uses ICU regex syntax,
// which accepts every one of these 8 patterns unmodified from app/services/pii_scrubber.rb's own
// Ruby syntax: verified directly against real matching input for each (see FOTPiiScrubberTests),
// not assumed to translate cleanly just because the syntax looks the same.
static NSArray<NSArray *> *FOTPatterns(void) {
    static NSArray<NSArray *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSArray *> *built = [NSMutableArray array];

        // error is declared fresh inside this inner block, not captured from the outer one:
        // taking &error on a variable a block captures by value (not marked __block) doesn't
        // give ARC the ownership qualifier an NSError** out-parameter needs, confirmed directly
        // as a real build error, not a hypothetical.
        void (^add)(NSString *, NSString *, NSRegularExpressionOptions) = ^(NSString *label, NSString *pattern, NSRegularExpressionOptions options) {
            NSError *error = nil;
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:&error];
            NSCAssert(regex != nil, @"failed to compile PII pattern %@: %@", label, error);
            [built addObject:@[ label, regex ]];
        };

        add(@"EMAIL", @"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", 0);
        add(@"SSN", @"\\b\\d{3}-\\d{2}-\\d{4}\\b", 0);
        add(@"CREDIT CARD", @"\\b\\d{4}[ -]\\d{4}[ -]\\d{4}[ -]\\d{1,4}\\b", 0);
        add(@"BEARER TOKEN", @"\\bBearer\\s+[A-Za-z0-9\\-._~+/]+=*", NSRegularExpressionCaseInsensitive);
        add(@"JWT", @"\\bey[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", 0);
        add(@"AWS KEY", @"\\bAKIA[0-9A-Z]{16}\\b", 0);
        add(@"STRIPE KEY", @"\\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}\\b", 0);
        add(@"GITHUB TOKEN", @"\\bgh[pousr]_[A-Za-z0-9]{20,}\\b", 0);

        patterns = built;
    });
    return patterns;
}

@implementation FOTPiiScrubber

+ (id)scrub:(id)value key:(NSString *)key {
    if ([self isSensitiveKey:key] && value != nil) {
        return FOTRedacted;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        NSMutableDictionary *scrubbed = [NSMutableDictionary dictionaryWithCapacity:dict.count];
        [dict enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *stringKey = [k isKindOfClass:[NSString class]] ? k : [k description];
            scrubbed[k] = [self scrub:v key:stringKey];
        }];
        return scrubbed;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        NSMutableArray *scrubbed = [NSMutableArray arrayWithCapacity:array.count];
        for (id element in array) {
            [scrubbed addObject:[self scrub:element key:key]];
        }
        return scrubbed;
    }

    if ([value isKindOfClass:[NSString class]]) {
        return [self scrubString:(NSString *)value];
    }

    return value;
}

+ (NSString *)scrubString:(NSString *)string {
    NSString *result = string;
    for (NSArray *pair in FOTPatterns()) {
        NSString *label = pair[0];
        NSRegularExpression *regex = pair[1];
        NSString *replacement = [NSString stringWithFormat:@"[%@ FILTERED]", label];
        // NSRegularExpression's replacement templates treat "$" specially: escape any literal
        // "$" in the label (none of the 8 labels here contain one, but this is future-proofing,
        // not something this specific input could ever actually need).
        NSString *template = [NSRegularExpression escapedTemplateForString:replacement];
        result = [regex stringByReplacingMatchesInString:result
                                                   options:0
                                                     range:NSMakeRange(0, result.length)
                                              withTemplate:template];
    }
    return result;
}

+ (BOOL)isSensitiveKey:(NSString *)key {
    if (key.length == 0) {
        return NO;
    }
    NSMutableString *normalized = [key.lowercaseString mutableCopy];
    static NSRegularExpression *nonAlnum;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nonAlnum = [NSRegularExpression regularExpressionWithPattern:@"[^a-z0-9]" options:0 error:nil];
    });
    [nonAlnum replaceMatchesInString:normalized options:0 range:NSMakeRange(0, normalized.length) withTemplate:@""];

    for (NSString *sensitive in FOTSensitiveKeys()) {
        if ([normalized rangeOfString:sensitive].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

@end
