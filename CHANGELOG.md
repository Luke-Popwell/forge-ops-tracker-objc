# Changelog

## 0.7.1 (2026-10-07)

- The library now ships its MIT licence (`LICENSE.txt`). Earlier versions were published without one. No code changes.

## 0.7.0 (2026-09-29)

- SQL masking now catches values it used to let through, matching ForgeOps's own masker again: a string with a backslash-escaped quote (`'o\'brien'`, `E'o\'brien'`) is masked whole instead of leaving the rest of it visible, a string's type prefix goes with it (`E''`, `X''`, `N''`, `B''` and `U&''` each become one `?`), and hex (`0x1F`), binary (`0b101`), exponent (`3e10`, `1.5E-3`) and leading-dot (`.5`) numbers are masked. On a `database` span whose `dbSystem` is `mysql` or `mariadb`, "double quoted" text is a string and is masked too; on any other database it's a name and is still left alone. New `+[FOTSqlStatement maskedStatement:system:]` is that system-aware masker; `maskedStatement:` masks as it does with a nil system. Digits and letters next to a value are now judged by ASCII only, the way the server does, so a number right after an accented letter is masked the same on both sides.

## 0.6.0 (2026-09-25)

- A `database` span can now carry the SQL it ran, such as a local SQLite query: new `-[FOTTrace measureSpan:kind:data:statement:dbSystem:block:]` and `-[FOTTrace recordSpan:kind:startedAt:durationMs:data:statement:dbSystem:]`. The statement is masked on the device (every string and number literal becomes `?`), cut at 4000 characters, and sent in the span's data as `db.statement`, with `db.system` lowercased. A `db.statement` put in `data` directly is masked the same way. Both are ignored on spans of any other kind.

## 0.5.0 (2026-09-25)

- New `+[ForgeOpsTracker recordChange:title:]` (plus `recordChange:title:details:` and the full `recordChange:title:details:environment:service:actor:url:identifier:occurredAt:`) tells ForgeOps what changed in your app, typically from a feature flag or remote config change callback, so the change shows on the timeline next to the errors around it. `kind` is one of the new `FOTChangeKind` constants (any other string is sent as `"other"`). Sent to `/api/v1/changes` on a private serial queue, off the calling thread; it never raises, a failed request or a plan without change tracking is silent, and it's a no-op when reporting isn't enabled. New `-[FOTConfiguration changesURL]` and `-[FOTClient deliverChange:]`.

## 0.4.0

- Trace context: a request your app sends inside a trace carries a W3C `traceparent` header, so a backend that also reports to ForgeOps continues the trace, and an error captured with the trace carries its `trace_id`, which links it to the backend error from the same request (the two projects must be linked in ForgeOps). New `-[FOTTrace startRequestSpan:]` / `startRequestSpan:name:` and the nil-safe `+[FOTRequestSpan startWithRequest:trace:name:]` add the header and record the `http` span it names (the header's parent id is that span's own id); `+[ForgeOpsTracker dataTaskWithSession:request:trace:completionHandler:]` does both around an `NSURLSession` data task. `+[ForgeOpsTracker captureException:context:user:trace:]` links an error to a trace explicitly; inside `traceNamed:block:` or `measureSpan:kind:block:` the trace is used automatically, including for an uncaught `NSException` raised there. `FOTTrace.traceId` is public. Two new options: `propagateTraces` (default `YES`; `NO` stops the header but still records the span) and `tracePropagationTargets` (default `nil`, every host; otherwise host strings matched exactly or as a subdomain on a dot boundary, and `NSRegularExpression`s matched against the host). A request that already has a `traceparent` is left alone, nothing instruments `NSURLSession` automatically, and trace and span ids are never all zeros. Errors captured outside a trace are unchanged.

This client is distributed as a tagged git mirror with no version file, and no `CHANGELOG.md` existed for it
before this entry; like `sdks/java`'s first entry, it starts the file without backfilling earlier tags
(v0.1.0 to v0.3.0).
