# Vendored background_downloader 9.5.9

Source: https://pub.dev/api/archives/background_downloader-9.5.9.tar.gz

Archive SHA-256: `ae55e127f87397b372578fc9474568b879fa78326103c342e00160558d08e527`

Fetched and independently hashed on 2026-11-04. Files were extracted from that
archive, not copied from a review directory. Upstream LICENSE and release files
are retained. `downloader.patch` is a reviewable unified diff against the archive;
its two documentation artifacts (`PATCHES.md`, `downloader.patch`) are excluded
from the diff itself. Package version remains 9.5.9; the application's path
reference and repository commit identify this patched distribution.

## Execution boundary changes

- `execution_journal.dart` / `ExecutionJournal.swift`: execution-only v1 snapshots,
  versioned `<receiptVersion>.json` records, flushed before notification; pending
  writes are not readable records. Failed pending writes use unique names and
  remain available for diagnosis after a retry. Native version allocation,
  reading, merging and publication use one recursive lock. App-side native
  checkpoints use that same lock through `recordExecution`. The Dart journal
  still requires a single writer; it does not provide cross-isolate mutual
  exclusion (see the independent check evidence below). The vendor has no
  application imports.
- `BDPlugin.swift`: legacy `popLocalStorage` becomes a non-destructive read;
  invalid encoded resume material cannot fall back to an ordinary enqueue.
  The old API name is retained for upstream call compatibility.
- `TaskFunctions.swift`: status and resume material persist before Dart delivery;
  terminal states retain adapter-owned resume data; legacy preferences updates
  serialize through the same lock.
- `UrlSessionDelegate.swift`: independent cumulative bytes and monotonic samples,
  resumed-offset baseline; synchronous completed-file destination registration
  before moving callback-owned system temporary data into persistent staging.
  Adapter staging is never silently overwritten.
- `base_downloader.dart`: adapter-owned execution metadata opts out of final-state
  resume cleanup and paused cancellation deletion. Unmodified upstream task
  groups retain their normal behavior. Startup reads cannot consume native data.
- `desktop_downloader.dart`: retain resume data while submitting a resume and
  await material persistence before processing the following paused status.
  Queued cancellation persists before notification. `waitForExecutionIdle` joins
  adapter workers before another command can reuse their execution directory;
  final adapter statuses do not detach a still-running worker prematurely.
- `download_isolate.dart`: actual GET response must be safe 206 with strong,
  matching ETag, exact Content-Range and length before opening the partial file.
  Local size and SHA-256 are checked before GET and again before append. Reject
  200/416, absent/weak/changed validators, wrong ranges, a short suffix that does
  not reach the requested end, changed known total lengths, and corrupt material
  with TaskResumeException
  (mapped structurally to restartRequired). No truncate, delete, or fallback write
  is allowed on unsafe resume. Pause/failure/cancel preserve material, including
  small files and zero retries. Close/checkpoint failures cannot report paused
  or complete success. Private staging is registered separately from publication.
- `isolate.dart`: actual flushed download writes feed bytes/checkpoints even when
  Content-Length is absent. Hash/offset checkpoints permit safe manual recovery
  after process death. State snapshots persist before their SendPort delivery.
- `file_downloader.dart`: restore already durable resume data without networking;
  serialize app-owned checkpoints with native callbacks. No automatic enqueue is
  added. Adapter startup disables tracking/rescheduling/completion/cleanup and
  uses retries=0.

The application adapter owns `commands.sqlite` (schema/user_version=1), with
executions, command-id/payload/result records and explicit acknowledgement watermarks.
It does not write AppStore business tables. Acknowledgements must match an
already committed AppStore row. They retain latest snapshots, discard only
acknowledged older records, and release owned desktop material only with an
explicit current cancellation/publishing acknowledgement. Ordinary paused/failed
acknowledgements have no release side effect. Ambiguous command outcomes remain
queryable and are never resubmitted automatically.
Execution identity and its command intent commit together in a short transaction.
A live matching business receipt is also compared with the full engine payload
before acknowledgement. Desktop release checks normalized and resolved paths,
including symlinks. A reopened adapter leaves historical samples in inspect
instead of emitting them as observations in its new monotonic clock.

