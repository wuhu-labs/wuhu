# SpaceContract

The wire contract for the space domain: every tool input/output, the observe
payload, and the error shape. Swift is the source of truth. JSON Schema is
derived from these `@Contract` types (see the checked-in `Tests/contract/*.schema.json`
fixtures, which are simultaneously the golden fixtures, the reviewable contract
diff, and the LLM tool definitions); TypeScript is derived from the schema files.
The target imports nothing beyond `Contract` and `JSONValue` so server internals
cannot leak into wire types.

This file pins the wire semantics the JSON Schema cannot carry. It is a contract:
changes here are contract changes.

## Encoding conventions

- **Discriminated unions** (`MutationEvent`, `RowOp`, `ObserveInput`) are
  **internally tagged**: `{"kind": "<case>", …flattened labeled values}`, never
  the externally-tagged `{"<case>": {…}}` wrapper and never a `_0` key. The
  `@Contract` macro derives both the schema and the matching `Codable` from one
  source, so they cannot drift.
- **Optional fields** are omitted from the object when absent (never sent as an
  explicit `null`), and are absent from the schema's `required`.
- **`JSONValue` leaf** (`QueryOutput.rows` cells, `RowOp` insert/update `values`)
  is any JSON value; its schema is the empty schema `{}`. Values keep their JSON
  type on the wire — a number stays a number, a string a string, `null` null —
  with no string re-encoding. A `json`-typed table column therefore carries its
  canonical JSON directly, not a JSON-in-a-string, and a `boolean` column
  carries `true`/`false`. This rehydration follows the **declared column type**
  of each result column: an expression or computed column (which has no declared
  type) surfaces the raw SQLite storage class instead — a boolean expression is
  `0`/`1`, JSON built by an expression is a string.

## Field semantics

- **`mtime`** (`Entry.mtime`, `HistoryEntry.mtime`): **seconds since the Unix
  epoch** (1970-01-01T00:00:00Z), UTC, fractional. Not the 2001 reference-date
  epoch, not milliseconds. A consumer converts with
  `Date(timeIntervalSince1970: mtime)` / `new Date(mtime * 1000)`.

- **Version tokens** (`Entry.token`, `ReadOutput.token`, `WriteOutput.token`,
  `EditOutput.token`, `SyncOutput.token`, `CheckoutOutput.token`): an **opaque** string. Clients must
  not parse or compare it structurally; they record it from a read/write and pass
  it back verbatim as `ifMatch` on the next write/edit/remove. Space backend:
  revision-backed and content-stable (a no-change write mints no revision and
  returns the same token). Machine backend: mtime-derived. The opacity is what
  lets the two backends share one contract.

- **`sync`** is the revisioned-space document reconciliation verb. A client sends
  the full UTF-8 `content` it edited and the opaque `baseToken` returned by the
  read that established its editing baseline. The server performs a three-way,
  line-based merge against that historical revision. `saved` and `merged` return
  the canonical stored content and its new baseline; `conflict` returns the live
  content and token without writing. Overlapping changes are never resolved by
  last-writer-wins. Machine paths and non-UTF-8 content are unsupported.

- **`ReadInput.lines`**: a 1-based, inclusive line range spelled `"A-B"` (e.g.
  `"1-40"` is the first forty lines). Both endpoints are required. Omit `lines`
  to read the whole file.

- **Grep pagination** (`GrepInput.step`, `GrepOutput.cursor`): an **opaque**
  continuation cursor string (donor `GrepTool` semantics). `GrepOutput.cursor`
  is present **iff** the results were truncated by `matchLimit`/`entryLimit`;
  the client passes it back as the next `GrepInput.step` to continue. Absent
  `cursor` means the scan is complete.

- **`HistoryEntry`**: `to` is present on `move` entries (the destination path);
  `fromRev` is present on `checkout` entries (the revision the content was
  restored from). Both absent otherwise, so a history entry explains itself
  without a correlated read.

- **`HistoryEntry.by` / `.via`**: present on a revision a page wrote through
  `/_/space/*` (SpaceServer SPEC, "Page data"): `by` the viewer's persona,
  the three-word id of the read cookie's account (absent for the `--dev`
  seat), `via` the path the page reported. `via` is the page's claim, not authenticated.

