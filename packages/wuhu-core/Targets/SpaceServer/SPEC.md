# SpaceServer

`GET /v1/media?url=…` is the worker's single transcript-media read. It accepts `wuhu-blob:` hashes and `wuhu-space:` attachment references; hostless space paths use the session's group. Exec tokens are refused before resolving any media. Worker reads do not consult blob ownership or the session's current file-reader rules, so immutable history remains usable after access changes. Ordinary tool file reads retain their reader checks.


## In-process execution ownership

`SessionRuntime.assemble` composes one directly conforming Hub actor for session persistence, inference and script machine access; a worker owns tool execution, QuickJS scripts and handlers. Worker code receives `any Main`, semantic values and machine stream facets, not `Space`, `SessionStore`, a writer or blob storage. Hub construction is inert and its credentials, signing, metrics, traces, model-placement and machine capabilities are injected. The server retains admission, subscription scheduling, authorization, persistence and machine-hub composition; it invokes handlers through `Worker.fire` and persists their returned state and wakes. Session loops, provider sockets, QuickJS scripts and handlers run in the server process, in a `KernelWorker` that reaches main only through `MainConnection` with its worker token (the loop's worker routes, including the session's token, park wake and cache warming) and holds nothing of main's. A worker may instead open its line at `/v1/worker/line`; main announces it there and publishes its attempt and usage notices into its own hub and board. Ordinary restart reconstructs durable work, not live sockets or JavaScript heaps.

## Workers in their own processes, and reboot in place

`wuhu serve --worker-process` (embedding: `serve(workers: .process(reboots:))`) runs the worker in a child process: the same binary with `WUHU_ROLE=worker`, `WUHU_WORKER_SOCKET` and `WUHU_SPACE_ID`, its worker token on its standard input. It reaches main's API only over `<folder>/run/worker.sock` (0600; a path over 103 bytes refuses startup): HTTP for the routes, one request per connection, and websockets for its line and exec caller legs. Its own credentials sign provider requests; OIDC tokens come from main's worker routes (`oidc-token`, `oidc-binding`, `oidc-readiness`). Main holds `<folder>/main.lock` and its two listening sockets (API, worker socket) for its whole life; a worker that ends unasked is dropped and replaced, and its sessions are woken on the new one. Verbs that find no worker (none announced, or a severed line) are retried every second, never failed.

