#import <Foundation/Foundation.h>
#import "FOTConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * What became of one delivery attempt. Rejected is a 4xx other than 408 and 429: the server will
 * never take this payload, so whoever holds it lets it go instead of sending it again. Failed is
 * everything that may work later (no DSN, a network error, a timeout, a 5xx, 408, 429), so the
 * payload is kept and retried, within the bounds each caller sets.
 */
typedef NS_ENUM(NSInteger, FOTDeliveryOutcome) {
    FOTDeliveryOutcomeDelivered,
    FOTDeliveryOutcomeRejected,
    FOTDeliveryOutcomeFailed,
};

/** The outcome an HTTP status stands for; 0 is no response at all. */
FOUNDATION_EXPORT FOTDeliveryOutcome FOTDeliveryOutcomeForStatus(NSInteger status);

/** @internal Why a payload with this status was let go, for the one log line that says so. */
FOUNDATION_EXPORT NSString *FOTDeliveryDropReasonForStatus(NSInteger status);

/**
 * Delivers one payload over HTTP. Every failure mode: DNS, connection, timeout, a non-2xx
 * response: is caught here and turned into a NO return rather than a thrown exception, since a
 * broken or unreachable tracker must never be able to break the host app. Uses NSURLSession, not
 * a third-party dependency: same reasoning as every other SDK in this repo (see e.g.
 * sdks/node/src/client.js): this has to work in any host app without adding a dependency of its
 * own for something as simple as one POST request.
 *
 * -deliver: is synchronous (blocks the calling thread until the request completes or times out),
 * deliberately: crash report upload here always happens on the *next* app launch (see
 * FOTCrashStore), from a background queue this SDK controls itself, not inline with anything
 * user-facing; there's no live request to avoid blocking the way the other SDKs' async delivery
 * queues exist to protect.
 */
@interface FOTClient : NSObject

- (instancetype)initWithConfiguration:(FOTConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)deliver:(NSDictionary<NSString *, id> *)payload;

/**
 * Same delivery contract as -deliver:, against the DSN's performance_samples endpoint (see
 * FOTConfiguration -performanceSamplesURL). `samples` is wrapped as {"samples": [...]}, the shape
 * Api::V1::PerformanceSamplesController expects.
 */
- (BOOL)deliverPerformanceSamples:(NSArray<NSDictionary<NSString *, id> *> *)samples;

/**
 * Same delivery contract again, against the DSN's custom metrics and infrastructure metrics endpoints
 * (see FOTConfiguration -customMetricsURL). `entries` is wrapped as {"metrics": [...]}, the shape
 * Api::V1::CustomMetricsController and Api::V1::InfrastructureMetricsController expect.
 */
- (BOOL)deliverMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries;
- (BOOL)deliverInfrastructureMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries;

/**
 * Same delivery contract again, against the DSN's spans endpoint (see FOTConfiguration -spansURL).
 * `trace` is sent as-is: {"trace_id": ..., "spans": [...]}, the shape Api::V1::SpansController
 * expects.
 */
- (BOOL)deliverSpans:(NSDictionary<NSString *, id> *)trace;

/**
 * Same delivery contract again, against the DSN's changes endpoint (see FOTConfiguration
 * -changesURL). A 403 (a plan without change tracking) is just a NO like any other rejection.
 */
- (BOOL)deliverChange:(NSDictionary<NSString *, id> *)change;

/**
 * The same requests as -deliver:, -deliverPerformanceSamples:, -deliverMetrics: and
 * -deliverInfrastructureMetrics:, returning the HTTP status instead (0 when there was no response),
 * for the callers inside this SDK that hold on to a payload and so need to know whether a failure
 * is final (see FOTDeliveryOutcomeForStatus), not only that it happened. Never raises.
 */
- (NSInteger)statusOfDelivering:(NSDictionary<NSString *, id> *)payload;
- (NSInteger)statusOfDeliveringPerformanceSamples:(NSArray<NSDictionary<NSString *, id> *> *)samples;
- (NSInteger)statusOfDeliveringMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries;
- (NSInteger)statusOfDeliveringInfrastructureMetrics:(NSArray<NSDictionary<NSString *, id> *> *)entries;

@end

NS_ASSUME_NONNULL_END
