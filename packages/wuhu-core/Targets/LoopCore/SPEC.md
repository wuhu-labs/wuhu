# LoopCore

## Archive

`SessionService.archive(id, force: false)` implements subtree archive. `SubtreeArchiveBusy.sessions` carries every busy node's id and title, and `message` renders the list. The service reserves settled runtime actors before committing any archive, so an idle pass cannot start work between the tree check and its archive. Failed preflight releases those reservations.

Archiving a session takes its entire parent-chain subtree, leaves first and root last. A separately created top-level agent has no parent and is not included. Only the root's archive rights are checked. Without force, every session is checked for the existing unfinished-work condition (retired contractors are never busy, even with queued input); refusal archives nothing and names every busy session by id and title. With force, busy sessions are interrupted before any archive write, and every open request in the subtree, including an undrained request, is closed with a final-kind message saying the session was archived before reporting. Its requester receives that message even outside the subtree. Unarchive remains single-session, subject to the archive grace window.

Reservations make wake and enqueue return promptly: queued deliveries remain durable and a released live actor resynchronizes its queue before resuming. `SessionError.archiveInProgress` rejects conflicting control while reserved. An executor change that invalidates the runtime reservation fails with `SessionError.archiveReservationLost` rather than asserting; this runtime race can leave already-committed descendants archived, and a retry completes the remaining subtree. A reservation also blocks creation of children below that node; children attached before a parent is reserved are included by the final tree scan. A pending kernel compact command is not consumed while reserved, and resumes after a refused archive releases its reservation.

## Inference lifecycle

`InferenceReply.committed` receives the actual assistant entry and resulting transcript only after successful durable append and in-memory commit; it is never invoked for discarded/retried/cancelled inference. Provider IDs have already been replaced by kernel IDs and the entry preserves their map. Compaction by either path, Start over, archive/unarchive, retirement and shutdown await `LoopConfig.invalidateInference`. Defaults are no-ops, preserving existing SSE and executor clients.

Cancellation immediately after a durable `committed` callback stops the pass before a forced-compaction fallback; the already-committed assistant remains durable, but no mechanical compaction runs after cancellation. This applies equally to SSE and WebSocket replies.

Cancelling `SessionService.start()` joins both live-pass drainage and registry shutdown. It returns only after every loaded actor’s shutdown and awaited inference invalidation complete; boot failure likewise awaits registry teardown before propagating the error. Registry shutdown closes admission before joining its reaper and actors, so late work signals cannot rematerialize a session after shutdown.
