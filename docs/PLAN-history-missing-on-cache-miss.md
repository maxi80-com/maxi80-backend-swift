# Plan — Missing history entries on cache-miss tracks

Status: **IMPLEMENTED 2026-07-16** (after the lambda-kit routing migration
landed — `cb8c661`). All steps below done: `collect()` refactored so history is
written in exactly one place with a guaranteed no-cover fallback on any
enrichment throw; per-branch `logger.debug` breadcrumbs replace the `DIAG:`
lines; `S3Manager.getObject` hardened with a 404-any-type catch; new resilience
tests added. `swift build` + full suite (118 tests) green. Not yet deployed —
`make build && make deploy` still to do (see Verification).

## Symptom

Some tracks never appear in `history.json` even though they play on air.
Concrete case (2026-07-16): **Yazoo — "Don't go (maxi)"** played repeatedly
between ~07:00 and ~07:08 UTC and was never recorded. There is a visible gap in
history between `06:57:28Z` (Michael Jackson) and `07:09:26Z` (Maxi80 filler).

This is a **different bug** from the artwork-download failure fixed in `1d5d55d`
(that fix is downstream at step 6; this aborts at step 3).

## Root cause (evidence from CloudWatch)

`MetadataCollector.collect` records history only inside each success branch
(`recordHistory(...)` is called at the end of the Maxi80 skip branch, the
cache-hit branch, the migration branch, the no-search-results branch, and the
fresh-collection branch). If any step throws **before** reaching one of those
calls, `collect` propagates the error, the invocation is marked failed, and
**no history entry is written**.

For every "Don't go (maxi)" invocation the logs show:

1. `DIAG: after readHistory — 100 entries` (line 68) ✅
2. `DIAG: before readMetadata (S3 cache check)` (line 89/90) ✅
3. **nothing further** — no `Cache hit`, no `Migrating stripped…`, no
   `No search results`, no error line.
4. The **same `requestId`** is re-invoked ~66s then ~124s later with a fresh
   `platform.start` — the EventBridge **async-retry** signature. The attempt is
   failing.

Corroborating 24h aggregate counts:

| Log line | Count in 24h |
|---|---|
| `Cache hit` | hundreds ✅ |
| `Successfully collected` (fresh) | **0** |
| `Migrating stripped…` | **0** |
| `No search results…` | **0** |

So the `s3Writer.readMetadata` **cache lookup at line 90 throws for a
cache-miss track**, and because that is upstream of every `recordHistory` call,
the entry is lost. Cache **hits** work fine (hundreds/day) — `getObject`
returns data without issue when the object exists.

"Don't go (maxi)" is a genuine cache miss: the exact key
`v2/Yazoo/Don't go (maxi)/metadata.json` does not exist in S3 (only
`v2/Yazoo/Don't go/…` and `v2/Yazoo/Don't Go/…` do, from earlier
stripped-title collections).

### What is NOT the cause / open detail

- **Not** the artwork-download path (`1d5d55d`) — flow never gets there.
- **Not** the Apple Music search or the parenthesis-stripping design. Confirmed:
  no search ran for this track in the incident window (0 search log lines); the
  flow died before step 4. Separately verified the parens design is correct —
  stored title keeps `(...)`, `searchTitle()` strips the trailing group for the
  query only, and the cached `search.json` for `Yazoo/Don't go` shows the query
  did once return the right match (`Yazoo — Don't Go`).
- The **exact exception type** thrown by `getObject` on this cache miss is not
  yet pinned (could be a `NoSuchKey`/`NotFound` that the current catch clauses
  fail to match, or a non-404 status — e.g. 403 — provoked by the special
  characters `'`, `(`, `)`, spaces in the key). Per decision below we do **not**
  need to pin it to fix the reported symptom, but we will log it (generic
  `catch`) so it stops being a mystery, and can revisit `getObject`'s matching
  afterward from real data.
- Whether this predates the 2026-07-15 Soto migration is **inconclusive** and
  intentionally dropped as a line of investigation — the `DIAG`/`Successfully
  collected` log lines were added in that same batch, and a near-fully-cached
  catalog makes real cache-misses rare, so log archaeology can't cleanly date
  the regression. The fix below is cause-agnostic.

## Design decision

Requirement (restated): **a track must always land in history**, even with no
cover and even if enrichment (cache read, search, artwork, S3 writes) fails.

Chosen approach (confirmed with owner): **generic exception handling** —
guarantee the history entry regardless of which enrichment step fails, rather
than hunting and special-casing each exception type. Defense-in-depth.

## Implementation plan (do after routing migration lands)

All changes in `Sources/IcecastMetadataCollector/MetadataCollector.swift`
unless noted.

