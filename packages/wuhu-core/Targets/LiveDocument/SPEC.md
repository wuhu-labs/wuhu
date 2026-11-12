# LiveDocument

A live document kind's Loro replica, generic over its `LiveFormat`: `.wmd` (WmdDocument's `LiveFormat.wmd`) and `.canvas` (CanvasDocument's `LiveFormat.canvas`). The server keeps one per open node (SpaceCore's live nodes).

## Format

`LiveFormat` is three functions: `configure` sets up a fresh doc (mark expansion, tree fractional index), `text` projects a doc to its canonical agent view, and `apply` edits a doc into what an agent's text says, answering notes on what it did beyond the text (a `.canvas` connector that went with a deleted item). `apply` throws `LiveSyntaxError` (`line`, `reason`) to refuse the text whole; any other error is a Loro failure. `restoring` marks an older revision's text coming back (a checkout, a file seeding a new document), which may name what the doc no longer has.

## Replica

`LiveReplica` is one Loro doc: built empty, or from a snapshot plus the updates logged after it. `text` projects the doc and `text(at:)` the doc at a checkpoint's frontiers. `updates(since:)` exports what a version vector lacks (nil when nothing), and `importUpdate` imports one, reporting whether it changed the doc. An update whose causal dependencies the doc lacks throws `missingDependencies`; Loro holds its operations until the dependencies arrive. `importClientUpdate` imports the bytes and checks Loro's actual `isShallow` state, refusing `invalidUpdate` if the history is shallow regardless of the envelope metadata. An import that throws may have mutated the replica; the caller must discard it. Update blobs and full snapshots remain accepted when they leave complete history. Construction from a snapshot and log asserts complete history, as retained rows and installed seeds must never be shallow. `snapshot()` always exports a full snapshot.

`merge(text:base:peer:restoring:)` turns an agent's text into edits made at `base`, the frontiers of the version the agent read (nil: the doc as it is). It forks the doc at `base`, applies the text into the fork as `peer`, and returns the update with the format's notes, or nil when the text changes nothing. It leaves the replica as it was: the caller logs the update, then imports it. `peer` must be new to the document: a fork at an older `base` would reuse a known peer's counters.