- **`TableMutateOutput.ids`**: the ids of the rows `insert` ops created, in
  op order, one revision for the whole call. `table.mutate` stays
  positional; the named row ops (`{insert: {col: v}}`, `{update: id, set}`,
  `{delete: id}`) exist only in `wuhu:space` and `POST /_/space/rows`, and
  touch each row id at most once per call (`invalidArgument` otherwise).

- **`attributes.read` / `attributes.patch`**: a Markdown file's top-level
  frontmatter keys, read from the source YAML, and the token of the file.
  A patch sets keys (values any JSON) and removes keys under `ifMatch`; a
  stale `ifMatch` fails `conflict` with `ToolError.token` the current token.
  It keeps the body bytes, the newline style, and the order, comments and
  quoting of untouched keys; a changed key is edited in place and a new one
  appended. A file with no frontmatter gains a block; a non-`.md` path is
  `invalidArgument`, and so is frontmatter the patch cannot edit safely (a
  root flow mapping).

- **`ToolError.token`**: a conflict's current version token, when the verb
  knows it, so a client retries without a second read.

- **Typed query cells** (`/_/space/query`, `/_/space/observe`, `wuhu:space`):
  a cell is a JSON scalar, `{"blob": base64}` or `{"json": value}`. A BOOLEAN
  column is `true`/`false` and a JSON column `{"json": value}`; bound
  parameters take the same forms. The legacy `query` tool and `/_/query` keep
  their shape.

- **`ListOutput.rev`**: the space's current committed revision, read in the same
  snapshot as `entries` — the listing reflects exactly the space at `rev`.
  Passing it as observe's `from` makes `ls` → `observe?glob=…&from=<rev>`
  gap-free with no full replay. On an `@rev` listing it is the pinned revision.

- **Key labels and signatures**: an enrolled `pubkey` is an algorithm-tagged
  label — `ed25519:<b64>` (raw 32-byte Ed25519 key) or `p256:<b64>` (65-byte
  X9.63 uncompressed P-256 point, byte-for-byte the WebCrypto `raw` export).
  A signature is raw 64 bytes under both algorithms: Ed25519, or ECDSA P-256
  r||s hashed with SHA-256 (the WebCrypto shape; DER is rejected). The label's
  tag alone selects the verifier, and a signed assertion's JWT header `alg`
  (`EdDSA` for `ed25519:`, `ES256` for `p256:`) must match that tag — any
  mismatch is invalid, which closes algorithm confusion. Ed25519 is what
  native clients (CLI, machine agent) mint; `p256:` exists for WebCrypto
  engines that lack Ed25519.

  Base64 convention is **per field**, and the two are not interchangeable —
  a browser that picks the wrong one gets a silent `401`, never a parse hint:

  - The **pubkey label's** `<b64>` and the **handshake signature** (the
    `signature` in `ShareLoginInput` and the `x-wuhu-machine-signature`
    connect header) are **standard** base64 — `+`/`/`, `=` padding. The
    decoder (`Data(base64Encoded:)`) rejects base64url and unpadded input.
  - The **JWT assertion**'s three dot-separated segments
    (`header.payload.sig`) are **base64url**, unpadded (`-`/`_`, no `=`) —
    the raw signature bytes in the third segment are encoded this way, not
    standard base64.

