#import "FOTSqlStatement.h"

NSString *const FOTSqlStatementKey = @"forge_ops_sql";

static const NSUInteger FOTSqlMaxLength = 4000;
static const NSUInteger FOTSqlMaxNames = 10;
static const NSUInteger FOTSqlMaxNameLength = 200;
static const NSUInteger FOTSqlMaxCauseDepth = 5;

static NSRegularExpression *FOTSqlRegex(NSString *pattern, NSRegularExpressionOptions options) {
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:options error:&error];
    NSCAssert(regex != nil, @"invalid SQL pattern %@: %@", pattern, error);
    return regex;
}

static NSRegularExpression *FOTSqlLiteral(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex(@"'(?:[^']|'')*(?:'|\\z)|(\\$[A-Za-z_]*\\$).*?(?:\\1|\\z)|(?<![\\w$.])\\d+(?:\\.\\d+)?(?!\\w)",
                            NSRegularExpressionDotMatchesLineSeparators);
    });
    return regex;
}

static NSString *FOTSqlNamePattern(void) {
    static NSString *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *part = @"(?:[\\w$#@]+|\"[^\"]+\"|\\[[^\\]]+\\]|`[^`]+`)";
        pattern = [NSString stringWithFormat:@"%@(?:\\.%@)*", part, part];
    });
    return pattern;
}

static NSRegularExpression *FOTSqlProcedureCall(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex([NSString stringWithFormat:@"\\b(?:CALL|EXEC(?:UTE)?|PERFORM)\\s+(?!IMMEDIATE\\b|FUNCTION\\b|PROCEDURE\\b)(%@)", FOTSqlNamePattern()],
                            NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

static NSRegularExpression *FOTSqlRelation(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex([NSString stringWithFormat:@"\\b(FROM|JOIN|INTO|UPDATE|TABLE)\\s+(%@)(\\s*\\()?", FOTSqlNamePattern()],
                            NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

static NSRegularExpression *FOTSqlSelectFunction(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex([NSString stringWithFormat:@"\\A\\s*SELECT\\s+(%@)\\s*\\(", FOTSqlNamePattern()], NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

static NSRegularExpression *FOTSqlFromInsideFunction(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex(@"\\b(?:EXTRACT|SUBSTRING|TRIM|OVERLAY)\\s*\\([^()]*\\)", NSRegularExpressionCaseInsensitive);
    });
    return regex;
}

static NSRegularExpression *FOTSqlFullName(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex([NSString stringWithFormat:@"\\A%@\\z", FOTSqlNamePattern()], 0);
    });
    return regex;
}

static NSRegularExpression *FOTSqlSqliteCompiling(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = FOTSqlRegex(@"while compiling:\\s*(.+?)\\s*\\z", NSRegularExpressionDotMatchesLineSeparators);
    });
    return regex;
}

static NSArray<NSString *> *FOTSqlClean(NSArray<NSString *> *names) {
    NSMutableArray<NSString *> *cleaned = [NSMutableArray array];
    for (NSString *raw in names) {
        NSString *name = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length > FOTSqlMaxNameLength) {
            name = [name substringToIndex:FOTSqlMaxNameLength];
        }
        BOOL isFullName = [FOTSqlFullName() firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
        if (isFullName && ![cleaned containsObject:name]) {
            [cleaned addObject:name];
        }
    }
    if (cleaned.count > FOTSqlMaxNames) {
        return [cleaned subarrayWithRange:NSMakeRange(0, FOTSqlMaxNames)];
    }
    return cleaned;
}

static NSString *FOTSqlGroup(NSTextCheckingResult *match, NSUInteger index, NSString *in) {
    NSRange range = [match rangeAtIndex:index];
    return range.location == NSNotFound ? nil : [in substringWithRange:range];
}

@implementation FOTSqlStatement

+ (NSString *)statementInException:(NSException *)exception {
    return [self statementInUserInfo:exception.userInfo reason:exception.reason depth:0];
}

// The exception's userInfo (this key, or the names SQLite wrappers commonly use), a nested
// underlying exception/error, then SQLite's own error text as the last resort.
+ (NSString *)statementInUserInfo:(NSDictionary *)userInfo reason:(NSString *)reason depth:(NSUInteger)depth {
    for (NSString *key in @[FOTSqlStatementKey, @"sql", @"statement", @"query"]) {
        id value = userInfo[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
            return value;
        }
    }

    if (reason.length > 0) {
        NSTextCheckingResult *match = [FOTSqlSqliteCompiling() firstMatchInString:reason options:0 range:NSMakeRange(0, reason.length)];
        NSString *statement = match ? FOTSqlGroup(match, 1, reason) : nil;
        if (statement.length > 0) {
            return statement;
        }
    }

    if (depth < FOTSqlMaxCauseDepth) {
        id underlying = userInfo[NSUnderlyingErrorKey] ?: userInfo[@"NSUnderlyingException"];
        if ([underlying isKindOfClass:[NSError class]]) {
            NSError *error = underlying;
            return [self statementInUserInfo:error.userInfo reason:error.localizedDescription depth:depth + 1];
        }
        if ([underlying isKindOfClass:[NSException class]]) {
            NSException *inner = underlying;
            return [self statementInUserInfo:inner.userInfo reason:inner.reason depth:depth + 1];
        }
    }
    return nil;
}

