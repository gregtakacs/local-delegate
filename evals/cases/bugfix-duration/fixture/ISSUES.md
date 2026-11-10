# Open bug reports

- #41 "1 minutes" — singular units are pluralized: `formatDuration(60000)` says "1 minutes".
- #42 Status page shows "2 minutes" for a job that ran 1m35s. Values are being rounded instead of
  truncated per unit; 95 seconds should read "1 minute, 35 seconds".
- #43 `formatDuration(90061000)` (1d 1h 1m 1s) returns three units although `largest` defaults to 2.
- #44 Negative durations (clock skew) print "" — they should print like positive ones prefixed
  with "-" (e.g. "-5 seconds"). Sub-second positive values print "" too; they should be "0 seconds".
- #45 `parseDuration("1.5h")` returns null, which is correct, but `parseDuration(" 5s")` and
  `parseDuration("5S")` also return null — leading/trailing whitespace and uppercase units should be
  accepted.
