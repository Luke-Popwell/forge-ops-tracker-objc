#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FOTRedacted; // "[FILTERED]"

/**
 * Redacts likely-sensitive content out of a payload before it ever leaves the device: the same
 * patterns ForgeOps itself applies again on arrival (defense in depth: this layer keeps the data
 * out of the crash report file on disk and off the wire; the server-side layer is what actually
 * protects the database). Ported from app/services/pii_scrubber.rb: same key list, same 8 regex
 * patterns, same "[LABEL FILTERED]" replacement format, same REDACTED constant. Deliberately does
 * NOT support Project#additional_sensitive_keys: confirmed server-side only (see that file's own
 * header comment: extending the pattern list to arbitrary customer regexes is a ReDoS risk best
 * kept out of every client).
 */
@interface FOTPiiScrubber : NSObject

/**
 * value may be an NSString, NSDictionary, NSArray, or anything else (passed through unchanged).
 * key is the enclosing dictionary key `value` was found under (nil for a bare top-level value or
 * an array element), and is what the key-name check runs against.
 */
+ (id)scrub:(nullable id)value key:(nullable NSString *)key;

+ (NSString *)scrubString:(NSString *)string;

@end

NS_ASSUME_NONNULL_END