+ (NSString *)maskedStatement:(NSString *)statement {
    if (![statement isKindOfClass:[NSString class]] ||
        [statement stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return nil;
    }
    NSString *masked = [FOTSqlLiteral() stringByReplacingMatchesInString:statement
                                                                  options:0
                                                                    range:NSMakeRange(0, statement.length)
                                                             withTemplate:@"?"];
    if (masked.length > FOTSqlMaxLength) {
        // Composed-character-safe, so the cut never splits an emoji or other surrogate pair.
        NSRange cut = [masked rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, FOTSqlMaxLength)];
        return [[masked substringWithRange:cut] stringByAppendingString:@"..."];
    }
    return masked;
}

+ (NSDictionary<NSString *, id> *)objectsInMaskedStatement:(NSString *)masked {
    if (![masked isKindOfClass:[NSString class]] ||
        [masked stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        return nil;
    }

    NSString *sql = [FOTSqlFromInsideFunction() stringByReplacingMatchesInString:masked options:0 range:NSMakeRange(0, masked.length) withTemplate:@" "];
    NSRange full = NSMakeRange(0, sql.length);
    NSSet<NSString *> *builtins = [NSSet setWithArray:@[@"count", @"sum", @"min", @"max", @"avg", @"now", @"coalesce", @"nullif", @"lower", @"upper", @"length", @"concat", @"cast", @"date_trunc", @"current_timestamp", @"current_date", @"row_number", @"rank", @"json_build_object", @"json_agg", @"array_agg"]];
    NSSet<NSString *> *keywordsNotNames = [NSSet setWithArray:@[@"select", @"set", @"values", @"where", @"lateral", @"only", @"unnest", @"generate_series"]];

    NSMutableArray<NSString *> *procedures = [NSMutableArray array];
    for (NSTextCheckingResult *match in [FOTSqlProcedureCall() matchesInString:sql options:0 range:full]) {
        [procedures addObject:FOTSqlGroup(match, 1, sql)];
    }

    NSMutableArray<NSString *> *relations = [NSMutableArray array];
    for (NSTextCheckingResult *match in [FOTSqlRelation() matchesInString:sql options:0 range:full]) {
        NSString *keyword = [FOTSqlGroup(match, 1, sql) uppercaseString];
        NSString *name = FOTSqlGroup(match, 2, sql);
        if ([keywordsNotNames containsObject:name.lowercaseString]) {
            continue;
        }
        // FROM/JOIN some_function(...) is a set-returning function (often a stored one), not a
        // table. INSERT INTO t (a, b) is just a column list, so INTO/UPDATE/TABLE never count.
        BOOL functionCall = FOTSqlGroup(match, 3, sql).length > 0 && ([keyword isEqualToString:@"FROM"] || [keyword isEqualToString:@"JOIN"]);
        [(functionCall ? procedures : relations) addObject:name];
    }

    NSTextCheckingResult *select = [FOTSqlSelectFunction() firstMatchInString:sql options:0 range:full];
    if (select != nil) {
        NSString *function = FOTSqlGroup(select, 1, sql);
        BOOL hasFrom = [sql rangeOfString:@"\\bFROM\\b" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound;
        if (![builtins containsObject:function.lowercaseString] && !hasFrom) {
            [procedures addObject:function];
        }
    }

    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    NSRegularExpression *firstWord = FOTSqlRegex(@"\\A\\s*(\\w+)", 0);
    NSTextCheckingResult *first = [firstWord firstMatchInString:sql options:0 range:full];
    NSString *operation = first ? [FOTSqlGroup(first, 1, sql) uppercaseString] : @"";
    NSSet<NSString *> *operations = [NSSet setWithArray:@[@"SELECT", @"INSERT", @"UPDATE", @"DELETE", @"MERGE", @"WITH", @"CALL", @"EXEC", @"EXECUTE", @"CREATE", @"ALTER", @"DROP", @"TRUNCATE"]];
    if ([operations containsObject:operation]) {
        result[@"operation"] = operation;
    }
    result[@"procedures"] = FOTSqlClean(procedures);
    result[@"relations"] = FOTSqlClean(relations);
    if ([result[@"procedures"] count] == 0 && [result[@"relations"] count] == 0 && result[@"operation"] == nil) {
        return nil;
    }
    return result;
}

@end
