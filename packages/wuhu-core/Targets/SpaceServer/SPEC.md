# SpaceServer

The HTTP/WebSocket projection of one Space over wuhu-serve. Tools and observe
are the space surface; this file pins the machine-domain surface added in M4:
the registry routes, the two WebSocket endpoints, and the relay + grace
semantics layered over MachineContract/MachineChannel.

## Machine registry (space sqlite, SpaceCore arm)

- `machines` — machine records (`mc_<8>`, owning machine account, optional
  name, created-at). Each machine is one `machine`-kind account
  (one-to-one, unique index), and its credentials are ordinary enrolled keys
  in `account_keys` with the `exec-machine` capability — minted through the
  space's unified enrollment (`join_tokens`), never a parallel credential
  store. Rotate and revoke reset the machine account's credentials (keys,
  read sessions, outstanding join tokens) and kick any live hub leg; rotate then
  mints a fresh one-time join token to re-enroll the box.
- `machine_execs` — the exec registry: exec id (`ex_<8>`, server-minted),
  machine, **relay stream id**, command summary, caller (unused until auth),
  started-at, terminal state (`NULL` = live; `exited:N` / `signaled:N` /
  `cancelled` / `machine-lost`), kill-delivered flag. The stream id is
  allocated per machine at mint (max+1) and persisted so the id the machine
  agent's channel learned stays valid across server restarts.
- `script_execs` — owner rows for execs a `run_script` execution started
  (exec id, script id, session). The row commits with its `machine_execs` row
  and is deleted when the script ends, so a row still present at boot names a
  script the restart killed (see *Scripts on machines*).

## The acting group

Every request on the API origin acts in one group. Hostless paths, `/v1/f/*`,
tool calls and observe globs are that group's; `wuhu://<group>.localspace/<path>`
names another group's, and a group the acting group does not read answers as
a missing path. There is no fallback from a hostless path to another group.
The space paths a conversation post attaches are hostless, read in the acting
group, or `wuhu://<group>.localspace/<path>` in a group the acting group reads;
an unread group is 404 `notFound`, any other form 400. A conversation's
attachments live in its group and a member reads them from any group.

- A person (an assertion, or anonymous in dev) acts in the group the
  `wuhu-group` header names, else the Host `<group>.<space host>` (one label
  before the `--origin` host), else `shared`. `shared` needs no check. A group
  that does not exist or was removed is 404 `unknownGroup`; a group the
  person's account is not a member of is 403 `groupForbidden` (anonymous in
  dev skips membership); a header and a Host naming different groups are 400
  `groupConflict`. The person speaks as the persona the identity routes give
  them: the one `?identity=` names, else the account's first. A persona of
  another account is 403 `identityNotYours`, a claim from a key that is not
  a device or seat key 403 `personaRequiresDevice`. That persona is the
  member for watermarks, DMs and notifications.
- An exec token acts in its session's group (see *The gate*).
- The web origin serves the group its Host names: `<group>.<host>` (one label
  before the `--web-origin` host, else the `--origin` host) is that group, and
  the bare host, or a serve without an origin, is `shared`, byte-identical to
  a serve without groups. A group that does not exist or was removed is 404
  `unknownGroup` on every path. Pages, `/_/query` and `/_/observe` read that
  group with the cookie's viewer as the actor; the `wuhu-group` header is never
  read there, so a page cannot pivot into its viewer's other groups.
  - The one exception is a conversation's attachment folder:
    `/_/conversations/<id>/attachments/…` on any host is read in the group
    that homes conversation `<id>` when the host's group reads that group or
    the cookie's viewer is a member of the conversation (a cross-group DM),
    and is the host group's own path otherwise. The SPA opens an attachment on
    its own content origin at the hostless path, dropping the
    `wuhu://<group>.localspace` a reader outside the conversation's group is
    handed, so every member opens what was posted without a cookie for the
    conversation's group host.
  - Every file under `/_/conversations/<id>/attachments/`, whichever group
    homes it and whoever posted it, is message content, never a page of the
    host: it is served with `Content-Security-Policy: sandbox allow-scripts`
    (no `allow-same-origin`; a group host appends its `frame-ancestors` to
    the same policy) and without the import map or shell injection. Its
    scripts run in an opaque origin, so its fetches carry no cookie and its
    writes send `Origin: null`, which page-write admission refuses as
    `crossOrigin` whatever `page` they claim.
  - A read session is minted on one host with no `Domain`, binds that host's
    group (`read_sessions.grp`, NULL for `shared`), and admits on that host
    only. Every `wuhu_read` cookie sent is tried, so one a sibling host tosses
    at the parent domain cannot shadow the host's own. On a group host,
    minting and reading need membership (403 `groupForbidden`); `--public-read`
    opens the bare host only.
  - Sibling group hosts are same-site, so `SameSite=Lax` still sends a host's
    cookie with its neighbour's subresource and script requests. A request is
    cross-origin when its `Sec-Fetch-Site` is present and neither
    `same-origin` nor `none`, its `Sec-Fetch-Mode` is not `navigate`, and its
    `Origin` is not one of the host's paired SPA origins. It gets 403 `crossOrigin`
    when a cookie admits it to `/_/query` or `/_/observe` on any host, or to
    anything a group host serves; `DELETE /_/session` refuses it with or
    without a cookie. The pairing, and CORS, is exact: `<group>.<API host>`
    and the bare API origin (where the SPA runs for every group a person
    reads) for a group host, the bare API origin alone for the bare host; a
    sibling's `<other>.<API host>` never pairs. On a direct LAN serve each is
    the same scheme and host at the API port. Pairing grants no read: minting
    on a group host still needs membership.
  - Every group-host response carries `Content-Security-Policy:
    frame-ancestors 'self' <paired SPA origins>` (the origins CORS pairs), so
    a navigation the cookie serves cannot land in a sibling's frame. The bare
    host sends none.
  - HTML on a group host carries `<meta name="wuhu-group" content="<group>">`
    ahead of the shell script.
  - TLS: `--group-certificate`/`--group-private-key` (a `*.<host>` leaf, needs
    `--origin`; checked at boot, and a pair no handshake can use — a key off
    the named curves, e.g. EC with explicit curve parameters, or a key that
    isn't the leaf's — stops the start with `GroupTLSError.unusable`, naming
    the file and why) is served by SNI to names exactly one label under each
    listener's host. Every other name, and a handshake without SNI, gets the
    `--cert` leaf, whose fingerprint is the one recorded and pinned. A
    listener answers 421 to its sibling listener's host and group hosts, never
    its own; the sibling's host is 421 even when it is one label under this
    listener's host (`--origin https://api.example --web-origin
    https://web.api.example`), so it never reads as a group.