- **Share-login handshake** (`ShareLoginInput`): `challenge` is a one-shot,
  short-lived value from `GET /v1/enroll/share-login/challenge`; `signature`
  is the base64 raw signature (per `pubkey`'s label algorithm above) by
  `pubkey`'s private key over the UTF-8 bytes of
  `ShareLogin.signingMessage(challenge:)` (`wuhu-share-login:<challenge>`).
  The signature authenticates the minter; `pubkey` only names the enrolled
  key row it is verified against.

## Observe delivery

`ObserveInput` is the observe verb's input; delivery payloads are pinned here
because the stream framing has no `@Contract` return type of its own:

- **`glob(pattern:)`** delivers a stream of `MutationEvent` for paths matching the
  glob, in one group: a hostless glob watches the acting group, and
  `wuhu://<group>.localspace/<glob>` watches that group when the acting group
  reads it (404 `notFound` otherwise, like a missing path). Events of a
  qualified glob carry the same `wuhu://<group>.localspace` prefix on `path`
  and a move's `to`; no stream carries another group's events, replayed or
  live.
- **`sql(query:throttleMs:)`** delivers `QueryOutput` snapshots, re-emitted when
  the result set changes, throttled by `throttleMs` (milliseconds; absent means
  no additional throttle). On `GET /v1/observe` the SQL function `viewer()`
  returns the caller's identity, the one a `POST /v1/watermark` from the same
  credential would advance. A statement calling `viewer()` from a credential
  that resolves to no identity is refused with the watermark POST's error
  rather than read as `NULL`. Everywhere else (`/_/observe`, the `query`
  tool, session observes) it returns `NULL`. A statement joining `notifications` and
  `watermarks` on `viewer()` is how a client observes its own unread state.

`checkout` restores old content, and a `glob` observer of the affected path
receives a `MutationEvent` of kind **`write`** — observers care that content
changed, not how. The provenance that the change was a checkout lives in
`HistoryEntry.change == .checkout` (with `fromRev`), not in the mutation stream.
This is why `MutationEvent` has no `checkout` case even though `ChangeKind` does.

`write` and `move` events carry `entry` — the node's `EntryKind` (for a move,
the node at the destination). `delete` events carry no `entry`: the journal
tombstones a deleted path without recording what it was, so replayed deletes
cannot state a kind, and live deletes stay wire-identical to their replay.

## Session domain wire semantics

