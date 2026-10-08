import JSONValue
import struct SpaceCore.SessionStore
import enum WuhuAI.Tool

extension ToolExecutor {
  public static let tools: [Tool] = [
    Tool(
      name: "read",
      description: "Read a file: /<path> is the space, machines://<name-or-id>/<path> a machine, wuhu://system/<path> the read-only system files. Text output is clamped to 2000 lines / 50KB with a continuation notice. Images (png, jpg, jpeg, gif, webp, whose bytes must match the name; up to 50 MiB) arrive as attached images, scaled down to what the model takes; other binary files are refused.",
      parameters: schema([
        ("path", string("/<path> in the space, machines://<name-or-id>/<path> or wuhu://system/<path>.")),
        ("lines", string("Line window \"A-B\" or \"A-\" (1-indexed, inclusive), e.g. from a truncation notice.")),
      ], required: ["path"]),
    ),
    Tool(
      name: "write",
      description: "Create or replace a file: /<path> is the space, machines://<name-or-id>/<path> a machine. Writing an ordinary file path creates it (.table paths use wuhu:space createTable in run_script), parent directories are implicit, and there is no mkdir. Overwriting requires a prior read at the file's current version; stale or missing reads fail and ask you to re-read.",
      parameters: schema([
        ("path", string("/<path> in the space or machines://<name-or-id>/<path>.")),
        ("content", string("Full file content to write.")),
      ], required: ["path", "content"]),
    ),
    Tool(
      name: "edit",
      description: "Apply exact old/new text replacements to a file you have read at its current version. Each old string must match exactly once.",
      parameters: schema([
        ("path", string("/<path> in the space or machines://<name-or-id>/<path>.")),
        ("edits", .object([
          "type": .string("array"),
          "description": .string("Replacements applied in order."),
          "items": schema([
            ("old", string("Exact text to replace; widen with context until unique.")),
            ("new", string("Replacement text.")),
          ], required: ["old", "new"]),
        ])),
      ], required: ["path", "edits"]),
    ),
    Tool(
      name: "grep",
      description: "Search file contents with a regular expression under a directory (default: the space root). Matched lines are shortened past 500 bytes.",
      parameters: schema([
        ("pattern", string("Regular expression to search for.")),
        ("path", string("Directory or file to search: /<path> in the space, machines://<name-or-id>/<path> or wuhu://system/<path>.")),
        ("match_limit", integer("Maximum matches to return (default 50).")),
        ("entry_limit", integer("Maximum files to scan (default 1000).")),
        ("step", string("Continuation cursor from a previous grep result.")),
      ], required: ["pattern"]),
    ),
    Tool(
      name: "find",
      description: "Find files by glob under a directory (default: the space root).",
      parameters: schema([
        ("glob", string("Glob pattern, e.g. **/*.swift.")),
        ("path", string("Directory to search: /<path> in the space, machines://<name-or-id>/<path> or wuhu://system/<path>.")),
        ("match_limit", integer("Maximum paths to return (default 50).")),
        ("entry_limit", integer("Maximum entries to scan (default 1000).")),
        ("step", string("Continuation cursor from a previous find result.")),
      ], required: ["glob"]),
    ),
    Tool(
      name: "exec",
      description: "Run a shell command (sh -c) on a machine, in the working directory you name. It is killed past max_output (default 1 MiB, max 4 MiB); you see the last 50 KiB. Create ordinary space text files with write; create tables and instantiate document templates with wuhu:space in run_script. Space byte upload and history operations remain HTTP/CLI-only until their module APIs ship.",
      parameters: schema([
        ("machine", string("The machine's name or id, as the machines tool lists it.")),
        ("cwd", string("Absolute working directory on that machine.")),
        ("command", string("Shell command line.")),
        ("env", stringMap("Environment variables to add to the command's environment, as name to value.")),
        ("secrets", stringMap("Environment variables filled from secrets of the machine's group (not yours), as variable name to secret name. The value never comes back to you and is masked as *** in the output; a name the group lacks fails before the command runs.")),
        ("timeout_seconds", number("Kill the command after this many seconds.")),
        ("max_output", integer("Output byte budget (default 1 MiB, max 4 MiB).")),
      ], required: ["machine", "cwd", "command"]),
    ),
    Tool(
      name: "machines",
      description: "List the machines enrolled in this space: the name a human gave the box (\"mac-mini\"), its id, and whether it is attached right now. Either the name or the id addresses a machine in machines:// paths and exec. A detached machine refuses reads and execs until it dials back in.",
      parameters: schema([], required: []),
    ),
    Tool(
      name: "templates",
      description: "List the session templates your group defines (/templates/<name>/): the name create_session takes, the kind and executor spec it fills in, and what it is for. A template also clones its own files into the new session's home, so it is how a space carries a reusable job.",
      parameters: schema([], required: []),
    ),
    Tool(
      name: "observe",
      description: "Subscribe to a read-only SQL query over the space database; you receive a message whenever its results change. Cancel with cancel_observation.",
      parameters: schema([
        ("sql", string("Read-only SQL over space tables and induced tables (docs, links, sessions, ...).")),
        ("throttle_seconds", number("Minimum seconds between change notifications (default 30).")),
      ], required: ["sql"]),
    ),
    Tool(
      name: "timer",
      description: "Schedule a message back to yourself: once after in_seconds, or repeatedly on a 5-field UTC cron expression. Cancel with cancel_timer.",
      parameters: schema([
        ("message", string("The message you will receive when the timer fires.")),
        ("in_seconds", number("Fire once after this many seconds.")),
        ("cron", string("Fire repeatedly: \"minute hour day month weekday\" in UTC.")),
      ], required: ["message"]),
    ),
    Tool(
      name: "cancel_observation",
      description: "Cancel an observation subscription.",
      parameters: schema([
        ("subscription_id", string("The subscription id an observe result reported.")),
      ], required: ["subscription_id"]),
    ),
    Tool(
      name: "cancel_timer",
      description: "Cancel a timer subscription.",
      parameters: schema([
        ("subscription_id", string("The subscription id a timer result reported.")),
      ], required: ["subscription_id"]),
    ),
    Tool(
      name: "query",
      description: "Run a read-only SQL query over the space database (space tables plus induced tables such as docs, links, and sessions).",
      parameters: schema([
        ("sql", string("Read-only SQL.")),
      ], required: ["sql"]),
    ),
    Tool(
      name: "send_message",
      description: "Post a message into a conversation. With no target argument it posts into your own box — the public surface people comment on. Pass conversation for a group you are in, session to DM another session, or user to DM a person; another agent's box is reachable only by its conversation id. reply_target points at one earlier message in the same conversation; it is decoration, not a requirement.",
      parameters: schema([
        ("message", string("Message text.")),
        ("conversation", string("Conversation id to post into.")),
        ("session", string("Session to reach; the message lands in your DM with it, never in its box.")),
        ("user", string("User to DM; the DM is created on first post.")),
        ("reply_target", string("Message id this answers, from that message's message-id header.")),
        ("attachments", .object([
          "type": .string("array"),
          "description": .string("Files to attach: /<path> in the space or machines://<name-or-id>/<path>. At most 8, 50 MiB each and 150 MiB in all; they are copied into the conversation."),
          "items": .object(["type": .string("string")]),
        ])),
      ], required: ["message"]),
    ),
    Tool(
      name: "request",
      description: "Open a request on a child you created, task or agent: the message lands in your DM with it and it owes you a final report. One open request per child — request again only after its final. A deadline is your backstop, not the task's: on expiry you are told, and you decide to re-request, kill or replace.",
      parameters: schema([
        ("task", string("Session id of a child you created (a task or an agent).")),
        ("message", string("What you are asking it to do.")),
        ("deadline_seconds", number("Tell me if there is no final report within this many seconds.")),
      ], required: ["task", "message"]),
    ),
    Tool(
      name: "report",
      description: "Report on the request open against you. progress is a status line your parent sees without the request closing; final answers it and closes it. request_id is never inferred — take it from the request message's header.",
      parameters: schema([
        ("request_id", string("The open request's id.")),
        ("kind", string("progress or final.")),
        ("content", string("Report text.")),
      ], required: ["request_id", "kind", "content"]),
    ),
    Tool(
      name: "set_title",
      description: "Set your name. Your title is the name every roster, chat, inbox and notification shows for this session, and nobody else writes it: short, stable and set once, as soon as you know your role (\"Product Researcher\"). It is not a status line; report status in messages. A placeholder left standing is a session nobody can find.",
      parameters: schema([
        ("title", string("One line, at most \(SessionStore.titleLimit) characters.")),
      ], required: ["title"]),
    ),
    Tool(
      name: "manipulate_ui",
      description: "Drive the UI of a device someone is looking at. The payload reaches the device app verbatim; supported today: {\"sidebar\": \"/.sidebars/<name>.json\"} selects that custom sidebar and {\"sidebar\": \"everything\"} selects the full outline. The device id comes from the <device> line of a message header, or from query: SELECT id, name, kind, machine_id FROM devices. A device applies a command only while it is live — one older than 15 seconds is dropped. Only a top-level agent may drive a device; a task or child agent is refused.",
      parameters: schema([
        ("device", string("Device id, three words, from a <device> header line or the devices table.")),
        ("payload", .object([
          "type": .string("object"),
          "description": .string("What the device should do, passed through untouched."),
        ])),
      ], required: ["device", "payload"]),
    ),
    Tool(
      name: "generate_image",
      description: "Generate an image from a text prompt and save it as a png at destination. Never overwrites: it fails when a file already exists there.",
      parameters: schema([
        ("prompt", string("Image description.")),
        ("destination", string("Where to save the png: /<path> in the space or machines://<name-or-id>/<path>.")),
        ("provider", string("Optional configured capability provider override.")),
        ("model", string("Optional model override; unsupported features fail.")),
        ("quality", string("draft, standard, fine or ultra.")),
        ("size", string("1024x1024, 1536x1024 or 1024x1536.")),
      ], required: ["prompt", "destination"]),
    ),
    Tool(
      name: "create_session",
      description: "Create a session: by default a child task. A child agent gets a box of its own; a top-level agent (top_level) has no parent and belongs to the humans — you gain no parent/ancestry control but retain creator archive/unarchive rights, and only an agent may create one. A child lives in your group; a top-level agent in yours too unless group names another your group reads. With expects_reply the child starts working on message and owes you a final report; without, message arrives as a DM from you and there is no duty, which is how you prime a child agent for a human who then takes over (a task takes no messages from people). Omitted provider, model and effort default to your own; a template's values win over that default, and explicit arguments win over both. The provider picks who runs the session: a claude provider runs Claude Code, any other the kernel loop.",
      parameters: schema([
        ("title", string("Session title: one line, at most \(SessionStore.titleLimit) characters.")),
        ("kind", .object([
          "type": .string("string"),
          "enum": .array([.string("task"), .string("agent")]),
          "description": .string("task (default) or agent; an agent template or top_level makes agent the default."),
        ])),
        ("top_level", .object([
          "type": .string("boolean"),
          "description": .string("Create a root agent with no parent instead of a child; expects_reply is refused."),
        ])),
        ("group", string("Top-level only: the group the new agent lives in, one your group reads; defaults to yours.")),
        ("message", string("The brief; required with expects_reply.")),
        ("expects_reply", .object([
          "type": .string("boolean"),
          "description": .string("Open a request on the new child so it reports back."),
        ])),
        ("provider", string("Model provider id, e.g. anthropic.")),
        ("model", string("Model name as listed in the models data.")),
        ("effort", string("Reasoning effort; defaults to the model's default.")),
        ("tags", .object([
          "type": .string("array"),
          "description": .string("Query/filter tags; never read by the session."),
          "items": .object(["type": .string("string")]),
        ])),
        ("template", string("Session template name, from the templates tool (/templates/<name>/), or wuhu://<group>.localspace/templates/<name> for another group's: its template.json fills parameters you leave out and its files are cloned into the new session's home.")),
      ], required: ["title"]),
    ),
    Tool(
      name: "run_script",
      description: "Run a JavaScript ES module on the server as you. It answers the call with result(value), at most once; after that, each update(value) reaches you later as a message, and it keeps running until nothing is pending. Available: import { query, observe, watch, createTable, tableSchema, alterTable, instantiateTemplate, mutateRows, readAttributes, patchAttributes } from \"wuhu:space\" — query`SELECT … WHERE x = ${x}` (interpolations are bound parameters) or query(sql, params) resolves to an array of row objects over the same tables as the query tool, a JSON column parsed and a blob a Uint8Array; observe with the same arguments is an async iterable yielding the rows now and again after every change that alters them; watch(glob, { from }) an async iterable of file events { kind: write|delete|move, path, to?, rev, entry? }, from a rev when given; leaving either loop closes it; createTable(path, { columns: [{ name, type }] }) creates a .table and resolves to { rev, token }; type is string|integer|number|boolean|json, id is implicit and reserved, columns are ordered and names unique; tableSchema(path, { rev? }) resolves to { header, token }; alterTable(path, header, { ifMatch, allowDropColumns? }) replaces the whole header at the required current token, requires allowDropColumns: true to omit a column, and refuses type changes; instantiateTemplate(template, { in? }) atomically allocates and creates an incr/date document instance and resolves to { path }; mutateRows(path, [{ insert: { col: v } } | { update: id, set: { col: v } } | { delete: id }]) applies the ops in one revision and resolves to { rev, ids } (ids of the inserted rows); readAttributes(path) resolves to a Markdown file's frontmatter { attributes, token }, and patchAttributes(path, { set, remove, ifMatch: token }) sets and removes top-level keys keeping the rest of the YAML, resolving to { token }; a stale token throws a SpaceError whose code is conflict and whose token is the current one; every failure of these is a SpaceError with code, message and hint; paths are in your group or wuhu://<group>.localspace/<path> in a group yours reads, and writes refuse another session's home; conversation(id, { after, before, limit }) from \"wuhu:space\" — a page { messages, next } of one conversation, oldest first, each message { id, sender: { id, handle?, session?, title?, group }, kind, text, attachments: [path], replyTarget, requestId, createdAt }: after or before (never both) takes a message id as a header shows it or an ISO time with a zone, no cursor reads the latest, limit defaults to 50 (max 500), next is the cursor for the following page in the same direction (a no-cursor read continues with before) and is null at the end; an agent's box id is its session id, so conversation(import.meta.session) reads your box; dm(a, b) is the DM id between two sessions, or null when there is none you can read; a box is readable when your group reads its group, a DM when you are in it or it is homed in your group, a group conversation only by its members, anything else reads as missing, and reading marks nothing; import { move, remove } from \"wuhu:space\" — move(from, to, { replace }) and remove(path, { ifMatch? }) mutate space files (including tables) like wuhu mv and wuhu rm; they take a path in your group or wuhu://<group>.localspace/<path> in a group yours reads, and refuse another session's home; move refuses an existing to unless replace: true, which replaces a file in the same revision; this remove shares its name with the wuhu:secret one, so import one under an alias (import { remove as removeFile } from \"wuhu:space\"); static imports of space files, import { x } from \"wuhu:/skills/tool/lib.js\", and of the read-only system files built into the server, import { x } from \"wuhu://system/<path>\", with ./ and ../ inside such a file staying on its side, read as of the moment the script starts (1 MiB per file, 256 files); import { secret, set, list, remove } from \"wuhu:secret\" — your group's secrets, whose values nothing returns: secret(name) is a placeholder that fetch replaces with the value in the URL, headers and body it sends, and every value sent is masked as *** in responses, console, result() and update(); secret(name, { group: \"shared\" }) names one of a group yours reads, never by fallback; set(name, value) needs an admin of your group (a top-level agent; tasks and child agents never are), list() its names and list({ group }) those of a group yours reads; remove(name) is always refused, since a removal needs a human admin; a machine's exec takes secrets by name instead ({ secrets: { ENV: \"NAME\" } }), resolved in the machine's group rather than yours, and refuses a placeholder in its command, env or stdin; import { generateImage, editImage, transcribe } from \"wuhu:ai\" — editImage(images, prompt, { destination, provider?, model?, quality?, size? }) edits private PNG paths; transcribe(audio, { provider?, model?, language?, timestamps?: [\"words\",\"segments\"], diarize? }) reads private audio (25 MiB, two hours) and returns text, provider/model, optional language/durationSeconds/segments/words/confidence/usage (seconds, unavailable metadata omitted); import { webSearch } from \"wuhu:web_search\" — webSearch(query, { provider?, count? }) returns query/provider/sources/title/url/snippet; CapabilityError has code/message/hint. Explicit broken active providers never fall back; unconfigured capabilities use a Codex login. generateImage(prompt, { destination, provider?, model?, quality?, size? }) does what generate_image does and resolves to { path, mimeType, bytes, width, height }, never the image itself; up to 4 run at once, the rest wait their turn; import { createSession, request, setTags, archive, unarchive, interrupt, resume } from \"wuhu:session\" — createSession({ title, kind, topLevel, group, provider, model, effort, template, tags, message, expectsReply, key }) takes create_session's arguments and resolves to { id, requestId? } as soon as the session exists (a child's report arrives later as a message to you, never to the script), and the same key returns the first session instead of a second; if cloning the template or handing over the message fails after creation, it throws an Error whose id is the new session; request(id, message, { deadlineSeconds }) resolves to { requestId }; setTags(id, tags) replaces the whole list; archive(id, { force: true }) interrupts busy nodes and archives the whole descendant subtree, closing open requests with an archived-before-reporting final; archive(id) defaults to non-force and refuses the whole tree if any node is busy, listing all busy ids and titles; unarchive restores only one session; archive, unarchive, interrupt and resume take a session id; setTags, interrupt and resume act only on you and your descendants; archive and unarchive also on a session you created and, when you are a top-level agent (an admin of your group), on any session of your group; import { machines, machine } from \"wuhu:machine\" — machines() lists usable machines, machine(nameOrID) offers stat/list/read/readText/write/remove/mkdir/move/exec/spawn with script-local Process handles; the generated module-export inventory is wuhu://system/module-exports.json; import.meta.session (your id); sleep(ms); signal (aborted by stop_script or the max lifetime); fetch, Request, Response, Headers, AbortSignal.timeout/any with whole bodies (text, json, arrayBuffer); console, whose tail comes back only when the script throws or is killed. Top-level await works.",
      parameters: schema([
        ("source", string("The module source.")),
        ("timeout_seconds", number("How long to wait for result(); default 60.")),
        ("on_timeout", .object([
          "type": .string("string"),
          "enum": .array([.string("detach"), .string("kill")]),
          "description": .string("detach (default): return at once and deliver the result later as a message; kill: stop the script and fail."),
        ])),
        ("max_lifetime_seconds", number("Hard cap on the whole run, updates included; default 3600.")),
      ], required: ["source"]),
    ),
    Tool(
      name: "stop_script",
      description: "Stop one of your running scripts: its signal aborts, and it is killed if still running after 5 seconds.",
      parameters: schema([
        ("id", string("The script id run_script reported.")),
      ], required: ["id"]),
    ),
  ]
}

private func schema(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
  jsonObject([
    ("type", .string("object")),
    ("properties", jsonObject(properties.map { ($0, $1) })),
    ("required", .array(required.map(JSONValue.string))),
    ("additionalProperties", .bool(false)),
  ])
}

private func string(_ description: String) -> JSONValue {
  .object(["type": .string("string"), "description": .string(description)])
}

private func integer(_ description: String) -> JSONValue {
  .object(["type": .string("integer"), "description": .string(description)])
}

private func stringMap(_ description: String) -> JSONValue {
  .object([
    "type": .string("object"),
    "description": .string(description),
    "additionalProperties": .object(["type": .string("string")]),
  ])
}

private func number(_ description: String) -> JSONValue {
  .object(["type": .string("number"), "description": .string(description)])
}
