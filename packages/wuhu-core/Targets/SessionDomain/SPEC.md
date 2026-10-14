# SessionDomain

## Scope-context state

`ScopeContext.deliveredContext` and `SystemNotification.deliveredContext` optionally carry delivery-kind-prefixed SHA-256-to-first-source-path maps for automatically delivered instruction files and skill listings. `ToolExecutionState.deliveredContext` folds these maps from persisted notices in log order, preserving the first path for each hash. Legacy notices/states without the field decode with no delivered-content history. A generation head resets this map and folder roots; context metadata on entries retained from a previous generation is excluded from the new generation's fold without changing those historical entries or their rendering. New notices after the retained tail count normally. State snapshots carry neither map nor folder roots, so compaction and Start over load files again on their next touch; hydration/restart of the same generation retains dedupe history.

## Reply discipline

The session prompt directs sessions to reach people through boxes and other sessions through session–session DMs. `send_message` exposes only `conversation` and `session` targets. Old person–session DMs are readable history, not reply surfaces.

A generation head may carry a settle snapshot and an optional settle boundary identifying the queue tail and sent-message sequence already folded into that snapshot. Only Start over writes the boundary; compaction and creation heads omit it. The field is optional for backward compatibility: existing heads decode with no boundary, and a nil boundary adds no bytes to their canonical JSON. Older decoders ignore the extra boundary while retaining all previously supported head fields, including the explicit settle snapshot.


`ImageLimits.fitted` derives its area ratio in floating point before multiplying image dimensions, so untrusted header dimensions do not overflow an integer width×height product. Model long-edge, patch-count and byte budgets retain their existing meanings.

`Transcript.renderRequest` is a projection of stored transcript entries and explicit attribution/system/tool inputs. It does not compute fullness or synthesize context-pressure notices. A pressure notice is an ordinary persisted context notification, grouped after a turn's tool results like other context notifications; its historical percentage, timestamp and position survive replay and Codable round trips.

Both model/bookmark and mechanical compaction use `Transcript.compacted` to build the new generation. Retained tails drop all old context-pressure notifications, at any position, while keeping other selected entries and recalculating `keptCount` from the actual retained items. Pressure is recomputed only before a subsequent inference against the new generation; ordinary reconnect/restart replay still keeps unfinished-turn notices verbatim.


An empty-summary head with no pre-reads is inert even when it carries subscriptions or a restart note. A nonempty summary or pre-read list makes the head work. Start over snapshots armed subscriptions as context, not an instruction to take a turn.

## Cache-warming input classification

`Transcript.cacheWarmingInputOrigin` classifies the latest substantive delivered input, scanning backward through assistant entries, tool results, bookmarks and generation heads. A nonempty context notification with subscription ID `cache-warming` marks warming origin; direct and conversation messages (including requests), timers, observations and other non-nag delivered notifications mark real-input origin. Context notices, owed-reply nags and park reminders are inert for this classification. An empty canceled warming notice is also inert. With no substantive input, the projection is nil and the store preserves its durable origin across generation changes.

An assistant commit caused by real input resets the warming ping count; a warming-origin commit and its tool/bookmark continuations preserve it. Nags appended in the same assistant batch cannot reset it. Silent handler firings without a delivered wake neither reset the count nor move the inference deadline. Compaction preserves the count and origin, while clearing the offer baseline. Start over deliberately clears all warming state; an opted-in agent starts a fresh budget after its next inference. A server restart preserves durable state and defers overdue deadlines without catch-up pings.

`Transcript.hasPendingCacheWarming` identifies nonempty warming notices after the latest assistant entry. `discardingPendingCacheWarming` cancels them and subsequent unconsumed context-pressure decorations by emptying their text without removing historical positions or real delivered input. Canceled notices are absent from rendering and cannot create work. The runtime revalidates current agent/model opt-in and quota before consuming a persisted notice, including after queue recovery or Start over.

## Retired executors

`SessionExecutor.claudeCode` is a decode-only legacy discriminator. `ExecutorUnavailableError` is the typed refusal for using it, with description "executor no longer supported". `requireSupported` rejects it; `isRemoved` identifies retired Claude Code and contractor records for store-only lifecycle handling. `SessionCreationParams.executor` accepts nil or `kernel`; `claude-code` throws that error, and other strings are invalid executor specifications. Template manifests validate the compatibility field before merging, so an explicit override does not conceal a template naming the removed executor. Model resolution refuses a removed result rather than routing it to the kernel. `ToolFailure.code` optionally carries a machine-readable rejection code; unsupported creation uses `executorNoLongerSupported` with the same description as its message.

`Transcript.registeredSubscriptions` is an optional transient projection of durable registration IDs, not transcript history and not part of Codable bytes. With no projection the pure history fold is unchanged. With a projection, the completed environment fold drops observe/timer subscriptions absent from the registration set, without changing file access, folder roots, settle state or request-deadline delivery semantics. Compaction applies the same filter to the supplied head snapshot and carries the projection onto its returned transcript, so retained historical timer results cannot recreate a retired timer. Rendering projects generation-head subscription context without mutating historical entries. Stores and loaded runtimes must refresh this read snapshot before using current subscription state.


`Transcript.handlerSubscriptions` and `ToolExecutionState.handlerSubscriptions` are transient handler-ID sets, defaulting to empty and excluded from Codable bytes. The transcript fold projects the handler IDs into tool state; compaction carries them on its returned transcript. An armed handler timer is not a guaranteed model wake and does not suppress task/request park reminders. Plain timers and request deadlines retain the prior guaranteed-wake behavior; observers remain nonguaranteed.

## Requested group targets

`SessionExecutor.modelGroup(id:effort:)` runs in the kernel and renders requested intent as `{"modelGroup":"id","effort":"high"}` for inspection; storage writes the pin as legacy concrete provider/model/effort and recovers group intent additively from the route row. The effective effort is frozen at resolution. Group targets are mutually exclusive with provider/model at create, Start over and in templates. Explicit targets replace template/inherited target fields as a whole; effort-only overrides keep the requested target. Children inherit intent, not an active member pin. Removed executor rules remain unchanged. `SessionModelRoute` is separate from intent and carries optional group/member and a concrete specifier, endpoint/auth binding fingerprint, opaque route epoch and placement reason/time/evidence; it contains no credentials or personal account IDs.

## Portable replay handoff

`ReplayBinding` is an opaque configured credential/endpoint identity and independent route epoch. Assistant entries and generation heads optionally carry it; old JSON decodes without one. Ordinary compaction preserves the last binding and route epoch. `Transcript.hasUnscopedReplay` detects legacy account-bound reasoning/hosted records without a verified origin; absence of scope never establishes affinity.

`portableHandoff` is a local mechanical projection into a new generation, not a model summary. It refuses pending kernel calls, replaces encrypted reasoning with separately stored readable summaries (drops redacted blocks), and replaces hosted records with type/action digests. It never decodes opaque content. Rewritten assistant entries receive new content IDs while kernel call IDs/mappings and retained receipt IDs stay unchanged. A bounded completed recent tail and full outstanding request/owed-message bodies and attachment references survive; older portable content becomes a bounded digest. Subscription and settle/open-request state are carried structurally. If indispensable inputs cannot fit the destination usable budget, `modelHandoffTooLarge` refuses instead of truncating the task. Historical opaque entries remain inspectable in their old generation.

`SessionTitle.maximumCharacters` is the shared 200-character title bound for persistence validation and worker tool schemas. `SessionStore.titleLimit` retains its existing public value through that contract constant.