## Page data: `/_/space/*`

A page imports `wuhu:space`; the import map every served HTML page carries
points it at `/_/space.js`, the browser transport over the shared core
`packages/wuhu-web/app/app/lib/shell-sdk/space-core.js` (also served, no-cache,
as `/_/space-core.js`). The core speaks these routes on the content origin;
`run_script` embeds the same core over host calls. The legacy `/_/query` and
`/_/observe` are unchanged.

- Reads pass the wall `/_/query` passes (a read session, `--dev` or
  `--public-read`, and the cross-origin refusal):
  - `GET /_/space/query?sql=&params=` answers a typed snapshot
    `{columns, rows}`: a cell is a JSON scalar, `{"blob": base64}` or
    `{"json": value}`; a BOOLEAN column is `true`/`false`, a JSON column is
    `{"json": …}` (a cell that does not parse stays `{"json": "<text>"}`).
    `params` is one JSON array of bound values (the same cell forms), else
    400. It revalidates like `/_/query`.
  - `GET /_/space/observe?sql=&params=[&throttleMs=]` is an SSE stream of
    those snapshots, the first the current result; a bad statement or `params`
    is refused before the stream opens, with the status `/_/space/query`
    gives it (below). The legacy `/_/observe` keeps its flat 422.
  - `GET /_/space/watch?glob=[&from=]` is an SSE stream of file events
    `{kind: write|delete|move, path, to?, rev, entry?}`, the same as
    `/_/observe?glob=`. With `from`, it replays the events after `from`
    first. Without `from`, it opens with one `event: head` frame, data
    `{"rev": <head>}`, the revision read after the subscription starts: every
    later event arrives on the stream, so a client that drops, even before
    the first file event, resumes with `from=<the larger of head and the last
    event's rev>` and loses nothing. File events keep the default `message`
    type; the legacy `/_/observe?glob=` sends no head frame.
  - `GET /_/space/attributes?path=` runs `attributes.read`.
- Writes are `POST /_/space/rows` `{path, ops, page}` → `{rev, ids}` and
  `POST /_/space/attributes` `{path, set?, remove?, ifMatch, page}` →
  `{token}`. `ops` are `{insert: {col: cell}}`, `{update: id, set: {col:
  cell}}` or `{delete: id}`, applied in one revision; `ids` are the inserted
  rows' ids in order. A call touching one row id twice is refused as
  `invalidArgument` (an update's untouched fields come from the row before
  the call, so two ops on one row cannot fold). The patch is `attributes.patch`'s. Admission, in order:
  a `Content-Type` other than `application/json` is 415; an `Origin` that is
  not this host's own content origin (the request's scheme and host, or the
  `--web-origin` with the Host's group label), or a `Sec-Fetch-Site` other
  than `same-origin`, is 403 `crossOrigin`; no live read session for the
  host's group is 401 (`--public-read` admits no visitor to write; `--dev`
  writes as its seat, with no actor); a body past 4 MiB is 413, one that is
  not a JSON object 400; `page` must be the writing page's
  `location.pathname` — absolute and hostless, percent-decoded, a trailing
  slash dropped — else 400. `page` is the page's own claim; what keeps
  message content from writing is the attachment sandbox above, not `page`.
  Other methods on these routes are 405.
- A page acts as its host's group minus admin, whoever views it: an
  admin-only target (the group's instruction layer, e.g. shared's
  `AGENTS.md`) is refused as `unauthorized` even for an admin viewer, and so
  is every session home. Every path follows one rule: hostless is the host's
  group, `wuhu://<g>.localspace/<path>` group `g` when the host's group reads
  it.
- Failures carry the tool error payload (`code`, `message`, `hint?`,
  `token?`) with a status by code: `notFound` 404, `conflict` 409 (a stale
  `ifMatch`, carrying the current `token`), `invalidPath`/`invalidArgument`
  400, `unauthorized` 403, `unsupported` 422, `unavailable` 503, `internal`
  500.
- Attribution: a page write's revision records `actor`, the viewer's
  persona — the three-word id of the cookie's account, as the content
  origin's other reads name it (null for the `--dev` seat) — and `via`, the page path the
  page reported in its body, in `revision_actors(rev PRIMARY KEY, actor,
  via)`; only page writes add a row. `history` shows them as `by` and `via`.
  `via` is the page's own claim; only `actor` is authenticated.
- The read cookie authenticates `/_/space/*` on the content origin, never
  `/v1`.
- Every served HTML page gets
  `<script type="importmap">{"imports":{"wuhu:space":"/_/space.js"}}</script>`
  at the start of `<head>` (after the `<head>` tag, else after the doctype,
  else first), since an import map must precede every module script; the
  shell script is still injected before the last `</body>`. The HTML `ETag`
  is `"<token>-shell-<12 hex>"`, the hex a digest of both injections, so a
  change to either revalidates every cached page.

## Sessions in groups