`SIGHUP` reboots main in place. A new worker comes up and announces; each old worker hands its sessions off at the end of its step in flight and exits (`RevocationPolicy.handOff`). Main then stops accepting (connections queue in the listeners' backlogs), lets requests in flight finish (up to 5 s), lets go of its workers without telling them, shuts down, writes its in-memory state (session, worker, exec and v2 tokens, OIDC grants, minted worker count, worker pids, parked wakes) to `run/handover.json` (0600, read once and removed) and `execve`s itself with the listeners in `WUHU_LISTEN_FDS`. The main that comes up takes the handover, adopts its children, announces no script restart, and serves; the worker's line reconnects and re-announces the sessions it holds. A reboot whose new worker does not announce within 60 s is abandoned. `tools/dev/evergreen-reboot.sh` checks one SIGHUP mid-turn with a DeepSeek session (dev only, never CI).

## Person–session DM refusal

`POST /v1/conversation/message` refuses opening or posting into a person–session DM, including a post by a person to an existing DM id. Person requests receive HTTP 403 with code `humanAgentDM`; session identities (including script HTTP requests) cannot post into any `.dmUser` conversation or pass `user`, including explicit JSON `null`, and receive the typed tool refusal through the session gate (HTTP 422, code `refused`). The message is exactly: "There is no DM between human and agent. If you want to notify a human that has talked in your conversation box, simply post that box, optionally specifying the reply target's message ID." No post is rerouted to a box. Existing person–session DM history remains readable with the existing authorization; no migration or deletion occurs. People’s person–person DM posts, session–session DMs, box posts and their notifications, requests and reports are unchanged.

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
  machine, **relay stream id**, command summary, caller, tool-call id, opaque tool spec and owed-end flag,
  started-at, terminal state (`NULL` = live; `exited:N` / `signaled:N` /
  `cancelled` / `machine-lost`), kill-delivered flag. The stream id is
  allocated per machine at mint (max+1) and persisted so the id the machine
  agent's channel learned stays valid across server restarts.
- `script_execs` — owner rows for execs a `run_script` execution started
  (exec id, script id, session). The row commits with its `machine_execs` row
  and is deleted when the script ends, so a row still present at boot names a
  script the restart killed (see *Scripts on machines*).

## One listener, two planes

`serve` binds one TLS listener (`--port`, default 5530). The Host of each request picks the plane, compared lowercased and without one trailing dot, as is the `--origin` host:

- The bare host (the `--origin` host; without `--origin`, `localhost`) serves the API (`/v1/*`) and the web app. It serves no space content.
- `<group>.<host>`, exactly one label under it, serves that group's content: pages, files, `/_/session`, `/_/query`, `/_/observe`, `/_/space/*`, the shell and view providers. `shared.<host>` is `shared`. A content host answers no API route: `/v1/...` there is a content path.
- A name two or more labels under the host (`a.b.<host>`) is 421: the certificate may cover it, so a browser can reuse a connection for it, and 421 makes it retry on a fresh one to the right name.
- Every other name (an IP address, another LAN name a machine or CLI dials) reaches the API plane.

Without `--origin` the content host is `localhost`, so a browser on the serving machine reaches `<group>.localhost:<port>`; the self-signed certificate a fresh serve generates covers `*.localhost`. Serving group content to other devices needs `--origin`, which must name a host: an IP literal has no subdomains, so `serve` refuses one and points to an sslip.io name. `--web-port` and `--web-origin` still parse, for old launch configurations; each is ignored with one warning on stderr.

## The acting group

Every request on the API plane acts in one group. Hostless paths, `/v1/f/*`, tool calls and observe globs are that group's; `wuhu://<group>.localspace/<path>` names another group's, and a group the acting group does not read answers as a missing path. There is no fallback from a hostless path to another group. The space paths a conversation post attaches are hostless, read in the acting group, or `wuhu://<group>.localspace/<path>` in a group the acting group reads; an unread group is 404 `notFound`, any other form 400. A conversation's attachments live in its group and a member reads them from any group. Attachment paths supplied to a conversation post obey the same file readership as direct reads, including channel membership before group readability for hostless and qualified paths. An unreadable source returns `notFound` without posting or copying its bytes.

- A person (an assertion, or anonymous in dev) acts in the group the `wuhu-group` header names, else `shared`. The Host never names it. The group must exist and the person must read it by the one access rule (open membership, an account or acting-group entry, or space admin): a group that does not exist or was removed is 404 `unknownGroup`, one they may not read is 403 `groupForbidden` (anonymous in dev skips both). Acting in a group takes reading it; writing in it takes its write role. The person speaks as the persona the identity routes give them: the one `?identity=` names, else the account's first. A persona of another account is 403 `identityNotYours`, a claim from a key that is not a device or seat key 403 `personaRequiresDevice`. That persona is the member for watermarks, DMs and notifications.
- An exec token acts in its session's group (see *The gate*).
- A content host serves the group its Host names: `<group>.<host>` is that group, `shared.<host>` is `shared`. A group that does not exist or was removed is 404 `unknownGroup` on every path. Pages, `/_/query` and `/_/observe` read that group with the cookie's viewer as the actor; the `wuhu-group` header is never read there, so a page cannot pivot into its viewer's other groups.
  - The one exception is a conversation's attachment folder:
    `/_/conversations/<id>/attachments/…` on any host is read in the group
    that homes conversation `<id>` when the host's group reads that group or
    the cookie's viewer is a member of the conversation (a cross-group DM),
    and is the host group's own path otherwise. The SPA opens an attachment on
    its own content origin at the hostless path, dropping the
    `wuhu://<group>.localspace` a reader outside the conversation's group is
    handed, so every member opens what was posted without a cookie for the
    conversation's group host.
  - `?download=1` on a file answers its raw bytes (no import map or shell
    injection) with `Content-Disposition: attachment; filename*=UTF-8''<name>`,
    the file name percent-encoded per RFC 8187: the SPA's file card links
    there, since a cross-origin `download` attribute is ignored.
  - Every file under `/_/conversations/<id>/attachments/`, whichever group homes it and whoever posted it, is message content. HTML, XHTML, SVG and XML attachments are downloads with `Content-Disposition: attachment; filename*=UTF-8''<name>`. Images other than SVG, audio, video and PDF remain inline. Attachment directories return 404 instead of resolving indexes or rendering listings. All attachment responses retain `Content-Security-Policy: sandbox allow-scripts` (a group host appends `frame-ancestors`) and omit the import map and shell injection.
  - A read session is minted on one host with no `Domain`, binds that host's group (`read_sessions.grp`, NULL for `shared`), and admits on that host only. Every `wuhu_read` cookie sent is tried, so one a sibling host tosses at the parent domain cannot shadow the host's own. On a group host, minting and reading take a role in that group by the one access rule (403 `groupForbidden` otherwise, never a `shared` bypass); `--public-read` opens `shared.<host>` only.
  - Sibling group hosts are same-site, so `SameSite=Lax` still sends a host's cookie with its neighbour's subresource and script requests. A request is cross-origin when its `Sec-Fetch-Site` is present and neither `same-origin` nor `none`, its `Sec-Fetch-Mode` is not `navigate`, and its `Origin` is not one of the host's paired SPA origins. It gets 403 `crossOrigin` when a cookie admits it to `/_/query` or `/_/observe` on any host, or to anything a group host other than `shared.` serves; `DELETE /_/session` refuses it with or without a cookie. The pairing, and CORS, is exact: a content host pairs with the bare host, where the SPA runs for every group a person reads, as `--origin` spells it and as the bare host at the request's own scheme and port; without `--origin`, also as `127.0.0.1` and `[::1]` at that scheme and port, so the web app opened by loopback address frames and fetches its content. A sibling content host, `shared.` included, never pairs. Pairing grants no read: minting on a group host still needs membership.
  - Every group-host response carries `Content-Security-Policy: frame-ancestors 'self' <paired SPA origins>` (the origins CORS pairs), so a navigation the cookie serves cannot land in a sibling's frame. `shared.<host>` sends none.
  - HTML on a group host carries `<meta name="wuhu-group" content="<group>">`
    ahead of the shell script.
  - Share links. A place in a group is shared as the web app's own URL, `https://<host>/<path>?group=<group>`; `shared`'s has no `group`. A link written as `https://<group>.<host>/<path>` names the content. A top-level navigation there (`GET`, `Sec-Fetch-Dest: document`, `Sec-Fetch-Mode: navigate`) that the file wall refuses is 303 to `<bare origin>/<path>?<query>` with every `group` query item dropped and `group=<group>` appended; on `shared.` none is appended (`Cache-Control: no-store`), so an old link opens the document in the web app, which signs in. A frame, a fetch, a navigation a cookie admits, and `shared.` under `--public-read` get the content. The web app's shell carries a smart app banner whose `app-argument` folds `?group=<g>` into the host, `wuhu://<g>.<host>/<path>`.
  - TLS: `--group-certificate`/`--group-private-key` (a `*.<host>` leaf, needs `--origin` and `--cert`/`--key`, else `GroupTLSError.noOrigin` / `.noCertificate`: the generated certificate is pinned, so it serves every host; checked at boot, and a pair no handshake can use — a key off the named curves, e.g. EC with explicit curve parameters, or a key that isn't the leaf's — stops the start with `GroupTLSError.unusable`, naming the file and why) is served by SNI to names exactly one label under the host. Every other name, and a handshake without SNI, gets the `--cert` leaf.

## Page data: `/_/space/*`

A page imports `wuhu:space`; the import map every served HTML page carries
points it at `/_/space.js`, the browser transport over the shared core
`packages/wuhu-web/app/app/lib/shell-sdk/space-core.js` (also served, no-cache,
as `/_/space-core.js`). The core speaks these routes on the content origin;
`run_script` embeds the same core over host calls. The legacy `/_/query` and
`/_/observe` are unchanged.

- Reads pass the wall `/_/query` passes (a read session, `--dev` or `--public-read`, and the cross-origin refusal):
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
  - `GET /_/space/watch?glob=[&from=][&batch=1]` streams file events `{kind: write|delete|move, path, to?, rev, entry?}`. Replay is strictly after `from`. Without `from`, the stream opens with an `event: head` frame containing `{"rev": <head>}`, so a disconnect before the first mutation can resume from that baseline. The subscription starts before the head read, so queued mutations at or below that head are still delivered on the opening stream; the browser uses head only as a resume baseline before any delivered revision, never a delivery filter. A drop before any queued revision is delivered resumes from head as before. A completed queued revision replaces that baseline with its own revision, even when older than head, so a disconnect before the remaining queued commits replays them. The default keeps the existing individual `message` frames and bytes. Opting into `batch=1` uses the whole-revision `revision` frames of `/v1/observe`, with the same head and admission rules. The browser `wuhu:space` watch yields individual mutations from either frame kind and checkpoints a whole revision after delivering its array. A legacy per-event boundary R remains unproven: reconnect requests R−1 and suppresses previously delivered `(kind, path, to)` identities in R, retaining only that boundary revision's identities. This recovers siblings without repeating prior deliveries. The deprecated `/_/observe?glob=` route sends no head frame and is unchanged.
  - `GET /_/space/attributes?path=` runs `attributes.read`.
  - `GET /_/space/find?glob=[&path=][&matchLimit=][&hidden=][&noIgnore=][&step=]` and `GET /_/space/grep?pattern=[&path=][&matchLimit=][&hidden=][&noIgnore=][&step=]` run the `find` and `grep` tools as the page's group, answering their output: `{paths, cursor?, scanned, skipped}` and `{matches: [{path, line, text}], cursor?, scanned, skipped}`, `cursor` present exactly when more results remain. A missing glob or pattern, a limit that is not an integer, or a flag other than `true`/`false` is 400 `invalidArgument`; the tool's own refusals keep their codes (a bad regex or cursor 400, an unread group or missing path 404, a `machines://` path 503 `unavailable`, since a page has no machine seam). Other methods are 405.
- Writes are `POST /_/space/rows` `{path, ops, page}` → `{rev, ids}` and `POST /_/space/attributes` `{path, set?, remove?, ifMatch, page}` → `{token}`. `ops` are `{insert: {col: cell}}`, `{update: id, set: {col: cell}}` or `{delete: id}`, applied in one revision; `ids` are the inserted rows' ids in order. A call touching one row id twice is refused as `invalidArgument` (an update's untouched fields come from the row before the call, so two ops on one row cannot fold). The patch is `attributes.patch`'s. Admission, in order: a `Content-Type` other than `application/json` is 415; an `Origin` that is not this host's own content origin (the request's scheme and host), or a `Sec-Fetch-Site` other than `same-origin`, is 403 `crossOrigin`; no live read session for the host's group is 401 (`--public-read` admits no visitor to write; `--dev` writes as its seat, with no actor); a body past 4 MiB is 413, one that is not a JSON object 400; `page` must be the writing page's `location.pathname` — absolute and hostless, percent-decoded, a trailing slash dropped — else 400. `page` is the page's own claim; what keeps active message content from running as a page is the attachment download policy above, not `page`. Other methods on these routes are 405.
- `POST /_/space/session` (wuhu:session's createSession options plus `key`, `page`) → the `POST /v1/session` output, and `POST /_/space/message` (`{message, conversation | session, reply_target?, attachments?, page}`) → `{messageId, conversationId, n, delivered: []}`, take the write admission above and act as the viewer (the `--dev` seat as `owner`), through the hub's one create and post path. Bound: the viewer's authority intersected with the host's group, at every step. A page creates sessions only in that group, posts (its create's first message included) only into that group's conversations and boxes, and attaches only that group's files; anything else is 403 `outsidePageGroup`. A guest viewer, or one who does not write the group, is 403 `groupForbidden`; a task 403 `taskInput` (a person creates agents only); an incomplete create 422 `{code: incompleteSession, message, id}`; other refusals are 422 with their code, a server without sessions 404. `key` makes a create idempotent per viewer and group: a key never replays across groups. With `expectsReply` the create opens a request on the new agent whose `requester` is the viewer's persona: the request and the agent's reports post in the agent's box, and `request.key` is unique in the group as for a session's request.
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
- Instructions, in prompt order: the system AGENTS.md and skills; the session's own group
  (`/AGENTS.md` and the skills under `/.agents/skills/`, hostless); the system SESSION.md; the home.
  No group's instructions reach another group's sessions. Each AGENTS.md renders as a Mustache
  template for the session; the scopes are read as of the session's prompt revision and the
  rendered prompt is stored per generation, so an edit, a rename or a model switch reaches a live
  session only at its next compaction or Start over, never mid-generation. A machine's
  notes come from the machine's group, qualified when that is not the
  session's. Automatic machine/repository notices deduplicate exact file text across all paths and machines within one generation, replacing repeated AGENTS.md text or skill listings with a one-line reference to the first loaded path. Compaction and Start over reset this history; same-generation restart preserves it.
- Writing a group's `/AGENTS.md` or anything under `/.agents/skills/` takes a
  member of that group (a session of it, or a member person), else
  `forbiddenWrite`; every group, `shared` included, follows the same rule.
  Every file of the settings group takes a space admin (an `admin` of that
  group). Anonymous in dev passes.
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
- A person's post (`POST /v1/conversation/message`, and the opening message of `POST /v1/session/:id/restart`) may carry `viewing`: the space path of the doc or page open when it was sent, `/<path>` in the acting group or `wuhu://<group>.localspace/<path>`. It must be at most 1024 bytes, a valid space path without whitespace, control characters, quotes, `<`, `>` or `&`, and readable by the poster at send time (a missing and an unreadable path are refused alike); otherwise the post is refused `400 invalidArgument` with `reason: "viewing"` and an explaining message, before anything is stored. On a restart, `viewing` without a message is refused `400 invalidArgument` without that reason. It is stored group-qualified in the `message_viewing` side table, never checked again, and delivered to each recipient as its group names it: hostless in the recipient's own group, `wuhu://<group>.localspace/<path>` otherwise. The header renders it as `<viewing>…</viewing>` right after `<device>`; a message without it renders as before. Every value interpolated into a header tag (sender, handle, source, message and reply ids, device and its name, viewing, sender group) renders with `&`, `<` and `>` escaped as `&amp;`, `&lt;` and `&gt;`, so no value can close its tag and open another; a device name longer than 64 characters (grapheme clusters) or containing a control character, a line break, `<`, `>` or `&` is refused `400 invalidArgument` with the reason at `PUT /v1/device` and `PATCH /v1/device/:id`; names already stored are untouched. A session never sets it: the session gate refuses a post body naming `viewing` (even `null`) with `400 invalidArgument`.
- Reading a conversation (`GET /v1/conversation/:id/messages` and `observe`, `GET /v1/session/:id/conversation`, a script's `conversation()` and `dm()`): a box when the reader's group reads its group; a DM when the reader is in it or it is homed in the reader's group; a human-only channel (`kind: users`) when the person is a member, or the reader is a session whose group reads the channel's home group. A group read edge alone never admits a nonmember person. Anonymous dev-seat and public-read callers cannot read channels. Anything else reads as an unknown conversation (404 `notFound`; `dm()` answers null). Channel attachment bytes, file tools and directory listings, including content-origin reads, enforce this same contract. An open conversation observation revalidates readership on membership/group changes and stops when access is revoked. `GET /v1/conversations` lists the person's memberships and readable channels, or a session's memberships and channels in readable groups, ordered most-recent-active first (last message position descending; channels with no messages last).
- A session route (`/v1/session/:id/…`: `transcript`, `direct`, `context`,
  `home`, `log`, `entry/:ref`, `compact`, `restart`, `tags`, `title`,
  `interrupt`, `resume`, `archive`, `unarchive`) answers a session whose group
  the acting group does not read as an unknown session (404 `notFound`),
  before any effect.
- In SQL, `conversations` shows the acting group's non-channel conversations plus memberships and readable channels under the read contract above; `messages` and `conversation_members` follow it. `message_senders` (`n`, `sender_session_id`, `sender_grp`, `sender_title`) gives each visible message's poster group; `watermarks` shows only the reader's own rows (a session's id or a person's persona). `notifications` shows the acting group's plus the reader's own, but channel message notifications require channel readership regardless of recipient. Qualified group and wildcard views enforce the same channel gate; removing a member also hides historical notifications from queries and observations.


## Certificate pinning

What the server hands out for a client to enroll with — `EnrollMintOutput`, `ShareLoginOutput`, `MachineAddOutput` and `MachineRotateOutput` — carries a `fingerprint` only when `serve` runs the certificate it generated into `<folder>/tls`. With `--cert`/`--key`, self-signed or not, it is absent everywhere and clients check the certificate against their system trust store. `serve` records the certificate's fingerprint and which kind it is in the deployment record, so the offline `wuhu user invite` follows the same rule; a record written by a server from before the kind was recorded reads as unknown and yields no `fp` until the next boot rewrites it. Re-enrolling replaces a client's pin: a CLI `login` or `machine join` with an `fp` records it over the old one, and one without drops the host's pin once the server passes system trust, which is how a client pinned under the old rule moves to system trust. When system trust rejects the server, an existing pin carries the enrollment and stays.

## Bearer assertions

A person's request carries `Authorization: Bearer <assertion>`, a JWT the client signs with an enrolled key (encoding: SpaceContract's SPEC). Claims are `key`, `space`, `exp` and an optional `nbf`, in whole Unix seconds; other claims (an `iat`, say) are ignored, except `session`, which fails to parse. The gate checks the scheme and shape, the `space` claim, the key row, the signature, that the key is a person's, then the window. The window is the server's clock with no leeway: `exp` is exclusive, and `nbf`, when present, must not be later than now. Every refusal is 401 `unauthorized` with the message it always had; the error envelope (`ToolError`: `code`, `message`, optional `hint`, `token`, `reason`) tells the window apart only by `reason`:

- No `reason`: the credential is gone or never was — no live person key matches (revoked, expired, never enrolled, or a machine or space key, byte-identical so a response leaks neither existence nor capabilities; the person check precedes the window so a stale assertion cannot tell them apart either), a missing bearer where one is required, another scheme, a malformed assertion, another space's, a bad signature.
- `reason: "assertionExpired"` (past `exp`) or `"assertionNotYetValid"` (before `nbf`): a genuine signature by a live person key, refused only for its times, which the client chose by its own clock. The client re-signs with times corrected by `now` from `GET /v1/server` and retries; the key is fine.

Removing a key ends what it holds open. A streamed response (no `Content-Length`: SSE observe/watch, conversation and session streams) or a WebSocket that a person key opened through the production wall is held against that key until it ends. `DELETE /v1/key` (self or addressed) ends every one held by that key, and `DELETE /v1/accounts/:id` every one held by any key of the account, as soon as the row is gone: a response finishes cleanly with no in-band frame, a WebSocket closes. The client's reconnect then meets the revoked-key 401 above. A hold re-reads the key row after it registers, so a removal racing the open still ends it. Other keys keep theirs. Session exec-token requests, machine connections and content-origin read-cookie streams are never held, nor is anything under `--dev`, which has no wall. A hold is released when its stream ends, so the ledger is bounded by the streams open now.

## Endpoints

- In flat mode (`--content-host-pattern`, requiring `--origin` and exclusive with `--group-certificate`), the pattern starts with exactly one `{group}` and is a DNS authority; its port, if present, must match the origin. Group hosts substitute a valid `GroupID` prefix into the template, excluding ids with `--` at positions 3–4 (reserved for IDNA); hosts other than the origin host or a pattern match return 421 before either plane. `/v1/server` advertises `contentHost` instead of `contentBase`. Read/viewer cookies are `__Host-wuhu_read` / `__Host-wuhu_viewer`, retaining the legacy attributes, with no legacy-name admission or emission. The service worker reads the prefixed viewer name first, then the legacy name. Share links and the smart banner follow the template, not `<group>.<host>`: a content link is `https://` plus the template with `{group}` replaced (`https://<group>--<tenant host>/<path>`, `shared--…` for `shared`), and a refused top-level navigation there gets the same 303 to the web app; the banner's `app-argument` folds `?group=<g>` (other than `shared`) into `wuhu://<g>--<tenant host>/<path>`. The dotted `<group>.<host>` forms get 421. Without the flag, host routing, discovery and cookies are unchanged.

- `GET /v1/server` — discovery for API clients: `ServerInfo` with `origin` (`--origin`, absent without it) and `contentBase`, the `host[:port]` a client writes after `<group>.` for a group's content origin (`https://<group>.<contentBase>`): the `--origin` authority, else `localhost:<port>`. Public, outside the API wall. `features` lists `groups` (the server takes the `wuhu-group` header) , `observe-batch` (opt-in whole-revision filesystem observation) and `watch-batch` (whole-revision `/_/space/watch` responses), and `group` is the group the request names, unchecked: an exec token's session group, else the header, else `shared`. `now` is the server's clock when it answered, Unix epoch seconds with a fraction: a client that signs its own assertions learns its clock offset from it (see Bearer assertions); the answer carries `Cache-Control: no-store` and an HTTP-date `Date` of the same instant. It carries no list of groups; that is `GET /v1/groups`.
- `GET /v1/groups` — `[GroupSummary]`, every group not removed, with where the caller stands: `member` (it writes there: a person's writable groups, a session's own group only), `readable` (a group the caller reads by the one access rule: an open group, a group listing its acting group or its account, the settings group; the caller acts in `shared` unless the credential is a session) and `admin` (its role there is `admin`). Personal groups are never listed, the caller's own included. The settings group is left out, and so is a personal group unless the caller is a member of it. The caller is the request's credential alone; for a person the group the request names by `wuhu-group` header changes nothing, and it need not be a member of it. A session's exec token naming a group other than its own is still 403 `groupMismatch` at the session gate, as on every route. A readable group the caller is not a member of is reached only through a member group's hostful paths (`wuhu://<g>.localspace/…`): naming it by `wuhu-group`, or minting `/_/session` on its content host, is 403 `groupForbidden`. Public discovery outside the API wall, like `/v1/server`: anonymous is every flag `false` everywhere, the --dev seat every flag `true` (it acts in every group), a bearer that fails verification 401. The flags are optional in the contract so a newer client reads an older server; a client treats a missing `admin` as not an admin.
- `GET /v1/receipt` — the answer recorded for the caller's tool call (the
  `wuhu-tool-call` header), as `PUT /v1/f/*` and `POST /v1/tools/*` record
  it: a worker whose call is a replay learns its write already happened before
  paying for what precedes it (an image generation). A receipt stands for the
  request it answered: a repeat that asks something else, and `?address=` naming
  another path than the write's, is 409 `conflict`; none recorded is 404.
- `GET /v1/f/<path>` · `PUT /v1/f/<path>` — the byte lane for space files,
  paired with the text-only JSON tools. `GET` answers the raw bytes with the
  content type derived from the path extension (`mimeType(for:)`, the same
  table the content origin uses — content type is never stored) and the
  version token as a quoted `ETag`; `path@rev` reads a historical view.
  `?group=<id>` names that group's file, as `wuhu://<id>.localspace/<path>`
  does for the tools (a group the acting group does not read is 404, a
  malformed id 400); the CLI's `cat` and `put` send a qualified path this way.
  `?machine=<id-or-name>` names a machine's file, as `machines://<id-or-name>/<path>`
  does for the tools; a machine file is read whole up to one wire frame
  (`VFSDefaults.maxReadBytes`), `415` past it, and a session reaches the
  machine as itself on both verbs. `PUT` writes the request body verbatim,
  honors `If-Match`, bounds the body at 64 MiB (`413` past it), and answers
  the `WriteOutput` shape (`{rev, token}`). Both live under `/v1` so the API wall gates them exactly
  like `POST /v1/tools/*`: `--public-read` opens the content origin, never
  this. Tool failures map onto HTTP status (`notFound` → 404, `conflict` →
  409, `unauthorized` → 403, `unsupported` → 415, `provider_auth` → 502,
  …) instead of the tools route's flat 422; 401 stays the credential's.
- `POST /v1/transcribe` · `GET /v1/transcribe` — private speech to text and availability probe, resolved through shared `/capabilities.json` rather than credential priority. POST retains raw audio Content-Type/body; the capability routes section below defines options, rich metadata, bounds and typed errors. Both sit under `/v1` and the API wall gates them.
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
- `POST /v1/machine` (add: optional name and group → id + one-time join token, shown once; the
  box consumes it at `POST /v1/enroll/consume`, enrolling its own key) ·
  `GET /v1/machine` (list with `attached`) · `POST /v1/machine/:id/rotate`
  (kick + fresh join token) · `POST /v1/machine/:id/revoke` (kick) ·
  `PUT /v1/machine/:id/name` `{name}` (rename) ·
  `PUT /v1/machine/:id/group` `{group}` (move).
- Every space has a hidden `settings` group holding `/models.json`, `/model-groups.json`, `/capabilities.json` and `/machine-v2-upgrade.json`; the server reads them from there and nowhere else, and migration 003 deleted `shared`'s copies. Every group reads it, and only a space admin writes any of its files or takes it as a session's home. It is never listed by `GET /v1/groups`.
- `group_roles` is the one access table: `(subject_kind, subject, grp, role)`, where `subject_kind` is `account` or `group`, `role` is `read`, `write` or `admin` (ordered), and an open group (`groups.visibility`) needs no row. A person's role in a group is the best of its account's row, its acting group's row, an open group's `write`, and space admin; a session's is its own group's `write` plus its group's row, with a live top-level agent `admin` of its own group. Space admin is `admin` in `group_roles` for the settings group and administers every group but another person's own; an account's `admin` flag (`GET /v1/accounts`, `AccountPayload`) is that rule. Guests (`accounts.guest`) read only their account's rows and create no sessions. A personal group (`groups.personal_account`) belongs to one person, is listed only to that person, reads as nothing to anyone else (an entry naming it is refused), and grants nothing beyond itself. `GET /v1/group/:id` returns `{id, alias, open, secrets, personal, entries}` to anyone who reads the group; `PUT /v1/group/:id` `{alias?, open?, secrets?}` and `PUT`/`DELETE /v1/group/:id/access` change visibility, the secrets switch and the list for a group admin only.
- A machine belongs to one group (`machines.grp`). Without a body `group`, a new machine joins the acting group; with one, that group. Either way the caller must administer it (`403 adminRequired`); no personal-group default. A body `group` must exist (`404 unknownGroup`). Both registration routes follow this policy and echo the actual group in `MachineAddOutput.group`; `wuhu machine add --group G` and the global `wuhu --group G machine add` send only the registration target in the body, not the acting-group header. The CLI checks the echo when an explicit target was requested; environment and folder group settings do not set a registration target. A route that names a
  machine or an exec, the listing and `POST /v1/exec` see only machines in a
  group the acting group reads, 404 otherwise. Using one takes its
  `machines.scope`: `owner` admits the machine's own group alone,
  `reachable` every group with write in that group (enrollment takes a body
  `scope`, default `owner`; machines from before the switch are
  `reachable`). The listing shows only the machines the caller can use. `PUT /v1/machine/:id/scope` `{scope}` switches it for an
  admin of the machine's group. A move needs an admin of the
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
- Group secrets: `PUT /v1/secret/:name` `{value}` (create or replace) ·
  `DELETE /v1/secret/:name` · `GET /v1/secret` → `{names}`, all on the acting
  group's store; `?group=` names another only when that group's
  `groups.secrets_scope` is `reachable` and the caller writes it. Stored in
  `$WUHU_CONFIG_DIR/secrets/<space-id>/<group>.json`
  (0600, directories 0700), outside `space.sqlite`, so values never enter the
  revision journal, history or backups; no route returns a value. Names match
  `[A-Za-z_][A-Za-z0-9_]{0,127}` and values are non-empty (400 otherwise); an
  unknown name is 404, and 503 when the server has no config directory. A set
  needs an admin of the group; a removal can't be undone and needs a human
  admin (403 `adminRequired`). The server refuses to start while the
  pre-groups flat file `secrets/<space-id>.json` exists (`needsSecretsMove`,
  with the `mkdir … && mv … <space-id>/shared.json` that fixes it). The same
  stores feed exec `secrets` (*Exec secrets come from the machine's group*,
  below); a machine keeps no secrets of its own.
  `run_script` reaches the store through `wuhu:secret`: `secret(name)` is a
  secret of the session's own group, never another's by fallback, and
  `secret(name, { group: "shared" })` one of a group whose `secrets_scope` is
  `reachable` and that the session's group writes. It returns the placeholder `wuhu-secret.<name>.<8 hex nonce per run>`
  (`wuhu-secret.<group>:<name>.<nonce>` for a named group), built only from
  characters URL and form encoding leave alone. `set(name, value)` needs an
  admin of the session's group, so only a top-level agent sets one;
  `remove(name)` is always refused, since a removal needs a human admin.
  Any of the four given a `{ machine }` option throws a TypeError and touches
  no store: machines keep no secrets, and a script's exec names secrets of the
  machine's group in `wuhu:machine`'s `secrets`. `fetch`
  replaces a placeholder with the value in the
  URL, header values and body it sends, and every value sent is masked as
  `***` in response bodies, headers and statusText, console, `result()`,
  `update()` and failure messages.
- `run_script`'s `wuhu:space` is the page core over host calls, acting as the
  session: `query` resolves to an array of rows (a BOOLEAN is a boolean, a
  JSON column parsed, a blob a `Uint8Array`), `observe` and `watch` are async
  iterables over live host streams that keep the script alive while it
  iterates and close when the loop is left, and `mutateRows`,
  `readAttributes`, `patchAttributes`, `find` and `grep` run the same verbs
  as the page routes, refusing another session's home. A failure is a `SpaceError` with
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
                      tags, message, expectsReply, stallSeconds, request, key }) // { id, requestId?, existing? }
