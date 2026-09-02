# ForgeOpsTracker (Objective-C)

Objective-C crash reporting client for a [ForgeOps](../../) instance. Real-world Objective-C
today is overwhelmingly iOS/macOS app code, not a web backend, so there's no server-side
request-exception path for this SDK to hook into. This SDK is instead a
genuine **crash reporter**: it captures what would otherwise crash the app (an uncaught
`NSException`, or a fatal signal like `SIGSEGV`), and uploads it -- not live, but on the *next* app
launch. See "Delivery model" below for why that's a deliberate design choice, not a limitation to
work around.

## Installation

Not yet packaged for CocoaPods/Swift Package Manager -- no podspec or package manifest exists yet,
so there's no single dependency declaration to point at. Clone or vendor the source directly
instead:

```
git clone https://github.com/Luke-Popwell/forge-ops-tracker-objc.git
```

That's a mirror, kept in sync automatically from `sdks/objc` in the main `forge_ops` repo (which is
private, so isn't itself something a consumer could ever clone directly) -- develop against that
repo, not this one. Once cloned, add the files under
[`Sources/ForgeOpsTracker/`](Sources/ForgeOpsTracker/) directly to your Xcode project (or a local
Swift package target).

## Configuration

```objc
#import <ForgeOpsTracker/ForgeOpsTracker.h>

[ForgeOpsTracker configureWithBlock:^(FOTConfiguration *config) {
    config.dsn = @"https://<api_key>@your-forgeops-host/api/v1/events";
    config.environment = @"production";
    config.releaseVersion = @"1.4.0"; // named releaseVersion, not release -- see FOTConfiguration.h
}];
[ForgeOpsTracker installHandlers];
```

Call this as early as possible in app startup (`application:didFinishLaunchingWithOptions:`, or
your SwiftUI `App`'s `init`). `installHandlers` does two things: installs the uncaught-exception
and fatal-signal handlers described below, and kicks off an upload (on a background queue) of any
crash report left over from the *previous* launch.

## What gets captured automatically

- **An uncaught `NSException`** -- via `NSSetUncaughtExceptionHandler`. Any previously-installed
  handler (another crash reporter, a debugger) is chained to afterward, not replaced.
- **A fatal signal** (`SIGABRT`, `SIGILL`, `SIGSEGV`, `SIGFPE`, `SIGBUS`, `SIGTRAP`) -- via
  `sigaction`. See [`FOTSignalHandler.h`](Sources/ForgeOpsTracker/FOTSignalHandler.h)'s own
  comment for exactly what this can and can't safely do from inside a real signal handler (POSIX
  only guarantees a small set of functions are safe to call there at all); the short version is
  that it writes a raw backtrace to disk using only `backtrace_symbols_fd()` and `write()`, then
  re-raises the same signal so the OS's own default crash behavior (a real crash log, a possible
  core dump) still happens exactly as if this SDK weren't installed.

**An exception your own code catches and handles** -- report it explicitly:

```objc
@try {
    [self riskyOperation];
} @catch (NSException *exception) {
    [ForgeOpsTracker captureException:exception context:@{ @"orderId": order.identifier }];
}
```

## Delivery model: capture now, upload on next launch

There is deliberately no live, in-process delivery queue here, for a reason specific to crash
reporting: **the app is about to terminate**,
possibly through a code path (a signal handler) where most of what a normal HTTP client needs --
memory allocation, Objective-C message dispatch in general -- isn't safe to rely on. Real
mobile/desktop crash reporters all take the same approach: capture as little and as safely as
possible right now, write it durably to disk, and
upload it the next time the app runs normally. `FOTCrashStore` is that durable disk queue;
`FOTReporter#uploadPendingReports` is what drains it, called from `installHandlers` at the next
launch (and immediately, from a background queue, after an explicit `captureException:context:`
call that didn't crash the process).

## Backtrace frames have no file/line

`NSException#callStackSymbols` is a **binary symbol table dump**, not source locations -- that
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
capture-time, keyed off that frame's own file path and line number -- but a backtrace frame here
never carries a real file path or line number at all (see "Backtrace frames have no file/line"
above: `line` is always `null`, since a compiled, stripped release binary has no source location
left in it at runtime). `FOTEventBuilder`'s underlying capture step is a documented no-op rather
than a partial implementation of something that can never actually run: there is no case, on this
client's capture path, where a real file+line pair exists to read.

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data -- email addresses, formatted SSNs/credit
cards, known API key/token formats, and anything under a suspiciously-named key -- and redacted
before the crash report is even written to disk. ForgeOps itself scrubs again on arrival
regardless, so this is a second, earlier layer, not the only one.

To disable it:

```objc
config.scrubPII = NO;
```

## Running the tests

This is a library meant to be dropped into a host app's own Xcode project, not an app itself, so
there's no `.xcodeproj`/scheme here to run `xcodebuild test` against. The `Makefile` instead
compiles the sources and tests directly with `clang` into a plain `.xctest` bundle and runs it with
`xcrun xctest` -- genuinely real XCTest, just without the Xcode project wrapper:

```bash
cd sdks/objc
make test
```

One real gap in the test suite, deliberately: the fatal-signal handler's own body (writing a
backtrace from inside `SIGABRT`/`SIGSEGV`) isn't exercised by an automated test, since actually
raising a fatal signal to test it would crash the test process itself -- the same reason every
real crash reporter's signal-handling path is validated by manual/integration crash testing, not a
unit test. What *is* tested: that installation actually registers a real signal handler (read back
via `sigaction`), and that the raw-report parser correctly turns a hand-written fixture file into
event-shaped fields.
