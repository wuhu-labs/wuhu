# SessionTools

## Script archive

`archive(id, { force: false })` in `wuhu:session` defaults to non-force. Its control bridge forwards the force flag to the runtime after checking the caller's rights on the root. `force` must be a boolean. A busy refusal rejects with the full id/title list. A descendant-only busy refusal does not claim that the caller itself is mid-turn. Force self-archive is always refused, including from a detached script. Non-force self-archive is refused mid-turn because the call keeps the session busy. A detached script that outlives the turn can archive it once it has settled; this archives its whole subtree, subject to the same non-force busy check.

Archiving a session takes its entire parent-chain subtree, leaves first and root last. A separately created top-level agent has no parent and is not included. Only the root's archive rights are checked. Without force, every session is checked for the existing unfinished-work condition (retired contractors are never busy, even with queued input); refusal archives nothing and names every busy session by id and title. With force, busy sessions are interrupted before any archive write, and every open request in the subtree, including an undrained request, is closed with a final-kind message saying the session was archived before reporting. Its requester receives that message even outside the subtree. Unarchive remains single-session, subject to the archive grace window.

## Cron timers

Five-field cron schedules match UTC Gregorian minute, hour, day-of-month, month and weekday fields. Day-of-month and weekday combine with OR when both are restricted. A cron search converts its input date to an integer Unix minute ID once (`floor(unixSeconds / 60)`), starts at the next ID, and performs all candidate increments, day/hour skips and UTC field decomposition in integer space. Only the matching minute ID converts back to a date, with exact whole-minute Unix seconds. A result is strictly later than its input and matches the expression.

After a recurring fire, the next slot is computed strictly after the later of the current wall clock and the due time just fired. Missed slots are not replayed. Existing off-minute stored due times need no migration: they fire once under their existing deterministic notification identity, then advance to an exact cron minute.

The firing registry treats completion as an event and reloads durable registrations before re-arming. It retains ongoing observations across marker/delivery updates, but never retains a finished firing task merely because its arming key is unchanged. Only a proven non-advancing reschedule (a rejected persisted timestamp or a successful recurring fire leaving its stored due unchanged) logs an error and stops that arming instead of entering a fire/deduplication loop. Every other firing failure logs the actual error and re-arms from the stored row after a continuous-clock backoff of 1, 2, 4, 8, 16, 32, then at most 60 seconds. The same retry rule applies to cron timers, one-shot timers, request deadlines, park retirement and observation delivery; a clean observation-stream end or operational observation-read error also retries rather than silently stopping. A changed arming starts with a fresh backoff. Retries preserve deterministic delivery identities and only advance observation markers after a successful store write. Invalid observation queries retain their explicit error-notification-and-retirement behavior; failure to write that retirement is retryable. A changed durable arming can be started again. Superseded tasks and all tasks on registry exit are cancelled and awaited.

One-shot timer delays, request deadlines and archive grace remain relative durations and retain fractional-second inputs; they do not compute recurring calendar boundaries.

A request deadline is delivered to the parent queue and the owner notification feed atomically with slot retirement; failure of either delivery retries the still-armed deadline.

## Machine exec liveness

An exec tool or script stops waiting when the server records `machine-lost`, reporting that the remote process outcome is unknown rather than claiming an exit. For other terminal records, one additional caller connection may drain retained output; a second sever without an exit event fails as no longer replayable. Successful server-local connections do not reset that terminal drain budget. Transient reconnects for live execs and the byte-exact replay/retention policy are unchanged.