- A session lives in one group, fixed at creation. A child always takes its
  creator's group. Only a top-level agent takes `group` (`SessionCreateInput`,
  `create_session`, `createSession`, `wuhu session create --top-level
  --home-group`), defaulting to the creator's; a group the creator's group
  does not read is 403 `groupForbidden` (a tool refusal from a session).
  `group` without a top-level agent is refused. A template name resolves in
  the creator's group, or `wuhu://<group>.localspace/templates/<name>` in a
  readable one; `GET /v1/templates` lists the acting group's.
- Instruction layers, in prompt order: the system files; the space-wide layer
  (`shared`'s `/AGENTS.md` and skills, listed by full
  `wuhu://shared.localspace/…` path), only for a session outside `shared`
  whose group has `space_layer` on; the group layer (the group's `/AGENTS.md`
  and skills, hostless); the home. Like the files, the `space_layer` flag is
  taken at session start and again at each compaction and Start over, never
  mid-generation; every toggle, on or off, bumps `group_epoch` and drops the
  scope notices of the group's sessions. A machine's notes come from the machine's
  group, qualified when that is not the session's.
- Writing `/AGENTS.md` or anything under `/.agents/skills/` in `shared` needs
  an admin of `shared` (a top-level agent or a human admin; a child never is),
  else `layerForbidden`; in any other group every member may. `/models.json`
  is `shared`-admin only. Anonymous in dev passes.
- No dialing in. A post to a box needs the box's group readable; opening a
  DM to a session needs its group readable, and an existing DM needs that or
  the other side having posted in it; a mention or reply-target wakes a
  session only when its group is readable to the poster's, it owns the
  conversation, or it has posted there. A refusal reads as `unknownSession` /
  `unknownConversation`. A new DM is homed in the opener's group; a created
  conversation in the acting group.
- Each delivered message records the poster's group (the `message_groups`
  side table; a session's own group, else the acting group) and whether the
  poster is an admin of the recipient's group. The header renders
  `<sender-group>` only when the poster's group differs from the recipient's,
  and `<sender-admin>yes|no</sender-admin>` always. `senderGroup` is on every
  message a surface returns: `ConversationMessagePayload` (HTTP, `observe`,
  the CLI log), a script's `conversation()`, `message_senders` and the push
  relay's data.
