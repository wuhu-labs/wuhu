# Wuhu Roadmap

## Vision

Wuhu is an async coding agent that works like a teammate. You talk to a
personal assistant, it manages coding sessions on your behalf, and you steer
them asynchronously. All LLM inference, session state, and project knowledge
live on a single server.

Core beliefs:

- **Vertical integration.** Wuhu implements both the scheduler (assistant) and
  coder agents. One system, one box, no glue.
- **Async-first.** Agents run in the background. Users steer them with
  messages injected at interrupt checkpoints, not by watching tokens stream.
- **Multiplayer-native.** Multiple users and agents share a workspace. Every
  session, message, and action is visible to the team.
- **Persistence matters.** Sessions survive crashes. All metadata (steer vs
  follow-up, queue state, tool call status) is persisted, not just chat
  history. The system can resume from any committed state.

## Architecture Principles

- **Server is the source of truth.** SQLite for transactional runtime state
  (sessions, queues, users, environments, runners). Server-hosted filesystem
  for project knowledge (issues, docs) that agents access as regular files.
- **Database-driven config.** Static config files are bootstrap only (port,
  DB path, seed admin). Environments, runners, users, and their relationships
  are managed at runtime via CLI/API.
- **Runners are pluggable.** Two connection modes: runner-connects-to-server
  (self-hosted, unstable runner address) and server-connects-to-runner (stable
  runner, e.g. cloud-hosted). Runners can be written in any language. The
  protocol is "execute bash, stream results."
- **Client config is minimal.** Server address + auth token. Controllable via
  environment variables so unboxed clients can run on behalf of different
  users.

## App Experience

The native app is the primary interface. On open:

- **Left:** Dashboard — active sessions, recent completions, blocked agents.
- **Right:** Ongoing conversation with your personal assistant (the scheduler
  agent).

The assistant is the default entry point. You tell it what to do, it spawns
coding sessions, reports back, and asks for input when blocked. You can also
create coding sessions directly for hands-on work.

Interaction spectrum (low to high involvement):

1. Send a message to the assistant → it handles everything, reports back.
2. Escalate to a dedicated chat thread for more back-and-forth.
3. Open a coding session directly and pair-program with the agent.

Team communication: agents and humans share chat spaces. An agent posts its
intent before acting ("I'll fix the failing test"), then does it. Visibility
by default.

## Immediate Priorities

### 1. Dynamic Environments

Move environment management from static server config to runtime. Environments
are created/updated/deleted via CLI and API, persisted in SQLite. No server
restart required.

Runner-environment bindings become dynamic too — assign runners to
environments by tags/groups. This is the foundation for multi-repo and
multi-runner workflows.

### 2. Auth

Email-based login. Server stores users in SQLite. Basic roles: admin (manage
envs, runners, users) and member (create sessions, send messages). CLI and
API require auth tokens. Static user lists in config are the bootstrap path
for initial setup.

### 3. App Quality

Make WuhuApp usable as a daily driver:

- Auto-name sessions (from first message or assistant summary).
- Readable message display — between the current extremes of too-minimal and
  too-verbose.
- Text input that doesn't feel worse than a web app.
- Session tagging / filtering.

### 4. CLI as Management Surface

The CLI should be able to do everything the API can: manage environments,
runners, users, sessions. This serves two purposes:

- Humans manage Wuhu from the terminal.
- The assistant agent uses the same commands as tools (`wuhu env create`,
  `wuhu session create`, `wuhu send`).

## Near-Term

- **Assistant agent behavior.** Implement `AgentBehavior` for the scheduler
  role: tools are `spawn_session`, `send_message`, `query_sessions`,
  `read_knowledge_base`. Long-lived sessions with summary-based context
  management instead of compaction.
- **Session-spawns-session.** Coding sessions created by the assistant link
  back via `parentSessionID`. Completion/blocked notifications flow to the
  parent. The assistant decides whether to summarize and ping the user or
  just update state.
- **Knowledge base.** Server-hosted filesystem for issues, docs, and project
  notes. Agents read/write them as regular files. The app provides a UI over
  these files. Git-backed for versioning and crash recovery.

## Later

- Agent-driven review and merge queue (metadata lives in Wuhu, syncs minimal
  state to GitHub).
- Runner groups and tagging. Cloud-hosted runners (Durable Objects, etc.).
- Autonomy knob — configure how much the assistant handles independently vs
  asks for confirmation.
- On-the-fly UI generation in chat (agent renders inline widgets/views).
- Evaluate agent and team productivity from session history.
- Tiered context management for long-lived assistant sessions (recent messages
  verbatim, older summarized, oldest in long-term memory files).

## Non-Goals (for now)

- Replacing GitHub for git or CI.
- Building a general-purpose agent for non-developer workflows.
- Syncing issues back to GitHub Issues.
