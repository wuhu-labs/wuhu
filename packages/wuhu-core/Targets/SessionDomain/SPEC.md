# SessionDomain

## Reply discipline

The session prompt directs sessions to reach people through boxes and other sessions through session–session DMs. `send_message` exposes only `conversation` and `session` targets. Old person–session DMs are readable history, not reply surfaces.

A generation head may carry a settle snapshot and an optional settle boundary identifying the queue tail and sent-message sequence already folded into that snapshot. Only Start over writes the boundary; compaction and creation heads omit it. The field is optional for backward compatibility: existing heads decode with no boundary, and a nil boundary adds no bytes to their canonical JSON. Older decoders ignore the extra boundary while retaining all previously supported head fields, including the explicit settle snapshot.


`ImageLimits.fitted` derives its area ratio in floating point before multiplying image dimensions, so untrusted header dimensions do not overflow an integer width×height product. Model long-edge, patch-count and byte budgets retain their existing meanings.

`Transcript.renderRequest` is a projection of stored transcript entries and explicit attribution/system/tool inputs. It does not compute fullness or synthesize context-pressure notices. A pressure notice is an ordinary persisted context notification, grouped after a turn's tool results like other context notifications; its historical percentage, timestamp and position survive replay and Codable round trips.

Both model/bookmark and mechanical compaction use `Transcript.compacted` to build the new generation. Retained tails drop all old context-pressure notifications, at any position, while keeping other selected entries and recalculating `keptCount` from the actual retained items. Pressure is recomputed only before a subsequent inference against the new generation; ordinary reconnect/restart replay still keeps unfinished-turn notices verbatim.


An empty-summary head with no pre-reads is inert even when it carries subscriptions or a restart note. A nonempty summary or pre-read list makes the head work. Start over snapshots armed subscriptions as context, not an instruction to take a turn.