Identity attribution: the server operates a single distinguished **owner**
human identity. `identity` fields are optional everywhere; absent (or the
literal `owner`) means the owner, and any other value must be a persona the
space minted at `POST /v1/persona` (`PersonaMintOutput`) — an allocator
word-name drawn against the caller's enrolled key, sharing the allocation
counter with session ids so the two name spaces cannot collide. A free-form
identity is rejected with 403 `unknownIdentity` before it can act. `timezone`
fields are IANA identifiers supplied by the client seat (the CLI sends the
local timezone, the SPA the browser's); absent means UTC — never
server-local.

- **`ToolRostersOutput`** (`GET /v1/session-tools?executor=kernel|claude-code`): the tool roster a session of that executor kind is given, from the one declaration the runtime reads. `ToolDescriptor.parameters` is the tool's parameter JSON Schema verbatim. Omitting `executor` returns both rosters, kernel first. The kernel roster is the Claude Code roster plus the transcript tools the loop executes itself (`bookmark`, `compact`); Claude Code compacts on its own, so MCP `tools/list` serves the Claude Code roster exactly. The route is deliberately not under `/v1/tools`, which is the space toolbox a person drives.
- **`SessionCreateInput`**: the provider's dialect picks the executor — a
  `claude` provider runs Claude Code, every other one the kernel loop — so
  there is no executor field. `effort` absent means the model's declared default
  effort; `SessionCreateOutput.effort` reports the resolved value. The model
  specifier is validated against the space's `/models.json` — unknown
  provider/model/effort is rejected before the session row exists, and so is a
  title that is not one non-empty line of at most 200 characters. The created
  session is inert until something is posted to it. From a session's exec
  token, the call is the `create_session` tool: `kind` absent means a
  child task, the model fields absent mean the caller's own, and `topLevel:
  true` asks for a top-level agent (refused to a task); a human's call
  ignores `topLevel`.
- **`SessionRequestInput` / `SessionRequestOutput`** (`POST
  /v1/session/:id/request`, session token only): the `request` tool on a
  child of the calling session. `deadlineSeconds` is the tool's
  `deadline_seconds`; the answer carries the request id and the DM it was
  posted in.
- **`SessionTagsInput`** (`POST /v1/session/:id/tags`): `tags` replaces the
  session's whole tag list; an empty array clears it. Allowed on any
  lifecycle. The answer is the stored list as `{"tags": [...]}`.
- **`SessionRestartInput`** (`POST /v1/session/:id/restart`): every model
  field is optional and an omitted one keeps the session's live spec, so an
  empty body is a pure transcript wipe. A restart on the same provider keeps
  what it does not name; naming another provider carries nothing over. A
  session left from the removed contractor executor has no spec to keep, so it
  needs `provider` and `model`. The resolved spec is validated
  exactly as `SessionCreateInput` is. `message`, when given, is posted right
  after the restart as an ordinary input, and `SessionRestartOutput.queued`
  reports its delivery count (absent when no message was carried);
  `generation` is the new epoch. The line the space writes
  into the fresh generation rides the head's `note`, never a transcript item:
  a note is context, so a restarted session is inert until something is posted
  to it.
- **`ProvidersOutput`** (`GET /v1/providers`): every provider in the space's
  `/models.json`, sorted by id, with its dialect and models. `usage` is the plan
  usage the server last observed and is absent until it has one; only the
  `codex` and `claude` dialects report it. Inference refreshes it for free
  (Codex response headers, Claude Code's rate-limit events), and the server
  reads it itself once a provider has gone fifteen minutes unobserved. Windows
  are named by length (`five_hour`, `seven_day`) and merge by name, so a report
  naming one window leaves the others standing. `usedPercent` is 0-100 and may
  pass 100; `resetsAt` and `observedAt` are epoch seconds.
- **`attachments`** (on `ConversationPostInput`): paths of files already in the space and already written, each hostless (`/<path>`, read in the acting group) or `wuhu://<group>.localspace/<path>` in a group the acting group reads, exactly as `send_message` takes them; anything else is refused as not a space path (`400`), and a group the acting group does not read answers `404 notFound` like a missing file. Files carried with the post itself travel as `multipart/form-data`: a part named `message` holding the `ConversationPostInput` JSON, then one part named `file` per file, in order, its `filename` the name the copy keeps. A post without files may still be plain `application/json`; there is no base64 form. A message carries at most 8 attachments, uploads and paths together, each at most 50 MiB and 150 MiB in all, of any type (`AttachmentLimits`). The server counts bytes as a part streams in, so a refused upload stops at the byte that broke the limit; the refusals are `400 tooManyAttachments`, `413 attachmentTooLarge` and `413 attachmentsTooLarge`, each naming the file, plus `400 invalidArgument` for a malformed body and `404 notFound` for a path that is not a file. The message part is capped at 8 MiB and the whole body at 166 MiB. An uploaded name keeps only its last `/` component, with `@ % # ?`, control and format characters replaced by `_`. A file whose name says `png`/`jpg`/`jpeg`/`gif`/`webp` and whose bytes carry that format's magic bytes is stored as the `image` case, whatever its size; anything else is the `file` case, typed by its extension (`MediaType`), else by the part's declared `Content-Type`, else `application/octet-stream`. Whether an image reaches a model as an image is decided when the message is delivered: up to 3 MB (`ImageMedia.maxBytes`) it goes as an image block, scaled then to what the receiving model takes, and past that it becomes one line like any other file. Within the acting group there is no further location gate on a path. In the transaction that stores the message, each file is copied to `/_/conversations/<conversation>/attachments/YYYY/MM/DD/HHmmssZ/<name>` in the conversation's group (the post's UTC time; a clash becomes `name-2.ext`, `name-3.ext`, …; the mutation event carries that group), and `ConversationMessagePayload.attachments` lists those copies, never the original path, each as an `AttachmentPayload`. A copy's path is stored hostless and handed to each reader as it names it: hostless to a reader acting in the conversation's group, `wuhu://<group>.localspace/<path>` to anyone else, whether read over `/v1/conversation/<id>/messages` and its observe stream, a script's `conversation()`, or delivered into a session's queue (named from the recipient's group). A member of a conversation reads its attachment folder in the conversation's group even when its own group does not read that group, so every member of a cross-group DM can open, re-attach and download what was posted there. The folder is write-once: the file verbs cannot write, delete or move anything under `/_/conversations/`, so a later edit of an original never changes what a message showed. `AttachmentPayload` is the stored shape of one attachment: `kind` (`image` or `file`), `path`, `mimeType` and `size` in bytes, absent only on images posted before files could be attached. The stored row of an image also carries `width` and `height` in pixels when its header gives them (`ImageMedia.pixelSize(ofBytes:)`); both are optional, a reader that predates them ignores them, and `AttachmentPayload` does not carry them. A reader takes the kind and type from it, never from the file name.
- **Session homes** (`/_/sessions/<id>/`): a home lives in its session's group, readable by every caller whose acting group reads that group, and writable only by session `<id>` itself, acting in that group, and by humans (the `/v1/tools/*` and `/v1/f/*` routes). A `write`, `edit` or `generate_image` (or a script's `generateImage` from `wuhu:ai`) from any other session, its parent included, fails `unauthorized` with a hint to propose the change to the owner by message; image generation refuses before calling the provider. Cloning a template's files into a new child's home at `create_session` is the server's act, not the creator's write.
- **Machine notes** (`/_/machines/<name>/`): stored at `/_/machines/<machine id>/…` and presented by name. The file verbs, the web origin and `wuhu:/` script imports take the machine's name or its id in that position and reach the same folder; a machine with no name appears under its id. Listing `/_/machines` returns exactly one directory per enrolled machine, named by its name, or by its id when it has none. Readable and writable by every session and every human. A path under a name or id that no enrolled machine has fails `conflict` on writes, like the rest of `/_/`, and `notFound` on reads; `/_/machines/<name>` itself and every other name under `/_/` stay refused. A rename moves nothing. Both sides of a move, template instantiation, `history`, `checkout` and `path@rev` reads map through the current name-to-id mapping; the table verbs take only an enrolled machine's id path and refuse any other with `conflict`; `docs`, `links`, observe globs and the revision journal show the stored id path.
- **`ChannelPostInput`** (`POST /v1/channel/post`): exactly one of `session`
  (new thread in that session's owning channel) or `replyTo` (reply into that
  message's thread). `ChannelPostOutput` carries the created `messageId` and
  its `threadId` — reply correlation (`--wait`) depends on them.
- **`ChannelEntryPayload.createdAt` / `NotificationPayload.createdAt`**:
  seconds since the Unix epoch, UTC, fractional (the `mtime` convention).
- **Watermarks** (`POST /v1/watermark`): advances `(identity, source)` to the
  newest notification cursor, wholesale — written only by a deliberate client
  act; badges are derived (`n > watermark`), never stored. A conversation is
  unread for an identity when it has a `conversation_message` notification to
  that identity above its watermark; other kinds (errors, deadlines) never make
  it unread. A push carries `badge`: the number of unarchived agent boxes
  unread for the recipient when the push is sent. Direct and group
  conversations do not count toward it yet. Each APNs relay push stands on
  its own: its `collapse_key` is `<grant>:<n>`, the same as its
  `idempotency_key`, so only a retried send of that notification replaces it,
  and its `thread_id` is the notification's source (the conversation, or the
  session), so a device stacks one conversation's pushes in one group.