1. **Guarantee history via a fallback around enrichment.**
   Wrap the enrichment pipeline (steps 3–7: cache check → migration → search →
   artwork → S3 writes → per-branch `recordHistory`) in a `do/catch`. On any
   thrown error, log it at `error` level **with the concrete error type**
   (`String(describing: error)` and `type(of: error)`) and fall back to
   recording a minimal history entry:

   ```
   await recordHistory(artist: artist, title: title, file: "nocover.jpg", logger: logger)
   ```

   Guard against a double-record: if a success branch already recorded, the
   catch must not also record. Simplest structure — track a
   `var recorded = false`, set it true inside `recordHistory` call sites (or
   return a Bool up the branches), and in the catch only record when
   `!recorded`. (Alternative: give each enrichment step its own local
   `do/catch` that degrades to the no-cover branch, so the outer function has a
   single guaranteed `recordHistory`. Prefer whichever reads cleaner in the
   post-migration code; the invariant is "exactly one history entry per
   non-dedup invocation, always".)

   Keep the two legitimate early `return`s that must NOT record: the empty-
   metadata skip (line 58–61) and the same-track dedup skip (line 69–74).

2. **Harden `S3Manager.getObject` cache-miss handling.**
   In `Sources/Maxi80Backend/AWS/S3Manager.swift`, make a missing object
   deterministically return `nil`. Current catches:
   - `S3ErrorType where .noSuchKey || .notFound`
   - `AWSResponseError where context?.responseCode == .notFound`

   Add a final defensive branch that treats any error whose
   `context?.responseCode == .notFound` (regardless of concrete type) as `nil`,
   and re-throws everything else. This closes the gap if Soto surfaces the 404
   as a type not currently matched. Do the same review for `objectExists`
   (already has two 404 branches — keep consistent).

   Note: if the real error turns out to be a **403** on special-character keys
   (not a 404), returning `nil` would be wrong there — a 403 is a real failure,
   not a miss. That is exactly why step 1 (always-record fallback) is the
   primary fix and step 2 is secondary hardening. Decide step 2's final shape
   from the error type that step 1's new `error`-level log reveals in
   production.

3. **Tests** (Swift Testing, in `Tests/Maxi80BackendTests/`).
   Use the existing `MockS3Client` (`Tests/Maxi80BackendTests/Mocks/`) to drive
   `MetadataCollector.collect` with injected fakes — no live AWS.
   - `testCollect_whenCacheReadThrows_stillRecordsHistoryWithNoCover()` —
     Mock `getObject` throws; assert exactly one history entry recorded with
     `nocover.jpg`.
   - `testCollect_whenSearchThrows_stillRecordsHistory()` — Mock HTTP client
     throws in `searchAppleMusic`; assert history recorded.
   - `testCollect_successfulCacheMiss_recordsExactlyOnce()` — full happy-path
     cache-miss; assert a single history entry (guards against the
     double-record regression from step 1).
   - `testGetObject_missingKey_returnsNil()` — `S3Manager`-level, using the mock
     or a fake transport, covering the 404-shaped errors.

4. **Add `logger.debug` breadcrumbs on every branch of `collect()`.**
   This incident was diagnosable only because two ad-hoc `DIAG:` lines happened
   to bracket the failing call. Make that systematic: every branch of
   `collect()` should log which path it took and its outcome, so the next
   "missing track" is one log query away. Cover **all** branches (each should
   emit at entry and, where it records/returns, at exit):

   | # | Branch (current line) | Debug line to add |
   |---|---|---|
   | 1 | Empty-metadata skip (58–61) | `"Path: empty metadata → skip, no history"` |
   | 2 | Same-track dedup skip (69–74) | `"Path: dedup skip (== latest history) → no history"` |
   | 3 | Maxi80 artist skip (79–85) | `"Path: Maxi80 filler → recording nocover"` |
   | 4 | Cache hit (90–121) | `"Path: cache hit"` + `"cache-hit color present/absent"` |
   | 5 | Color backfill success/fail (97–118) | `"backfill: succeeded/failed/no-song"` |
   | 6 | Stripped→full migration success/fail (124–181) | `"Path: migration entered/copied/wrote/deleted/failed"` |
   | 7 | No search results (187–195) | `"Path: no search results → recording nocover"` |
   | 8 | Artwork present/download-failed/none (198–213) | `"artwork: downloaded N bytes / download failed / none on song"` |
   | 9 | Fresh-collection success (219–243) | `"Path: fresh collect → wrote metadata/search/artwork, recording <file>"` |

   Also add a single **entry breadcrumb inside `recordHistory`** logging the
   final `(artist, title, file, color)` actually written, and — per step 1 — an
   `error`-level line in the new outer `catch` with the concrete error type.
   Keep them at `.debug` (the Lambda's `LOG_LEVEL` can be raised to `debug`
   on demand) except the catch, which is `.error`. Replace the two temporary
   `DIAG:` lines with these permanent, named breadcrumbs so we don't leave
   throwaway diagnostics in the code.

   Net invariant to assert in review: reading the logs for any single
   invocation must make the chosen path and the history outcome unambiguous
   without guessing.

5. **Verification.**
   - `swift build` green, `swift test` green (esp. `HistoryManagerTests`,
     `S3WriterTests`, new tests).
   - Deploy (`make build && make deploy`).
   - Confirm on next real cache-miss track that `Successfully collected` (or the
     new fallback `error` log) appears AND a history entry is written. Watch for
     the concrete error type in the new `error` log to finalize step 2.
   - Sanity-check `history.json` shows the previously-missing tracks going
     forward.

## Files touched (anticipated)

- `Sources/IcecastMetadataCollector/MetadataCollector.swift` — always-record fallback (step 1) + per-branch `logger.debug` breadcrumbs replacing the temporary `DIAG:` lines (step 4).
- `Sources/Maxi80Backend/AWS/S3Manager.swift` — getObject 404 hardening (step 2).
- `Tests/Maxi80BackendTests/…` — new tests (step 3).
