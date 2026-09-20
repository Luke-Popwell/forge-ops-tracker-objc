# ForgeOpsTracker (Objective-C)

Objective-C crash reporting client for a [ForgeOps](../../) instance. Real-world Objective-C
today is overwhelmingly iOS/macOS app code, not a web backend, so there's no server-side
request-exception path for this SDK to hook into. This SDK is instead a
genuine **crash reporter**: it captures what would otherwise crash the app (an uncaught
`NSException`, or a fatal signal like `SIGSEGV`), and uploads it: not live, but on the *next* app
launch. See "Delivery model" below for why that's a deliberate design choice, not a limitation to
work around.

## Installation

Not yet packaged for CocoaPods/Swift Package Manager: no podspec or package manifest exists yet,
so there's no single dependency declaration to point at. Clone or vendor the source directly
instead:

```
git clone https://github.com/Luke-Popwell/forge-ops-tracker-objc.git
```

That's a mirror, kept in sync automatically from `sdks/objc` in the main `forge_ops` repo (which is
private, so isn't itself something a consumer could ever clone directly): develop against that
repo, not this one. Once cloned, add the files under
[`Sources/ForgeOpsTracker/`](Sources/ForgeOpsTracker/) directly to your Xcode project (or a local
Swift package target).

## Configuration

```objc
#import <ForgeOpsTracker/ForgeOpsTracker.h>

[ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
    config.dsn = @"https://<api_key>@getforgeops.net/api/v1/events";
    config.environment = @"production";
    config.releaseVersion = @"1.4.0"; // named releaseVersion, not release: see FOTConfiguration.h
}];
[ForgeOpsTracker installHandlers];
```

Call this as early as possible in app startup (`application:didFinishLaunchingWithOptions:`, or
your SwiftUI `App`'s `init`). `installHandlers` does two things: installs the uncaught-exception
and fatal-signal handlers described below, and kicks off an upload (on a background queue) of any
crash report left over from the *previous* launch.

## What gets captured automatically

- **An uncaught `NSException`**: via `NSSetUncaughtExceptionHandler`. Any previously-installed
  handler (another crash reporter, a debugger) is chained to afterward, not replaced.
- **A fatal signal** (`SIGABRT`, `SIGILL`, `SIGSEGV`, `SIGFPE`, `SIGBUS`, `SIGTRAP`): via
  `sigaction`. See [`FOTSignalHandler.h`](Sources/ForgeOpsTracker/FOTSignalHandler.h)'s own
  comment for exactly what this can and can't safely do from inside a real signal handler (POSIX
  only guarantees a small set of functions are safe to call there at all); the short version is
  that it writes a raw backtrace to disk using only `backtrace_symbols_fd()` and `write()`, then
  re-raises the same signal so the OS's own default crash behavior (a real crash log, a possible
  core dump) still happens exactly as if this SDK weren't installed.

**An exception your own code catches and handles**: report it explicitly:

```objc
@try {
    [self riskyOperation];
} @catch (NSException *exception) {
    [ForgeOpsTracker captureException:exception context:@{ @"orderId": order.identifier }];
}
```

## Identifying users

```objc
[ForgeOpsTracker captureException:exception context:nil user:@{ @"id": user.identifier, @"email": user.email }];
```

Or `+setUser:` to attach it to every subsequently reported error (an explicit `captureException:`
call, an uncaught `NSException`, a fatal signal) until changed or cleared, rather than passing it
to every call by hand, e.g. right after sign-in:

```objc
[ForgeOpsTracker setUser:@{ @"id": user.identifier, @"email": user.email }];
// on sign-out:
[ForgeOpsTracker setUser:nil];
```

