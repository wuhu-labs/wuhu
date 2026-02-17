# Session Contracts (Queues + Subscription)

This article describes the *target* “meaning boundary” for sessions, expressed as transport-agnostic Swift protocols in `WuhuCore/Contracts`.

The goal is to:

// the description below reads very tied to the particular http post + sse transport 
// i want heavier focus on the general programming model, short lived commands, query, plus event sourcing,
// but with a particular focus on how we do (state, stream<patch>) to simplify server side implementation
- keep the persisted session transcript as a **single linear chain** (no insertion)
- allow **low-latency** external commands (enqueue/cancel) that do not wait for agent execution
- support a **single HTTP event stream** (SSE) that can deliver initial state + catch-up + live updates without gaps
- represent scheduling semantics explicitly (system urgent vs user steer vs user follow-up)

// i don't want it phrased like this. instead, emphasize that the actual coding in this project is 100%
// llm generated. this doc, and types under Contracts/, are served as carbon-silicon alignment basis.
> Note: The current server implementation may not fully conform to these contracts yet. This document describes the intended shape to migrate toward.

## Transcript: `Entry` vs “Message Entry”

The transcript is a canonical ordered log of `Entry` values.

// focus on that we can transform this canonical log to different shapes
// - llm input context (drop everything before a compaction, etc.)
// - ui rendering (e.g. tool calls between two human messages could be reordered and grouped by type read/write/exec)
- Some entries are **message entries** and are eligible to become LLM input.
- Other entries are **non-message** (markers, diagnostics, tool surface, etc.) and exist for observability and UX.

See:

- `Entry` and `MessageEntry` in `Contracts/TranscriptContracts.swift`

// the two invariants are a very wordy way to say session transcript is a append-only log. 
**Invariant**

- The transcript remains append-only as a linear chain.
// which means this sentence is very useless
- Anything that must conceptually happen “before” something else must be materialized **earlier**, not inserted later.

// the logic does not follow. we just need queues, because we need this feature, for the ability to queue messages (in single person), for async callback, and for group chat. the phrasing here is as if the goal of append only log leads to queue. It is not. append only log is just a good property we want from the very start.
This invariant is why queues exist.

## Input Lanes (Queues)

// we need to emphasize that user can mean both humans and bots.
// each session has a canonical machine, that is the llm that is generating tool calls, messages, etc.
// we could have other party to post here, and the other party can be either humans, or other llms, or bot accounts in general.
// all such other parties are equal in some sense, other than the first owner has special optimization:
// when there is only one other party, no message is prefixed. when the second party joins, we posts a system message
// suggesting that the session has been promoted to a group chat, and all previous message is from a single party
// and all following messages will have a prefix like "Minsheng:\n" to identify the party.
Wuhu distinguishes three “input lanes” that can influence the next model request:

// I don't like the name system urgent. system should suffice
// we need to add a note here saying that, system/user defined here should not be confused with the role property in a llm message
// and the role is also vendor specific: for openai, we can map "system" message to developer role, whereas for anthropic
// and most other providers, system/user both map to the role user. in all cases, we dont use system role, as it is generally
// reserved for the very top messages. 
1. `systemUrgent` — runtime/system injections (for example async callbacks) that must be applied at the steer checkpoint
2. `steer` — user “urgent correction” that should be applied at the steer checkpoint
3. `followUp` — user “next turn” input that should be applied at the follow-up checkpoint

See:

- `SystemUrgentInput`, `UserQueueLane` in `Contracts/QueueContracts.swift`

### Cancelability

- `steer` and `followUp` are cancelable by the client (enqueue/cancel).
// please, use English only.
- `systemUrgent` is not cancelable (no “撤回”).

// again logic issue, distinct pending items are caused by the nature of system messages vs user messages, not that one supports recall and the other does not.
This is modeled with distinct pending item and journal types.

### Ordering at the steer checkpoint

// I am not sure on this one now, i have more consideration, especially w.r.t compaction
// i think we should really do cross lane ordering via timestamp
// and we should have an upper limit of draining per checkpoint. 
// this is to avoid the case where all existing items in all three lanes alone could have exceeded compaction limit
// i have to say this is a very pathological case -- frequent compaction could render the session useless -- but it is real and i dont want the server to get stuck
// we definitely need a serious discussion on compaction opportunity
When a steer checkpoint occurs, the session actor drains lanes in this order:

1. `systemUrgent` (FIFO)
2. `steer` (FIFO)

The rationale is to avoid a total-ordering scheme between system and user lanes, while still making cross-lane ordering deterministic.