- **Notifications** (`GET /v1/notifications?identity=&after=`): append-only
  rows above the cursor; `payload` is the kind-specific JSON object. A person
  has one inbox across all their groups with one read position: the route
  returns the identity's rows of every group whatever the acting group, and
  each `NotificationPayload.group` names the row's group (a conversation's, or
  the session's; absent from servers before groups). A `conversation_message`
  payload carries `senderGroup` when the poster's group isn't the
  conversation's, so an outside sender shows with its group. Pushes carry the
  same ruling: an APNs relay push's `data` and a web push's notification
  `data` both carry `group`, the notification's group, and an outside
  sender's title reads `<sender> (group <senderGroup>)`, as `wuhu inbox`
  prints it.
- **`TranscriptReadOutput`** (`GET /v1/session/:id/transcript`): one-shot
  snapshot of the current generation for the CLI transcript views; `items` are
  the same opaque canonical `TranscriptItem` encodings the direct-view stream
  carries.

## Session observation streams

Both streams follow one contract: snapshot-then-tail, no gaps, no duplicates,
resumable by cursor. Cold sessions are silent topics — observing never
materializes the session actor.

- **Channel SSE** (`GET /v1/channel/:id/observe?after=<n>`): each SSE message
  is one `ChannelEntryPayload`; `n` is the resume cursor.