There's no way to automatically detect "the current user" on iOS/macOS, so this is manual either
way. A mobile app install is effectively single-user (unlike a server handling many concurrent
requests at once), so this is a plain class-level property, not thread-local storage. A
fatal-signal crash report is filled in with whoever is "current" at *upload* time (the next
launch), not necessarily who was signed in the moment it actually crashed: the signal handler
itself can never safely read this (see `FOTSignalHandler.h`'s own header comment on what's safe to
touch there), the same "best effort, filled in later" treatment that crash report's
environment/release/server_name already get. `id`/`email`/`username` are all independently
optional. Shows up on an issue's own detail page, and as its own affected-users count alongside the
regular event count.

## Breadcrumbs

A small, bounded trail of recent events attached to whatever gets reported next, so an issue's
detail page can show what led up to it, not just the moment it happened:

```objc
[ForgeOpsTracker addBreadcrumb:@"charging card" category:@"payment" level:@"info" data:@{ @"orderId": order.identifier }];
[ForgeOpsTracker addBreadcrumb:@"opened checkout"]; // category @"custom", level @"info"
```

Only the 30 most recent (`FOTConfiguration.maxBreadcrumbs`) are kept, oldest dropped first; turn it
off with `trackBreadcrumbs = NO`. Safe to call from any thread. `message` and `data` are PII-scrubbed
like the rest of the payload, and the whole trail is omitted from the payload when empty.