- Reading a conversation (`GET /v1/conversation/:id/messages` and `observe`,
  `GET /v1/session/:id/conversation`, a script's `conversation()` and `dm()`):
  a box when the reader's group reads its group; a DM when the reader is in it
  or it is homed in the reader's group; a group conversation only by its
  members. Anything else reads as an unknown conversation (404 `notFound`;
  `dm()` answers null). `GET /v1/conversations` lists every conversation the
  person's persona is a member of, whatever the acting group.
- A session route (`/v1/session/:id/…`: `transcript`, `direct`, `context`,
  `home`, `log`, `entry/:ref`, `compact`, `restart`, `tags`, `title`,
  `interrupt`, `resume`, `archive`, `unarchive`) answers a session whose group
  the acting group does not read as an unknown session (404 `notFound`),
  before any effect.
- In SQL, `conversations` shows the acting group's plus those the reader is a
  member of; `messages` and `conversation_members` follow it;
  `message_senders` (`n`, `sender_session_id`, `sender_grp`, `sender_title`)
  gives each visible message's poster group; `watermarks` shows only the
  reader's own rows (a session's id or a person's persona); `notifications`
  shows the acting group's plus the reader's own, so a member always sees
  a DM they are in and its notifications.
- A person has one inbox across all their groups, with one read position:
  `GET /v1/notifications` returns the identity's rows of every group whatever
  the acting group, each naming its `group`, and a conversation message from
  a poster outside the conversation's group carries the poster's
  `senderGroup`. The CLI keeps one inbox cursor per space, so switching
  `--group` or the Host replays nothing.
- In SQL, an unqualified name reads the acting group;
  `"wuhu://<g>.localspace/<name>"` reads a group `g` the acting group reads,
  and `"wuhu://*.localspace/<name>"` is the union over every readable group,
  with `grp` as a column. This release that union covers the built-in tables
  only; user tables, whose schemas can differ between groups, are combined
  with an explicit `UNION ALL` over their qualified names. An unqualified
  `links` stays same-group only (source and destination both in the acting
  group, as before groups); naming the group (`"wuhu://<g>.localspace/links"`)
  also shows that group's links into other groups, with their `dst_grp`.

## Endpoints

- `GET /v1/server` — discovery for API clients: `ServerInfo` with `webPort`
  when a web-content origin is bound, `{}` otherwise. The server reports the
  port, not an origin — only the client knows which host it reached, so the
  web origin is the API origin's host with this port. Public, outside the API
  wall. `features` lists `groups` (the server takes the `wuhu-group` header),
  and `group` is the group the request names, unchecked: an exec token's
  session group, else the header, else the Host, else `shared`. It carries no
  list of groups; that is `GET /v1/groups`.
- `GET /v1/groups` — `[GroupSummary]`, every group not removed, with where the caller stands: `member` (it acts and creates there: a person's `group_members` rows, a session's own group only) and `readable` (the union of what its member groups read, so every member group is readable). The caller is the request's credential alone; for a person the group the request names by `wuhu-group` header or Host changes nothing, and it need not be a member of it. A session's exec token naming a group other than its own is still 403 `groupMismatch` at the session gate, as on every route. A readable group the caller is not a member of is reached only through a member group's hostful paths (`wuhu://<g>.localspace/…`): naming it by `wuhu-group` or Host, or minting `/_/session` on its content host, is 403 `groupForbidden`. Public discovery outside the API wall, like `/v1/server`: anonymous is both `false` everywhere, the --dev seat both `true` (it acts in every group), a bearer that fails verification 401. Both flags are optional in the contract so a newer client reads an older server.
- `PUT /v1/groups/:id` — `GroupUpdateInput` → `GroupSettings`. Behind the API
  wall. `spaceLayer` turns the space-wide layer (see *Sessions in groups*) on
  or off for the group's sessions. Only an admin of that group may, else 403
  `forbidden`; anonymous in dev passes. A missing group is 404
  `unknownGroup`. The CLI is `wuhu group set --space-layer on|off <id>`.
- `GET /v1/f/<path>` · `PUT /v1/f/<path>` — the byte lane for space files,
  paired with the text-only JSON tools. `GET` answers the raw bytes with the
  content type derived from the path extension (`mimeType(for:)`, the same
  table the content origin uses — content type is never stored) and the
  version token as a quoted `ETag`; `path@rev` reads a historical view.
  `?group=<id>` names that group's file, as `wuhu://<id>.localspace/<path>`
  does for the tools (a group the acting group does not read is 404, a
  malformed id 400); the CLI's `cat` and `put` send a qualified path this way.
  `PUT` writes the request body verbatim, honors `If-Match`, bounds the body
  at 64 MiB (`413` past it), and answers the `WriteOutput` shape
  (`{rev, token}`). Both live under `/v1` so the API wall gates them exactly
  like `POST /v1/tools/*`: `--public-read` opens the content origin, never
  this. Tool failures map onto HTTP status (`notFound` → 404, `conflict` →
  409, `unsupported` → 415, …) instead of the tools route's flat 422.
- `POST /v1/transcribe` · `GET /v1/transcribe` — speech to text. `POST` takes the raw audio bytes with an audio `Content-Type` (`audio/wav`, `audio/mpeg`, `audio/mp4`, `audio/m4a`, `audio/webm`; aliases such as `audio/x-m4a` and `audio/mp3` normalize) and an optional `?language=` hint, and answers `TranscriptionOutput` (`{text, provider, model, language?, durationSeconds?}`). The space picks the provider: a stored ChatGPT login for `codex` outranks an `openai` api key, and with neither the route answers `503 noTranscriber`. Audio above 25 MiB is `413`; a non-audio content type is `415`; an upstream refusal is `502 unavailable` (`429` when the provider rate-limits) so a provider fault never reads as the caller's fault. `GET` is the capability probe — `TranscriberInfo` (`{available, provider?, model?}`) — so a client can hide a dictation affordance the space cannot serve. Both sit under `/v1` and the API wall gates them.
- `GET /v1/machine/challenge` — mints a one-shot connect challenge: burned at
  the first take, dead after a short lifetime, bounded in count under a
  flood. Open in non-dev mode; it feeds the connect handshake.
- `GET /v1/machine/connect` (WS) — the machine agent's dial-in. The box
  presents pubkey, challenge, and a raw signature (Ed25519 or P-256 r||s, per
  the pubkey label's algorithm tag — see SpaceContract's SPEC) over the
  domain-separated challenge payload in the `MachineConnect` upgrade request
  headers, verified **before the upgrade is accepted**: the challenge must
  take (one-shot, unexpired), the signature must verify under the algorithm
  the presented pubkey's label names, and the pubkey must resolve through the
  live key row to a machine.
  A missing, malformed, replayed, expired, or revoked handshake — including a
  key row that no longer decodes — is refused with 401 and no frame ever
  flows. This route stays open in non-dev mode: the handshake is its
  credential.
- Revocation reaches LIVE connections, not just future dials: revoke/rotate
  kick the hub leg synchronously, and each machine session runs a watchdog
  that re-resolves the live key row every `keyRecheck` (default 30s, hub
  clock) and severs the leg the moment the pubkey stops resolving — covering
  key rows removed outside the machine routes, even on an idle connection.
- **WebSocket routes bypass router middlewares** (a wuhu-serve design
  decision: `Middleware` wraps plain `Handler`s and cannot express upgrades).
  Both WS routes therefore self-gate — connect via the signature handshake,
  `/v1/exec/:id` via the registry lookup — and any future auth middleware
  will NOT cover them: auth for a WS endpoint must live in its route handler.
- `POST /v1/machine` (add: name → id + one-time join token, shown once; the
  box consumes it at `POST /v1/enroll/consume`, enrolling its own key) ·
  `GET /v1/machine` (list with `attached`) · `POST /v1/machine/:id/rotate`
  (kick + fresh join token) · `POST /v1/machine/:id/revoke` (kick) ·
  `PUT /v1/machine/:id/name` `{name}` (rename) ·
  `PUT /v1/machine/:id/group` `{group}` (move).
- A machine belongs to one group (`machines.grp`). A person's new
  machine joins their personal group, the `--dev` seat's joins `shared`
  (every machine enrolled before groups is in `shared`). A route that names a
  machine or an exec, the listing and `POST /v1/exec` see only machines in a
  group the acting group reads, 404 otherwise. A move needs an admin of the
  machine's group and of the target, a rename an admin of the machine's
  group (403 `adminRequired`: its name is every group's handle on it); rotate
  and revoke need a human admin of the machine's group. The machine's notes live in the tree of its current
  group, and a move carries them there in the same revision: `/_/machines` in
  a group's tree lists the machines of that group. An exec's row is homed in
  its caller session's group, a person's in the group they act in, else the
  machine's; the person exec routes (list, status, kill, the caller WS) see
  only execs homed in a group the acting group reads.
- `POST /v1/exec` — mint: `{machine}` → `{id}`. Writes the registry row
  (command fills in at exec-start) and starts the caller grace, so a minted
  but never-driven exec expires instead of lingering live.
- `GET /v1/exec/:id` (WS) — the caller leg. Mint first, then dial with the
  exec id; the same dial with the same id is the resume path. A terminal exec
  still admits the dial so a caller that blipped across the exit can drain the
  machine-retained tail byte-exactly; see the drain grace below.
- `GET /v1/exec` (ps: live registry rows) · `GET /v1/exec/:id` (plain HTTP:
  status of any known exec, `state` carrying the terminal outcome — the M6
  CLI distinguishes machine-lost from an ordinary blip with this) ·
  `POST /v1/exec/:id/kill` (no-op on terminal rows; otherwise the row turns
  `cancelled` first and the kill frame follows, so the real exit still
  settles it to `exited:N` / `signaled:N`. Recording first makes the kill
  stick against a racing start: a start relayed after it is refused, and a
  start already in flight is followed by a second kill frame, since the agent
  drops a kill for a stream it has not started. If the machine is detached,
  any connected caller leg is closed — no exit event will ever come, the
  registry carries the outcome — and the kill is delivered on the machine's
  next connect).
- Vault: `POST /v1/machine/:id/vault` `{name, value}` ·
  `DELETE /v1/machine/:id/vault/:name` · `GET /v1/machine/:id/vault`
  (names only). Delegated over the machine channel as wire ops; the value
  transits this process transiently and is never persisted or logged
  server-side. 503 when the machine is not attached. Setting needs an admin
  of the machine's group, removing a human admin of it (403 `adminRequired`).
  A session reaches a vault through `run_script`'s `wuhu:secret` with
  `{ machine }` (below), under the same gates.
- Group secrets: `PUT /v1/secret/:name` `{value}` (create or replace) ·
  `DELETE /v1/secret/:name` · `GET /v1/secret` → `{names}`, all on the acting
  group's store. Stored in `$WUHU_CONFIG_DIR/secrets/<space-id>/<group>.json`
  (0600, directories 0700), outside `space.sqlite`, so values never enter the
  revision journal, history or backups; no route returns a value. Names match
  `[A-Za-z_][A-Za-z0-9_]{0,127}` and values are non-empty (400 otherwise); an
  unknown name is 404, and 503 when the server has no config directory. A set
  needs an admin of the group; a removal can't be undone and needs a human
  admin (403 `adminRequired`). The server refuses to start while the
  pre-groups flat file `secrets/<space-id>.json` exists (`needsSecretsMove`,
  with the `mkdir … && mv … <space-id>/shared.json` that fixes it).
  `run_script` reaches the store through `wuhu:secret`: `secret(name)` is a
  secret of the session's own group, never another's by fallback, and
  `secret(name, { group: "shared" })` one of a group the session's group
  reads. It returns the placeholder `wuhu-secret.<name>.<8 hex nonce per run>`
  (`wuhu-secret.<group>:<name>.<nonce>` for a named group), built only from
  characters URL and form encoding leave alone. `set(name, value)` needs an
  admin of the session's group, so only a top-level agent sets one;
  `remove(name)` is always refused, since a removal needs a human admin.
  `{ machine: "<name-or-id>" }` names a machine's vault instead, one the
  session's group can use and that is attached: `set(name, value, { machine })`
  needs an admin of the machine's group (again only a top-level agent of that
  group), `list({ machine })` returns its names, and `remove(name, { machine })`
  is always refused; naming both a group and a machine is a TypeError.
  `secret(name, { machine })` is a TypeError too, never a fallback to the
  group's secret: a vault's values never leave the machine, so no placeholder
  stands for one, and `exec`'s `secrets` is how a script uses them. `fetch`
  replaces a placeholder with the value in the
  URL, header values and body it sends, and every value sent is masked as
  `***` in response bodies, headers and statusText, console, `result()`,
  `update()` and failure messages.
- `run_script`'s `wuhu:space` is the page core over host calls, acting as the
  session: `query` resolves to an array of rows (a BOOLEAN is a boolean, a
  JSON column parsed, a blob a `Uint8Array`), `observe` and `watch` are async
  iterables over live host streams that keep the script alive while it
  iterates and close when the loop is left, and `mutateRows`,
  `readAttributes` and `patchAttributes` run the same verbs as the page
  routes, refusing another session's home. A failure is a `SpaceError` with
  `code`, `message`, `hint` and, for a stale `ifMatch`, `token`; a query
  result past the script's buffer budget is `invalidArgument`.
- `run_script`'s `wuhu:space` also exports `move(from, to, { replace })` and
  `remove(path)`. They run the `mv` and `rm` tools, so each is one journaled
  revision. They take space paths only: hostless, in the session's group, or
  `wuhu://<group>.localspace/<path>` in a group the session's group reads (a
  move across groups is still one revision); a `machines://` or
  `wuhu://system/` address or an `@rev` suffix is refused as `invalidPath`. A
  path in another session's home, or in the session's own home in another
  group (`from`, `to` or `path`), is refused as `unauthorized`, the way the
  write tool refuses it. `move` refuses an existing `to`; with `replace: true` an existing
  file there is replaced in the same revision (a folder still refuses). This
  is how a session swaps in a finished `avatar.png` without readers ever
  seeing a half-written one.

