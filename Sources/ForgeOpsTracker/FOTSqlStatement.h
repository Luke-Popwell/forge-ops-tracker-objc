#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The key an NSException's userInfo (or an NSError's) can carry the failing SQL statement under, so
 * the code that ran the query can attach it where everything downstream finds it with no extra
 * call:
 *
 *     @throw [NSException exceptionWithName:@"DatabaseError" reason:error.localizedDescription
 *                                  userInfo:@{ FOTSqlStatementKey: query }];
 *
 * Or report an exception you already have, with the statement, via
 * +[ForgeOpsTracker captureException:sql:context:].
 */
extern NSString *const FOTSqlStatementKey;

/**
 * Finds the SQL behind a database error and reduces it to something safe to send: the names of the
 * stored procedures, tables and views it touched, and (only if FOTConfiguration.captureSqlStatement
 * is on) the statement itself with every string and number replaced by "?". Ported from
 * gems/forge_ops_tracker's SqlStatement, which is itself ported from the server's own
 * SqlStatementMasker/SqlObjectExtractor: same rules everywhere, and the server applies them again
 * on arrival, so a difference here can only ever mean less is masked client-side, never that
 * something unmasked gets stored.
 *
 * Deliberately a single pass over a few patterns, not a SQL parser. On Apple platforms the SQL comes
 * from a local SQLite database, so beyond FOTSqlStatementKey the only source is SQLite's own error
 * text (`while compiling: ...`); Core Data exposes no statement at all.
 */
@interface FOTSqlStatement : NSObject

/** The raw statement carried by `exception` (its userInfo, a nested underlying error, or SQLite's
 * `while compiling:` text), or nil when it carries none. */
+ (nullable NSString *)statementInException:(NSException *)exception;

/** Replaces every string literal and number with "?", truncated to 4000 characters; nil for a
 * blank statement. */
+ (nullable NSString *)maskedStatement:(nullable NSString *)statement;

/** Takes an already-masked statement and returns @{@"operation": ..., @"procedures": @[...],
 * @"relations": @[...]}, or nil when nothing recognizable was found. A view and a table are
 * written the same way in SQL text, so both land in relations. */
+ (nullable NSDictionary<NSString *, id> *)objectsInMaskedStatement:(nullable NSString *)masked;

@end

NS_ASSUME_NONNULL_END