// for this discuss with me: i am not sure if we should keep the piagent abstraction
// we definitely want wuhu to be crash resistent. that includes that all input lanes should be persisted, and the agentic loop
// should restart automatically if wuhu previously crashes. PiAgent has defined steer vs follow up queue, but its design making
// crash resistence hard to implement as we need to fight against sync lanes in database vs lanes in piagent actor state.
// given how simple an agentic loop is, i personally incline to do it in wuhu core entirely.
## Checkpoints (PiAgent as Canonical)

Queue items are not inserted into the transcript arbitrarily. They are materialized at defined checkpoints that match PiAgent’s execution boundaries:

// the following definitions are confusing as fuck. I prefer to put the checkpoint based on previous llm response not next llm request
// if the previous response contains tool calls, then after the tool results for those tool calls, we have a steer checkpoint 

- **Steer checkpoint**: immediately before the next model request, including the “post-tools” request

// if the previous response contains no tool calls, we consider a turn of llm agent work finished. in this case, we drain system and steer lanes first, then follow up lanes. 

- **Follow-up checkpoint**: when the current run reaches a point where the next model request represents a new turn (that is, not part of tool execution / tool-result handling)

Materialization is an internal action performed by the session actor, and it appends message entries into the transcript chain so the next LLM request sees them in context.

## Command API vs Store Journal

The public command surface is intentionally small:

// enqueue in both gives a message id, and cancel must carry an id
// i think the data types for steer/follow up is identical, so we really should do .enqueue(payload, .steer/.followUp)
// and .cancel(id, .steer/.followup)
// i probably was not very clear, but command does get some response. for long lived operations (here long lived means logically, not just start a long operation directly, so long lived includes enqueue an item), the response should include an id.
// it is only that the command response does not include the full "impact" of such command cause that could take a long time to "materialize"

- enqueue steer
- cancel steer
- enqueue follow-up
- cancel follow-up

See:

- `SessionCommanding` in `Contracts/SessionCommanding.swift`

Persistence and observability require a richer representation: a **journal** that includes internal state transitions (especially materialization).