There's no request/controller lifecycle in a crash reporter to record one from automatically, so
every breadcrumb is one you add by hand. A mobile app is effectively single-flow, so there is one
shared trail (like `setUser:`'s one shared user); call `[ForgeOpsTracker clearBreadcrumbs]` to start
a new logical unit of work (a new sign-in session, say) with a fresh one.

**A fatal signal keeps its breadcrumbs too.** A signal handler can't safely read the in-memory
trail, and the process is gone by the time its report uploads on the next launch, so once
`installHandlers` has run the trail is also written to disk as it changes (PII-scrubbed, as a
sibling file of the crash reports directory), and the next launch attaches the previous run's trail
to that run's raw signal report. It's only attached when the trail's last write is not later than
the crash itself: if a later run has already replaced it, no trail is better than a misleading one.

## Performance monitoring

Times whatever you wrap and reports one small aggregate per transaction (how many times it ran,
total and maximum duration) every `FOTConfiguration.performanceFlushInterval` (60s by default), for
the Performance page's per-transaction table. Not one network call per timed call.

Each aggregate also carries a small latency histogram (a count per fixed latency bucket: 50, 100,
250, 500, 1000, 2500, 5000 and 10000ms, plus an overflow bucket), so ForgeOps can show an
approximate p50/p95/p99 per transaction, not just an average. Percentiles are accurate to the width
of whichever bucket a duration falls into; the SDK never stores the individual durations.

```objc
// Wrap a block; recorded even if it raises an NSException (which propagates unchanged):
[ForgeOpsTracker measureTransaction:@"GET /users/:id" block:^{
    [self handleRequest:request];
}];

// Or record a duration you measured yourself, in milliseconds:
[ForgeOpsTracker recordPerformance:@"nightly-export" durationMs:elapsedMs];
```

This client has no web framework integration, so **nothing is timed automatically**: you choose what
to wrap. Keep transaction names low-cardinality (`@"GET /users/:id"`, not `@"GET /users/42"`):
every distinct name is its own row. Safe to call from any thread. Turn it off with
`trackPerformance = NO`; it also does nothing (and starts no timer) when reporting isn't enabled for
the current environment.

The periodic flush is a GCD timer on a private serial queue, started on the first recorded duration.
A dispatch source never keeps a process alive, so it can't hold a command-line tool open. But an
iOS app is suspended shortly after it goes to the background, and nothing is flushed at exit (there
is no normal exit to hook), so **call `[ForgeOpsTracker flushPerformance]` yourself** from
`applicationDidEnterBackground:`/`sceneDidEnterBackground:` (on a background queue if you'd rather
not block the main thread, since it's synchronous) or before a command-line tool quits, or the last
window is lost.

A failed delivery keeps every tally, so the next flush's window just grows. What a flush delivered
is *subtracted* from the tallies afterward, never the whole set cleared: a record from another
thread that lands while the network call is in flight (the lock is deliberately released around it)
would otherwise be silently discarded, a real bug `sdks/go` had and fixed and that
`gems/forge_ops_tracker`'s reference implementation still has. A deterministic test pins this.

## Distributed tracing

One flow's own call tree (a screen load, a sign-in, a network round trip and what it triggered),
shown as a span tree on ForgeOps. A trace is sent only when the whole flow took at least
`traceCaptureThreshold` seconds (1 by default), so fast flows cost nothing on the wire. Traces are
per app; nothing is propagated across services.

```objc
[ForgeOpsTracker traceNamed:@"load home screen" block:^(FOTTrace *trace) {
    [trace measureSpan:@"fetch feed" kind:@"http" block:^{ [self fetchFeed]; }];
    [trace measureSpan:@"decode" kind:@"service" data:@{ @"items": @42 } block:^{ [self decode]; }];
}];

// Or hold the trace across queues and finish it when the flow ends:
FOTTrace *trace = [ForgeOpsTracker startTrace:@"checkout"];
dispatch_async(queue, ^{ [trace recordSpan:@"charge" kind:@"http" startedAt:started durationMs:ms data:nil]; });
[trace finish];
```

Unlike the server SDKs, a mobile flow hops between the main queue and background queues, so a trace
is an explicit object you pass around or capture in a block, not ambient per-thread state, and it is
safe to use from any thread. Nesting is tracked per thread: a span opened by `measureSpan` is the
parent of any span recorded on the same thread inside its block, and a span recorded from another
thread parents under the root. `startTrace:` returns `nil` when `trackTracing` is `NO` or reporting
isn't enabled, and messaging `nil` is a harmless no-op, so callers never check. `kind` is one of
`controller`, `service`, `database`, `redis`, `http`, `job`, `other` (anything else is sent as
`other`, since the server rejects a whole trace over one unknown kind). `measureSpan` records even if
its block raises an `NSException`, which propagates unchanged. A trace holds at most 500 spans.

This client has no web framework integration, so **nothing starts a trace or records a span
automatically**. Delivery runs on a private serial queue, bounded, off the calling thread. Nothing is
flushed at exit and an iOS app is suspended shortly after it backgrounds, so call
`[ForgeOpsTracker flushSpans]` (synchronous, on a background queue if you would rather not block the
main thread) from `applicationDidEnterBackground:` or before a command-line tool quits. Turn the
feature off with `config.trackTracing = NO`.

## Custom metrics and infrastructure monitoring

Two explicit calls (nothing is automatic, so there is no `trackMetrics` flag): a business event you
name yourself, and a reading from one of your own hosts.

```objc
[ForgeOpsTracker captureMetric:@"signup"];                       // value defaults to 1: a bare counter
[ForgeOpsTracker captureMetric:@"payment" value:49];             // a real magnitude; it may be negative (a refund)

[ForgeOpsTracker captureInfrastructureMetric:@"cpu" value:0.42 hostname:nil];  // nil defaults to serverName
[ForgeOpsTracker captureInfrastructureMetric:@"disk" value:0.81 hostname:@"db-1"];
[ForgeOpsTracker flushMetrics];                                  // send right now
```

Each capture is buffered and flushed as one batch every `metricFlushInterval` /
`infrastructureMetricFlushInterval` (60 seconds by default) on a private serial queue, off the calling
thread. Nothing is flushed at exit and an iOS app is suspended shortly after it backgrounds, so call
`[ForgeOpsTracker flushMetrics]` (synchronous, on a background queue if you would rather not block the
main thread) from `applicationDidEnterBackground:` or before a command-line tool quits. Every entry is
stored as it was captured (a signup is a row, not a running total), so a count or sum you compute later
is exact. Both are a no-op when reporting isn't enabled for the environment.

**Infrastructure readings need a hostname**, and an app has none by default: pass one, or set
`serverName` in `configureWithBlock:` (it is `nil` by default, and a reading without one is dropped with a log line
rather than sent).

A failed delivery keeps every entry for the next flush, and an entry captured while a delivery is in
flight is kept too (the Ruby gem's own buffer loses it; a test pins this with a hook that captures at
exactly that moment). Each buffer holds at most 1000 entries and drops further ones until a flush
succeeds, since a plan without the feature rejects every flush and would otherwise grow it for as long
as the process lives. A NaN or infinite value is dropped at capture: `NSJSONSerialization` raises on
one. Requires a ForgeOps plan that includes custom metrics / infrastructure monitoring.

## Delivery model: capture now, upload on next launch

There is deliberately no live, in-process delivery queue here, for a reason specific to crash
reporting: **the app is about to terminate**,
possibly through a code path (a signal handler) where most of what a normal HTTP client needs
(memory allocation, Objective-C message dispatch in general) isn't safe to rely on. Real
mobile/desktop crash reporters all take the same approach: capture as little and as safely as
possible right now, write it durably to disk, and
upload it the next time the app runs normally. `FOTCrashStore` is that durable disk queue;
`FOTReporter#uploadPendingReports` is what drains it, called from `installHandlers` at the next
launch (and immediately, from a background queue, after an explicit `captureException:context:`
call that didn't crash the process).

## Backtrace frames have no file/line

`NSException#callStackSymbols` is a **binary symbol table dump**, not source locations: that
information doesn't exist in a compiled, stripped release binary at runtime. Real line-level
symbolication needs an offline pass
against the app's own dSYM (exactly how native crash reporters do it), which is out of scope for
a client SDK with no external symbolication service to call. Each backtrace frame here carries the
binary image name (as `file`) and the parsed symbol (as `method`); `line` is always `null`. See
[`FOTEventBuilder.h`](Sources/ForgeOpsTracker/FOTEventBuilder.h) for the full detail.

## Source context

`FOTConfiguration.captureSourceContext` exists (defaulting to `YES`, the same default every other
SDK in this repo uses) purely for API-shape consistency: a host app configuring this client sees
the same option every other SDK has. It does nothing here. Every other SDK in this repo that
supports it reads a few lines of source off disk around an in-app frame's culprit line at
capture-time, keyed off that frame's own file path and line number, but a backtrace frame here
never carries a real file path or line number at all (see "Backtrace frames have no file/line"
above: `line` is always `null`, since a compiled, stripped release binary has no source location
left in it at runtime). `FOTEventBuilder`'s underlying capture step is a documented no-op rather
than a partial implementation of something that can never actually run: there is no case, on this
client's capture path, where a real file+line pair exists to read.

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data (email addresses, formatted SSNs/credit
cards, known API key/token formats, and anything under a suspiciously-named key) and redacted
before the crash report is even written to disk. ForgeOps itself scrubs again on arrival
regardless, so this is a second, earlier layer, not the only one. The user attached via
`captureException:context:user:` or `setUser:` above is a deliberate exception: it's never
scrubbed, since redacting it would defeat the whole point of identifying users in the first place.

To disable it:

```objc
config.scrubPII = NO;
```

## Running the tests

This is a library meant to be dropped into a host app's own Xcode project, not an app itself, so
there's no `.xcodeproj`/scheme here to run `xcodebuild test` against. The `Makefile` instead
compiles the sources and tests directly with `clang` into a plain `.xctest` bundle and runs it with
`xcrun xctest`: genuinely real XCTest, just without the Xcode project wrapper:

```bash
cd sdks/objc
make test
```

One real gap in the test suite, deliberately: the fatal-signal handler's own body (writing a
backtrace from inside `SIGABRT`/`SIGSEGV`) isn't exercised by an automated test, since actually
raising a fatal signal to test it would crash the test process itself: the same reason every
real crash reporter's signal-handling path is validated by manual/integration crash testing, not a
unit test. What *is* tested: that installation actually registers a real signal handler (read back
via `sigaction`), and that the raw-report parser correctly turns a hand-written fixture file into
event-shaped fields.
