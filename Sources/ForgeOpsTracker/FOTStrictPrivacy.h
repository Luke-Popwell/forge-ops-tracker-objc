#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Strict privacy (FOTConfiguration.strictPrivacy): for apps that can't let personal or health data
 * leave the device. With it on, a payload carries only structured facts about an error (its class,
 * its frames, release, environment, server, trace id, timings), never free text a person could
 * have typed: no message, breadcrumbs, endpoint, SQL statement or source context, only the context
 * and tag keys named in privacyAllowedFields, and the user's id alone. Ported from the server's own
 * app/services/strict_privacy.rb (which applies the same rules again on arrival when the project's
 * Strict privacy setting is on), against sdks/STRICT_PRIVACY.md; sdks/strict_privacy_vectors.json
 * pins the fingerprint, path and span name results byte for byte.
 *
 * "Word character" in every rule below means ASCII [A-Za-z0-9_] only, whatever ICU thinks a word
 * is, so an Arabic-Indic digit or an accented letter next to a number never changes the result.
 */
@interface FOTStrictPrivacy : NSObject

/** The message with hex object ids, UUIDs and standalone ASCII numbers replaced, in that order. */
+ (NSString *)normalizedMessage:(nullable NSString *)message;

/**
 * The first 32 lowercase hex characters of the SHA-256 of the normalized message's UTF-8 bytes. Lets
 * the server group errors without ever seeing the message; nothing about the text can be read back.
 */
+ (NSString *)messageFingerprint:(nullable NSString *)message;

/**
 * A request or page path as strict privacy sends it, with no query or fragment. A route template
 * (any segment that starts with ":" or "*", or is wrapped in {}, <> or []) is kept as it is:
 * "/patients/:id/notes" stays. A raw path keeps only its first segment (":id" when that holds an
 * ASCII digit or is longer than 40 characters), then "/:path" if there was more:
 * "/patients/jane-doe/12" is "/patients/:path", "/42/edit" is "/:id/:path". No segments is "/".
 */
+ (NSString *)strictPath:(nullable NSString *)path;

/** The name +strictPath: had before its rule changed: the same method, kept so existing code still builds. */
+ (NSString *)pathWithoutIds:(nullable NSString *)path;

/**
 * An outbound call's span name with its method and host only: "GET https://api.example.com/x/42" is
 * "GET api.example.com". A target that's a path goes through +strictPath:
 * ("GET /orders/42/items" is "GET /orders/:path", "GET /orders/:id" stays), and so does a name that
 * is itself a path ("/orders/42" is "/orders/:path").
 * Anything else ("OrdersController#create", "SELECT orders") is returned unchanged. The address is
 * read by hand, never by a URL parser: see sdks/STRICT_PRIVACY.md's "Span names" section.
 */
+ (NSString *)spanName:(NSString *)name;

/**
 * A transaction name under strict privacy: a route template or controller action is kept, a raw
 * request path keeps only its first segment, by the same rule as +spanName:. A missing or blank name is returned as it is.
 */
+ (nullable id)transactionName:(nullable id)name;

/**
 * An error event's payload reduced to what strict privacy sends: "message" is "", with
 * "message_fingerprint" computed from it (or kept, if the payload already carries a well formed
 * one, so reducing twice changes nothing); breadcrumbs, endpoint and sql_statement removed; context
 * and tags keep only allowedFields' keys with string, number or boolean values, and are omitted when
 * nothing is left; user is {"id": "<string>"} or omitted; frames lose any source context. Every
 * other key is kept exactly as it was, except transaction_name, which goes through +transactionName:.
 */
+ (NSDictionary<NSString *, id> *)event:(NSDictionary<NSString *, id> *)payload
                          allowedFields:(nullable NSArray<NSString *> *)allowedFields;

/**
 * A background job failure: "error_message" removed, transaction_name through +transactionName:,
 * everything else (error_class included) kept.
 * This client has no job integration of its own; here so a host app's own job reporting, and every
 * SDK in this repo, share one rule.
 */
+ (NSDictionary<NSString *, id> *)failureEvent:(NSDictionary<NSString *, id> *)payload;

/**
 * A trace's span: name through +spanName:, data keeping only db.statement (already masked) and
 * db.system, and omitted when nothing is left.
 */
+ (NSDictionary<NSString *, id> *)span:(NSDictionary<NSString *, id> *)payload;

@end

NS_ASSUME_NONNULL_END
