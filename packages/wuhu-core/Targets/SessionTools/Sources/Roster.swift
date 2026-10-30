import JSONValue
import func MainHub.jsonObject
import enum SessionDomain.SessionTitle
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
      description: "Search file contents line by line with a regular expression (ICU syntax) under a directory or in one file (default: the space root). Skips hidden entries, what .gitignore files exclude, binary files and files with a line over 64 KiB, and says how many it skipped. Matched lines are shortened past 500 bytes. A page stops at match_limit or its scan budget and hands back a step to continue.",
      parameters: schema([
        ("pattern", string("Regular expression to search for.")),
        ("path", string("Directory or file to search: /<path> in the space, machines://<name-or-id>/<path> or wuhu://system/<path>.")),
        ("match_limit", integer("Maximum matches to return (default 50, at most 1000).")),
        ("hidden", boolean("Also search hidden entries: dot-names, /_ and /users at the space root.")),
        ("no_ignore", boolean("Also search what .gitignore files exclude.")),
        ("step", string("Continuation cursor from a previous grep result.")),
      ], required: ["pattern"]),
    ),
    Tool(
      name: "find",
      description: "Find files and directories by glob (.gitignore dialect, matched against the path under the directory) under a directory (default: the space root). Skips hidden entries and what .gitignore files exclude, and says how many it skipped. A page stops at match_limit or its scan budget and hands back a step to continue.",
      parameters: schema([
        ("glob", string("Glob pattern, e.g. **/*.swift.")),
        ("path", string("Directory to search: /<path> in the space, machines://<name-or-id>/<path> or wuhu://system/<path>.")),
        ("match_limit", integer("Maximum paths to return (default 50, at most 1000).")),
        ("hidden", boolean("Also search hidden entries: dot-names, /_ and /users at the space root.")),
        ("no_ignore", boolean("Also search what .gitignore files exclude.")),
        ("step", string("Continuation cursor from a previous find result.")),
      ], required: ["glob"]),
    ),
    Tool(
      name: "exec",
      description: "Run a shell command (sh -c) on a machine, in the working directory you name, and wait up to wait_seconds for it to end, or only 10 s more once a person messages you (90 s for anything else). A command still running then keeps running: the call returns JSON {status: \"running\", id: \"exec.<id>\", tail, note}, its end arrives later as one message, and cancel(id) kills it. It is killed, with its whole process group, after max_lifetime_seconds (default 1800, at most 14400) or past max_output (default 1 MiB, max 4 MiB); you see the last 50 KiB. Work that may run past 14400 s starts detached instead (setsid nohup <command> > <log> 2>&1 & echo $!: output to a log file, keep the PID) and is watched from run_script (the monitor skill). Create ordinary space text files with write; create tables and instantiate document templates with wuhu:space in run_script. Space byte/text reads, guarded writes, metadata and paged history are available in wuhu:space.",
      parameters: schema([
        ("machine", string("The machine's name or id, as the machines tool lists it.")),
        ("cwd", string("Absolute working directory on that machine.")),
        ("command", string("Shell command line.")),
        ("env", stringMap("Environment variables to add to the command's environment, as name to value.")),
        ("secrets", stringMap("Environment variables filled from secrets of the machine's group (not yours), as variable name to secret name. The value never comes back to you and is masked as *** in the output; a name the group lacks fails before the command runs.")),
        ("wait_seconds", number("How long the call waits for the command to end before it returns running; default 300.")),
        ("max_lifetime_seconds", number("Kill the command and its process group after this many seconds; default 1800, at most 14400.")),
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
      description: "Subscribe to a read-only SQL query over the space database, or to a server-sent event stream; you receive a message whenever its results change or events arrive, or a handler runs silently and can wake you. Cancel it with cancel and the subscription id it reports (obs.…).",
      parameters: schema([
        ("sql", string("Read-only SQL over space tables and induced tables (docs, links, sessions, ...).")),
        ("url", string("Instead of sql: an http(s) SSE stream the server dials with an OIDC token naming you (audience: its origin), resuming after the last event taken.")),
        ("throttle_seconds", number("Minimum seconds between firings (default 30); a stream's handler fires on every event.")),
        ("handler", string("Optional space script module path; default export receives {rows | event: {id, type, data}, state, wake} and returns next JSON state. Runs as you, 60 s budget.")),
        ("name", string("Optional readable name, shown in subscriptions; defaults to the handler's file name.")),
      ], required: []),
    ),
    Tool(
      name: "timer",
      description: "Schedule a message back to yourself: once after in_seconds, or repeatedly on a 5-field UTC cron expression. Cancel it with cancel and the subscription id it reports (timer.…).",
      parameters: schema([
        ("message", string("The message you will receive when the timer fires.")),
        ("handler", string("Optional space script module path; default export receives {fireTime, state, wake} and returns next JSON state. Runs silently as you, 60 s budget.")),
        ("in_seconds", number("Fire once after this many seconds.")),
        ("cron", string("Fire repeatedly: minute hour day month weekday in UTC.")),
        ("name", string("Optional readable name, shown in subscriptions; defaults to the handler's file name.")),
      ], required: ["message"]),
    ),
    Tool(
      name: "cancel",
      description: "Stop something you started, by the id it reported: an observation (obs.…) or a timer (timer.…) stops firing (a handler firing already running runs on: when it finishes its wakes arrive; if it fails or times out it ends failed); a script (script.…) has its signal aborted and is killed if still running after 5 seconds; an exec (exec.…) has its process group sent TERM, then KILL 5 seconds later. The result names what ended and how. A subscription that is not armed (ended or never yours), an unknown id and one another session owns are notFound; a script or exec that already ended is alreadyEnded. <session-state> lists what is running.",
      parameters: schema([
        ("id", string("The id: obs.…, timer.…, script.… or exec.…")),
      ], required: ["id"]),
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
      description: "Post a message into a conversation. With no target argument it posts into your own box — the public surface people comment on. Pass conversation for a group you are in, session to DM another session; another agent's box is reachable only by its conversation id. reply_target points at one earlier message in the same conversation; it is decoration, not a requirement. The text renders as markdown; a bare URL becomes a link, a URL inside inline code does not.",
      parameters: schema([
        ("message", string("Message text.")),
        ("conversation", string("Conversation id to post into.")),
        ("session", string("Session to reach; the message lands in your DM with it, never in its box.")),
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
      description: "Open a request on a child you created, task or agent: the message lands in your DM with it and it owes you a final report. One open request per child — request again only after its final. A deadline is your backstop, not the task's: on expiry you are told, and you decide to re-request, kill or replace. Separately, if the child and its descendants show no progress (an inference, a finished tool call, a message to you) for stall_seconds while not waiting on a script, exec, timer or request of its own, you get one stall notice; progress re-arms it. It only notifies.",
      parameters: schema([
        ("task", string("Session id of a child you created (a task or an agent).")),
        ("message", string("What you are asking it to do.")),
        ("deadline_seconds", number("Tell me if there is no final report within this many seconds.")),
        ("stall_seconds", number("Tell me once the child has shown no progress for this many seconds (default 1800; 0 turns it off).")),
      ] + requestTerms, required: ["task", "message"]),
    ),
    Tool(
      name: "report",
      description: "Report on the request open against you. progress is a status line your requester sees without the request closing; final answers it and closes it. When the request has a schema, a final's content is JSON matching it; one that doesn't is refused with the reasons, and the third refusal fails the request. request_id is never inferred — take it from the request message's header.",
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
        ("title", string("One line, at most \(SessionTitle.maximumCharacters) characters.")),
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
      description: "Create a session: by default a child task. A child agent gets a box of its own; a top-level agent (top_level) has no parent and belongs to the humans — you gain no parent/ancestry control but retain creator archive/unarchive rights, and only an agent may create one. A child lives in your group; a top-level agent in yours too unless group names another your group reads. With expects_reply the child starts working on message and owes you a final report; without, message arrives as a DM from you and there is no duty, which is how you prime a child agent for a human who then takes over (a task takes no messages from people). Omitted target and effort default to your requested target (not its active member); modelGroup is exclusive with provider/model. Explicit targets replace inherited/template targets as a whole; a template's values win over that default, and explicit arguments win over both. Every provider runs in the kernel. An executor other than kernel is refused invalidArgument.",
      parameters: schema([
        ("title", string("Session title: one line, at most \(SessionTitle.maximumCharacters) characters.")),
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
        ("stall_seconds", number("With expects_reply: tell me once the child has shown no progress for this many seconds (default 1800; 0 turns it off).")),
        ("request", jsonObject([
          ("type", .string("object")),
          ("description", .string("With expects_reply: the request's kind, key, schema and fields, as on the request tool. A key your group already used for that kind creates nothing and returns that request's session.")),
          ("properties", jsonObject(requestTerms)),
          ("additionalProperties", .bool(false)),
        ])),
        ("executor", string("kernel only; another value is invalidArgument, \"unknown executor: <value>\".")),
        ("provider", string("Model provider id, e.g. anthropic.")),
        ("model", string("Model name as listed in the models data.")),
        ("modelGroup", string("Session routing group id from /model-groups.json; mutually exclusive with provider/model.")),
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
      description: "Run a JavaScript ES module on the server as you. result(value) answers once; subsequent update(value) calls arrive as messages. Runs until nothing is pending. Top-level await works. Globals: import.meta.session, signal (aborted on cancel/lifetime), sleep(ms), console (tail on throw, kill or running return), fetch, Request, Response, Headers, AbortSignal.timeout/any; response bodies support text/json/arrayBuffer. Static imports: wuhu:/<path> and wuhu://system/<path>, including relative imports. Runtime details: wuhu://system/skills/script-runtime/SKILL.md.\nRead each module's skill before use (all at wuhu://system/skills/<name>/SKILL.md):\nwuhu:space — space-scripts (conversation/dm: read-box).\nwuhu:secret — secret-scripts.\nwuhu:ai — ai-scripts.\nwuhu:web_search — web-search.\nwuhu:session — sessions.\nwuhu:machine — machine-scripts.\nExport inventory: wuhu://system/module-exports.json.",
      parameters: schema([
        ("source", string("The module source.")),
        ("wait_seconds", number("How long the call waits for result() before it returns JSON {status: \"running\", id: \"script.<id>\", tail, note}; the script runs on and its result arrives as a message. Default 300; once a person messages you the call waits only 10 s more (90 s for anything else).")),
        ("max_lifetime_seconds", number("Hard cap on the whole run, updates included; default 3600, at most 14400.")),
      ], required: ["source"]),
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

private func boolean(_ description: String) -> JSONValue {
  .object(["type": .string("boolean"), "description": .string(description)])
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

private let requestTerms: [(String, JSONValue)] = [
  ("kind", string("What sort of request this is, e.g. review; a column of the requests table.")),
  ("key", string("Needs kind. Unique per kind in your group: a second request with the same kind and key opens nothing and returns the first.")),
  ("schema", .object([
    "type": .string("object"),
    "description": .string("A JSON Schema the final report must match: the final's content is then JSON, stored parsed as the request's result."),
  ])),
  ("fields", .object([
    "type": .string("object"),
    "description": .string("Any JSON object kept on the request row, for whoever queries requests."),
  ])),
]
