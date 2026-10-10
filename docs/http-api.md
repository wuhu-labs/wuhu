# HTTP API map: the `/v1` surface

The route inventory of the space's host — a map, not a schema. The API is pre-1.0 and may change with any release.

Wire types are Swift contract types in `SpaceContract`: their generated JSON Schemas are the shapes ([wire schemas](wire-schemas.md)), and [SpaceContract/SPEC.md](../packages/wuhu-core/Targets/SpaceContract/SPEC.md) carries the semantics a schema cannot. The machine routes are pinned in [SpaceServer/SPEC.md](../packages/wuhu-core/Targets/SpaceServer/SPEC.md).

Auth: without `--dev` the space's host admits a request only with a verified bearer assertion from an enrolled key (`Authorization: Bearer …`) or a session's exec token; anything else is `401 unauthorized`, "this space admits enrolled devices only". The routes that carry their own credential or are discovery are open: `GET /v1/machine/connect` and `GET /v1/machine/challenge`, `POST /v1/enroll/consume`, `POST /v1/enroll/share-login` and `GET /v1/enroll/share-login/challenge`, `GET /v1/server` and `GET /v1/groups`, `GET /.well-known/openid-configuration` and `GET /.well-known/jwks.json`. Static SPA GETs (non-`/v1`) also pass. How a device gets its key is in [getting-started.md](getting-started.md#authentication).

A session's exec token (`Authorization: Bearer wst_…`, handed to a
session's exec as `WUHU_TOKEN`) is its own principal, dev or not: it acts as
that session on the verbs a session has — the file routes and `read`, `ls`,
`stat`, `grep`, `find`, `history`, `query`, `write`, `edit`, `rm`, `mv`,
`checkout`, the table verbs, `new`, `attributes.read` and `attributes.patch`;
`observe`; `GET /v1/server`, `GET /v1/groups` and `GET /v1/machine`; message posts, session
create, request, archive, unarchive, interrupt, resume and tags; exec, ps
and kill on its own execs — under the rules its tools keep (the home rule and
the ancestry rule). Every other route answers `403` with `not available to a
session`. An expired,
revoked or unknown token is `401` with the reason. See
[SpaceServer/SPEC.md](../packages/wuhu-core/Targets/SpaceServer/SPEC.md), *Session execs act as their
session*.

## Space core

| Route | Purpose |
| --- | --- |
| `POST /v1/tools/:name` | The tool surface — read, write, edit, sync, remove, move, list, stat, grep, find, history, checkout, query, table verbs, new, attributes.read, attributes.patch. `sync` three-way merges a full-text editor draft from its read token. `ls` at `/` omits `/_` (the system folder, which holds the session homes) and `/users` unless `hidden: true`. One route, dispatched over the toolbox; the tool schema is the API: see the [space tool pages](../packages/wuhu-core/Targets/SpaceToolReference/Tests/reference/README.md). |
| `GET /v1/observe?glob=…&from=…` / `?sql=…&throttleMs=…` | SSE observation: glob mutation events (rev-cursored replay then live) or SQL snapshots. In `sql`, `viewer()` is the caller's identity (the one `POST /v1/watermark` advances), so a sidebar can observe its own unread state; a caller without an identity gets the watermark route's refusal for a statement that calls it. Every SSE response opens with a `:` comment preamble and carries comment heartbeats (15s; 1s on conversation streams) — clients should treat prolonged byte silence as a dead connection. |
| `GET /v1/f/<space path>` / `PUT /v1/f/<space path>` | The byte lane: raw file bodies in and out, no JSON envelope. `GET` answers the bytes with a `Content-Type` derived from the path extension and the version token as `ETag`; `PUT` takes an arbitrary binary body (`If-Match` for optimistic concurrency) and answers `{rev, token}`. Bodies over 64 MiB are refused with `413`. |
| `GET /.well-known/openid-configuration` | OIDC issuer discovery, open without a credential on the API host: configured HTTPS `issuer`, `jwks_uri`, and `id_token_signing_alg_values_supported` (`["ES256"]`). A missing identity key or invalid/missing HTTPS `--origin` returns 422 `oidcConfiguration`; Host is never used as the issuer. |
| `GET /.well-known/jwks.json` | Public ES256 P-256 signing key in a JWKS `keys` array, selected by `kid`; includes only `kty`, `crv`, `alg`, `use`, `kid`, `x` and `y`, never private key material. Open on the API host, with the same configuration refusal as discovery. |
| `GET /v1/server` | Discovery, open without a credential: `space` (the space identity, `spc_…`), `origin` (the `--origin` it was started with), `contentBase` (the `host[:port]` a group's content is served under, `https://<group>.<contentBase>`: the `--origin` authority, else `localhost:<port>`), `features` (`["groups"]`), and `group` (the group the request names by `wuhu-group` header, unchecked). Optional `aiDisclosure` is the operator-configured AI provider set: `{version, providers: [{name, location, via, policy}]}`. Clients bind sharing consent to `version` and re-ask when it changes. It is absent on unconfigured/self-hosted servers. Absent fields are omitted. |
| `GET /v1/groups` | The space's live groups, `[{id, member, readable}]` (`GroupSummary`), as the caller stands to each. For a person the group the request names by header or Host changes nothing; a session's exec token naming a group other than its own is `403 groupMismatch`, as on every route. `member`: the caller acts and creates there (a person's memberships; a session's own group only). `readable`: a group the caller is a member of reads it, so every member group is readable. A readable group the caller is not a member of is reached only through a member group's hostful paths (`wuhu://<g>.localspace/…`); naming it by `wuhu-group` or Host, or minting `/_/session` on its content host, is `403 groupForbidden`. Open without a credential, like `/v1/server`: an anonymous caller gets both `false` everywhere, the `--dev` seat both `true`; a bearer that fails verification is `401`. A client of an older server finds both absent. |
| `PUT /v1/groups/:id` | Change a group's settings: `{spaceLayer?}` (`GroupUpdateInput`) → `{id, spaceLayer}` (`GroupSettings`). `spaceLayer` says whether the space-wide layer (`shared`'s `/AGENTS.md` and skills) reaches the group's sessions. Needs an admin of that group (`403 forbidden`); `404 unknownGroup`, `400 invalidArgument`. |
| `POST /v1/transcribe` | Speech to text. Raw audio body with an audio `Content-Type` (wav, mpeg, mp4, m4a, webm), optional `?language=`; answers `TranscriptionOutput`. Provider order: a stored ChatGPT login (`codex`) first, then an `openai` api key; neither → `503 noTranscriber`. Over 25 MiB → `413 invalidArgument`; wrong content type → `415 unsupported`; upstream refusal → `502 unavailable` (`429` when rate-limited). |
| `GET /v1/transcribe` | Capability probe: `TranscriberInfo` — `{available, provider?, model?}`. |
| `GET /*` | The embedded SPA app shell (Bazel-built binaries); `/v1/*` never falls back to it. Its own files and screens live under `/_/`; every other path is a space URL the SPA opens (`/_/sessions/<id>`, `/_/conversations/<id>`, else a file or folder). |

## Machines

| Route | Purpose |
| --- | --- |
| `POST /v1/machine` | Add: optional name → id + one-time join token + `fingerprint?` (see [Enrollment](#enrollment)) (token shown once; the box consumes it at `POST /v1/enroll/consume`). A person's machine joins their personal group, created on first need; the `--dev` seat's joins `shared`. The name is lowercased and must match `[a-z0-9][a-z0-9.-]{0,62}` (`400 invalidMachineName`); it is unique per space, compared case-insensitively (`409 machineNameTaken`). |
| `GET /v1/machine` | List with attachment state; `name` is `null` on an unnamed machine. Only machines in a group the acting group reads. |
| `PUT /v1/machine/:id/name` | Rename: `{name}` → `MachineStatus`. Same grammar and uniqueness rules as add. |
| `PUT /v1/machine/:id/group` | Move the machine to another group: `{group}` (`MachineMoveInput`) → `MachineStatus`. Needs an admin of both groups (`403 adminRequired`); an unknown target is `404 unknownGroup`. Its notes under `/_/machines/<name>/` move into the new group's tree in the same revision; a note already at the same path there gives way to the moved one. |
| `POST /v1/machine/:id/rotate` | Kick the machine's enrolled key (dropping any live connection) and mint a fresh join token, with `fingerprint?` as for add. Needs a human admin of the machine's group. |
| `POST /v1/machine/:id/revoke` | Kick the key and drop any live connection; rotate re-enables. Needs a human admin of the machine's group. |
| `GET /v1/machine/challenge` | Mint a one-shot connect challenge: burned at first take, short-lived. Open in non-dev mode. |
| `GET /v1/machine/connect` (WS) | The machine agent's dial-in; pubkey + challenge + signature headers, verified against the live key row before upgrade, plus `x-wuhu-machine-capabilities` (`group-secrets` from an agent that takes secret values with the exec start). Open in non-dev mode. |
| `POST /v1/exec` | Mint an exec id for a machine. |
| `GET /v1/exec/:id` (WS) | The caller leg: dial with the minted id; re-dial with the same id resumes byte-exactly. |
| `GET /v1/exec` | ps: live exec registry rows. |
| `GET /v1/exec/:id` (HTTP) | Status of any known exec, including the terminal outcome. |
| `POST /v1/exec/:id/kill` | Kill frame to the machine; delivery deferred if detached. |

A machine belongs to one group. Every route above that names a machine or an exec answers `404` unless the machine's group is one the acting group reads (itself included), so a machine outside reach is indistinguishable from none. An exec is also homed in a group — its session's, or the group a person minted it from — and the exec routes (`GET /v1/exec`, status, kill, the caller WS) answer only for execs homed in a group the acting group reads, on a machine it may use.

Every `/v1/machine/:id/*` route resolves `:id` as either the `mc_…` id or the machine's name, case-insensitively — a name can never satisfy the id grammar (`mc_` contains an underscore, which names exclude), so one parameter carries both. The stored id stays the key: a rename never invalidates a stored address or an exec.

## Secrets

Secrets for `run_script` and for execs, one store per group: every route reads and writes the acting group's (`wuhu-group` header; a person naming none acts in `shared`), never another's by fallback. Values live in the server's config directory at `secrets/<space-id>/<group>.json`, outside `space.sqlite`, so they never enter the revision journal, history or backups. No route returns a value. An exec's `secrets` (`ENV → NAME`) resolve in the store of the group the machine belongs to when the exec starts, whoever minted it; the server sends the values with the exec start to an agent that announced `group-secrets`, and a name that store lacks fails the exec before it spawns (`wuhu: no secret NAME in group GROUP` on stderr, exit 127). A server that finds the pre-groups flat file `secrets/<space-id>.json` refuses to start with `needsSecretsMove`, naming the `mkdir` and `mv` that put it at `secrets/<space-id>/shared.json`.

| Route | Purpose |
| --- | --- |
| `PUT /v1/secret/:name` | Create or replace a secret: `{value}` → `{}`. `400` for a name outside `[A-Za-z_][A-Za-z0-9_]{0,127}` or an empty value. Needs an admin of the group (`403 adminRequired`). |
| `GET /v1/secret` | Secret names only → `{names: [...]}`, sorted. |
| `DELETE /v1/secret/:name` | Delete a secret; `404` when unknown. Can't be undone, so it needs a human admin of the group (`403 adminRequired`). |

All three answer `503` when the server has no config directory to hold the store.

## Users

Handles are display only. They never authenticate anything, never appear in an assertion, and never replace the persona name a row stores as its principal — the server resolves a handle at read time, so a rename re-renders history instead of rewriting it. A handle is lowercased and must match `[a-z0-9][a-z0-9-]{1,31}`, and it is unique per space compared case-insensitively.

| Route | Purpose |
| --- | --- |
| `GET /v1/users` | The space directory: every persona plus every principal that carries a profile (which covers the `owner` principal on a `--dev` server) → `{users: [{id, handle?, displayName?}]}`. Gated like `GET /v1/conversations`. |
| `PUT /v1/user/me/profile` | Set the bearer's own handle: `{handle, displayName?}` → `UserPayload`. `400 invalidHandle` (the message states the grammar), `409 handleTaken`. Setting the same handle again is a no-op success; a new one frees the old in the same write. |

`ConversationMessagePayload.senderHandle` and `ConversationMemberPayload.memberHandle` are read-time siblings of the id fields, `null` when the principal has set no handle. Nothing denormalizes a handle into a message, a queue payload, or a transcript entry.

## Enrollment

`fingerprint` in the mint, share-login, machine add and machine rotate responses is the `sha256:<hex>` of the server's certificate for clients to pin, present only when the server runs the certificate it generated into `<folder>/tls`. Under `--cert`/`--key`, self-signed or not, it is absent and clients use their system trust store.

| Route | Purpose |
| --- | --- |
| `POST /v1/enroll` | Mint a join token: `{account, capabilities, ttlSeconds?}` (default 3600) → `{token, expiresAt, space, fingerprint?}` (token shown once, stored only as a verifier). Capabilities: `device`, `seat`, `exec-machine`, `space`. Self-or-admin: any account mints for itself; minting for another account needs an admin bearer (the `--dev` seat acts as admin). |
| `POST /v1/enroll/revoke` | Kill an unconsumed join token: `{token}` → `{}`; `404 notFound` when no live invite carries that token. Self-or-admin on the token's account, gated inside the claiming transaction so a refused revoke leaves the invite alive. |
| `POST /v1/enroll/consume` | Enroll a key: `{token, pubkey, name?}` → `{account, capabilities, machine?, machineName?}` (the machine fields name the machine when the token's account is one). A joining box passes its hostname as `name`; the server claims it for an **unnamed** machine only, suffixing `-2`, `-3`, … until free, and reports the result in `machineName`. A machine that already carries a name keeps it and `machineName` reports the kept one — a join never renames, that is `PUT /v1/machine/:id/name` alone. The pubkey must be a parseable key label (`ed25519:<base64 raw key>` or `p256:<base64 x963 key>`); a malformed one is a 400 and leaves the token alive. One transaction claims the token and inserts the key, so a token consumes exactly once and dies at enrollment. Open in non-dev mode. |
| `GET /v1/enroll/share-login/challenge` | Mint a one-shot share-login challenge: burned at first take, short-lived. Open in non-dev mode. |
| `POST /v1/enroll/share-login` | Any enrolled key mints a one-time device link for its own account: `{pubkey, challenge, signature, ttlSeconds?}` → `{token, expiresAt, space, fingerprint?}` (`device` capability). `ttlSeconds` runs 1…259200 (three days) and defaults to 600; outside that it is `400`. A bad handshake is `401 keyInvalid`. The signature — a raw signature over `wuhu-share-login:<challenge>` by the named key, under the algorithm its label tags (`ed25519:` or `p256:`), verified against the live key row — authenticates the minter; the pubkey is only an index. Open in non-dev mode. |
| `POST /v1/persona` | Draw a messaging persona (allocator word-name) recorded against the verified bearer's key and account: no body → `{persona}`. Requires a verified assertion even in `--dev`; each call draws afresh (one per wallet × space is the CLI's caching policy, not the server's). |

## Accounts and keys

Management routes share one authorization choke point: session-scoped
(folder-wallet) assertions are refused wholesale (`403 sessionScoped`), a
verified key acts as its account, admin is an account flag, and the
anonymous seat is an admin only behind `--dev`. Non-admins failing an
admin-only rule get `403 adminRequired`.

| Route | Purpose |
| --- | --- |
| `POST /v1/accounts` | Admin: create a human account `{name?, admin?}` → `AccountPayload`. |
| `GET /v1/accounts` | Admin: the live roster (removed accounts are tombstoned out). |
| `DELETE /v1/accounts/:id` | Admin: remove a human account — its keys, browser logins, and outstanding invites die; the row stays as a tombstone so attribution history keeps resolving. Refuses the last admin (`409 lastAdmin`) and machine accounts (their own verbs manage them). |
| `POST /v1/accounts/:id/admin` | Admin: grant or revoke the admin flag `{admin}`. Demoting the last admin is `409 lastAdmin`; revoking from an account that stays an admin of `shared` through a team group it belongs to changes nothing and is `409 adminThroughGroup`, naming the group; offline recovery (`wuhu user add --space <folder> --admin`, server stopped) remains the bedrock. |
| `GET /v1/keys?account=` | List enrolled keys. Default: the bearer's own account; another account's keys need admin. |
| `DELETE /v1/key` | No body: revoke the presenting key (possession is the authority). With `{pubkey}`: addressed revocation — own keys always, any key for an admin. |

## Sessions

| Route | Purpose |
| --- | --- |
| `GET /v1/providers` | Every provider in the space's `/models.json` (`ProvidersOutput`), sorted by id: its `dialect`, its models (`ProviderModel`: `id`, `effortLevels`, `defaultEffort?`), and `usage` — the plan usage the server last observed (`ProviderUsage`: `plan?`, `windows` of `UsageWindow` `name`/`usedPercent?`/`resetsAt?`, `observedAt`), absent until observed. Only the `codex` dialect reports usage: inference refreshes it from Codex response headers, and the server reads it itself once a provider has gone fifteen minutes unobserved. |
| `GET /v1/session-tools?executor=kernel` | The kernel tool roster (`ToolRostersOutput`), including `bookmark` and `compact`. Omitting `executor` returns this one roster. Each `ToolDescriptor` contains its name, description and verbatim parameter JSON Schema. An unknown executor is `400 invalidArgument`. This is distinct from the space toolbox at `/v1/tools`. |
| `GET /v1/templates` | Session templates (`SessionTemplatesOutput`): every `/templates/<name>/template.json`, with its `kind` default, `provider`, `model`, `effort` and `description`. |
| `POST /v1/session` | Create an inert session (`SessionCreateInput`; `kind` is `agent` or `task` and comes from the request or from `template`'s manifest — neither is `400`; an agent also gets its induced box, whose conversation id is the session id). `template` merges `/templates/<name>/template.json` underneath the explicit fields and clones the template's other files into `/_/sessions/<id>/`. Human-created sessions are roots — `parent` is not accepted — and agents: a `task` kind, whether given or from the template, is `403 taskInput`, because a task works for a parent and a root one could never be told anything. The spec is validated against `/models.json`, and every provider runs in the kernel. Explicit `executor: claude-code`, in the request or template, returns `422 executorNoLongerSupported` before creation. `SessionCreateOutput` echoes the stored `kind`, `parent`, `model` and `effort`. The title is validated as a rename is (`422 invalidArgument`). When the session was created but cloning the template into its home failed, the answer is `500 incompleteSession` with the new session's id in `hint`, so a caller can find it instead of creating a second one. |
| `POST /v1/session/:id/request` | Session token only: open a request on a child of the calling session (`SessionRequestInput`: `message`, optional `deadlineSeconds` → `SessionRequestOutput`: `requestId`, `conversationId`). Runs the `request` tool, so its refusals (`422`) are the tool's. Any other bearer gets `404`. |
| `POST /v1/session/:id/interrupt` | Stop after the current step. |
| `POST /v1/session/:id/resume` | Clear interrupt/error and continue; a retired Claude Code session instead returns `422 executorNoLongerSupported` until handed over with Start over. |
| `POST /v1/session/:id/archive` | Archive a settled session (grace window). A person archives a session a persona of theirs created, or any session of a group they are a human admin of; anyone else is `403 forbidden`. A session token archives itself, a session it created or descends from, or, as a top-level agent, any session of its own group. |
| `POST /v1/session/:id/unarchive` | Restore within the grace window. Same gate as archive. |
| `POST /v1/session/:id/title` | Rename a session (`SessionTitleInput`). The stored title comes back as `{"title": ...}`; it is trimmed, must be one non-empty line, and is capped at 200 characters (`422 invalidArgument` otherwise). The same write backs the `set_title` tool, so a session can name itself. |
| `POST /v1/session/:id/tags` | Replace a session's tags (`SessionTagsInput`: `tags`, an array of strings; an empty array clears them). Allowed on any lifecycle, archived included. The stored tags come back as `{"tags": [...]}`; a malformed body is `400`, an unknown session `404`. |
| `POST /v1/session/:id/compact` | Ask a session to fold its context (`SessionCompactInput`, body optional). Records one standing command; a second request before delivery replaces the first. A Claude Code session writes `/compact [instructions]` on standard input once no turn runs and nothing is queued. The kernel loop takes the same row at its next settled pass and pins that turn to the compact tool; `instructions`, when given, are injected first as one `compact request` system notification. A task takes no instructions from a person: they are `403 taskInput`, and a bare compact still works. |
| `POST /v1/session/:id/restart` | Start a session over (`SessionRestartInput`, body optional; `SessionRestartOutput`). Keeps the id, the box, the DMs and the home folder; opens a fresh empty generation and archives the old one. Drops undrained queue rows, subscriptions, timers and any standing command, and clears the interrupt/error axes. Omitted model fields keep the live spec on the same provider; another provider inherits nothing. `message` is posted right after into the agent's box as an ordinary input; for a task it is `403 taskInput` and the session is not restarted. `409` while the session has unfinished work or an open run, or when it is archived; `422` for an invalid spec. |
| `GET /v1/session/:id/context` | Context-window usage (`SessionContextOutput`). Kernel sessions answer `source: "estimate"` — the server's own token estimate over the transcript against the model's usable budget. The same object rides `GET /v1/session/:id/log`, so a list view needs no second call. |
| `GET /v1/session/:id/home` | What the session sees (`SessionHomeOutput`): its home path, the resolved `AGENTS.md` chain in injection order, and the skills listing, system entries (`wuhu://system/…`) first, the space's and the home's as of the session's prompt revision — the same walk the executors inject, so a UI never re-implements it. |
| `POST /v1/conversation` | Create a `users` conversation (`ConversationCreateInput`); the caller is added if absent. Boxes are induced at agent creation and DMs are created on first post, so neither is creatable here. |
| `POST /v1/conversation/message` | Post a message (`ConversationPostInput`): exactly one of `conversation`, `session` (that agent's box) or `user` (a person–person DM, created on demand), plus an optional `replyTarget` and an optional `attachments` list of absolute paths already in the space. To carry files from the client, send `multipart/form-data`: a part named `message` with that JSON, then one part named `file` per file (its `filename` is the name the copy keeps); a post without files may be plain JSON. At most 8 attachments per message, uploads and paths together, each at most 50 MiB and 150 MiB in all, any type. A person never wakes a task: a post whose only recipients are tasks (`session` naming one, or a mention or reply that reaches no one else) is `403 taskInput`, and a post that also reaches others skips the tasks. A person–session DM, whether opened with `user` or addressed by an existing conversation id, is `403 humanAgentDM`; old history stays readable. Session identities cannot use `user` (including `null`) or post into any person DM: they receive `422 refused` with the typed refusal, never an automatic box post. Refusals: `400 tooManyAttachments`, `413 attachmentTooLarge`, `413 attachmentsTooLarge` (each names the file), `400 invalidArgument`, `404 notFound`; the message part is capped at 8 MiB and the body at 166 MiB. A `png`/`jpg`/`jpeg`/`gif`/`webp` whose bytes match its extension is stored as an image, anything else as a file typed by its extension or the part's `Content-Type`. In the transaction that stores the message, each file is copied write-once to `/_/conversations/<conversation>/attachments/YYYY/MM/DD/HHmmssZ/<name>` (UTC time of the post; a clash becomes `name-2.ext`, `name-3.ext`, …; `@ % # ?` and control characters in an uploaded name become `_`). `ConversationMessagePayload` lists those copies as `attachments`, each an object `{kind, path, mimeType, size}` (`kind` is `image` or `file`; `size` is absent only on images stored before files could be attached); the file verbs cannot write, delete or move anything under `/_/conversations/`. |
| `GET /v1/conversation/:id/messages?after=&limit=` or `?tail=&before=` | One-shot conversation read: forward above a cursor, or the last `tail` messages before `before`. |
| `GET /v1/conversation/:id/observe?after=` (SSE) | Conversation stream: one `ConversationMessagePayload` per event. |
| `GET /v1/conversations?identity=` | Conversations the identity is a member of, most recently active first. |
| `GET /v1/session/:id/conversation` | The induced box of an agent, with its member list and attention-window bounds. `409 noBox` for a task. |
| `GET /v1/session/:id/transcript` | One-shot transcript snapshot of the current generation. |
| `GET /v1/session/:id/log?level=&limit=&before=` | A page of the current generation's transcript (`SessionLogOutput`): `items`, each with a stable `ref`, filtered to `level` 1–3 (default 1, the least detail), the last `limit` (default 50, at most 500) before the `before` ref, plus the session's `context` usage. |
| `GET /v1/session/:id/entry/:ref` | One transcript item by the `ref` a log page gave it (`SessionEntryOutput`). |
| `GET /v1/session/:id/direct?generation=&position=` (SSE) | The direct view stream: committed items plus the ephemeral attempt side channel. |
| `POST /v1/watermark` | Advance a human read watermark for `(identity, source)`, wholesale. A conversation is unread while a `conversation_message` notification to the identity sits above it; clients post it when a conversation is opened. |
| `GET /v1/notifications?identity=&after=` | Notification rows above the cursor, from every group: a person has one inbox and one read position across their groups. Each row's `group` names its group, and a `conversation_message` payload's `senderGroup` names an outside sender's. |


## Devices

A device is an app install a person is signed into (a phone, pad, mac, vision or web client).

| Route | Purpose |
| --- | --- |
| `PUT /v1/device` | Register or refresh the presenting device: `{installation, kind, name}` (`DeviceRegisterInput`) → `DevicePayload`. Authenticated by the device key itself, which needs the `device` capability (`401` otherwise). The row is keyed by account and installation, so a reinstall adopts its device. A key already current for another device is `409 deviceKeyTaken`; an unknown `kind` is `400 invalidArgument`. |
| `PATCH /v1/device/:id` | Annotate a device: `{name?, machine?}` (`DeviceAnnotateInput`; `machine` is a machine id or name) → `DevicePayload`. Your own account's devices, or any as an admin (`403 forbidden`). |
| `GET /v1/devices` | Every device (`DevicesOutput`). |
| `POST /v1/device/:id/command` | Queue a UI command for the device: `{payload}` (any JSON, delivered verbatim) → `{n}`. The app applies it only while fresh. |

## Web push

| Route | Purpose |
| --- | --- |
| `GET /v1/web-push/config` | Return the space's VAPID application-server public key. |
| `PUT /v1/web-push/subscription` | Idempotently bind a browser subscription to the presenting device key and its persona. New bindings start at the current notification cursor. |
| `DELETE /v1/web-push/subscription` | Remove the presenting device key's subscription by endpoint. |
| `PUT /v1/push-relay/grant` | Bind a native app's push relay grant to the presenting device key and its persona: `{endpoint, grant, token}` → `204`. The endpoint must be `https` on an allowed host (`notifications.wuhu.ai` unless `WUHU_PUSH_RELAY_HOSTS` lists others), else `400`; a grant bound to another device is `409`. |
| `DELETE /v1/push-relay/grant` | Remove the presenting device key's grant: `{grant}` → `204`. |

The existing `notifications` outbox is the only notification producer. Each
subscription owns a delivery cursor; `404`/`410` removes it, transient failures
retry durably, and revoking its device key removes it by foreign-key cascade.

Wherever these routes accept an `identity`, it must be a persona minted at
`POST /v1/persona` (or absent/`owner`, attributing to the owner); anything
else is 403 `unknownIdentity`. This is what keeps a free-form identity from
squatting a session's word-name and stealing its messages.

Both session SSE endpoints follow one contract: **snapshot-then-tail, no
gaps, no duplicates, resumable by cursor** — `after=<n>` for conversations,
`(generation, position)` for the direct view (a superseded generation cursor
gets a `reset` followed by the full current generation). Observing a cold
session never materializes it. The full event vocabulary is in
[SpaceContract/SPEC.md](../packages/wuhu-core/Targets/SpaceContract/SPEC.md) under "Session observation streams".

## Group hosts

A request for `<group>.<host>`, on the same port, is not `/v1`: it serves that group's files raw at `/` and exposes the page data API `wuhu:space` (`GET /_/space.js` over the `/_/space/*` routes, below), the deprecated `GET /_/query?sql=` and `GET /_/observe?sql=|glob=`, the injected `GET /_/shell.js` embed SDK, the page service worker `GET /_/worker.js` (with `Service-Worker-Allowed: /`) and the modules it imports, credentialed `GET /_/session` read-cookie bootstrap, and bundled view providers under `/_/views/`. Shell/content communication is cross-origin `postMessage` over one contract, `wuhu:ready` / `wuhu:context` / `wuhu:navigate`, and the SDK is one file. Space content is never served from the space's host itself, and a name nested deeper (`a.b.<host>`) or with an empty label is `421`. `POST /_/session` mints a read-only login cookie (`wuhu_read`) from a bearer assertion, and the auth wall is live: content reads, `/_/query` and `/_/observe` all answer `401 unauthorized` without a live read session, unless the server runs `--dev`, or `--public-read` and the request is for `shared.<host>`; `--public-read` never opens another group host. Product chrome — `/_/shell.js`, bundled view providers, the minter itself — stays open so a browser can reach the point of authenticating. The cookie is a group-host credential only: the space's host never accepts it, and the mutations it admits are a page's own JSON writes to `POST /_/space/rows` or `POST /_/space/attributes` from the page's own origin, plus proxied fetch from that origin. Every admitted content response, `/_/query` and `/_/observe` included, names the cookie's account in `Wuhu-Viewer`. A mint also sets `wuhu_viewer=<account>`, a script-readable cookie that tells the page worker whose cache to read; `DELETE /_/session` clears both cookies. Nothing a group host stores is ever wiped with `Clear-Site-Data`. Each group host serves only that group: its files, `/_/query` and `/_/observe`, with a cookie minted on that host (host-only, no `Domain`) by a member of the group. A cross-origin browser request (`Sec-Fetch-Site` other than `same-origin` or `none`, not a navigation, and not from the paired SPA: the `--origin`, or the space's host at the request's own scheme and port) is refused when the cookie admits it to `/_/query` or `/_/observe`, or to anything on a group host other than `shared.`; `DELETE /_/session` refuses it always. Group-host responses other than `shared.`'s carry `Content-Security-Policy: frame-ancestors 'self' <paired SPA>`. A top-level `GET` navigation (`Sec-Fetch-Dest: document`, `Sec-Fetch-Mode: navigate`) that no live cookie admits answers `303` to the share link `https://<host>/<path>?group=<group>` (no `group` for `shared`), `Cache-Control: no-store`, so the web app opens it; see [SpaceServer/SPEC.md](../packages/wuhu-core/Targets/SpaceServer/SPEC.md) "The acting group". Every served file carries its revision as a quoted `ETag` and `Cache-Control: no-cache`, so a client revalidates each use and a matching `If-None-Match` answers `304` with no body. HTML with the shell script injected gets its own tag. A directory listing carries no tag. `/_/query` tags its result with a digest of the result, is `Cache-Control: private, no-cache`, and answers a matching `If-None-Match` with `304` the same way. A `Range` with an `If-Range` other than the current tag gets the whole body. The page worker, registered by `shell.js`, answers page navigations and `/_/query` stale-while-revalidate from its IndexedDB cache, and opens `/_/observe?sql=` with the kept snapshot as the first event before the live stream, keeping each snapshot it relays. `/_/space/query` and `/_/space/observe` are kept the same way, keyed by statement and `params`. Entries are written under the response's `Wuhu-Viewer` account and read under the `wuhu_viewer` cookie's, so another account never reads them; when the cookie names someone else, or no one, the previous viewer's entries are purged. A refused live answer reaches the page as it would without the worker. When a kept page revalidates to a new tag the worker posts `wuhu:fresh` and `shell.js` reloads the frame; a `401` posts `wuhu:unauthorized`, which `shell.js` forwards to the shell so it mints a new cookie. Product chrome (`shell.js`, view providers) is never stored.

### Proxied fetch for content pages

| Route | Contract |
| --- | --- |
| `POST /_/space/fetch?url=&method=&headers=&page=` | Proxies an HTTP(S) request from a signed-in content-page viewer. Raw request body, target method (GET/POST/PUT/PATCH/DELETE/HEAD), headers as a JSON object, page = location.pathname; all query values percent-encoded. Streams the backend status/headers/body, strips Set-Cookie and marks the response `Wuhu-Fetch-Result: upstream`. |

A page imports `fetch` from `wuhu:space`; its ordinary browser fetch remains unproxied. Add `{"allow":["https://dashboard.example.com"]}` to the page's own group's `/fetch.json`. Entries are exact HTTP(S) origins (an optional trailing `/` is accepted), with no wildcard, credentials or nonempty path; explicit LAN/private backends are allowed. The file is read for every call: edits take effect immediately, and no neighbouring group's list is consulted. Missing/empty list (`fetchListMissing`), unlisted target or redirect (`fetchOriginForbidden`) and page Authorization (`fetchAuthorizationForbidden`) are typed refusals, with `/fetch.json` named when appropriate. Cookie and Host are never forwarded; the transport generates Host for the pinned target. Origin and Sec-Fetch-Site must identify a same-origin page, and a live group-bound read cookie is mandatory. Anonymous/--public-read/--dev without a cookie is `fetchViewerRequired`; exec bearers are not accepted.

The existing identity key signs a fresh ES256 JWT per redirect hop: Authorization Bearer, iss = space HTTPS origin, aud = target origin, 60 s lifetime, space/group/path/viewer plus standard iat/exp/jti/sub. viewer is an opaque authenticated stable id (currently a persona handle, never email); path is a page-supplied claim. Backends verify kid/signature against the API host's `/.well-known/jwks.json` and check iss/aud/exp. Target methods/headers/body pass through, except credentials and hop-by-hop headers; requests are capped at 10 MiB and the entire operation at 60 s. Hosts are resolved once per hop and connections are pinned to those addresses. Policy failures reject as SpaceError; backend 4xx/5xx return an ordinary Response. Wuhu-Viewer on forwarded responses is replaced with the authenticated account, and the page worker does not invalidate query caches or notify the shell for these marked upstream responses. A failure after response headers closes the stream instead of replacing the response status. There is no direct-browser or alternate-list fallback.

```html
<script type="module">
  import { fetch } from "wuhu:space";
  const response = await fetch("https://dashboard.example.com/q", {method: "POST", body: "select 1"});
  console.log(await response.text());
</script>
```

### Page data: `wuhu:space`

Every served HTML page carries an import map at the start of `<head>` that
resolves `wuhu:space` to `/_/space.js`, so a page module imports the names a
`run_script` module does. Message attachments are the exception: they are
served sandboxed, with no import map, and cannot write. The SDK speaks the data routes on the page's own
origin, as the viewer's read cookie: `GET /_/space/query`,
`GET /_/space/observe` (SSE of typed snapshots), `GET /_/space/watch` (SSE of
file events, opening with an `event: head` frame carrying the head `rev` when
no `from` is given), `GET /_/space/attributes`, and the page writes
`POST /_/space/rows` and `POST /_/space/attributes`, which act as the host's
group minus admin and record the viewer's persona and the page in the
revision's attribution. The wire, admission, status codes and attribution are
in [SpaceServer/SPEC.md](../packages/wuhu-core/Targets/SpaceServer/SPEC.md) "Page data"; query strings are percent-encoded, since
the server reads a `+` as itself.

```html
<ul id="done"></ul>
<script type="module">
import { query, observe, mutateRows, readAttributes, patchAttributes } from "wuhu:space"
const list = document.querySelector("#done")
;(async () => {
  for await (const rows of observe`SELECT title FROM "/tasks.table" WHERE status = ${"done"}`)
    list.replaceChildren(...rows.map(r => Object.assign(document.createElement("li"), { textContent: r.title })))
})()
const { ids } = await mutateRows("/tasks.table", [{ insert: { title: "Ship page writes", status: "todo" } }])
await mutateRows("/tasks.table", [{ update: ids[0], set: { status: "done" } }])
const { token } = await readAttributes("/notes/plan.md")
await patchAttributes("/notes/plan.md", { set: { status: "done" }, remove: ["draft"], ifMatch: token })
console.log(await query`SELECT title, status FROM "/tasks.table" WHERE status = ${"done"}`)
</script>
```

A refusal rejects with a `SpaceError` carrying the server's `code`, `hint` and
`token` (a stale `ifMatch` is `conflict` with the current `token`); a non-`2xx`
answer without that body, a proxy's `502` say, is `internal` with the message
`HTTP <status>`. A network failure rejects with fetch's own `TypeError`: writes
are online only, and the page worker passes every `POST` to the network,
never keeping or queueing it.

A live stream opens when iteration starts and ends when the loop leaves. A
dropped connection, or an unreachable space, opens again after three seconds;
an error status ends the loop with its `SpaceError`. `watch` resumes after the
last event it delivered, or after the head frame's `rev` when none came yet,
so a drop loses nothing.

After a `2xx` write the page worker drops every query result that viewer kept,
before the page sees the answer, and a query result fetched across the write
is relayed but not kept. `/_/space/watch` and attribute reads are never kept.



### Server issuer selection

`publicationFailure` is the current directory publication error code (`directoryUnavailable`, `unknownId`, or `unlistedKey`), or null when confirmed/not using the directory. Server logs record the code on every failed publication, never key material.

`GET /v1/identity` returns resolved issuer URLs as `{defaultIssuer,overrides,publicationFailure}`; `GET /v1/identity/issuer-for?origin=<canonical-HTTP(S)-origin>` returns `{issuer}`. Reads require authentication and accept session exec credentials. `PUT /v1/identity` requires a human space admin and accepts exactly `{defaultIssuer:"self"|"directory"}`, `{audience:<origin>,issuer:"self"|"directory"}`, or `{audience:<origin>,remove:true}`. Settings live in server state, not group files. The default is self; directory choices require confirmed public-key publication before any directory-issued token is minted. Failed publication returns 503 `directoryUnavailable` and persists the chosen setting, never switching issuers silently. Re-submit the set request to retry. Changing issuer breaks existing verifier trust: migrate by trusting both issuer URLs first. Own-host well-known discovery always names the self issuer, even when a default or override uses the directory.

### Server identity key rotation and recovery

`POST /v1/identity/rotate` starts key rotation and returns `{ "rotating": true }`. `POST /v1/identity/register-new` registers a fresh id, commits it only after confirmation and durable storage, and returns `{ defaultIssuer, overrides, publicationFailure }` with resolved issuer URLs. Failed registration/storage preserves the previous issuer and minting status; maintenance and restart keep that saved id. If neither an override nor the default selects directory and no id exists, it returns 422 `directoryNotSelected`. Both require a human space-admin assertion (never a session exec), and concurrent mutations return 409 `identityBusy`. A pending rotation also returns 409, except `register-new` can recover a current `unknownId`/`unlistedKey` failure by registering old and pending keys together under the new id without changing the rotation phase or shortening overlap. Rotation preserves issuer URLs; fresh registration changes every directory-selected issuer and requires verifier migration.

Unconfirmed directory keys never mint tokens. Transient failure returns 503 `directoryUnavailable`; a removed registration returns 503 `unknownId`, and a key not listed for that id returns 503 `unlistedKey`. Inference exposes the same code in a typed 422 `invalidInput` hint, and page/script identity fetch preserves the typed code. Retry publication for transient failure; restore server state or explicitly register a new issuer for ownership failure.

## Removed executor

Session creation and Start over accept optional `executor: "kernel"`. An explicit `executor: "claude-code"`, including one in a session template, returns HTTP 422 with `code: "executorNoLongerSupported"` and `message: "executor no longer supported"`. Live stored Claude Code sessions become errored at startup and stay errored until Start over explicitly names a kernel provider. A bare restart and resume return that typed error. No automatic executor or provider fallback occurs. Old Claude Code turns are absent from transcript/history responses; raw stored rows and logs remain. The Claude Code MCP endpoints are removed, and `/v1/session-tools` lists only the kernel roster. The `claude` dialect uses kernel Anthropic Messages and requires API-key credentials rather than legacy Claude Code setup tokens.