- **Direct view SSE** (`GET /v1/session/:id/direct?generation=&position=`):
  each SSE message is one `SessionStreamEvent`.
  - `reset(generation)` opens every connection whose cursor is absent or names
    a superseded generation (compaction bumped it): drop held state, the full
    current generation follows as `item` events from position 0.
  - `item(generation, position, item)` is a committed transcript entry;
    `(generation, position)` is the resume cursor. `item` is an opaque JSON
    leaf: the session domain's canonical `TranscriptItem` encoding (the same
    bytes the store persists), not a `@Contract` mirror.
  - Attempt events narrate the ephemeral inference side channel: `started`,
    `delta` (append `text` to the attempt's accumulated stream), `cancelled`
    (drop the bubble; the attempt will retry or park). Late joiners receive
    `started` plus one `delta` carrying the accumulated text so far.
  - `materialized(attemptId, entryId)` fires strictly after the durable
    commit (it is derived from the committed-row observation, not from the
    inference stream) and precedes its `item` event; the client swaps the
    streamed bubble for the entry by exact `entryId` match. The committed
    assistant entry's id equals its attempt id by construction.

## Space URLs

`SpaceURL` is the one URL grammar for pointing at something in a space. The TypeScript twin is `packages/wuhu-web/app/app/lib/space-url.ts`; both are pinned by the same vectors.

- A URL is `<scheme>://<host>/<path>[?query][#fragment]`. The host is always present: `host[:port]`, lowercased, with `:443` dropped. Userinfo is refused.
- The bare host `system` is reserved: `wuhu://system/<path>` addresses the read-only files built into the server (the system `AGENTS.md` and skills), not a space, so it never parses as a space URL, and `SpaceURL.host(origin:)` names no host for a bare `system` origin. Since `:443` is dropped, `https://system:443/…` is the bare host too. With any other port, `system:5530` is an ordinary space host: a real space host always has a dot or a port.
- Two schemes spell the same URL: `https` is the canonical, shareable form the SPA serves; `wuhu` opens the native app. `http` and `wuhu:///…` are not space URLs.
- A hostless `wuhu:/<path>`, or a plain `/<path>`, means the space the link lives in (a doc, a message, a sidebar, a page), and inside it the group the link lives in: a document's own group (a page served from `<group>.<host>` on the web origin is that group's), or for a tool call, script or import the acting group. It never falls back to another group. It parses only against that space's host (`init?(_:contextHost:)`), and it is the preferred form inside content because it survives host changes. A parsed hostless link carries the context host, so formatting it, as Share does, always yields the full `https://<host>/<path>`.
- The path decides the destination: exactly `/_/sessions/<id>` is a session, exactly `/_/conversations/<id>` a conversation (DMs included), and every other path a file or folder, `/` being the root. So a session home's files (`/_/sessions/<id>/AGENTS.md`) and attachments stay file URLs, while the home folder itself is reached through its session. The SPA's own screens (`/_/login`, `/_/enroll`, `/_/settings`, `/_/templates`, `/_/sessions`, and `/_/system/<path>`, which shows `wuhu://system/<path>`) are routes the SPA matches before this grammar; to anyone else they read as paths.
- Each path segment is percent-decoded and must be non-empty, not `.` or `..`, and free of `/`, `\` and control characters. One trailing slash is dropped. Formatting percent-encodes every byte outside `A-Z a-z 0-9 - . _ ~`.
- A `SpaceURL` holds only what parsing would produce: its initializer normalizes the host and refuses a destination that does not survive a format-and-parse round trip (so `.path` never names `/_/sessions/<id>` or `/_/conversations/<id>`), and a query containing `#`. Formatting then always parses back to the same value.
- `wuhu://<group>.localspace/<path>` names `<path>` in group `<group>` of the space at hand, never a space. `<group>` is one label of lowercase letters, digits and inner hyphens, and the host is compared lowercased like any host; a `.localspace` host naming no valid group (the bare `localspace` included) is an invalid address for the file verbs (`400 invalidArgument` over HTTP) and no link at all. `GroupID.address(_:)` and `GroupID.named(byHost:)` are the one parser every surface uses: the tools, the HTTP routes (`/v1/f?group=` takes what a group host takes), scripts, the CLI and `SpaceClient`. The file verbs, observe globs, script imports, `wuhu:space` move and remove, and document links (indexed into the named group) take this form; a group the acting group does not read answers as a missing path. `SpaceURL` parses it as an ordinary host.
- Query and fragment are opaque and carried verbatim. The SPA reads `?view=transcript|context` on a session.
- `SpaceURL.host(origin:)` names the host of a server origin (`https`, `http` or `wuhu`), so a client derives the share host from the origin it talks to.