## Verification and limits

`flutter test third_party/background_downloader/test/execution_boundary_test.dart
--reporter expanded` exercises real HTTP plus the production desktop transfer,
including pause/resume, unknown-length bytes, eleven unsafe resume variants and
failed-publication pending preservation (15 tests).
`integration_test/plugin_engine_test.dart` runs the actual macOS plugin engine
and SQLite with transaction failure/rebuild/acknowledgement tests.
`python3 integration_test/plugin_engine_process_check.py` launches, SIGKILLs and
reopens the actual macOS app against an external server; it checks zero new
requests and waitingRecovery. It leaves its evidence in the app sandbox temp
folder and kills only a newly launched executable at this checkout's exact path.

Xcode 27.2 rejects the approved iOS14/macOS10.15 build targets (its SDKs require
15/12). Ordinary build commands therefore fail target validation. A temporary
`XCODE_XCCONFIG_FILE` setting iOS15/macOS12 verifies both compiled artifacts
without changing the approved product baselines. This does not establish support
on the older baselines. No Windows host or iOS physical device is available.

**iOS remains unaccepted:** URLSession owns opaque resume data and may internally
restart requests. This patch does not prove it can intercept every unconfirmed
restart from zero; suspended/system-killed/force-quit scenarios and offset
semantics require physical-device evidence. No successful compile or Dart test
is evidence of those guarantees. iOS material release is conservative retention;
opaque private system material is not guessed or deleted. Target-directory
publication, user-selected authorization, UI and Android execution remain out of
scope. Retained legacy iOS preferences and current snapshots may require future
conservative garbage collection. The initial checkpoint rescan cost is superseded
by the incremental P2 implementation and real >4GiB evidence below.

**Remaining P1:** an independent four-isolate diagnostic against the production
Dart `ExecutionJournal.record` returned 400 successful writes but retained only
114 version records. Unique pending filenames preserve interrupted evidence but
do not serialize read/merge/version allocation. Worker joining closes the
single-adapter pause/resume overlap; multiple writers or adapter instances
sharing a directory still need an ownership/serialization decision. Do not
describe the Dart journal as safe for arbitrary concurrent writers.

**Remaining crash-recovery gap:** the independently inspected SIGKILL evidence
has checkpointOffset=8192 and actualLength=24576. The strict local-length guard
therefore rejects manual continuation before GET, even if the server is unchanged.
The process regression currently verifies nonautomatic restart, not successful
manual recovery. Safe recovery of a committed prefix plus an uncommitted tail
needs an explicit material-ownership strategy; do not truncate the evidence.

## Desktop P1 follow-up (2026-11-04)

Dart journal publication now uses an independent sqlite3 3.5.2 connection per
operation and `BEGIN IMMEDIATE` on each execution's `writer.sqlite`, with a
30-second busy timeout. The transaction covers latest/merge/version allocation
through flushed immutable-file publication; receipt reclamation uses the same
gate. This serializes real isolate/multi-instance writers and releases locks
after process death. Swift retains its native lock; Dart conservatively retains
iOS history instead of reclaiming outside that lock. Existing unique failed
pending files are retained. Four real isolates each performing 100 writes retain
400 unique payloads and consecutive immutable versions (zero errors/loss).

A crash tail longer than the authenticated offset is now treated as evidence,
not a reason to truncate or silently restart. Only the persisted prefix is
hashed, GET requests that offset with its strong validator, and all existing
response checks remain in force. After safe 206 validation, `recoveryOperation`
(id/source/candidate/offset/phase) and `ownedMaterials` register a new private
candidate before creation. The verified prefix is streamed to it, verified again,
and only that candidate is appended. Original tail bytes remain untouched.
Interrupted copying remains attributable; retries allocate new candidates and
retain every prior path for explicit owned-material release. Copy failure never
authenticates the uncommitted original tail through the transfer finalizer.
Current cancellation/publication release validates the entire registered private
set before deletion; ordinary paused/failed acknowledgements retain it.
No public DTO, AppStore/schema, Swift, SDK, permissions or product minimum target
changes are part of this follow-up.