await request(id, message, { deadlineSeconds, stallSeconds, kind, key, schema, fields }) // { requestId, existing?, task? }
await setTags(id, tags)                                   // replaces the list
await archive(id, { force: true }); await unarchive(id); await interrupt(id); await resume(id)
```

- Every call is checked when it runs, against the script's session as it stands then: an archived session is refused ("session X is archived and may no longer act on sessions"). `setTags`, `interrupt` and `resume` are allowed on the session itself and its descendants only; a root agent created with `topLevel` is not its creator's descendant. `archive` and `unarchive` also admit the session's creator and, from a top-level agent, any session of its own group (the rule: "only the session itself, its creator and admins of its group may"). Force self-archive is always refused ("can't force-archive itself; its parent, an ancestor or a human archives it"). Non-force archive of the script's own session is refused mid-turn: the call is part of that turn, so the session cannot settle ("can't archive itself mid-turn … its parent, an ancestor or a human archives it"). A detached script that outlives the turn can archive it once it has settled. The same subtree busy check and leaf-first archive apply. Archive asks each archived session's running scripts to stop through `LoopConfig.archived`, the archiving script included, and returns; each ends within the stop grace.
- `createSession` follows `create_session`: the kind is the explicit one, else the template's, else `agent` with `topLevel`, else `task`; the tree is capped at 16 levels; `topLevel` is for agents only, makes an agent, refuses `expectsReply`, and delivers `message` as a DM from the creator. Without `expectsReply`, `message` is a DM to a child too. Creating a child below a parent reserved for archive or already archived is refused, including from a detached script. Errors reuse the tool's wording with a `createSession:` prefix.
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
  (`POST /v1/exec` with `script: <run id>` as the session: `machine_execs`
  plus its `script_execs` owner row), so `wuhu ps` lists it under its `ex_`
  id; the worker then dials `/v1/exec/:id` like the CLI does. `secrets` names secrets of the machine's group
  (`{ VAR: "SECRET_NAME" }`, *Exec secrets come from the machine's group*);
  the agent injects and masks them. `env` names and the env/secrets overlap
  are checked as for the exec tool. A `wuhu:secret` placeholder in the
  command, an env value or stdin is refused: only `fetch` fills one in, and
  `secrets` is how a group secret reaches a machine. `timeout` is milliseconds
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
  ends — released, failed, `cancel`, its max lifetime — every exec it
  minted is killed through the hub (`POST /v1/exec/:id/kill`: `cancelled`,
  TERM then KILL) and `DELETE /v1/script-execs/:script` drops the session's
  owner rows for that script. A script that spawns and awaits nothing ends at
  once and takes its processes along.
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
   session names owned (see *Session execs act as their session*) and its
   `secrets` resolved (see *Exec secrets come from the machine's group*). Acks are end-to-end; the server holds **no durable
   stream state** — replay buffers live at the two endpoints.
4. Stream-0 routing is asymmetric: a caller `hello` is forwarded to the
   machine (triggering its un-acked replay), a machine `hello` is broadcast to
   that machine's caller legs (triggering theirs); VFS/search responses
   resolve server round trips by request id and are never relayed to callers.
   The server's own in-flight VFS/search round trips fail (`severed`) when the
   machine leg unbinds or rebinds — at bind, not on `hello`, so a round trip
   issued on the new binding that races the in-flight hello frame survives it.
5. `exec-exit` passing through marks the registry row terminal (a real exit
   also settles a row previously `cancelled` or `machine-lost`).

## Exec secrets come from the machine's group

Every exec surface — the exec tool, `run_script`'s `m.exec`/`m.spawn`,
`POST /v1/exec` with its WS caller leg, `wuhu exec --secret` — carries
`secrets` as `ENV_NAME → SECRET_NAME`, and the hub resolves it when it relays
the `exec-start`, so all of them behave alike.

- **Whose store.** NAME is looked up in the group store of the group the
  machine belongs to (`machines.grp`) when the start is first relayed. The
  calling session's or person's group plays no part, and a machine moved to
  another group uses that group's store from its next start on. The values come from
  the same `$WUHU_CONFIG_DIR/secrets/<space-id>/<group>.json` stores that
  `wuhu secret` and `wuhu:secret` manage.
- **Capability.** The machine connect upgrade carries
  `x-wuhu-machine-capabilities` (MachineContract). A machine leg bound with
  `group-secrets` in it gets the start re-encoded with `secrets` removed and
  `secretValues` (`ENV_NAME → value`) added; the agent injects and masks them
  and writes nothing to disk. The values live only in that frame and in the
  hub's memory for the exec's lifetime; they are never logged, stored in the
  registry, or put in an error.
- **Resolved once.** Only the first relay of an exec id resolves. A caller
  replaying the start after a blip gets it relayed with the values of that
  first relay and is never refused, even when the machine has since moved or
  the secret is gone: a running exec keeps its environment. The values are
  dropped at the exec's exit or when its caller grace runs out; a server
  restart forgets them, so a start replayed across one resolves afresh.
- **Refusal before spawn.** A name the machine's group lacks, a store that
  cannot be read, a server started without a config directory (no stores at
  all), or a machine no longer enrolled refuses the exec: the start never
  reaches the agent, the registry row turns `exited:127`, and the caller leg
  gets what a failed spawn gives — one stderr chunk `wuhu: no secret NAME in
  group GROUP\n` (or the matching reason) at cursor 0 and `exec-exit` with
  `exited(code: 127)`. A caller replaying that start after a blip gets the
  same refusal again. Several unknown names report the lexically first.
- **Old agents.** A machine leg bound without `group-secrets` (an agent from
  before the header) gets the start with `secrets` names as they came and no
  `secretValues`, and resolves them in its own `vault.json` as it always did;
  the server sends such an agent no value. It stays that way until the agent
  is upgraded and reconnects.
- A `wuhu:secret` placeholder is never a secret name: `run_script` refuses one
  in an exec's command, env or stdin before minting.

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
- **V2 execs.** Script bindings inject a server-owned `sessionCredential: {token, spaceURL, expiresAt}` before `exec.v1` admission. The bearer is bound to session, original group and script-scoped operation owner; retries retain the same credential and immutable expiry (invocation timeout, capped by script lifetime and 24 hours). The supervisor exports `WUHU_TOKEN_EXPIRES_AT` as Unix epoch seconds as well as the three identity names, overwrites caller values and masks the token on output. The session gate checks the durable operation on each request: missing, terminal, unknown, stopped or shut-down operation state is unauthorized. Group changes and session archive refuse authority. Expiry is HTTP 401 `credentialExpired`; the CLI also reports this typed error from the expiry environment before traffic, never falling back to anonymous/wallet. Credentials are not renewed. The in-memory v2 issuer retains bounded expired tombstones for another 24 hours, and checks existing durable credential ownership after tombstone pruning so an expired retry cannot mint a replacement; server restart invalidates all bearers. No database schema changes are needed.
- **Owned names.** On every relayed start, of any caller, the hub strips
  `WUHU_EXEC`, `WUHU_TOKEN`, `WUHU_SPACE_URL`, `WUHU_TOKEN_EXPIRES_AT`, `WUHU_ID_TOKEN_URL` and `WUHU_ID_TOKEN_REQUEST` from `env` and `secrets`;
  only the credential sets them.
- **ID-token capability.** With the credential, a session's exec (v1 hub, or a v2 start sent by the record's caller session) gets `WUHU_ID_TOKEN_URL` (`<spaceURL>/v1/id-token`) in `env` and `WUHU_ID_TOKEN_REQUEST` (`wit_` + 64 hex) in `secretValues`, so the agent masks it; a v1 agent without `group-secrets` gets it in `env`. The grant binds session, machine and exec, lives in memory with the exec token's life (timeout capped at 24 h), is stable per exec, and is revoked with the exec token, when a v2 relay ends and when the exec's machine is lost (a v1 exec that resumes afterwards no longer mints). Grants are memory-only: after a restart none survives, and a new one is a new capability. See Server identity for the route. The hub never touches `WUHU_IDENTITY`; the
  agent drops one it inherited itself (MachineAgent SPEC).
- **The gate.** A request whose bearer starts `wst_` goes to the session
  gate in front of the API wall (dev or not). An unknown or expired token, or
  one whose exec has ended, is 401 with the reason; an archived session is
  403. A valid token runs the request as the session under the rules its own
  tools keep:
  - group: the session's own. A `wuhu-group` header naming another group is 403 `groupMismatch`, before any route.
  - files: `GET /v1/f/*`, `PUT /v1/f/*`, and `POST /v1/tools/{read, ls, stat,
    grep, find, history, query, write, edit, rm, mv, checkout, table.create,
    table.alter, table.mutate, new}`. Writes keep the session home rule
    (another session's `/_/sessions/<id>/`, or the session's own in another
    group, is refused, 422): the checked
    address is `path`, both of `mv`'s, and for `new` its `in`, else its
    template's (the instance lands next to it; the template is only read).
    A `wuhu-tool-call` header on `POST /v1/tools/*` is the call's idempotency
    key: the first 2xx answer is recorded under (session, id) and a repeat
    with the same id gets that answer back without running the tool again,
    which is how a worker's write or edit retried after a crash never fails
    as stale. `read` with `image: true` of an image path (png, jpg, gif, webp;
    not under `wuhu://system/`) checks the bytes against the name, bounds them at
    `ImageMedia.maxReadBytes`, stores them in the blob store and answers
    `ReadOutput.image` (`{mimeType, blob, byteCount, width?, height?}`) with
    a one-line `content`.
    `GET /v1/observe`, `GET /v1/server`, `GET /v1/groups`.
  - The session verbs run on the hub as the session; the `wuhu-tool-call`
    header is their idempotency key too, owned by each verb: the answer is
    looked up and recorded in the write that makes the effect (a slot armed
    or cancelled, a device command, a title set, a session created) or the
    effect's id is derived from the call (a message, a request, a report,
    whose deadline and stall clocks commit with the request's message and
    end with its final), so a repeat, or two runs of one call at once, gets
    the first answer, a retried cancel is still "cancelled", and a retried
    title never overwrites a later one; a refusal leaves no receipt and runs
    again. An incomplete create (the
    session exists, its template or brief did not land) is 422
    `{code: incompleteSession, message, id}`, and the same call again
    finishes it. `POST /v1/conversation/message` is
    `send_message` (a post to a session is a DM from this session; `user` is
    refused 422 as the tool refuses it; multipart attachments are refused),
    answering `{delivered: []}`. `POST /v1/session` is `create_session`: a
    child task by default on the session's own model, `kind: agent` for a
    child agent, `topLevel: true` for a top-level agent (an agent only);
    `kind` reaches the hub as written, so an odd one is the hub's 422; the
    answer carries `title`, `requestId` and `member`. `POST
    /v1/session/:id/request` (`SessionRequestInput` → `SessionRequestOutput`,
    with `deadline`) is `request` on its child; `POST /v1/request/:id/report`
    (`RequestReportInput` → `RequestReportOutput`) is `report`; `POST
    /v1/session/:id/title` is `set_title`, for the session itself only
    (another id is 404); `POST /v1/device/:id/command` is `manipulate_ui`
    (top-level agents only); `POST /v1/subscription` (`SubscriptionInput`,
    exactly one of `observe` and `timer`, else 400) arms the session's own
    slot keyed by the tool call and `DELETE /v1/subscription/:id` is the
    subscription half of `cancel` (an ended or foreign id is 422 `notFound`);
    `GET /v1/templates` lists the templates `templates` lists; `GET
    /v1/machine` renders the hub's roster (machines its group reads, the
    hub's attach state; 422 when the server has no machine backend) as
    `[MachineStatus]`. Tool refusals are 422 carrying the tool's code.
  - `POST /v1/session/:id/{interrupt, resume, tags}` pass the
    self/ancestor check first (403 with the reason otherwise);
    `archive` and `unarchive` pass the archive rule above.
  - `POST /v1/scripts` (`ScriptRunInput` → SSE of `ScriptOutput`) is `wuhu script`: the session's worker runs `source` as a space script with `import.meta.args` = `arguments`, under `run_script`'s lifetime and API, and each `result`, `update` and `failure` is one event in order, closed by `end` once the run has ended; a stream that stops without `end` is a run that did not end. Closing the stream cancels the run. The run's span carries `script.kind: wuhu_script` and `script.source.sha256`; no script-run row exists in the space, so the span is the record.
  - `POST /v1/exec` mints an exec owned by the session (which gets its own
    token) on a machine its group reads (404 otherwise); `GET /v1/exec` lists its own live execs; `GET /v1/exec/:id`,
    `POST /v1/exec/:id/kill` and the WS caller leg answer only for its own
    execs (404 otherwise).
  - Everything else — users, accounts, keys, secrets, providers and
    auth, machine add/rotate/revoke/name, devices, notifications, usage,
    transcripts and logs, `sync` — is 403 with
    exactly `not available to a session`.

Resume of a session with unreadable stored transcript/history is refused with a conflict explaining that the data cannot be loaded and directing the caller to Start over. The HTTP and `wuhu:session` script surfaces both retain that guidance; readable errored sessions still resume normally.

## Session Start over

`POST /v1/session/:id/restart` opens an empty-summary generation, preserving armed observations, one-shot and cron timers, outgoing request deadlines and queued input. Queued messages reach and wake the new generation; a bare restart remains inert. The head shows the active subscription list before the restart note. The two-sentence note tells agents to catch up from their own box using the `read-box` skill (for example, read its last 2–5 messages); tasks are directed to their DM with their parent, never a nonexistent task box. Error, hold, run and retry state and park reminders are cleared, pending compaction commands are discarded, and the model/executor may change. Running scripts, children, open requests, home files, conversations and prior-generation history are unchanged. Archived and busy sessions still receive typed refusals; an errored session can be started over. A request deadline with no stored fire date is refused with `invalidSubscription`, rather than silently dropped.

## Resume and restart

Re-dial with the same exec id and the channel protocol heals byte-exactly:
the reconnecting endpoint replays its un-acked tail and its `hello` makes the
far side replay everything the relay dropped. A server restart is the double
blip: the registry rows (id, machine, stream id, non-terminal state) are all
the server needs; both legs re-dial the fresh process, stream ids come back
from the registry, and the exec resumes from the caller's cursor — nothing
but time is lost.

V2 output cut at its budget acknowledges the admitted prefix even when a machine poll coalesces it with discarded bytes. The channel consumption offsets are persisted before retained output is released, so a restart sends the exit and truncation at the same combined cursor the caller already holds. Replay skips each retained chunk's prefix below its channel's durable consumption offset, including when an acknowledgement covered only part of that chunk and no output was discarded.

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
  The process may still be running on the box. Both exec tools and scripts stop waiting at `machine-lost`; neither treats it as confirmed process exit. When the machine returns, a `machine-lost` exec without a connected caller is killed.
- **Machine silence 60s**: the logical machine relationship has a monotonic silence deadline, including while its socket appears attached. Only decoded inbound machine frames renew it; server-local caller reconnects and replacement machine sockets do not. An existing `stat("/")` VFS request every 20 seconds supplies liveness evidence from installed agents without changing the wire protocol, and at most one such probe is outstanding per socket. At expiry the hub detaches the machine, fails pending VFS/search calls with exactly `machine <machine> stopped responding`, and fails/closes its exec callers. Exec errors retain the warning that the remote process outcome is unknown. This deadline is independent of each remote process's runtime timeout and leaves byte ACKs and output replay unchanged. Binding, unbinding, and silence expiry are logged with the machine, socket generation, silence duration, last message type, and pending caller/request counts, without command text or secrets. Registry loss is recorded for all affected execs before error sends run concurrently; after a 100 ms best-effort error-send grace, the transport is aborted without flushing a close frame, failing pending writes and ending inbound. A backpressured caller cannot hold up another or keep the send task group waiting for an outbound flush. A caller rebound during loss accounting is failed on its current binding, including one accepted using a stale live registry record. A drain caller whose registry already records a terminal verdict other than `machine-lost` receives `execNotFound` with `exec <id> is finished and its stream is no longer replayable`; silence expiry never replaces its known verdict with an unknown process outcome.
- **v1 replay scope and map lifetime**: a caller's first start on each binding establishes its stream mapping before requesting one replay scoped to its authorized exec id, including terminal drains whose start is not forwarded. The preceding caller hello is not forwarded, so no duplicate unmapped replay is requested. A pending terminal ACK can establish its authorized stream mapping without resending the start. Machine reconnect still resumes live caller legs. The hub discards an exec's caller generation/stream/machine maps, machine stream mapping, exit-delivery marker and resolved-secret state once its durable record is terminal and its caller is absent; late machine frames do not recreate terminal history maps. A caller-gone timer may still deliver a pending machine-lost kill from the durable registry after these maps are dropped. Refused execs retain their small diagnostic/exit result separately until a matching terminal ACK or ten minutes from refusal, so a post-exit/pre-receipt caller crash can still replay exit 127 and its diagnostic.
- **Drain grace**: a caller bound to a terminal exec must receive the replayed
  exit event within one grace; if it does not (the agent restarted, so the
  retained stream is gone), it gets a stream-0 `control` error with code
  `execNotFound` and the leg closes — the outcome stays readable via
  `GET /v1/exec/:id`.
- Reconnect within a grace rebinds socket-scoped timers; stale socket expiries are no-ops. The logical silence deadline survives socket replacement until actual machine evidence arrives.
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
same pending-request plumbing (and severed-on-rebind semantics).
On a v2 machine every start a session caused carries `StartRequest.caller`
`{session, title, group}`, read from the session record at start time: file
tools and search take the session from `MachineSeam.caller` (set by
`ToolExecutor` around each tool call, and by `MachineSeam.attributed(to:)`
on a script's machine access; the parent owner binds it itself at `execute`, `placeImage` and `capabilityInput`, so each operation uses its actual calling session), exec from the leg that sent the start. A v2 exec belongs to one actor (a session, a person by account, or the --dev seat): the session that minted it, reserved from the mint; for a callerless exec, the one that sent its start, or before that the one attached. Another actor's dial of `/v1/exec/:id` is refused with 409 `execAttached` (the hub closes a leg that races past that check), so it can neither type into nor read the exec; the owning actor may always reconnect. The caller and the session credential are the record's session only when that session's own leg sent the start — a person's own (callerless) exec runs unattributed and without the credential. Starts no
session caused, and sessions that can no longer be read, carry none; the
field is display-only for the machine's audit and never authorizes.
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
- grep/find run one FileSearch query on every backend: the space walks
  itself, a machines:// address runs it on the machine as `search.v1`
  (machine v2 only: a v1 machine fails `unsupported`; an agent without
  `search.v1` fails `unavailable`, agent too old, before starting). Same
  walk order, hidden names, budgets and cursors, and every file read a range
  at a time whatever its size, so pages hold the same items across backends
  modulo the `machines://<id>` prefix (`SearchParityTests`). A cursor is bound
  to its backend: the group, the machine or the system files.
- Error mapping: machine `notFound`/`conflict`/`invalidArgument` keep their
  codes, `tooLarge` → `unsupported`, everything else → `internal`. A machine
  that is not attached (or a round trip severed mid-flight) fails
  `unavailable`; an id failing the `mc_` shape fails `invalidPath`.

The content plane's tool context has no machine seam: machines:// addresses fail `unavailable` there.

## Frame size bound

`serve()` binds its listener with a 16 MiB WebSocket frame ceiling (`ServeOptions.maximumWebSocketFrameBytes` = `MachineHub.maximumFrameBytes`; wuhu-serve's default is 1 MiB). Two machine-wire payloads travel as single frames that exceed the default on real sockets: an exec output chunk can be as large as the flow-control window (4 MiB default → ~5.6 MiB as base64 JSON), and a VFS `read` returns the whole file in one response frame. The ceiling is a memory guard against a hostile or buggy peer, not a tunable to chase file sizes.

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

## Per-call inference accounting

The kernel metrics sink writes every `InferenceMetric` to `inferences` alongside the existing `logs/inference.jsonl` line. Uncached input subtracts cache reads and writes from WuhuAI's total input; billed output includes reasoning. Missing usage and unreported reasoning remain null. Compaction uses the same sink.

Stored Claude Code inference rows remain queryable; no executor produces new ones.

## Subtree archive

`POST /v1/session/:id/archive` accepts no body or `{ "force": false }`; `{ "force": true }` forces the operation. A malformed body returns `invalidArgument`. A busy non-force archive returns HTTP 409 `conflict` with a `busy: id (title), ...` list. The CLI accepts `session archive <id> [--force]`; code mode accepts `archive(id, { force: true })`. The app's unchanged empty-body call is non-force.

Archiving a session takes its entire parent-chain subtree, leaves first and root last. A separately created top-level agent has no parent and is not included. Only the root's archive rights are checked. Without force, every session is checked for the existing unfinished-work condition (retired sessions are never busy, even with queued input); refusal archives nothing and names every busy session by id and title. With force, busy sessions are interrupted before any archive write, and every open request in the subtree, including an undrained request, is closed with a final-kind message saying the session was archived before reporting. Its requester receives that message even outside the subtree. Unarchive remains single-session, subject to the archive grace window.

## Capability HTTP surface

Authenticated `POST /v1/web-search` accepts `{ query, provider?, count? }` and returns the shared normalized search result. `POST /v1/image` accepts `{ prompt, images?: [base64 PNG], provider?, model?, quality?, size? }`, bounds its body to 36 MiB and decoded references to 25 MiB aggregate/at most five, and returns `{ b64JSON, mimeType: "image/png" }` for the create-only local CLI output. Image data is private request data, not a public Wuhu URL.

`POST /v1/transcribe` retains raw audio Content-Type/body and the existing response's text/provider/model/language/durationSeconds fields, adding optional segments/words/confidence/usage. Query options are language/provider/model/timestamps (comma-separated words,segments)/diarize (true/false). It resolves the same `/capabilities.json` selection as scripts and images before buffering up to 25 MiB; duration must be established locally and must not exceed two hours. MP4/M4A fragments use track timescales and decode/sample timing, not zero-duration initialization headers; unestablishable duration is rejected before provider I/O with invalid_argument and a re-encode hint. No ChatGPT-first picker remains. `GET /v1/transcribe` retains available/provider/model for existing clients; explicit configuration failures mark unavailable. App/browser/CLI need no new provider picker. Unconfigured capabilities synthesize Codex; explicit broken active/overrides produce typed errors without fallback.

Capability error bodies preserve code/message/hint. HTTP mapping: invalid_argument/unsupported_feature → 400 (streaming upload byte overflow → 413); provider_auth → 502 (the server's provider credential failed, not the caller's: 401 is the caller's own); provider_region/provider_entitlement → 403; provider_rate_limited → 429; provider_not_configured/provider_unavailable → 503. No upstream diagnostic bodies, credentials or signed result URLs are logged/returned. The existing authentication wall remains; session exec tokens may call these four capability routes, preserving group scoping and without access to credential-management routes.
## Partial-loading routes

`GET /v1/conversation/:id/messages?tail=100&paged=true` returns `ConversationHistoryOutput`: ascending messages, exclusive `before`, `hasEarlier` and `headPosition`. An older request adds `before`; the maximum paged tail is 100. Existing unpaged message responses retain their shapes. The channel/box/DM read contract above applies to each page.

`GET /v1/session/:id/transcript/page?limit=200` returns `TranscriptHistoryOutput`. Older reads supply `generation`, exclusive `before`. The response carries generation, optional `historyEpoch`, positioned entries, boundary origins, before, hasEarlier and snapshot head. Origins are attribution, not loaded transcript rows. An invalid cursor is 400; stale generation is 409 `generationChanged`. Session read authorization applies to each page.

`GET /v1/session/:id/direct?paged=true&generation=N&position=P` starts after the snapshot head. Bounded catchup beyond 200, a changed generation  sends reset and closes the response. Clients clear retained history on reset and rebootstrap. Stream attempt subscriptions are cancelled when the committed stream ends. The original whole-read and unpaged direct routes retain their prior contracts.

## Kernel Responses transport

SessionRuntime owns the bounded Responses socket registry and its structured sweeper. Model and credential resolution happen per attempt; selected WebSocket transport never falls back to SSE. The process composition root explicitly installs the live connector, while offline callers inject it. Session commit acknowledgements use actual persisted entries and current rendered attribution, and lifecycle changes invalidate the registry entry. `codex.rate_limits` uses a separate validated `rate_limits.primary/secondary` projection (`window_minutes`, `used_percent`, `reset_at`), not the `/wham/usage` schema. Zero/negative windows, percentages outside 0–100, missing values and nonfinite values are ignored. Quota observation never changes inference token usage or durable transcript state.

Assembled-runtime WebSocket tests exercise the production inference closure rather than substituting a test LoopConfig: actual durable assistant/tool commits establish a warm provider-ID continuation, successive successful calls release leases, provider 401/409 and cancellation invalidate owned leases before resume, and on-connect/inference/post-completion quota reaches the runtime UsageBoard.

The session runtime logs unexpected session-service termination errors instead of silently swallowing them; cancellation is normal shutdown.

## Configured AI disclosure

`SpaceServer.serve(aiDisclosureFile:)` / `wuhu serve --ai-disclosure <json-file>` reads a disclosure object once at startup, before store creation or listener binding. The file format is `{"version":"trial-2026-10","providers":[{"name":"DeepSeek","location":"China","via":"Wuhu metering proxy","policy":"https://wuhu.ai/privacy"}]}`: nonempty version, at least one provider, nonempty name/location/via, and an absolute HTTPS policy URL without credentials. Unreadable files throw `AIDisclosureError.unreadable`; malformed JSON, missing fields or invalid values throw `.invalid`, with a readable option/file diagnostic. There is no fallback or silent omission. The public `GET /v1/server` payload adds exactly `aiDisclosure: {version, providers}` when configured. Without the option the response bytes are unchanged. Editing the file requires a restart, and changing provider sets requires a new consent version.

Policy URLs must use the literal lowercase `https://` scheme prefix and have no leading or trailing whitespace. Host config and server startup reject, rather than normalize, other spellings.

## Server identity (OIDC)

First startup generates one ES256 P-256 signing key in the server-state `identity/identity.p256`, not in the space. The private directory is mode 0700 and the key mode 0600. Restart/upgrade reuses persisted key state; malformed existing keys are not replaced. JWKS includes `kid` for multiple-key publication.

Unauthenticated `GET /.well-known/openid-configuration` on the space API host returns `issuer`, `jwks_uri` and `id_token_signing_alg_values_supported: ["ES256"]`. `GET /.well-known/jwks.json` returns `keys` with the public EC key (`kty`, `crv`, `alg`, `use`, `kid`, `x`, `y`), never private `d`. Issuer is the configured HTTPS `--origin` (hosted: the tenant's own origin). Missing/non-HTTPS origin or unavailable identity gives HTTP 422 with code `oidcConfiguration`; never infer issuer from request Host. Group content hosts do not host these discovery routes.

For each OIDC kernel inference attempt, runtime supplies a freshly signed JWT. Audience is the canonical origin of the provider's `baseURL`, including non-HTTPS schemes, without user information, path, query or fragment. Tokens use `alg: ES256`, `typ: JWT`, `kid`, raw 64-byte ECDSA signatures, and claims `iss`, `aud`, integer `iat`, `exp = iat + 300`, unique `jti`, `space` (space id), `group` (group id), and `session` (session id, when acting). `sub` is `<group>/<session>` or `<group>` without a session. The kernel obtains the group from its persisted session record, never from client claims. Invalid audience/issuer and identity key-unavailable/signing failures become typed inference `invalidInput` 422 errors with static hints naming provider baseURL, HTTPS --origin or server identity key configuration. Unknown signer diagnostics remain suppressed; no credential/provider fallback or private error details are exposed.


`GET /v1/id-token?audience=<origin>` with `Authorization: Bearer wit_…` precedes the device wall and authenticates by that capability alone. It answers 401 `unauthorized` for an unknown or expired grant, or an exec that has ended, machine loss included, or no longer matches the grant's machine and caller; 403 for an archived session; 400 `invalidArgument` unless `audience` is a canonical origin; 503 `identityUnavailable` without a server identity; identity failures as `/v1/identity`. Success is `{token, expiresAt}`, `Cache-Control: no-store`: a JWT as for inference but with `exp = iat + 60`, the group read from the session record, and extra claims `machine` and `exec`. A `wst_` bearer reaches the session gate, which refuses it.

Server-state `identity/settings.json` persists issuer choices and the allocated directory ID, outside every group's files. Default `self` preserves the existing issuer and claims. `directory` selects `https://id.wuhu.ai/<id>`; exact canonical HTTP(S) audience-origin overrides win over the default. Directory registration submits a compact ES256 proof signed with the server key; replacement uses the same proof format and current key. No private key, space name or address is sent. A directory ID is validated as 32 base64url characters before persistence. Every startup republishes when directory is selected or an ID has already been allocated. Directory minting is refused until confirmed: transient publication failure is `directoryUnavailable`; a removed registration is `unknownId`, and a key not listed for the id is `unlistedKey`; inference surfaces typed 422 invalidInput with this code in its static hint, and page/script fetch preserves the corresponding typed code. Never fall back to self. A failed settings publication persists the requested choice and fails closed; transient publication failures are retried by the maintenance loop every minute, and the same set command can retry at once. Own-host discovery remains self-issued so self overrides still work, with the same public key as the directory.

Authenticated `GET /v1/identity` returns `{defaultIssuer, overrides, publicationFailure}` with resolved URLs. `publicationFailure` is the current directory failure code (`directoryUnavailable`, `unknownId`, or `unlistedKey`), or null when confirmed or not using the directory. Every failed publication logs only this code, never key material. `GET /v1/identity/issuer-for?origin=<canonical-origin>` returns `{issuer}`. Both are available to enrolled humans and session execs, never anonymous production readers. `PUT /v1/identity` takes exactly `{defaultIssuer:"self"|"directory"}`, `{audience:<canonical-origin>,issuer:"self"|"directory"}`, or `{audience:<canonical-origin>,remove:true}`. Writes require a human space-admin account (or the anonymous dev seat), never a session. Mutations are serialized; concurrent changes return 409 `identityBusy`. Malformed origins fail before persistence. This is server-wide configuration, not acting-group configuration. Changing an issuer is a breaking verifier migration: trust both issuers before switching.


Rotation is automatic 90 days after initial schedule creation or the previous rotation's completion. `POST /v1/identity/rotate` begins it immediately and returns `{rotating:true}`; it requires the same human space-admin authority as settings and returns 409 `identityBusy` when a rotation is already pending. Day 0 durably stores a new private key before publishing old and new together, keeps signing with old, and begins the overlap clock only after directory confirmation when applicable. After one day it durably switches to the new signer. After two days, and at least one full day after the actual switch, it replaces the directory set with only new, signed by new, then removes old from its own JWKS and persisted schedule. A delayed switch extends the overlap so recently minted old tokens remain valid. All three mint sites share this signer. Restart resumes the persisted phase, retries unconfirmed publication, and never generates a second pending key. The structured server lifecycle runs maintenance every minute and cancels its clock sleeps on shutdown. Own and directory public JWKS retain both keys throughout overlap.

`identity/settings.json` now also holds the active and pending raw private keys and phase timestamps under the same 0700 directory/0600 file protections, never group files, HTTP discovery or script snapshots. Existing settings without a schedule adopt the original `identity.p256` key and start the initial 90-day clock without changing tokens. The original key file remains a bootstrap artifact; persisted schedule state is authoritative after rotation. Back up the complete server identity directory.

`POST /v1/identity/register-new` registers the current public key set under a fresh id and replaces the saved id only after confirmed registration and durable persistence, returning the resolved issuer snapshot. Failed registration or persistence preserves the old id and its previous minting status; restart and maintenance continue using that saved id, never silently allocate a replacement. An accepted registration whose id could not be saved is unused; the admin may explicitly retry. It is human space-admin-only, never available to sessions/scripts, and serialized with settings and rotation. This is recovery for `unknownId`/`unlistedKey`, not a retry of the same issuer. It permanently changes every directory-selected audience's issuer; verifiers must migrate, ideally trusting both URLs before switching. Restore the complete server-state backup instead when preserving the old issuer is required. A purely self-issued space with no allocated id gets 422 `directoryNotSelected`; select directory first. A pending rotation gets 409 `identityBusy` unless current publication has failed with `unknownId` or `unlistedKey`. In that ownership-loss case recovery registers the full current key set (old and pending), preserves the persisted rotation phase, and allows rotation to resume under the new id with its overlap intact. Inference hints and page/script/HTTP error codes preserve these two ownership failures instead of pretending a retry can fix them.


## Proxied page fetch

`import { fetch } from "wuhu:space"` on a content-host page has the standard browser `fetch(input, init)` signature, accepts URL/string/Request input and returns a streaming `Response`. It sends `POST /_/space/fetch?url=<target>&method=<method>&headers=<JSON object>&page=<location.pathname>` with the raw request body. Query values are percent-encoded. Supported target methods are GET, POST, PUT, PATCH, DELETE and HEAD; every endpoint method other than POST is a typed 405 `fetchMethodInvalid`. RequestInit signal cancellation reaches the transport. The SDK never detours to direct browser fetch.

Admission requires Origin equal to the page's own content origin, Sec-Fetch-Site same-origin, and a live read cookie bound to that group. An anonymous viewer is 401 `fetchViewerRequired`, including under --dev or --public-read. No exec bearer is admitted: sessions cannot currently load content pages as themselves. The viewer token claim remains an opaque stable id so later session viewers can use their session id without a token-shape change. Human viewers use the account's persona handle (stable id), or account id when no persona exists; never email. `page` is the page's hostless absolute percent-decoded path, validated like other page writes, and remains a page-supplied claim, not an authenticated document identity.

Only the content host group's `/fetch.json` is read, fresh on every call, never a readable neighbour's or shared group's list. Its shape is `{"allow": ["https://dashboard.example.com"]}`: exact HTTP(S) origins (scheme, host, effective port), no user information, path, query, fragment or wildcard. An optional trailing `/` is accepted as an empty origin path. Host/scheme case and default ports canonicalize. Listed LAN/private origins are allowed. Missing, empty or unreadable list is 403 `fetchListMissing` naming `/fetch.json`; malformed entries are 400 `fetchListInvalid`. An unlisted target or redirect is 403 `fetchOriginForbidden` naming `/fetch.json`, before connection to that origin.

Target headers and body pass through except Cookie, Host, hop-by-hop headers and content length (the transport computes it). A page-set Authorization is refused as 403 `fetchAuthorizationForbidden`; only the server sets Authorization. Response Set-Cookie, hop-by-hop headers and connection-nominated headers are stripped, and Wuhu-Viewer is overwritten with the authenticated cookie account. The page worker recognizes Wuhu-Fetch-Result and does not bump its write epoch, purge query caches or notify the shell about an upstream 401. The response streams without collecting its body. The transport resolves each hop's host once, pins the connection to that numeric address using AsyncHTTPClient's DNS override, and keeps the original authority for Host/TLS verification. Redirects are followed only to listed origins, with a newly minted audience on each hop, up to 20 hops; 303 and POST 301/302 become GET, while 307/308 retain method/body. Invalid redirects or exhausted limit give 502 `fetchRedirectInvalid`.

The request body cap is 10 MiB (`413 fetchBodyTooLarge`) and one 60 s deadline covers upload, DNS, all hops and response streaming. Inbound deadline cancellation terminates the request-body read; policy refusals and timeout responses explicitly close the connection without a keep-alive drain. Pre-response deadline expiry is `504 fetchTimeout`; connection failure is `502 fetchUpstreamUnavailable`. A response stream already committed cannot replace its HTTP status with JSON: deadline/network failure closes it and browser body consumption rejects normally. Cancellation disposes the outbound connection. DNS runs off the cooperative executor; a cancelled wait does not permit a later connection. Fetch policy refusals have JSON `{code, message}` and the SDK rejects with SpaceError. Successfully forwarded responses carry `Wuhu-Fetch-Result: upstream`, even for upstream 4xx/5xx, so they return an ordinary Response rather than becoming policy errors.

The existing server identity signer and discovery JWKS sign fetch JWTs, never a second key. Each hop gets `Authorization: Bearer <jwt>` with ES256/kid, iss = the audience-selected issuer, aud = canonical target origin, iat, exp = iat + 60, jti, space (space id), group (host's group id), sub (group), path (page claim), viewer (opaque authenticated stable id). Missing identity/issuer or signing failure is 503 `fetchIdentityUnavailable`, with no signer/provider/credential fallback.

## Script fetch identity

The assembled script host has a dedicated opt-in identity transport using the same `ServerIdentity` key as page fetch and inference, with the acting session’s recorded group and stable space id. It mints a fresh ES256 JWT once per call with a 60 s lifetime and session claims, registers it with script masking before I/O, and sends it only to redirects on the explicitly named URL’s canonical HTTP(S) origin. Cross-origin redirects receive no Authorization; no redirect mints another token. Redirects are bounded at 20 and use a single 60 s deadline that also bounds DNS resolution; expiry is checked before each hop. POST becomes GET on 301/302, and non-HEAD becomes GET on 303; 307/308 retain method/body.

Single-hop HTTP connections disable automatic redirects and share the page path’s DNS-pinned streaming transport. Scripts preserve Set-Cookie response headers (pages still strip them). No page allow-list is consulted. Ordinary script fetch still uses its existing transport unchanged. Directory confirmation failures are directoryUnavailable; other identity configuration/mint/signing errors are fetchIdentityUnavailable, with no fallback. DNS, transport, timeout and invalid-redirect failures retain ordinary script fetch error behavior. Token echo masking is best-effort, not a guarantee against split/encoded echoes reaching JavaScript; audience binding and the 60 s lifetime bound their use. The private key never enters scripts, responses or the space.

View-provider routes (`/_/views/kanban`, `list`, `wall`, and `map`) refuse a `path` resolving under conversation attachments with 403 `attachmentViewForbidden`. They inspect the first `path` query value, matching the provider's URLSearchParams lookup, before returning a trusted provider frame. A malformed target URL receives 400 `invalidViewPath`. Copy an attachment definition to an ordinary space path before opening it as a view.


Session Start over reports the number of unreadable queued inputs dropped in its restart note, appended to the normal catch-up text. Readable queued inputs retain FIFO order and dedup identity and still wake the new generation. Retained open requests have their park-reminder count and last-reminder time reset, so a restarted task does not inherit its previous park backoff.

## Removed Claude Code executor

All model providers run in the kernel. `POST /v1/session`, session templates and `POST /v1/session/:id/restart` accept `executor: "kernel"` only; any other value is HTTP 422 `{ "code": "invalidArgument", "message": "unknown executor: <value>" }` (a template names itself in the message). A session-tool call returns a failure with the same code; code-mode creation throws an error naming it. No rejection creates a session or changes its generation. A session stored on any other executor is retired: its transcript pages, log and entries read empty, it never runs, and unarchiving it is refused with HTTP 422 `{ "code": "executorNoLongerSupported", "message": "executor no longer supported" }`. Start over must explicitly name a provider to hand a live one over; a bare restart cannot switch its executor. The session id, box, home, tags, children, subscriptions and readable queue input are retained.

The Claude Code installer, process loop, stream parser, mirror/history translation, image transport, MCP routes and loopback listener, usage probes and inference accounting hooks are removed. Old turns no longer appear in transcript/history routes; raw stored rows and external logs are not deleted. `/v1/session-tools` exposes only the kernel roster.

## Human-only channels

`POST /v1/conversation` accepts `{members: [persona], title?: string|null}` and returns `ConversationPostOutput` with the new conversation id. It creates a `users` channel homed in the acting group; every initial member must be a person, not a session. `POST /v1/channel/:id/add` and `/remove` accept `{people: [persona]}`; `/rename` accepts `{title: string|null}`. Creation and each mutation validate atomically. Anonymous creation receives `invalidArgument` with "creating a channel needs an identified person or session". Person members and sessions whose group reads the channel's home group may manage it; anonymous dev-seat and public-read callers cannot manage channels and receive the same typed unknown-conversation refusal as nonmember people. Session ids, empty identities and blank non-null titles are invalid arguments; unread/non-channel ids answer as unknown conversations. Adding a member is idempotent, removing an absent member is harmless, and `null` clears the title. `ConversationPayload` has nullable `title`; the UI falls back to members' names. The nullable title side table is additive and needs no ALTER, data reset or backfill.

Sessions read, post and manage without joining the channel; legacy session membership rows grant no person access. Plain messages notify people but do not wake a session unless addressed. Mentions, reply targets and the existing attention window still deliver to sessions. CLI `channel create|add|remove|rename` and `wuhu:space` `createChannel`, `addChannelMembers`, `removeChannelMembers`, `renameChannel` expose the same management services.

### Whole-revision observe frames

`GET /v1/observe?glob=…[&from=N]&batch=1` opts into `event: revision` frames carrying `RevisionEvents` (`rev` and a nonempty array of matching `MutationEvent` values). A revision arrives whole in commit order, replay is grouped strictly after `from`, and qualified globs retain the same group prefix on every event path and move destination. Without `batch=1`, the existing unnamed single-mutation SSE frames and bytes are unchanged. SQL observation is unchanged. The server advertises `observe-batch` through discovery; the web file feed requests it and publishes/checkpoints once per revision.

## Space host composition

`SpaceHost.open` assembles one space's routes and background runtimes independently of its listener. Its explicit `configDirectory` owns credentials and group secrets; `allowEnvironmentCredentials: false` prevents provider-key lookup in the process environment. `run()` owns a single cancellation-scoped background task; cancelling its caller cancels that task. `shutdown()` is self-contained and idempotent: it prevents later runs, cancels background and in-flight handler work, cancels all admitted legacy and bounded WebSocket sessions before aborting their transports, awaits all owned tasks, then flushes metrics and performs any configured development export. Caller cancellation likewise cancels an owned WebSocket session before abort releases its transport. A deferred upgrade session invoked after shutdown begins is aborted without running its body, including an upgrade returned before shutdown. The host exposes its open `Space` for trusted in-process administration. `SpaceHost.loadDisclosure(from:)` applies the same file parser and validation as single-space serve, which passes the loaded AIDisclosure to open rather than rereading it.

`SpaceDirectory.host(for:)` is the listener's dispatch seam. Its handler returns 421 for an unknown host. `SingleSpaceDirectory` returns its one host for every request hostname, retaining the existing single-space Host behavior. `SpaceServer.serve` still binds exactly one listener with its unchanged TLS, flag, import and export policies.

`SpaceLogContext` carries the space id in a task-local during assembly, request dispatch, deferred WebSocket sessions and background work. Executables install its swift-log metadata provider so all logs emitted in those scopes include `space`. Listener/process diagnostics outside a space scope have no tenant id.

Host shutdown owns and cancels response-body forwarding through completion, with demand-driven bounded buffering; SSE from an old host closes before stop/delete returns. Host assembly owns the web-push HTTP transport and asynchronously shuts it down even before run or after listener bind failure. Session registry disposal also occurs on the never-run path. Shutdown drains in-process machine exec callers before closing the space database. Development export, database close, and HTTP transport shutdown are all attempted even if an earlier step fails; shutdown rethrows the first error, including on repeated calls.

## Live account creation and admin

`POST /v1/accounts` and `POST /v1/accounts/:id/admin` authorize through the account's space-admin flag, not its acting group or personal-group admin status. Refusals retain code `adminRequired`. The existing anonymous `--dev` owner remains a development-only management actor; the live CLI requires an enrolled person instead. `POST /v1/enroll` remains self or space admin.

Creating a human account calls `Space.addAccount`, which transactionally runs `Groups.ensurePersonalGroup`: the new person becomes the admin of their new personal group, which reads `shared`, and nothing else — a new account no longer joins `shared`. `admin:true` also writes their `admin` row in the settings group. Repeated personal-group assurance returns the same group. No server stop or schema change is required.

## Machine v2 startup and key ownership

The server stores one private 32-byte `machine-v2.key` in its server state directory, outside `space.sqlite` and the space filesystem. The directory is 0700 and the file 0600; key and directory are synchronized before machine-v2 startup succeeds. Symlink keys, malformed keys, missing keys when encrypted v2 state exists, and wrong keys are typed `storeUnavailable` with no recreation, identity fallback or plaintext recovery. The key check authenticates even an otherwise empty initialized v2 store.

Machine-v2 startup validates the key (its sealed check row; a store from before the check, by any operation row that opens with it), then resumes each group's live operations before a caller can reach one of that group. A group whose resumption fails with its store unavailable stays unresumed: its operations are refused with `storeUnavailable` and its exec callers are turned away until a retry, with backoff from 1 s to 30 s while the service runs, resumes it; other groups go on, and only a key failure fails the service. Any other failure is one record's: a row that does not open, or one the store refuses to write, is set aside (its driver stops without another write, the row stays for inspection, no longer live and holding no bytes; the machine's lease ends the operation there), its exec record ends `machineLost`, and the rest of the group resumes. Each group has one encrypted store, one `MachineOperations` (all groups share one `TunnelLanes`, since a machine's tunnel serves every group reading it) and the explicit shared problems sink; its drivers restart for every live row, carry on from the row's committed, consumed and accepted cursors with a fresh local lease, and never resend a start (how a driver retries, concludes and retires is the OperationClient SPEC). The relay keeps its state on the exec operation, written with the claim: the actor holding the exec (the minting session, else the leg that sent the start), the wall-clock moment its timeout stops it, and, once output was cut (output limit, caller gone), the combined cursor the caller's output ends at. An exec operation whose exec record is still live becomes a relay entry again under that holder, so no other actor can attach first. Rollout boundary: an exec operation without relay state was started by a server from before this release, and there is no compatible resume: boot stops it as `serverUpgraded`, drops its output (an earlier server's per-channel output rows included) and ends its record `machineLost`, which its caller reads on return. A caller reaching an ended exec that keeps no endpoint has its socket closed and reads the outcome from the record. The caller endpoint resumes incoming output at the combined cursor the store says the caller consumed and stdin at the accepted plus pending offset; output that was cut is redelivered up to the cut cursor and stays cut there (the exit says `truncated`), because a cut stops the operation and keeps everything the caller has not acknowledged up to the cut, letting it go only once the caller has. A timed exec keeps its original deadline: the stop and the unresolved-timeout answer are both measured from the stored instant, so a restart past either reaches it at once, and a resumed exec is stopped at its deadline whether or not its caller is back, and the caller has the 60-second caller grace to reconnect before the operation is abandoned as `callerGone` and the record ends `cancelled`. Every other resumed operation (a file or search call, an exec whose record ended or is gone) is abandoned as `callerGone`: its driver stops it, discards its retained output and retires after the terminal acknowledgement. A restart stamps no stop reason of its own and discards no output an exec caller has not read, and `MachineHub` boot leaves live v2 exec records alone instead of marking them `machineLost`. There is no exchange-slot pool, background client or machine-wide recovery backoff: one machine's failures stay with that machine's drivers.

Presence is one loop per member machine, under the group it is a member of: a machine that leaves a group's membership loses that loop and the group's cached description, and a moved machine is watched under its new group. The loop describes its machine every third of the machine's lease (60 s until a description names one). A transient failure (transport, deadline, unavailable, capacity) changes nothing until the last answer is a full lease old, which records `lost` with `leaseSilence`; any other typed failure records `lost` with its code. Failures never leave their machine's loop, so a hanging or refusing box cannot stall other members or any operation. A settled `leaving` reply is followed by the explicit leave acknowledgement; only an acknowledged handshake persists detached, and a failed acknowledgement persists lost with `leaveHandshakeFailed`, never detached. Shutdown cancels the loops and every group's drivers.

## Machine v2 production lifecycle

`SpaceHost.open` attempts to provision/reopen an owner-private durable operation-store key outside the database and resumes live operations before admitting v2 script clients. `MachineV2Service` owns startup-error persistence, client gating and the structured run/shutdown lifecycle. A machine-v2 key or retained-record startup failure isolates v2 only: the host still opens v1, scripts, files and its other services. All v2 HTTP requests and script clients return the original typed failure (usually `storeUnavailable`); missing or wrong keys are never recreated, and encrypted operations never fall back to plaintext, MemoryOperationStore or v1. After a restart, an operation with no caller to return to is abandoned by persisted ID with no new start permission or retransmitted POST, and a live exec waits for its caller (see startup above). Confirmed detached presence survives restarts. Per-machine authentication loss stays in that machine's presence loop and drivers; key/store/trace configuration failures remain typed failures.

`POST /v1/machine-v2` accepts the same optional body `group` and registration-group policy as v1, requires a valid globally unique machine name, atomically creates the account, separately enrolled machine identity, explicit v2 membership and one-time token in a single space-writer transaction, and returns the ordinary token/fingerprint. An insertion failure leaves no half-created identity and the name remains retryable. `POST /v1/machine-v2/enroll` checks that membership inside the token/key claiming transaction before mutation; a v1 token remains usable and its credentials untouched on refusal. Consuming a machine account's token (`POST /v1/enroll/consume` and `POST /v1/machine-v2/enroll`, so also a rotate's re-key) leaves a receipt in the claiming transaction (a person's invite or share-login token stays strictly one-time): replaying the consumed token with the same pubkey returns the same key while that key lives and the token's original expiry has not passed; any other pubkey stays `401 tokenInvalid`, and a receipt dies with its key (rotation, revocation, removal). `GET /v1/machine-v2/:id` verifies membership either for a readable person/session principal or via a fresh signed v2 dial credential. Moving a machine updates only its v2 membership/presence ownership alongside the existing move transaction; read visibility is checked on every dispatch.

With `pubkey` in the body, `POST /v1/machine-v2` is one-call enrollment for a machine that holds its own key (the Wuhu app): the name stays unique across v1 and v2 (`409 machineNameTaken`), the group follows the same registration policy, and one transaction creates the account, machine, v2 membership and live `exec-machine` key (created by the calling person) with no join token; the response is the `EnrollConsumeOutput` that token enrollment returns. A malformed key is `400 invalidArgument`, an already-enrolled key `409 keyTaken`. The call is idempotent for a retry: when the name is already held by a v2 machine in the same group whose live `exec-machine` key is this `pubkey` and was enrolled by the same calling person, the same transaction returns that machine and key unchanged (`200`, same body, re-applying any `device` link) instead of `409`. A different key, a different person, another group, or a key since rotated or revoked is still `409 machineNameTaken`; the dev seat (no person) never replays. Optional `device` links the machine to one of the caller's own devices in the same transaction; another account's or an unknown device is `404 unknownDevice` (the dev seat may name any device), a session naming a device is `403`, and `device` without `pubkey` is `400`. `POST /v1/machine-v2/:id/revoke` lets the machine drop its own credentials: it is authenticated only by fresh MachineV2Connect headers whose machine set is exactly `:id` and whose live key resolves to that machine, then, in one space-writer transaction, re-checks that the presenting key is a live exec-machine key of that machine's account and purges every credential of the account; the machine's live connection is kicked after the commit. A rotation therefore lands wholly before (the presenting key is dead: `401`) or wholly after, and a revoke signed before a rotation never deletes the replacement. The production wall admits it unauthenticated like the signed status GET. On every machine-key path (signed status, connect, self-revoke) only a definitive refusal is `401` (`keyInvalid` for a bad handshake, `machineNotAuthorized` for an unknown, revoked or misaddressed key); a store, hub or internal failure is `503`, either `machineAuthUnavailable` or the hub's startup-failure envelope, and a machine must retry rather than discard its key. Token and one-call enrollment map non-domain failures to the same `503 machineAuthUnavailable`. The machine row stays, so a person can re-enroll it through rotate.

`GET /v1/machine-v2/challenge` and the bounded `/v1/machine-v2/connect` upgrade authenticate by the new MachineV2Connect signing domain. Challenges are consumed once and never reused across a server incarnation. The signed allowed machine set is validated before upgrade and for every dispatched Fetch request, including current enrolled-key validity and caller group readability. Replacing a tunnel aborts outstanding exchanges; an old connection's teardown cannot remove the replacement. A missing live route is typed `machineUnavailable`, never a route through today's MachineHub. Persisted acknowledged goodbye reports `detached` with its actual `leftAt`; otherwise it reports `lost` with `silentSince` from the last answer, or membership registration if never answered. Missing owning-group evidence after a concurrent removal is `unknownMachine`, not synthesized silence. Rotation/revocation aborts the v2 connection too. Connection close alone never records detached presence.

## Machine v2 agent upgrades

The server tells each v2 machine which agent to run; the machine installs it. The machine's own key-signed `GET /v1/machine-v2/:id` (its hello) carries `upgrade`, a `MachineV2Upgrade`, and `GET /v1/machine-v2/:id/upgrade` returns the same object alone. That route is key-signed only (fresh MachineV2Connect headers whose machine set is exactly `:id`, same `401`/`503` split as the signed status read) and passes the production wall like it; a person's or session's status read never carries `upgrade`.

The target is the server's own stamped version unless `/machine-v2-upgrade.json` in `shared` pins one. That file is `{"pause"?: bool, "pin"?: "N.N.N[-dev.N|-beta.N]", "machines"?: {"mc_…": {"pause"?, "pin"?}}}`; a machine's field overrides the global one, `null` means unset. It is read on every hello, so a pin or pause applies at the machine's next hello. The parse is strict: an unknown key, a wrong type, a malformed version or machine id makes the whole file unparseable. A missing or unparseable file means "follow the server"; an unparseable one is logged once per distinct content.

`status` is `paused` (pause in effect; `artifacts` empty), `unstamped` (no pin and the server is `0.0.0-unstamped`, so there is no version to name), `unpublished` (no platform's archive exists for the target; never a guess at another version), `unreachable` (the release host failed, timed out after 5 s, or served a malformed sidecar) or `ready`. Only `ready` lists `artifacts`, one per published platform: `{platform, url, sha256}` with `platform` `macos-arm64` or `linux-amd64`, `url` `https://wuhu.ai/releases/wuhu-<v>-<platform>.zip|.tar.gz`, and `sha256` the archive's digest from its immutable `.sha256` sidecar (`<hex>  <archive name>`). The server resolves a version from those sidecars, never from `latest.json`. A version whose every platform resolved is cached for the process; anything short of that (partial, unpublished, unreachable) is retried after 60 s. `version` is the target (absent when the server is unstamped and no pin names one), `pinned` whether a pin chose it.

The skew window this serves: a server keeps working with agents of the previous release, whose descriptors it reads on every describe. Before starting an operation, `MachineOperations.open` refuses any top-level input field a kind's closed (`additionalProperties: false`) input schema does not declare, `409 kindUnavailable` with `reason: agentTooOld`, `inputs` and `started: false`, so an older agent never receives a field it would reject or silently ignore.

Logical departure uses the ordinary describe GET. Only after a settled `leaving` reply does the machine's presence loop send `?leaveAck=true`; detached is persisted on that confirmed handshake, not a socket close or guessed delay. Failed acknowledgement is lost with `leaveHandshakeFailed`. The agent's local uninstall wait is bounded by one lease and explicitly reports an unacknowledged leave.

## Model group placement

Session create, templates, child tools/scripts/CLI and Start over accept `modelGroup` plus optional effort, exclusive with provider/model. HTTP create and Start over return optional `modelGroup` requested intent and active concrete `provider`/`model`. Direct execution establishes a durable concrete binding on first use; group placement and pin persistence are atomic with session creation or generation reset; active telemetry changes never repin a running session in this slice. `GET /v1/session/:id/model-route` returns requestedTarget, activeProvider, activeModel and optional persisted route/evidence and append-only decisions under normal session visibility. Every timestamp in this endpoint is an ISO 8601 UTC string ending in `Z`: route/decision `placedAt`, failure `firstFailureAt`/`lastFailureAt`/`deadline`/`retryAt`, evidence `observedAt`, and window `resetsAt`. Absent timestamps remain absent; numeric percentages/capacities/scores remain numeric. Internal stored payload/evidence encoding is unchanged. CLI list exposes requested_model_group, active_provider/model and phase through the same scoped route SQL projection; inspect returns the structured route endpoint. `GET /v1/providers` retains the providers array and adds groups (ordered aliases, concrete references, effective effort intersection/default and policy); no group is disguised as a provider/model list. Malformed group discovery returns a typed error rather than silently omitting the group.
## Idle agent cache warming

`SessionRuntime` runs the cache warmer as structured work alongside the session service. Concrete per-model `cacheWarming` opt-ins are reread from `/models.json`; no model is opted in by default. Only live idle normally held kernel agents with a prior inference are eligible. Inference completion schedules the next deadline and resets the ski-rental count when its latest real input was not a cache-warming notice; warming-origin tool continuations preserve the count. Silent subscription handler firings make no inference and cannot postpone the deadline or reset the budget. At consumption/recovery, pending notices are rechecked against current agent/model opt-in, quota and floor (the same transcript check as enqueue, not counting the pending notice); an ineligible notice is durably cancelled without an inference. Warming origin and its budget survive compaction. Quota decisions read the same `UsageBoard` that `GET /v1/providers` exposes: the current five-hour window stops warming at the configured remaining-percentage threshold, while absent or expired windows do not. The persisted notice is a system/context input tagged `cache-warming`, never a conversation message or notification to people. Only an agent whose estimated context is at least the configured floor is warmed, and every notice offers optional compaction: a compacted context below the floor stops warming. Restart recovery defers overdue deadlines without replaying missed pings. All turns continue through normal rendering and replay safety.

## Account-bound replay safety

Before each session request the runtime resolves the configured credential/endpoint binding. A changed identity or legacy unscoped account-bound content forces a local portable handoff before any request; normal OAuth token maintenance does not change the binding. Binding and route epoch survive ordinary compaction as optional transcript metadata. The initial request uses the persisted model-route epoch; a portable credential-boundary handoff advances the transcript replay epoch without repicking the group member. Start over discards the transcript binding and obtains a new placement epoch. Responses socket continuations and provider cache/thread keys are scoped by binding and epoch. Direct sessions remain direct; configuration errors never select another provider.

Behavior changes: legacy live transcripts with unscoped signatures/encrypted reasoning/hosted records lose signed replay once when adopted into a portable generation. Custom/proxy origins default to `opaqueReplay: none`, so their opaque outputs are projected to portable content on replay unless the operator explicitly asserts `affine` upstream account affinity. Anthropic/Claude providers in none mode must offer only `none` effort; a thinking-enabled declaration is a typed catalog error rather than a request with invalid unsigned thinking or silently disabled thinking. Responses none mode remains valid with reasoning projected to ordinary text.

Group-agent warming follows the persisted concrete pin for opt-in and quota; group preference edits and alternate-account usage never repick or gate the active member. Ordinary replay handoffs retain that pin, and Start over clears warming state with the new placement.

## Compaction placement and last-resort route transitions

Quota-aware group compaction re-runs headroom placement using current/reset-aware usage and relative capacities; the same member creates no epoch/history churn. A move projects all retained content through portable handoff, retains the produced summary/pre-reads, rejects an oversized indispensable handoff, and commits the generation/pin/evidence together. Direct sessions and manual select pins do not move automatically. A target requested through the compact tool replaces this placement for that compaction: a provider/model binds the session to that concrete route and leaves any group; a group id (matched exactly first, so it may contain a slash; only a non-group string is read as provider/model) places within that group from its declared members (joining it from a direct or other-group session); the current target is a no-op; an effort-only change on the same target keeps the epoch, member and transcript and updates only the configured effort. Every other requested move is a portable handoff with a new epoch; re-placing within the session's own group carries the ordinary route notice, any other move a short `Model switched X → Y (requested at compaction)` context notice. An unknown, unconfigured, effort-invalid, unplaceable or too-large-to-hand-off target is refused before any write, leaving route, history and generation unchanged; a concrete target equal to the group's current member still leaves the group. Placement checks local configuration strictly, but unused candidates with typed login/auth/quota runtime refusal are ineligible rather than failures of the healthy held member. A chosen candidate's late typed credential-refresh/refusal failure at resolution removes it and re-runs the scorer on remaining eligible members; only exhausted alternatives retain the old pin and wait. Other resolve errors remain typed failures; this applies to compaction after a last-resort move as well as choosing its destination.

Last-resort routing accepts only typed upstream quota/auth refusals, recognized credential-refresh login refusal on the held provider, or three consecutive recognized service/connection outages. It persists source/reason/code, first/latest failure times, fixed policy deadline and retry evidence in the held route. Removed group definitions retain the original typed invalid-route error without recording refusal. Normal inference resolves only the held member's credentials; unused candidates cannot veto a healthy replacement after handoff. Configuration, unknown/model-permission errors, arbitrary 401/403, parser errors and ambiguous transport errors never route. A quota reset before the deadline allows source recovery; long reset/auth waits stop at the frozen deadline. Success clears the episode. At deadline local portable compaction precedes headroom placement excluding the refusing alias, and a typed cause distinguishes last-resort history from ordinary compaction. No usable alternate retains the pin and waits. Pin recovery never automatically returns a healthy replacement to an earlier account. A session's short context notice identifies the move and cause without becoming a sent reply or successful report. Restart/resume re-evaluate persisted deadlines; interrupt/archive cancel active waits. Warming follows the held pin. Member-wide refusal suppression ignores interrupted/archived sessions, expires at a reported retry/reset (or the later of policy deadline and 60 seconds after the latest failure), and is superseded by a newer successful inference on the same group/provider account (same model for service outages). Superseding account recovery does not silently clear another session's route episode or change its frozen switch deadline.

## Optional server traces

`wuhu serve --otel-endpoint http://collector.example:4318` enables asynchronous OTLP/HTTP JSON export with `service.name=wuhu-server`, `service.version` set to the binary's release version and `host.name` set to the hostname; omit the flag to disable it entirely. `SpaceServer.serve(otelEndpoint:)` is the embedding equivalent. The endpoint is a collector base URL or explicit `/v1/traces` URL. The server has one dedicated exporter with a two-second request deadline.

A kernel loop pass is `agent.turn`; attempted inferences (at the normalized metrics seam) and tool dispatch are its children. Machine v1 exec and v2 operations are children of the tool or script that started them. Script launch captures its trace context before crossing the execution queue; handler scripts start a root if no turn context exists. Detached scripts/operations can outlive their finished parent. Each span carries `session.id` and `group.id`; inference spans include provider/model/effort, outcome, TTFT and token counts; tools include name, outcome/error code, input/output sizes and an unresolved machine reference when supplied; machine spans include resolved machine id, protocol version, kind and exit/verdict. Scripts record kind and outcome. No content or error descriptions are exported.

The server queue has a fixed 1024-span capacity; full queues drop new spans without awaiting export. Collector failures discard the batch and queued spans with one warning per streak; successful export rearms the warning. No retry, disk queue or unbounded failure buffer exists. Graceful shutdown stops producers and drains queued spans within a two-second total deadline before closing the exporter. Abrupt process loss or a drain deadline may still discard spans.

## Machine tool transport routing

MachineHub routes a registered v2 machine exclusively to its group's durable `MachineOperations`; a v1 registration still uses the original channel. This covers file and search seams, tool execs, script processes, attachments and all machines:// path consumers. A missing kind returns unknownKind naming the kind, never a v1 fallback. V2 execs reuse the current caller channel and ExecRecord surfaces while the operation protocol owns remote execution, bounded stdout/stderr, lease renewal, stop and credentials.

Attachment status for the roster and v2 GET comes from machine_v2_presence. GET /v1/machine-v2/:id also exposes state (attached/detached/lost), observedAt and reason, and `group`, the registration's current group as of the request, for a person/session reader and a signed machine alike. A machine reads its group back from this signed status after it connects and after every move; it treats `group` as optional, because a server older than the field omits it. Explicit group selection on v2 creation chooses the acting group; without one, person-created machines retain the personal-group default.





Owner-lease reconnects log every retry and exponentially back off from 100 ms to a 5-second cap, including repeated immediate EOF with successful hello. A lease surviving at least five seconds resets the retry delay. This is transport recovery of the same receipt journal, not authorization for parent-process replacement.

The v2 exec relay treats stdin operationEnded as a closed input after process completion, not as an exec failure: stdout and stderr continue draining and the observed native exit code or signal wins. Other stdin errors still fail the relay.

A request deadline or transport failure on a v2 exec exchange is not evidence about the remote process: the operation's driver retries it (describe, start, stdin write, output poll, stop, terminal acknowledgement) with a 100 ms to 2 s backoff for as long as the machine answered within one lease, and only a full lease of silence concludes the operation. Every retry is idempotent: stdin is resent at its persisted offset with identical bytes, a poll re-reads from the committed cursor, a terminal acknowledgement repeats its token, and a stop is durable intent the driver keeps sending until the machine holds it (the machine keeps the first reason). A start that answered with a typed refusal is concluded without a cleanup stop. The relay maps how an exec ended onto its record: completed is the native status; a caller kill or the caller-gone stop (`callerCancelled`, `callerGone`) ends the record `cancelled` while a connected caller still gets the native status; a timeout stops with `timeout`, and the caller gets the native status as `timedOut`, or, when the process has not ended `timeoutStopGrace` (30 s) after the stop, an unknown status with `machineLost`, after which nothing more reaches it; an output-limit cut ends with `truncated` after every admitted byte reached the caller, then the native status; a failed verdict or a concluded operation without a termination is exit 1 with its message on stderr. Output is acknowledged to the machine only once the caller holds it, so the machine keeps every byte the caller has not read. A caller that disconnects has the 60-second caller grace to come back; past it the operation is abandoned as `callerGone`. A finished exec's caller endpoint is kept for `endpointRetention` (10 minutes) on a timer, without needing traffic.

The v2 exec relay treats stdout/stderr channel EOF independently from process termination: it retains drained bytes and continues bounded polling until terminal evidence arrives, then returns the native exit status. A stdin operationEnded response after a fast process exit does not cancel output draining. Regression coverage runs the real supervisor ExecKind native process with both output descriptors closed before exit 7, as well as a fast-exit stdin refusal with authenticated response metadata.

In-process exec transport close ends the socket; it does not cancel or await the caller session. Its inbound sequence is pull-driven and ends at socket EOF without waiting for retained-tail work. Caller sessions remain named in the machine hub transport scope until they return; hub shutdown cancels this scope without awaiting non-cooperative transport work. Host shutdown drains key-response pumps, release lookups, and space observations.

## Web content

`WebContent` injects the optional SPA, view-provider files and shell JavaScript into `handler`, `SpaceHost.open` and `serve`. The library embeds no web assets; an empty value serves API/content routes without the SPA or shell injection. `serve` applies `webAppDirectory` only to the SPA, retaining injected providers and scripts.

## Worker exec jobs

A session’s `POST /v1/exec` carrying `wuhu-tool-call` claims one exec per session/call, preserving the first opaque `spec` and notifying the machine hub only for a fresh claim. Without the header it mints as before. Own tool-call exec detach/delivered routes set/clear a durable owed-end flag; recovery reads that flag even after terminal state is recorded. The worker does not announce an end until its running tool result is durably committed; retrying an uncommitted running result takes the end back for the call. Existing job rows migrate their specs and obligations into machine exec records, then are deleted so reopening cannot repeat the migration; the legacy table remains empty and unused for rollback compatibility. Own exec list/detail includes `toolCallID`; killing a terminal own exec is HTTP 422 `alreadyEnded`, while unknown or foreign execs remain 404 `notFound`.

The worker reaches the same upgrading API through an authenticated in-process HTTP/WebSocket connection. Socket server tasks are bounded by the machine hub’s caller scope. The runtime shares the worker’s exec registry with generation-head snapshots, interrupt, archive and startup recovery; archive marks the worker’s jobs cancelled, kills the caller’s remaining live tool-call execs through main’s relay backend, clears owed-end flags as main bookkeeping, then revokes the session token, and worker shutdown joins drivers without killing remote processes. Scripts retain Main’s exec transport operations independently.

## Group creation and alias boundaries

`POST /v1/groups` takes `{alias}` from a live non-guest human member and returns 201 `GroupDetail`; the creator becomes admin and the group starts open. Sessions use `createGroup({alias, owner})` in `run_script`, transported through the same route with a mandatory human owner (account id, persona id or person alias). Session exec tokens are refused on POST, including CLI calls. A guest, removed account, machine or absent owner is 403 `memberRequired`; a malformed alias is 400 `invalidAlias`, and a reserved spelling is 409 `aliasTaken`. Human callers may not choose a different owner.

Every group boundary resolves aliases to permanent ids before authorization: the acting header, group-detail/access routes, machine registration/move, session creation, secrets, file addresses, imports and content hosts. Current and retired aliases return the same canonical group detail. Old content-host aliases redirect unconditionally with 307 and `Cache-Control: no-store` to the current alias before read admission, preserving path and query. The browser mints its host-only read cookie on that current host; alias names are not confidential. Id URLs remain usable. GET /v1/groups retains exactly its existing four keys (`id`, `member`, `readable`, `admin`); aliases appear in group detail; CLI group list remains one discovery request and prints ids. Shared retains its id. Personal groups have no independent alias, and a person's alias resolves to their personal group.

`GET /v1/machine/:id/status` resolves a machine id or current/retired alias and returns its `MachineStatus` to a caller who may use the owner group. CLI exec/name resolution and script machine handles use that boundary, then operate only on the canonical id. Names may contain underscores but cannot squat a syntactically valid machine id.

`POST /v1/groups` returns 201 `GroupDetail` for the newly allocated group; it passes through the normal bearer wall and stream credential binding. Only GET discovery is public. Legacy clients may submit machine names with hyphens; the server maps those to underscores before validation and allocation.

## Group observers

`POST /v1/group/:id/observers` (`ObserverInput` → 201 `ObserverOutput`), `GET /v1/group/:id/observers` (`ObserversOutput`) and `DELETE /v1/group/:id/observers/:name` (`ObserverOutput`) arm, list and cancel a group's observers. Arming and cancelling need write on the group, listing read; the --dev seat does all three. A missing group is 404 `notFound`; the store's refusals map by code: `invalidArgument` 400 (also exactly-one-trigger and handler path problems), `conflict` 409, `notFound` 404. Session exec tokens reach these routes through the session gate as their session.

A firing's token (`ExecTokens.firingToken`, minted by the worker registry when it hands the firing to a worker and revoked when the firing returns, or at once when it is cancelled) is the one credential an observer has: `RequestCredential.observer`. The gate routes it through `observerRouter`, an allowlist acting as the observer's principal in its group: discovery and group reads, `/v1/f/*`, `/v1/observe`, the conversation reads, the space tools that sessions have over `/v1/tools/:name`, secrets, the machine verbs a session's scripts share (`addMachineRoutes`: the machines its group may use, their directories, and execs minted for its handler's script, owned by `<name>@<group>`, homed in the group and given no session credential), `POST /v1/session` (top-level in its group, admitted under the observer's hourly cap), `POST /v1/session/:id/request`, `POST /v1/conversation/message` and `POST /v1/inferences` (billed to the group and firing). Naming another group by `wuhu-group` is 403 `groupMismatch`; everything else, the observer routes and an exec outside a script included, is 403. An observer never writes a session home. Since a cancelled firing's worker can no longer reach main, the registry itself (`MachineHub.releaseScript`) kills the execs the firing's script still runs and forgets their owner rows, whenever a firing ends.