## Scripts on sessions: `wuhu:session`

`run_script` creates and drives sessions as its own session, through the same
code the `create_session` and `request` tools run:

```js
import { createSession, request, setTags, archive, unarchive, interrupt, resume } from "wuhu:session"
await createSession({ title, kind, topLevel, provider, model, effort, template,
                      tags, message, expectsReply, key }) // { id, requestId? }
await request(id, message, { deadlineSeconds })           // { requestId }
await setTags(id, tags)                                   // replaces the list
await archive(id); await unarchive(id); await interrupt(id); await resume(id)
```

- Every call is checked when it runs, against the script's session as it
  stands then: an archived session is refused ("session X is archived and
  may no longer act on sessions"). `setTags`, `interrupt` and `resume` are
  allowed on the session itself and its descendants only; a root agent
  created with `topLevel` is not its creator's descendant. `archive` and
  `unarchive` also admit the session's creator and, from a top-level agent,
  any session of its own group (the rule: "only the session itself, its
  creator and admins of its group may"). `archive` of the
  script's own session from inside its turn is refused: the call is part of
  that turn, so the session can't settle ("can't archive itself mid-turn
  … its parent, an ancestor or a human archives it"). A detached script that
  outlives the turn can archive it once it has settled.
- `createSession` follows `create_session`: the kind is the explicit one,
  else the template's, else `agent` with `topLevel`, else `task`; the tree is
  capped at 16 levels; `topLevel` is for agents only, makes an agent, refuses
  `expectsReply`, and delivers `message` as a DM from the creator. Without
  `expectsReply`, `message` is a DM to a child too. Errors reuse the tool's
  wording with a `createSession:` prefix.
- `key` makes a create idempotent per calling session: it is stored as the
  receipt of tool call `script-key:<key>`, so a script that runs again (after
  a restart, a retry) gets the first session back, its `requestId` included.
  Nothing is created twice. The receipt records whether the template's files
  are still owed (`cloneOwed`) and clears it once they are in the home, so a
  replay clones only when the first call never finished cloning; the brief is
  handed over only if its message does not exist yet, and a request replays
  onto the one already open. A retry therefore finishes a half-made session,
  or rejects the same way again. Without a key each call creates.
- A session that was created but whose template clone or brief failed
  afterwards rejects with an `Error` whose `id` is the new session, so the
  caller can retry with the same key, or archive it, instead of creating
  another.

## Scripts on machines: `wuhu:machine`

`run_script` reaches the space's machines through one module:

```js
import { machine, machines } from "wuhu:machine"
await machines()                     // [{ id, name, attached }]
const m = machine("mac-mini")        // name or id; no round trip
await m.stat(path)                   // { kind, size, mtime: Date, token } | null
await m.list(dir)                    // [{ name, kind, size, mtime: Date }]
await m.read(path)                   // Uint8Array, at most 8 MiB
await m.readText(path)               // string; throws if the bytes are not UTF-8
await m.write(path, data, { ifMatch }) // string or bytes -> the new token
await m.remove(path); await m.mkdir(path); await m.move(from, to)
await m.exec(cmd, { cwd, env, secrets, timeout, maxOutput })
                                     // { code, signal, stdout, stderr, truncated }
const p = await m.spawn(cmd, { cwd, env, secrets, stdin })
p.id; p.lines(); for await (const { stream, data } of p) {}
p.write(data); p.end(); p.kill(); await p.wait() // { code, signal }
```

- Every call resolves the machine and refuses at once when it is not
  attached ("machine X is not attached"); nothing waits for a machine to
  come back. Paths and `cwd` are absolute on the machine; `cwd` defaults
  to `/`.
- Files go over the same VFS ops as the fs tools. `write` creates the parent
  directories and carries at most 12 MiB minus 64 KiB, so its base64 frame
  stays under the frame ceiling below. `remove` is recursive. `stat` answers
  `null` for a missing path; other failures throw `code: message`.
- `exec` and `spawn` both run `sh -c cmd` as an exec minted in the registry
  (`machine_execs` plus its `script_execs` owner row), so `wuhu ps` lists it
  under its `ex_` id. `secrets` names entries of the machine's vault
  (`{ VAR: "vault-name" }`); the agent injects and masks them. `env` names and
  the env/secrets overlap are checked as for the exec tool. A space-secret
  placeholder from `wuhu:secret` in the command, an env value or stdin is
  refused: space secrets never reach a machine. `timeout` is milliseconds
  (exec only). A command the box cannot spawn ends with exit 127 and a
  `wuhu:` line on stderr.
- `exec` collects the whole output: `maxOutput` defaults to 1 MiB and is
  capped at 4 MiB (`timeout` at the script's max lifetime); `truncated` says the agent stopped at it. `signal` is the
  signal number when a signal ended the command (`code` is then `null`).
- `spawn` streams. `lines()` yields `{ stream: "out" | "err", text }` in
  arrival order, split on `\n` per stream, a trailing `\r` dropped, decoded as
  UTF-8 with replacement on the server. Iterating the process itself yields
  raw `{ stream, data: Uint8Array }` chunks. A process has one reader: the
  second `lines()` or iteration throws. A reader that leaves before the end
  (`break`, `return`, a throw) discards the rest: what is buffered is dropped
  and later output is acknowledged unread, so the process never blocks. `write`/`end` exist only with
  `{ stdin: true }`; writes go out in call order. `kill()` sends TERM to the
  process group and KILL five seconds later. `wait()` resolves with the exit
  and does not read output.
- Flow control: each process may hold 1 MiB its script has not read. The
  agent stops sending past that and the process blocks on its pipes; nothing
  is dropped. A line still open when 1 MiB is held is handed over as it
  stands. The window of a running process, and each running `exec`'s
  `maxOutput`, count against the script's 64 MiB buffer budget; a process
  that has ended counts only the output it still holds unread. At most 8 processes run per script;
  a ninth `spawn` throws until one exits.
- Lifetime: a process lives only while its script runs. When the script
  ends — released, failed, `stop_script`, its max lifetime — every exec it
  minted is killed through the hub (`cancelled`, TERM then KILL). A script
  that spawns and awaits nothing ends at once and takes its processes along.
- Machine loss: after the machine grace a process's reads and `wait()` throw
  ("machine X was lost while process ex_… ran; it gets killed if the machine
  comes back"). The script does not re-dial, so the hub kills the process
  when the machine reconnects (see *Grace*).
- Server restart: executions live in one process, so a restart kills every
  script. At boot the server reads the owner rows left behind, tells each
  owning session once ("script X was killed by a server restart; the machine
  processes it left running (ex_…) get killed about a minute after the
  restart, or when their machine reconnects if it is away then"), and deletes
  them. A graceful stop leaves the rows in place too: its kills are cut short
  by the shutdown. The processes themselves go
  through the boot caller grace: `reaped` and killed about 60 s after boot,
  or on their machine's next connect. Nothing resumes.
- Accepted leaks: a process the agent cannot see (the agent crashed and
  restarted while it ran, or it daemonized out of its process group) survives
  the kill.

## Exec flow

1. Caller mints an exec id over HTTP, then dials `/v1/exec/:id`.
2. The caller leg is a full `ChannelEndpoint`: it sends `exec-start` (carrying
   the minted id — idempotent on the machine, so a blip during start cannot
   double-spawn), streams stdin, and consumes cursor-stamped output.
3. The hub relays frames between the caller leg and the machine leg by
   rewriting the envelope's stream id (caller-chosen ↔ registry-allocated) and
   never touching bodies — except `exec-start`, which it re-encodes with the
   session names owned (see *Session execs act as their session*). Acks are end-to-end; the server holds **no durable
   stream state** — replay buffers live at the two endpoints.
4. Stream-0 routing is asymmetric: a caller `hello` is forwarded to the
   machine (triggering its un-acked replay), a machine `hello` is broadcast to
   that machine's caller legs (triggering theirs); vault/VFS/search responses
   resolve server round trips by request id and are never relayed to callers.
   The server's own in-flight vault/VFS round trips fail (`severed`) when the
   machine leg unbinds or rebinds — at bind, not on `hello`, so a round trip
   issued on the new binding that races the in-flight hello frame survives it.
5. `exec-exit` passing through marks the registry row terminal (a real exit
   also settles a row previously `cancelled` or `machine-lost`).

## Session execs act as their session

An exec whose registry row has a `caller` session — the exec tool's claim, a
`run_script` spawn, or a `POST /v1/exec` made with a session token — runs the
`wuhu` CLI as that session, not as the wallet on the box.

- **Token.** When the hub relays that exec's `exec-start` it attaches
  `session: {token, spaceURL}` (`ExecSessionCredential`). `ExecTokens` mints
  the token (`wst_` + 64 hex, from 32 random bytes) bound to {session, exec,
  expiry}; a replayed start for the same exec reuses it. Expiry is the start's
  `timeout`, capped at 24 h (24 h when there is none). The token is revoked on
  `exec-exit` or when its exec row is found in a state it never comes back
  from (`exited`, `signaled`, `cancelled`, `reaped`). `machine-lost` is not
  one: the exec resumes when its machine reconnects, so the token keeps
  working. The table lives in memory only, so a server restart invalidates
  every token. `spaceURL` is `--origin`, else `https://<host>:<port>`.
- **Owned names.** On every relayed start, of any caller, the hub strips
  `WUHU_EXEC`, `WUHU_TOKEN` and `WUHU_SPACE_URL` from `env` and `secrets`;
  only the credential sets them. The hub never touches `WUHU_IDENTITY`; the
  agent drops one it inherited itself (MachineAgent SPEC).
- **The gate.** A request whose bearer starts `wst_` goes to the session
  gate in front of the API wall (dev or not). An unknown or expired token, or
  one whose exec has ended, is 401 with the reason; an archived session is
  403. A valid token runs the request as the session under the rules its own
  tools keep:
  - group: the session's own. A `wuhu-group` header or a Host
    `<group>.<space host>` naming another group is 403 `groupMismatch`, before
    any route.
  - files: `GET /v1/f/*`, `PUT /v1/f/*`, and `POST /v1/tools/{read, ls, stat,
    grep, find, history, query, write, edit, rm, mv, checkout, table.create,
    table.alter, table.mutate, new}`. Writes keep the session home rule
    (another session's `/_/sessions/<id>/`, or the session's own in another
    group, is refused, 422): the checked
    address is `path`, both of `mv`'s, and for `new` its `in`, else its
    template's (the instance lands next to it; the template is only read).
    `GET /v1/observe`, `GET /v1/server`, `GET /v1/groups`, `GET /v1/machine` (machines its
    group reads).
  - `POST /v1/conversation/message` runs `send_message` (a post to a session
    is a DM from this session; multipart attachments are refused), answering
    `{delivered: []}`. `POST /v1/session` runs `create_session`: a child task
    by default on the session's own model, `kind: agent` for a child agent,
    `topLevel: true` for a top-level agent (an agent only). `POST
    /v1/session/:id/request` (`SessionRequestInput` → `SessionRequestOutput`)
    runs `request` on its child. Tool refusals are 422.
  - `POST /v1/session/:id/{interrupt, resume, tags}` pass the
    self/ancestor check first (403 with the reason otherwise);
    `archive` and `unarchive` pass the archive rule above.
  - `POST /v1/exec` mints an exec owned by the session (which gets its own
    token) on a machine its group reads (404 otherwise); `GET /v1/exec` lists its own live execs; `GET /v1/exec/:id`,
    `POST /v1/exec/:id/kill` and the WS caller leg answer only for its own
    execs (404 otherwise).
  - Everything else — users, accounts, keys, vault, secrets, providers and
    auth, machine add/rotate/revoke/name, devices, notifications, usage,
    transcripts and logs, `sync` — is 403 with
    exactly `not available to a session`.

## Resume and restart

Re-dial with the same exec id and the channel protocol heals byte-exactly:
the reconnecting endpoint replays its un-acked tail and its `hello` makes the
far side replay everything the relay dropped. A server restart is the double
blip: the registry rows (id, machine, stream id, non-terminal state) are all
the server needs; both legs re-dial the fresh process, stream ids come back
from the registry, and the exec resumes from the caller's cursor — nothing
but time is lost.

## Grace (clock-injected, no wall-clock sleeps in tests)

- **Caller gone 60s** (from unbind, from mint, and from boot for live rows
  without a caller): the exec is `cancelled`; if the machine is attached the
  kill frame goes out now, otherwise it is delivered when the machine next
  connects (`kill_delivered` dedupes across rebinds — a kill lost with a dying
  leg is covered by the agent's own server-absence grace). A `machine-lost`
  exec whose caller is gone too gets the same kill and keeps its verdict.
- **Machine gone 60s**: every live exec of that machine with a connected
  caller fails now: registry `machine-lost`, a stream-0 `control` error with
  code `machineLost` to the caller (everything already delivered stays
  delivered), then the caller leg is closed. The caller-side wrapper (M6)
  composes `ExecEvent.failed` from that error. The grace is armed both when a
  bound machine leg drops and when a caller binds while the machine is not
  attached — a machine that never dialed in, or one still gone after an
  earlier expiry, fails a fresh caller after one grace instead of silence.
  The process may still be running on the box. When the machine returns, a
  `machine-lost` exec is killed unless a caller leg is dialed for it: the
  exec tool keeps re-dialing, with no deadline, until the machine is back or
  its call is interrupted, and then resumes, while a script gives up at
  `machine-lost` (see *Scripts on machines*), so its processes
  get the kill.
- **Drain grace**: a caller bound to a terminal exec must receive the replayed
  exit event within one grace; if it does not (the agent restarted, so the
  retained stream is gone), it gets a stream-0 `control` error with code
  `execNotFound` and the leg closes — the outcome stays readable via
  `GET /v1/exec/:id`.
- Reconnect within a grace simply rebinds: timers are generation-guarded and a
  stale expiry is a no-op. Nothing hangs forever on any path.
- **Accepted edge — agent restart mid-exec**: `exec-start` is relayed only
  while the registry row is live (a replayed start for a finished exec is
  dropped, so an agent that restarted and lost its per-id dedup state cannot
  respawn a completed command). If the agent restarts while the exec is
  *live*, a resuming caller's replayed start does spawn the command again on
  the fresh agent — the same cost family as orphan-on-crash (ruling 8, no pid
  ledger): agent death may double-run a live command, never a finished one.

## Resolver arm (M5): fs tools over `machines://`

`handler()` wires the tool context with a machine seam: `hub.vfs(machine:op:)`
and `hub.search(machine:query:)` are round trips over the machine leg, the
same pending-request plumbing (and severed-on-rebind semantics) as the vault
ops.
Fs tools called with a `machines://<id>/<path>` address route through
FSResolver to the machine backend; space addresses are untouched. Ruling 2
scope holds — machine fs is raw:

- Machine paths are not restricted by the space path grammar (`@`, spaces,
  `//` all pass through raw). The one carve-out: a trailing `@<digits>`
  revision suffix on a machines:// address is rejected `unsupported` (never
  silently stripped, never treated as a raw name), and so is a `rev` input
  field — machine fs has no revisions, journal, history, or observe.
- Version tokens are the agent's mtime strings, opaque; outputs carry `token`
  but no `rev` (`rev` is optional in Write/Edit/List/Move outputs). `rm`
  returns `{}`; `mv` returns `{dangling: []}` (no links on a machine) and
  refuses to cross backends.
- `edit` is composed server-side (ruling 14) by the same tool code path as
  the space edit: read → TextEdit fuzzy apply → write with `ifMatch` = the
  read token. A token mismatch surfaces the space conflict contract — code
  `conflict` plus the re-read hint.
- `write` mkdirs the parent first, mirroring the space fs's implicit
  directories.
- grep/find on a machines:// address never walk the generic VFS: the tool
  dispatches one `SearchQuery` frame and adapts the `SearchResult` page.
  Result paths come back with the `machines://<id>` prefix; cursors stay
  machine-local and round-trip opaquely through `step`. Space-side find now
  carries the same `matchLimit`/`entryLimit`/`step` contract (defaults 50 /
  1000) over the same flat-lexicographic traversal order, so pages are
  identical across backends modulo the address prefix — contract-tested in
  `MachineToolTests`/`SearchParityTests` against a real agent through this
  handler.
- Error mapping: machine `notFound`/`conflict`/`invalidArgument` keep their
  codes, `tooLarge` → `unsupported`, everything else → `internal`. A machine
  that is not attached (or a round trip severed mid-flight) fails
  `unavailable`; an id failing the `mc_` shape fails `invalidPath`.

The web origin's tool context has no machine seam: machines:// addresses fail
`unavailable` there.

## Frame size bound

`serve()` binds the API listener with a 16 MiB WebSocket frame ceiling
(`ServeOptions.maximumWebSocketFrameBytes` = `MachineHub.maximumFrameBytes`;
wuhu-serve's default is 1 MiB). Two machine-wire payloads travel as single
frames that exceed the default on real sockets: an exec output chunk can be as
large as the flow-control window (4 MiB default → ~5.6 MiB as base64 JSON),
and a VFS `read` returns the whole file in one response frame. The ceiling is
a memory guard against a hostile or buggy peer, not a tunable to chase file
sizes.

M5 resolved the open question **document-and-defer**: VFS reads are not paged
at the wire level. The space design defers streaming reads too, and wire
paging would be contract churn M6/M7 do not need. Instead the bound is
enforced loudly at both ends:

- The agent refuses to read a file over its 8 MiB read bound (`tooLarge`,
  MachineAgent SPEC) — an oversized response frame is never produced, so a big
  file on the box cannot sever the channel.
- The hub refuses to send an outbound round-trip frame over the ceiling
  (`MachineHubError.frameTooLarge` → tool error `invalidArgument`) — an
  oversized `write` fails the one call, not the connection.

In-process tests never hit the NIO decoder's ceiling — these two explicit
gates are what make the failure mode reachable and tested.