Tests now include six checkpoint8192/file24576 scenarios (safe206,200,416,changed
ETag,badRange,badPrefix), in addition to the prior fifteen production boundary
regressions. The real process script now proves no automatic requests followed
by a user-triggered Range resume, exact completed content, and unchanged original
tail. At this P1 follow-up the full-file checkpoint cost remained P2; the later
incremental section below records its implementation and measurements. iOS
private-system restart behavior and Windows/minimum-version acceptance remain
blocked as described above.

Independent narrowed recheck: the production writer race again retained all
400 unique consecutive receipts. Rollback is best-effort so it cannot replace
the original publication/commit exception. The HTTP boundary suite now has 22
tests, including a filesystem obstruction at the first asynchronous prefix-copy
boundary: copying intent and the original resume checkpoint survive, retry
retains the old candidate reference, and original tail bytes remain unchanged.
This is fault injection, not a copy-phase OS-kill experiment. The macOS
integration also rejects an invalid final owned-material member before deleting
any preceding valid material. iOS, Windows, minimum-version and large-file
limitations above remain unaccepted.

## Incremental desktop material authentication (P2, 2026-11-04)

`desktop/material_digest.dart` replaces periodic and stopped-file rescans.
It uses public crypto SHA256 only, retaining a fixed 1MiB Uint8List tail and
32-byte chain. Let C0=SHA256(UTF8("bd-material-v1:seed")); each complete 1MiB
block updates Ci=SHA256(UTF8("bd-material-v1:block") || C(i-1) || block).
Snapshots are `bd-chain-sha256-v1:` followed by lowercase hex SHA256 of
UTF8("bd-material-v1:end") || Ci || uint64BE(totalLength) || remainingTail.
Snapshots are repeatable and do not close/consume the running state. Network
chunk boundaries do not affect the value. Plain 64-hex legacy SHA256 values
remain verifiable while rebuilding the new state in the same disk pass; unknown
versions reject. This is a versioned private digest, not an ordinary file SHA256.

New downloads update this state from successful sink additions. Checkpoints flush
and compare the actual file size, accepted byte count and digest length before
publishing offset/hash together. Periodic checkpoints and stopping never open or
read historical bytes. Close/flush/length failure cannot authenticate a new offset
and leaves the last authenticated checkpoint/material. A failed checkpoint is
not silently promoted by the finalizer. Resume still verifies actual disk prefix
and reconstructs state in a constant number of linear scans; fork/copy ownership,
safe206 validation, immutable original tails and explicit release remain intact.
No SDK, dependency versions, Swift, shared DTO or AppStore/schema changes.

Regression additions: snapshot/block/network slicing/legacy/tamper/flush-length
fault tests; both legacy and v1 tail recovery HTTP cases; an explicit opt-in
`test/large_download_checkpoint_test.dart` that transfers >4GiB over real local
HTTP into a real file, pauses after 4GiB, times the production checkpoint, checks
content in bounded chunks and independently rebuilds the disk digest. This large
test is outside the app's default 48-test suite. Exact commands, raw logs and
measurements are recorded in the active task's implement.md. The former O(n²)
periodic/final rescan is removed; recovery scans and prefix copies remain O(n).
Overall iOS/Windows/minimum-system acceptance remains blocked.

Independent P2 recheck: added fixed expected vectors independently computed
with Python hashlib for lengths 0, 1, 1MiB-1, 1MiB, 1MiB+1 and 3MiB+17; the
final focused suite has 34 tests (5 digest, 28 HTTP, 1 writer race). A separate
real HTTP/file run authenticated 4,315,807,744 consumed bytes, with a 21ms
same-test-process pause and a 15,028us production checkpoint. Disk rebuilding
took 34,306ms; explicit verification scans are not periodic/stopping production
scans. These timings are local observations, not UI-to-Repository end-to-end
latency guarantees or Windows/iOS/minimum-platform acceptance. Peak RSS includes
Flutter, HTTP and test allocations; the fixed digest tail buffer is 1MiB.
