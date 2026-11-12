# SessionDomain

## Scope-context state

`ScopeContext.deliveredContext` and `SystemNotification.deliveredContext` carry delivery-kind-prefixed SHA-256-to-first-source-path maps for automatically delivered instruction files and skill listings. `ToolExecutionState` is the tool boundary's explicit state; LoopCore persists it in `session_seen`, not by folding stored notices. The first source for each text hash wins within a generation. Compaction and Start over reset folder and text deduplication; a retained file receipt keeps its revision.

## Reply discipline

The system `AGENTS.md` directs sessions to reach people through boxes and other sessions through session–session DMs. `send_message` exposes only `conversation` and `session` targets. Old person–session DMs are readable history, not reply surfaces.

`NagState` keeps owed conversations and park reminders. Deliveries and committed tool results update it as the cell writes them. Open requests come from the requests table. Compaction and Start over retain this state unchanged, rather than reconstructing it from generation heads or lines.

`ImageLimits.fitted` derives its area ratio in floating point before multiplying dimensions, so untrusted header dimensions do not overflow an integer width×height product. `ImageLimits.intake` fits images once on admission; provider limits only price them afterward. Stored message lines carry no pixel dimensions: each image is estimated at the selected model's maximum image cost, so small images can trigger pressure earlier than dimension-aware estimates did.

`TranscriptItem` is an admission/rendering value, not a stored transcript schema. `TranscriptItem.lines(session:)` renders it once to `TranscriptLine` values (time, key, message, optional inference metadata). Requests send those messages unchanged. Keys are `head`, `head:note`, `head:summary`, `head:nudge`, `message:<messageID>`, `subscription:<subscriptionID>`, `attempt:<entry id>`, `call:<toolCallID>` and `reestablish`; a following image message adds `:image`. Assistant replies made in the current generation carry stop-reason and usage metadata; carried lines do not. Scope notices may be held on the cell row until the current reply's tool answers finish. `TranscriptPreamble` holds the fixed system prompt and tools named by stored position zero.

Line operations find calls, choose the range after a bookmark without orphaning its answers, estimate tokens, and select a recent tail without splitting a tool turn. A new generation drops old context-pressure notices. Pressure notices within a generation are ordinary persisted lines: estimation and rendering never change their percentage or position. Empty-summary generation heads with no pre-reads are inert even with subscriptions or a restart note; a nonempty summary or pre-reads makes a compaction head work.

## Cache-warming input classification

`TranscriptItem.cacheWarmingOrigin` classifies each admitted item: a nonempty warming notice is warming input, conversation messages and substantive notifications are real input, and assistant/tool/bookmark/head items, context notices and nags are inert. The cell keeps the last nonnil classification on its row, and a step it starts while that is warming is a ping. `SystemNotification.cacheWarming(id:at:)` is the notice's one source; `WarmingSchedule` is what a reply leaves the cell to wake and count with. A reply to real input resets the ping count and a ping's own reply preserves it; a reply carrying no schedule ends warming, as do Start over and a failed ping. Only a reply to real input starts warming: any other reply moves a warming that still exists and leaves a nil one nil, so warming that ended stays ended until real input. Compaction preserves count and origin.

## Retired executors

A session's executor is what runs it: `kernel`, or a model group. `SessionExecutor.retired(kind:)` is the decode-only value for a session an old space left on an executor this build does not have; it keeps the stored kind because the apps label archived sessions by it, and nothing creates, starts, restarts or rewrites one. `ExecutorUnavailableError` is the typed refusal for running one, with description "executor no longer supported"; `requireSupported` throws it, and `isRetired` identifies those records for store-only lifecycle handling. `SessionCreationParams.executor` accepts nil or `kernel`; any other string is an invalid executor specification (`ExecutorSpecError`, message "unknown executor: <value>"). Template manifests validate the compatibility field before merging, so an explicit override does not conceal a template naming an unknown executor. Model resolution refuses a retired result rather than routing it to the kernel. `ToolFailure.code` carries `invalidArgument` for a rejected executor.

A generation head's `snapshot.subscriptions` is what the session's cell found armed when it wrote the generation, rendered as `<session-state>`'s active subscriptions; the fold does not read it, and the transcript says nothing of what is armed. `NagState.nag` and `nextTimer` take `armedWake` from the cell: a plain timer is armed, which is sure to wake the model, so no park reminder is due. A handler's timer can stay silent and an observation may never fire, so neither counts.

## Requested group targets

