# Changelog

## 0.4.0

- Trace context: a request your app sends inside a trace carries a W3C `traceparent` header, so a backend that also reports to ForgeOps continues the trace, and an error captured with the trace carries its `trace_id`, which links it to the backend error from the same request (the two projects must be linked in ForgeOps). New `-[FOTTrace startRequestSpan:]` / `startRequestSpan:name:` and the nil-safe `+[FOTRequestSpan startWithRequest:trace:name:]` add the header and record the `http` span it names (the header's parent id is that span's own id); `+[ForgeOpsTracker dataTaskWithSession:request:trace:completionHandler:]` does both around an `NSURLSession` data task. `+[ForgeOpsTracker captureException:context:user:trace:]` links an error to a trace explicitly; inside `traceNamed:block:` or `measureSpan:kind:block:` the trace is used automatically, including for an uncaught `NSException` raised there. `FOTTrace.traceId` is public. Two new options: `propagateTraces` (default `YES`; `NO` stops the header but still records the span) and `tracePropagationTargets` (default `nil`, every host; otherwise host strings matched exactly or as a subdomain on a dot boundary, and `NSRegularExpression`s matched against the host). A request that already has a `traceparent` is left alone, nothing instruments `NSURLSession` automatically, and trace and span ids are never all zeros. Errors captured outside a trace are unchanged.

This client is distributed as a tagged git mirror with no version file, and no `CHANGELOG.md` existed for it
before this entry; like `sdks/java`'s first entry, it starts the file without backfilling earlier tags
(v0.1.0 to v0.3.0).
