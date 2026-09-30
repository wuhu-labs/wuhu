# SpaceCore

## Inferences

`inferences` is an induced, read-only SQL table available through query, observation and scripts with the same group visibility as `sessions`: the unqualified name reads the acting group, a group-qualified name reads a readable group, and the wildcard-qualified name includes `grp`. Opening an existing database creates the table and indexes idempotently; there is no backfill.

Each call has `id`, `session`, `at` (UTC start), `provider`, configured `model`, optional API-reported `served_model`, `effort`, `input`, `cache_read`, `cache_write`, `output`, `reasoning`, `outcome`, `error`, `duration_ms` and `ttft_ms`. `input` is uncached input; total input is `input + cache_read + cache_write`. `output` includes billed reasoning; `reasoning` is its reported subset or null when unavailable. Usage is null when a failed call reports none. Outcomes are `ok`, `networkError`, `httpError`, `timeout` and `cancelled`.

`Space.recordInference` inserts a call for an existing session and derives its group from that session. Observations wake on insertion. No lifecycle operation deletes inference rows: archive, compaction and Start over leave them intact.