`SessionExecutor.modelGroup(id:effort:)` runs in the kernel and renders requested intent as `{"modelGroup":"id","effort":"high"}` for inspection; storage writes the pin as legacy concrete provider/model/effort and recovers group intent additively from the route row. The effective effort is frozen at resolution. Group targets are mutually exclusive with provider/model at create, Start over and in templates. Explicit targets replace template/inherited target fields as a whole; effort-only overrides keep the requested target. Children inherit intent, not an active member pin. Removed executor rules remain unchanged. `SessionModelRoute` is separate from intent and carries optional group/member and a concrete specifier, endpoint/auth binding fingerprint, opaque route epoch and placement reason/time/evidence; it contains no credentials or personal account IDs. Placement evidence lists every binding window. A window’s `usedPercent`, `remaining` and `score` are optional so unobserved windows are explicit; any unscored binding makes the member score unknown.

## Portable replay handoff

`ReplayBinding` is an opaque configured credential/endpoint identity and independent route epoch. The session cell persists the latest binding; assistant entries and generation heads can also carry it. Ordinary compaction preserves it unless placement supplies a new one.

A portable replay handoff writes a pointer head and at most 8192 estimated tokens of recent, completed line history, plus a reserved `replay-handoff` notice. `TranscriptLine.carried(portable:)` clears inference metadata, replaces encrypted reasoning with its separately stored readable summary (drops redacted or summaryless blocks), and replaces hosted records with their digests. It never decodes opaque content. Call and receipt IDs remain paired. No older digest or protected request/message bodies are carried, and there is no destination-budget fit gate. Historical opaque content remains in its old generation. Route notices use `model-route`; both sources continue the current tool turn rather than starting a new input turn.

`SessionTitle.maximumCharacters` is the shared 200-character title bound for persistence validation and worker tool schemas. `SessionStore.titleLimit` retains its existing public value through that contract constant.

## Compaction placement

`SessionModelRoute.failure` is optional typed provenance with reason (`quota`, `authentication` or `upstreamOutage`), source, bounded code, first-failure time, optional latest-failure time, retry time and consecutive count; `refusing` is false only for an outage below three consecutive failures. Legacy failure JSON without a latest-failure time uses its first-failure time, and a legacy `deadline` or route `switchCause` is ignored on decode. `ModelRouteTransition` couples expected old epoch, replacement route, optional binding and notice, and a required `carriesTail` decision. A kept tail too large for the selected member is dropped. Route context notices state the aliases/reason and continuation semantics, and do not create a message/reply obligation.

FileRevision stores opaque machine version tokens as machine(String), while retaining legacy numeric mtime receipts and journal revisions. All three variants round-trip in stored tool results and file-access logs; new servers continue decoding existing receipts.

## Generation cache prefix

For every provider, past rendered messages are an exact prefix of every later request in the same generation; only appended input differs. System prompt and tools remain fixed within a generation. Message attribution is resolved once on transcript admission and stored with its sender; handle/device renames affect only later admissions. `MessageContent.following(_:)` puts an earlier exchange in a `<earlier-in-conversation>` block ahead of the delivered text; each quoted message is cut so its escaped text stays within `EarlierMessage.maxBytes`, and a cut names the source bytes kept, the total and the message id to read for the rest. The block is part of the admitted item, never re-rendered. The generation head's subscriptions, running work and pre-reads are a persisted snapshot from generation start (creation, compaction or Start over), not a live projection. Hydration after a server restart renders the same snapshot bytes. Old heads without running work render `running: none`; every new head constructor requires an explicit running snapshot, including portable replay and model/account switches. Subscription reconciliation affects scheduling and the next generation's snapshot, never historical rendering; silent handler retirement remains silent, and live registrations can be queried through `subscriptions`.

## Durable tool outcomes

`ToolOutcome.committed` is an optional asynchronous acknowledgement of durable admission, not tool execution. The worker invokes it only after successfully appending the outcome's tool result and optional context notice, for both ordinary calls and compaction re-establishment calls. A failed append or discarded outcome never invokes it. The callback may release retained external evidence (such as an exec caller leg) once the transcript owns the result.

`ToolResultPayload.text` is a tool result as plain text, for a caller that keeps no per-tool result shape; its failed call is `.failure`. It renders, estimates and backstops like a script result and changes no tool state.

`estimateTokens` (a quarter token per UTF-8 byte, rounded up) and `ContentBlock.estimatedTokens` are public so a caller outside the target estimates a transcript by the rule `[TranscriptLine].estimatedContextTokens` uses.