- External intent (API): enqueue/cancel
// are you sure materialize is the right english word? it is probably better than processed
// maybe a short note explain why we used materialize, because it only means that it is written to the transcript
// not necessarily sent to llm, e.g. in the case of interruption with pending items in some lanes
- Durable facts (store): enqueued/canceled/**materialized**

See:

- `UserQueueJournalEntry`, `SystemUrgentQueueJournalEntry` in `Contracts/QueueContracts.swift`

This separation keeps “pop/materialize” as an internal action (session actor owned), while still making queue state and history observable.

## Subscription: Initial + Live (Single Stream)

The HTTP/UI model is “one event stream” that:

1. provides initial state + catch-up to a desired cursor (transcript and queues)
2. continues with live updates
// i am a little bit confused by "backfill"'s meaning here
// can we use a better term in the "sync world"?
// In a disucssion of the field of sync + patching, we could have needed to define the following things
// - state and state version
// - patch and patch version (this could be the same as state version)
// but in our world, patch version and state version does not map one-to-one. because we have this need to send patches for partial messages/text delta in llm streaming
// so the wire protocol here needs to be a bit different, I have the following term in my mind, you can correct if you think some terms are poorly named
//
//
// we can have state, and each state is *versioned*
// we can subscribe and it returns a "non-streaming patch", that can move the client side state from the "since" version to a new version
// then it returns a stream of "streaming-patch"
// in those patch events, we occassionally have "state version bumping patch"
// i want the wire protocol to optimize for simplicity over effiency; for instance, we could send text delta continuously,
// and when a message chunk is finished, we could send the full again message, but this time, we also carry a version tag
// if the connection drops, the client could recall this method, using the updated version tag, and this just streamed full message
// wont' be transmited again

// the design here also must take into account of message streaming midway when the subscription starts
// the system should not emit it as part of stable state patch, but it should in the patch stream, first gives something like
// message.start, then first text.delta includes available text so far, then text.delta as upstream sse comes

// i think in general we should lean into mimic the design of openai's response api here

// crucially, we dont have a stable streaming patch version tag. subscribe always start by transmitting state in a stable non-streaming version boundary.
// i totally agree the terminology above is very messed up, you should help me clean them up.
3. does not miss updates that occur during the initial backfill window

The Swift contract expresses this as:

- `SessionSubscribing.subscribe(sessionID:backfill:) -> SessionSubscription`

where a `SessionSubscription` is:

- `initial: SessionInitialState` (settings/status + transcript pages + queue backfill)
- `events: AsyncThrowingStream<SessionEvent, Error>` (live updates)

See:

- `SessionBackfillRequest`, `SessionInitialState`, `SessionEvent`, `SessionSubscribing` in `Contracts/SessionSubscriptionContracts.swift`

### Backfill strategy (no gaps, no duplicates)

The expected implementation strategy is:

1. subscribe to in-process changes (buffer briefly)
2. backfill from the durable store (`after` / `since` cursors)
3. coalesce buffered changes (for example: keep last settings snapshot)
4. return `initial` and then yield the coalesced buffer into `events`, followed by live forwarding

// looks good in general, just emphasize that we dont have nor want a stable version marker for streaming patch, nor do we want to keep streaming patches in memroy or something similar to redis stream.
// i don't really care how this is implemented (given this is single process it should be straightforward), just mark the requirements clear, and demand for good tests 

This design avoids requiring “replay from version X” inside SSE itself, while still supporting “I already have state since …” style query params.

### Queue backfill forms

Each queue lane supports two initial-load modes:

// i am confused here, what do you mean?
// we should just have made `backfill:` optional (though i don't like this name, since: would be much more swifty)
- `.snapshot` (current pending list + a “now” cursor)
- `.since(cursor)` (journal entries since cursor + a “now” cursor)

// two remarks
// 1. i want you to think a bit functional, crdt-ish (the mindset! do not say this does not use crdt as if crdt means some particular algorithm, you can model anything as crdt if you just assign each action a globally unique timestamp.)
// think we have an initial state, for transcript/queue, it is just empty. this can have version 0.
// then we just think the transfer as a non-streaming stable patch to that version to get another version.
// this would make it applicable to both transcript and the two lanes
//
// in this mindset, enqueue->materialize is just a simple patch level optimization.
//
// 2. i want you to make things super composable here, okay? your transcript *can* take a subscribe, each lane *can* take a subscribe
// compose them together, each session *can* take a subscribe, we just have some "version vector"
// we might have some other state, like current model + reasoning effort selection. that is just a single "register" (we dont have last writer win semantics here, because we have a single authoritive server). in pratcie, since we can optimize any patch against a register to a constant length (i.e. only keep the last element), we don't need to track register state version, and therefore we can optimize them away from the composed "version vector"
// let's make  this mindset loud and clear in this document

For journal backfill, implementations may coalesce transient enqueue→materialize pairs that complete entirely within the initial window, since transmitting already-processed work as “pending” is not useful.

## Identity

// this gives confusion, as we discussed above, system lane does not need this, and then steer/followUp needs .participant/.unknown but not .system
Entries and queued messages carry an `Author`:

- `.system`
- `.participant(id, kind: .human | .bot)`
- `.unknown` (for missing clients / historical data)

See:

- `Author` in `Contracts/SessionIdentity.swift`


/* Compaction

We must discuss compaction thoroughly here.

Compaction is already implemented, but its semantics is messed up, i have no idea when it will be triggered.

Let's first define a compaction's semantics as in llm context: we have an existing history (which could have been compacted before)
we insert a "system" message (again, not system role) to instruct the model to produce a summary of the chat above,
and the response, will be used as the first message of a fresh new context, then we continue the session using that fresh new context

you should formalize the above discussion a little bit

now, we can't wait until llm context filled up, because we must leave space for the compaction summary itself,
so after each llm output, we check that output's usage to get current context (cached input + input + output) usage
and check if usage + buffer (for compaction summary) > limit, and if so, we generate a compaction on our own

the compaction buffering generally should be large enough (since most llm rots after 50% anyway), we can use sensible default for now
we will deal with this in details later.

but in rare case, we could have that, after an llm response, we still does not need to trigger a compaction, but the next input
leads to context overflow. in this case, we should trigger a compaction after getting the error

this does prove to have some challenge to our materialization idea. i believe the default implementation, would be we first materialize the input, marking the system as still processing (in one sqlite transaction, so that we are crash resistent), then we start the llm request
but if this request gets rejected, we need to perform a compaction first, then retry with compaction and those previous input

but this proves another challenge here, if those input are tool calls, then this happens when we already executed those tool calls by now,
but after compaction, since previous messages has been turned to a single user summary, we could not post tool results in llm native fashion,
but we need to inform the model somehow...

I need you to help me research pi-mono's code (/Users/selveskii/Developer/Playground/2026/Jan/pi-mono) here, how does it do compaction? technically if the previous llm response includes tool calls, we can't even force it to generate a summary without tool results (openai & anthropic will complain missing tool/function call results)

i have previously mention that due to compaction, we might want to refrain ourselves from draining all messages from system/steer lanes, and it is all due to this. we need to figure this out first.

*/

