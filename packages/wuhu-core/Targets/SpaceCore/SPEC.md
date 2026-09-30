# SpaceCore

## Inferences

`inferences` is an induced, read-only SQL table available through query, observation and scripts with the same group visibility as `sessions`: the unqualified name reads the acting group, a group-qualified name reads a readable group, and the wildcard-qualified name includes `grp`. Opening an existing database creates the table and indexes idempotently; there is no backfill.

Each call has `id`, `session`, `at` (UTC start), `provider`, configured `model`, optional API-reported `served_model`, `effort`, `input`, `cache_read`, `cache_write`, `output`, `reasoning`, `outcome`, `error`, `duration_ms` and `ttft_ms`. `input` is uncached input; total input is `input + cache_read + cache_write`. `output` includes billed reasoning; `reasoning` is its reported subset or null when unavailable. Usage is null when a failed call reports none. Outcomes are `ok`, `networkError`, `httpError`, `timeout` and `cancelled`.

`Space.recordInference` inserts a call for an existing session and derives its group from that session. Observations wake on insertion. No lifecycle operation deletes inference rows: archive, compaction and Start over leave them intact.

## Archive support

`SessionStore.archiveSubtree(root)` returns records in descendant-before-parent order using the parent chain, not `created_by`. `closeRequestsForArchive(id)` posts one replay-safe final-kind message for every still-open request, including undrained input, and cancels its deadline subscription on the parent. The wording explicitly says the session was archived before reporting; it does not claim the requested work was completed. The store's `archive(id, grace:)` and `unarchive(id)` remain single-record persistence operations; the session service owns subtree orchestration and runtime interruption.

Archive reservations are shared by all `SessionStore` values of a space. `reserveForArchive(id, token:)` serializes reservation with session creation, `isReservedForArchive(id)` checks it without waiting for runtime work, and `releaseArchiveReservation(id, token:)` only releases the matching token. Creating a child below a reserved or archived parent fails with `parentUnavailableForCreation`; a separately created top-level agent remains allowed by this storage gate.

## Subscription progress

`SessionStore.fireSubscription` accepts a reschedule only when the new due time, serialized at the database's millisecond precision, is strictly later than the currently stored due time. An equal timestamp, backwards timestamp, absent due timestamp or sub-millisecond change that persists unchanged throws the session-observation SPI's `NonAdvancingSubscription` error, including the attempted and stored due times. A removed subscription row instead throws a stale-callback error. Both reject the fire before enqueueing its notification; the transaction leaves both queue and subscription progress untouched.

The session-observation SPI exposes both a fresh registration snapshot and its change stream, including observation callback identities. The firing registry reloads a fresh snapshot on task completion rather than relying on a due-time key change to wake it. Stored subscription schema and existing off-minute due rows are unchanged.

Request-deadline firing commits the parent queue notification, owner deadline notification and subscription retirement in one transaction. A failed write leaves all three effects uncommitted and the slot retryable; replay after retirement cannot append another owner notification.
