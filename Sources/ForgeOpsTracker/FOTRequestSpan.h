#import <Foundation/Foundation.h>
#import "FOTTrace.h"

NS_ASSUME_NONNULL_BEGIN

/** The W3C trace context request header's name: "traceparent". */
FOUNDATION_EXPORT NSString *const FOTTraceParentHeader;

/**
 * One outgoing HTTP call inside a trace, from -[FOTTrace startRequestSpan:]. Send request (not the
 * one you passed in: this copy carries the traceparent header) and call -finishWithResponse:error:
 * when the call completes, from any thread. The span is recorded as kind http with this span's own
 * id, which is the parent id in the header, so the backend's root span nests under it.
 *
 *   FOTRequestSpan *span = [trace startRequestSpan:request];
 *   [[session dataTaskWithRequest:span.request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
 *       [span finishWithResponse:response error:error];
 *       ...
 *   }] resume];
 *
 * The header is "00-<32 hex trace id>-<16 hex span id>-01", the same shape
 * gems/forge_ops_tracker/lib/forge_ops_tracker/trace_parent.rb builds. The flags are always 01
 * (sampled): whether this trace is sent is only decided when it finishes, long after the header has
 * gone out, so "this may be recorded" is the only honest answer. The backend is free to make its
 * own decision either way.
 */
@interface FOTRequestSpan : NSObject

- (instancetype)init NS_UNAVAILABLE;

/**
 * Nil-safe form of -[FOTTrace startRequestSpan:name:]: with a nil trace (tracing off), request is
 * the one you passed in and finishing records nothing, so code never has to check.
 */
+ (instancetype)startWithRequest:(NSURLRequest *)request trace:(nullable FOTTrace *)trace name:(nullable NSString *)name;

/** The request to send: yours, plus the traceparent header when one was added. */
@property (nonatomic, copy, readonly) NSURLRequest *request;

/** This span's id (16 lowercase hex characters), or nil with no trace. */
@property (nonatomic, copy, readonly, nullable) NSString *spanId;

/**
 * The traceparent value added to request, or nil when none was (no trace, propagation off or not
 * targeted at this host, or the request already carried its own). Useful for a transport that
 * doesn't take an NSURLRequest, such as a WebSocket handshake.
 */
@property (nonatomic, copy, readonly, nullable) NSString *traceparent;

/**
 * Records the span, with the response's status code when it is an NSHTTPURLResponse. Idempotent:
 * only the first call records anything. error is accepted so a completion handler can pass all it
 * got; a failed call is recorded without a status, the same as the Ruby SDK's outbound spans.
 */
- (void)finishWithResponse:(nullable NSURLResponse *)response error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
