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
            @"iban", @"accountnumber", @"routingnumber", @"bankaccount",
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

// Card numbers in any other shape, and IBANs: see sdks/PII_SCRUBBING.md, which every SDK follows,
// and sdks/pii_scrubbing_vectors.json (a copy is in Tests/Fixtures), which pins the results. Word
// characters and digits are spelled out as ASCII classes: ICU's own \w, \d and \b are
// Unicode-aware, and the rule is ASCII only.
static NSRegularExpression *FOTCompile(NSString *pattern) {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    NSCAssert(regex != nil, @"failed to compile PII pattern %@: %@", pattern, error);
    return regex;
}

static NSRegularExpression *FOTDigitRun(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = FOTCompile(@"(?<![A-Za-z0-9_])[0-9](?:[ -]?[0-9])*(?![A-Za-z0-9_])");
    });
    return regex;
}

static NSRegularExpression *FOTCardPrefixes(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = FOTCompile(@"\\A(?:4|5[1-5]|2(?:22[1-9]|2[3-9][0-9]|[3-6][0-9][0-9]|7[01][0-9]|720)|3[47]|6011|64[4-9]|65|35(?:2[89]|[3-8][0-9])|36|30[0-5]|62)");
    });
    return regex;
}

static NSRegularExpression *FOTIban(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = FOTCompile(@"(?<![A-Za-z0-9_])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9_])");
    });
    return regex;
}

// Every match of regex replaced by transform of its text. Positions are NSString (UTF-16)
// offsets throughout, the same ones NSRegularExpression reports.
static NSString *FOTReplaceMatches(NSRegularExpression *regex, NSString *string, NSString *(^transform)(NSString *)) {
    NSMutableString *output = [NSMutableString stringWithCapacity:string.length];
    __block NSUInteger cursor = 0;
    [regex enumerateMatchesInString:string options:0 range:NSMakeRange(0, string.length) usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        [output appendString:[string substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];
        [output appendString:transform([string substringWithRange:match.range])];
        cursor = NSMaxRange(match.range);
    }];
    [output appendString:[string substringFromIndex:cursor]];
    return output;
}

static BOOL FOTPassesLuhn(NSString *digits) {
    NSInteger sum = 0;
    NSUInteger length = digits.length;
    for (NSUInteger index = 0; index < length; index++) {
        NSInteger value = [digits characterAtIndex:length - 1 - index] - '0';
        if (index % 2 == 1) {
            value *= 2;
            if (value > 9) {
                value -= 9;
            }
        }
        sum += value;
    }
    return sum % 10 == 0;
}

static BOOL FOTIsCardNumber(NSString *digits) {
    return digits.length >= 13 && digits.length <= 19
        && [FOTCardPrefixes() firstMatchInString:digits options:0 range:NSMakeRange(0, digits.length)] != nil
        && FOTPassesLuhn(digits);
}

// From each group of the run on, the longest stretch of whole groups that is a card number is
// replaced, so a card followed by its CVV, two cards in a row, and Amex's 4-6-5 are all found.
static NSString *FOTScrubCardNumbersIn(NSString *run) {
    NSMutableArray<NSString *> *digits = [NSMutableArray array];
    NSMutableArray<NSString *> *separators = [NSMutableArray array];
    NSUInteger start = 0;
    for (NSUInteger index = 0; index < run.length; index++) {
        unichar character = [run characterAtIndex:index];
        if (character == ' ' || character == '-') {
            [digits addObject:[run substringWithRange:NSMakeRange(start, index - start)]];
            [separators addObject:[run substringWithRange:NSMakeRange(index, 1)]];
            start = index + 1;
        }
    }
    [digits addObject:[run substringFromIndex:start]];
    [separators addObject:@""];

    NSMutableString *output = [NSMutableString string];
    NSUInteger i = 0;
    while (i < digits.count) {
        NSInteger found = -1;
        for (NSInteger last = (NSInteger)digits.count - 1; last >= (NSInteger)i; last -= 1) {
            NSArray *stretch = [digits subarrayWithRange:NSMakeRange(i, (NSUInteger)last - i + 1)];
            if (FOTIsCardNumber([stretch componentsJoinedByString:@""])) {
                found = last;
                break;
            }
        }
        if (found >= 0) {
            [output appendString:@"[CREDIT CARD FILTERED]"];
            [output appendString:separators[(NSUInteger)found]];
            i = (NSUInteger)found + 1;
        } else {
            [output appendString:digits[i]];
            [output appendString:separators[i]];
            i++;
        }
    }
    return output;
}

// The IBAN check, a digit at a time: the first four characters moved to the end, letters as two
// digits (A is 10), and the remainder by 97 is 1.
static BOOL FOTIsIban(NSString *candidate) {
    NSString *compact = [candidate stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (compact.length < 15 || compact.length > 34) {
        return NO;
    }

    NSString *rearranged = [[compact substringFromIndex:4] stringByAppendingString:[compact substringToIndex:4]];
    NSInteger remainder = 0;
    for (NSUInteger index = 0; index < rearranged.length; index++) {
        unichar character = [rearranged characterAtIndex:index];
        if (character >= 'A' && character <= 'Z') {
            NSInteger number = character - 55;
            remainder = (remainder * 10 + number / 10) % 97;
            remainder = (remainder * 10 + number % 10) % 97;
        } else {
            remainder = (remainder * 10 + (character - '0')) % 97;
        }
    }
    return remainder == 1;
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
    // IBANs first: a spaced IBAN's middle groups look like a formatted card number.
    NSString *result = FOTReplaceMatches(FOTIban(), string, ^NSString *(NSString *candidate) {
        return FOTIsIban(candidate) ? @"[IBAN FILTERED]" : candidate;
    });
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
    return FOTReplaceMatches(FOTDigitRun(), result, ^NSString *(NSString *run) {
        return FOTScrubCardNumbersIn(run);
    });
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
