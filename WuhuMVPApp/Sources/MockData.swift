import Foundation
import IdentifiedCollections

// MARK: - Mock Models

struct MockSession: Identifiable, Equatable {
  let id: String
  var title: String
  var environmentName: String
  var model: String
  var status: SessionStatus
  var updatedAt: Date
  var messages: [MockMessage]

  enum SessionStatus: String, Equatable {
    case running, idle, stopped
  }

  var lastMessagePreview: String {
    guard let last = messages.last else { return "No messages yet" }
    let prefix = last.role == .assistant ? "Agent" : last.author ?? "User"
    return "\(prefix): \(last.content.prefix(80))"
  }
}

struct MockMessage: Identifiable, Equatable {
  let id: String
  var role: Role
  var author: String?
  var content: String
  var timestamp: Date
  var toolCalls: [MockToolCall]

  enum Role: Equatable {
    case user
    case assistant
  }

  init(
    id: String = UUID().uuidString,
    role: Role,
    author: String? = nil,
    content: String,
    timestamp: Date,
    toolCalls: [MockToolCall] = []
  ) {
    self.id = id
    self.role = role
    self.author = author
    self.content = content
    self.timestamp = timestamp
    self.toolCalls = toolCalls
  }
}

struct MockToolCall: Identifiable, Equatable {
  let id: String
  var name: String
  var arguments: String
  var result: String
}

struct MockChannel: Identifiable, Equatable {
  let id: String
  var name: String
  var unreadCount: Int
  var messages: [MockChannelMessage]

  var lastMessagePreview: String {
    guard let m = messages.last else { return "" }
    return "\(m.author): \(m.content.prefix(60))"
  }

  var lastMessageTimestamp: Date? {
    messages.last?.timestamp
  }
}

struct MockChannelMessage: Identifiable, Equatable {
  let id: String
  var author: String
  var isAgent: Bool
  var content: String
  var timestamp: Date
}

struct MockIssue: Identifiable, Equatable {
  let id: String
  var title: String
  var status: IssueStatus
  var assignee: String?
  var priority: Priority
  var description: String
  var markdownContent: String = ""

  enum IssueStatus: String, CaseIterable, Equatable {
    case open = "Open"
    case inProgress = "In Progress"
    case done = "Done"
  }

  enum Priority: String, Equatable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"
  }
}

struct MockDoc: Identifiable, Equatable {
  let id: String
  var title: String
  var tags: [String]
  var updatedAt: Date
  var markdownContent: String
}

struct MockActivityEvent: Identifiable, Equatable {
  let id: String
  var description: String
  var timestamp: Date
  var icon: String
}

// MARK: - Static Mock Data

enum MockData {
  static let workspaceName = "Isofucius Inc."

  // MARK: Sessions

  static let sessions: IdentifiedArrayOf<MockSession> = [
    MockSession(
      id: "s-001",
      title: "Fix auth token refresh",
      environmentName: "wuhu-swift",
      model: "claude-sonnet-4-6",
      status: .running,
      updatedAt: Date().addingTimeInterval(-120),
      messages: authSessionMessages,
    ),
    MockSession(
      id: "s-002",
      title: "Add WebSocket reconnection logic",
      environmentName: "wuhu-swift",
      model: "claude-opus-4-6",
      status: .running,
      updatedAt: Date().addingTimeInterval(-300),
      messages: websocketSessionMessages,
    ),
    MockSession(
      id: "s-003",
      title: "Refactor database migrations",
      environmentName: "sandbox",
      model: "gpt-5",
      status: .idle,
      updatedAt: Date().addingTimeInterval(-43200),
      messages: [
        MockMessage(role: .user, author: "yihan", content: "Can you refactor the DB migrations to use the new GRDB migration API?", timestamp: Date().addingTimeInterval(-50000)),
        MockMessage(role: .assistant, content: "I'll update the migration system. Let me check the current setup first.", timestamp: Date().addingTimeInterval(-49900)),
      ],
    ),
    MockSession(
      id: "s-004",
      title: "Debug CI pipeline failure",
      environmentName: "wuhu-swift",
      model: "claude-sonnet-4-6",
      status: .stopped,
      updatedAt: Date().addingTimeInterval(-86400),
      messages: [
        MockMessage(role: .user, author: "kesou", content: "CI is failing on main. Can you check what's going on?", timestamp: Date().addingTimeInterval(-90000)),
        MockMessage(role: .assistant, content: "Let me look at the CI logs.", timestamp: Date().addingTimeInterval(-89900), toolCalls: [
          MockToolCall(id: "tc-ci-1", name: "bash", arguments: "gh run list --limit 5", result: "ID  STATUS  TITLE\n847 failure  main\n846 success main"),
        ]),
        MockMessage(role: .assistant, content: "Build #847 failed due to a Swift 6 concurrency error in `SessionStore.swift`. The `nonisolated` access to a mutable property was flagged.", timestamp: Date().addingTimeInterval(-89800)),
        MockMessage(role: .user, author: "minsheng", content: "That's the strict concurrency stuff. Can you add the Sendable conformance?", timestamp: Date().addingTimeInterval(-89700)),
        MockMessage(role: .assistant, content: "Done. Added `@unchecked Sendable` to `SessionStore` and wrapped the mutable state in a lock. CI should pass now.", timestamp: Date().addingTimeInterval(-89600)),
      ],
    ),
    MockSession(
      id: "s-005",
      title: "Implement environment resolver",
      environmentName: "sandbox",
      model: "claude-opus-4-6",
      status: .idle,
      updatedAt: Date().addingTimeInterval(-172_800),
      messages: [
        MockMessage(role: .user, author: "anna", content: "We need a resolver that maps environment names to definitions. Start with local and folder-template types.", timestamp: Date().addingTimeInterval(-180_000)),
        MockMessage(role: .assistant, content: "I'll build the environment resolver. This needs to handle both static definitions and dynamic template instantiation.", timestamp: Date().addingTimeInterval(-179_900)),
      ],
    ),
    MockSession(
      id: "s-006",
      title: "Write API documentation",
      environmentName: "wuhu-swift",
      model: "gpt-5",
      status: .idle,
      updatedAt: Date().addingTimeInterval(-259_200),
      messages: [],
    ),
    MockSession(
      id: "s-007",
      title: "Optimize query performance",
      environmentName: "wuhu-swift",
      model: "claude-haiku-4-5",
      status: .stopped,
      updatedAt: Date().addingTimeInterval(-345_600),
      messages: [],
    ),
    MockSession(
      id: "s-008",
      title: "Add runner health checks",
      environmentName: "sandbox",
      model: "claude-sonnet-4-6",
      status: .idle,
      updatedAt: Date().addingTimeInterval(-432_000),
      messages: [],
    ),
  ]

  // MARK: Detailed Session Messages

  private static let authSessionMessages: [MockMessage] = [
    MockMessage(
      role: .user, author: "minsheng",
      content: "The auth token refresh is failing silently. When the access token expires, the refresh request returns 401 but we're not handling it. Can you investigate and fix?",
      timestamp: Date().addingTimeInterval(-3600),
    ),
    MockMessage(
      role: .assistant,
      content: "I'll look into the auth token refresh logic. Let me start by reading the current implementation.",
      timestamp: Date().addingTimeInterval(-3550),
      toolCalls: [
        MockToolCall(
          id: "tc-1", name: "read_file",
          arguments: "Sources/WuhuClient/Auth.swift",
          result: "struct AuthManager {\n  func refreshToken() async throws -> Token {\n    let response = try await httpClient.post(\"/auth/refresh\", body: refreshBody)\n    return try decoder.decode(Token.self, from: response.body)\n  }\n}",
        ),
      ],
    ),
    MockMessage(
      role: .assistant,
      content: "I see the issue — `refreshToken()` doesn't check the HTTP status before decoding. A 401 body isn't a valid `Token`, so `decode` throws, but the error gets swallowed. Let me check the call site.",
      timestamp: Date().addingTimeInterval(-3500),
      toolCalls: [
        MockToolCall(
          id: "tc-2", name: "bash",
          arguments: "grep -rn \"refreshToken\" Sources/",
          result: "Sources/WuhuClient/Auth.swift:24:  func refreshToken()\nSources/WuhuClient/HTTPClient.swift:87:      try await authManager.refreshToken()\nSources/WuhuClient/HTTPClient.swift:91:      // retry original request",
        ),
        MockToolCall(
          id: "tc-3", name: "read_file",
          arguments: "Sources/WuhuClient/HTTPClient.swift:80-100",
          result: "  private func executeWithRetry(_ request: Request) async throws -> Response {\n    let response = try await execute(request)\n    if response.status == .unauthorized {\n      try await authManager.refreshToken()\n      return try await execute(request)\n    }\n    return response\n  }",
        ),
      ],
    ),
    MockMessage(
      role: .user, author: "anna",
      content: "Yeah I hit this too. The retry also doesn't distinguish between \"original 401\" vs \"refresh itself got 401\" — if the refresh token is expired we'd loop.",
      timestamp: Date().addingTimeInterval(-3450),
    ),
    MockMessage(
      role: .assistant,
      content: "Exactly right. The fix is:\n\n1. Add status code checking in `refreshToken()` \n2. Throw `AuthError.refreshTokenExpired` when refresh endpoint returns 401\n3. In `executeWithRetry`, catch that specific error and propagate instead of retrying\n\nImplementing now.",
      timestamp: Date().addingTimeInterval(-3400),
      toolCalls: [
        MockToolCall(
          id: "tc-4", name: "edit_file",
          arguments: "Sources/WuhuClient/Auth.swift",
          result: "Applied 2 edits to Auth.swift",
        ),
        MockToolCall(
          id: "tc-5", name: "edit_file",
          arguments: "Sources/WuhuClient/HTTPClient.swift",
          result: "Applied 1 edit to HTTPClient.swift",
        ),
        MockToolCall(
          id: "tc-6", name: "bash",
          arguments: "swift test --filter AuthTests 2>&1 | tail -5",
          result: "Test Suite 'AuthTests' passed.\n Executed 4 tests, with 0 failures in 0.832 seconds",
        ),
      ],
    ),
    MockMessage(
      role: .user, author: "kesou",
      content: "Looks clean. What about the case where the network is down entirely during refresh?",
      timestamp: Date().addingTimeInterval(-3350),
    ),
    MockMessage(
      role: .assistant,
      content: "Good catch — network errors during refresh will now propagate as `AuthError.networkError(underlying:)` instead of being silently swallowed. The caller can retry or show a connectivity alert. All 4 auth tests pass.",
      timestamp: Date().addingTimeInterval(-3300),
    ),
    MockMessage(
      role: .user, author: "minsheng",
      content: "Ship it.",
      timestamp: Date().addingTimeInterval(-3200),
    ),
  ]

  private static let websocketSessionMessages: [MockMessage] = [
    MockMessage(
      role: .user, author: "anna",
      content: "The WebSocket connection drops when the laptop sleeps and doesn't reconnect. Add exponential backoff reconnection.",
      timestamp: Date().addingTimeInterval(-7200),
    ),
    MockMessage(
      role: .assistant,
      content: "I'll add reconnection logic. Let me check the current WebSocket implementation.",
      timestamp: Date().addingTimeInterval(-7150),
      toolCalls: [
        MockToolCall(
          id: "tc-ws-1", name: "read_file",
          arguments: "Sources/WuhuClient/WebSocketTransport.swift",
          result: "actor WebSocketTransport {\n  private var connection: WebSocket?\n  \n  func connect(to url: URL) async throws {\n    connection = try await WebSocket.connect(to: url)\n  }\n}",
        ),
      ],
    ),
    MockMessage(
      role: .assistant,
      content: "No reconnection logic at all. I'll add a manager with exponential backoff (1s → 2s → 4s → 8s, capped at 30s) and jitter to avoid thundering herd.",
      timestamp: Date().addingTimeInterval(-7100),
      toolCalls: [
        MockToolCall(
          id: "tc-ws-2", name: "edit_file",
          arguments: "Sources/WuhuClient/WebSocketTransport.swift",
          result: "Applied 3 edits — added ReconnectionManager, backoff logic, and connection state observer",
        ),
      ],
    ),
    MockMessage(
      role: .user, author: "yihan",
      content: "Should we also handle the case where the server actively closes the connection with a close frame? That's different from a network drop.",
      timestamp: Date().addingTimeInterval(-7000),
    ),
    MockMessage(
      role: .assistant,
      content: "Yes — I'll distinguish between:\n- **Network drop**: reconnect with backoff\n- **Server close (1000 Normal)**: don't reconnect\n- **Server close (1001 Going Away)**: reconnect immediately (server is restarting)\n- **Server close (other)**: reconnect with backoff",
      timestamp: Date().addingTimeInterval(-6900),
      toolCalls: [
        MockToolCall(
          id: "tc-ws-3", name: "bash",
          arguments: "swift test --filter WebSocketTests",
          result: "Test Suite 'WebSocketTests' passed.\n Executed 7 tests, with 0 failures in 1.204 seconds",
        ),
      ],
    ),
    MockMessage(
      role: .user, author: "anna",
      content: "Perfect, merging.",
      timestamp: Date().addingTimeInterval(-6800),
    ),
  ]

  // MARK: Channels

  static let channels: IdentifiedArrayOf<MockChannel> = [
    MockChannel(
      id: "ch-general", name: "#general", unreadCount: 3,
      messages: [
        MockChannelMessage(id: "cm-1", author: "minsheng", isAgent: false, content: "Morning team. I'm starting on the auth refactor today.", timestamp: Date().addingTimeInterval(-28800)),
        MockChannelMessage(id: "cm-2", author: "anna", isAgent: false, content: "Nice. I'll be on the WebSocket reconnect. Created a session for it already.", timestamp: Date().addingTimeInterval(-27000)),
        MockChannelMessage(id: "cm-3", author: "yihan", isAgent: false, content: "Can someone review my PR for the migration refactor? It's #42.", timestamp: Date().addingTimeInterval(-14400)),
        MockChannelMessage(id: "cm-4", author: "Wuhu Agent", isAgent: true, content: "I've reviewed PR #42. The migration looks correct but there's a potential data loss edge case in step 3 — the `ALTER TABLE` drops the old column before copying data. I'd suggest reordering to copy first, then drop.", timestamp: Date().addingTimeInterval(-13800)),
        MockChannelMessage(id: "cm-5", author: "yihan", isAgent: false, content: "Good catch, fixing.", timestamp: Date().addingTimeInterval(-13200)),
        MockChannelMessage(id: "cm-6", author: "kesou", isAgent: false, content: "Deployed v2.3 to staging. All green so far.", timestamp: Date().addingTimeInterval(-7200)),
        MockChannelMessage(id: "cm-7", author: "minsheng", isAgent: false, content: "Auth fix is done and tested. Pushing to main now.", timestamp: Date().addingTimeInterval(-3600)),
        MockChannelMessage(id: "cm-8", author: "Wuhu Agent", isAgent: true, content: "CI build #848 passed on main (3m 14s). All 147 tests green.", timestamp: Date().addingTimeInterval(-1800)),
        MockChannelMessage(id: "cm-9", author: "anna", isAgent: false, content: "WebSocket reconnect is also merged. Good day.", timestamp: Date().addingTimeInterval(-600)),
      ],
    ),
    MockChannel(
      id: "ch-backend", name: "#backend", unreadCount: 0,
      messages: [
        MockChannelMessage(id: "cm-b1", author: "yihan", isAgent: false, content: "The sessions table migration is ready. I ran it against a copy of prod.", timestamp: Date().addingTimeInterval(-86400)),
        MockChannelMessage(id: "cm-b2", author: "Wuhu Agent", isAgent: true, content: "Migration completed successfully. Schema is now at v5. I verified row counts match pre-migration: 12,847 sessions, 284,103 entries.", timestamp: Date().addingTimeInterval(-82800)),
        MockChannelMessage(id: "cm-b3", author: "kesou", isAgent: false, content: "Nice. Can you also run the integrity check on the entries table?", timestamp: Date().addingTimeInterval(-79200)),
        MockChannelMessage(id: "cm-b4", author: "Wuhu Agent", isAgent: true, content: "Integrity check passed. All foreign keys valid, no orphaned entries, parent chain is consistent for all 284,103 entries.", timestamp: Date().addingTimeInterval(-75600)),
        MockChannelMessage(id: "cm-b5", author: "minsheng", isAgent: false, content: "Let's ship it. yihan can you do the prod migration during the maintenance window tonight?", timestamp: Date().addingTimeInterval(-72000)),
        MockChannelMessage(id: "cm-b6", author: "yihan", isAgent: false, content: "On it.", timestamp: Date().addingTimeInterval(-68400)),
      ],
    ),
    MockChannel(
      id: "ch-deployments", name: "#deployments", unreadCount: 1,
      messages: [
        MockChannelMessage(id: "cm-d1", author: "Wuhu Agent", isAgent: true, content: "Build #846 failed (feat/websocket-reconnect, 1m 05s)\n\n2 test failures in `WebSocketTransportTests`.", timestamp: Date().addingTimeInterval(-172_800)),
        MockChannelMessage(id: "cm-d2", author: "anna", isAgent: false, content: "I see the failures — the mock clock wasn't advancing properly. Fixing.", timestamp: Date().addingTimeInterval(-169_200)),
        MockChannelMessage(id: "cm-d3", author: "Wuhu Agent", isAgent: true, content: "Build #847 succeeded (feat/websocket-reconnect, 2m 58s). All 142 tests passed.", timestamp: Date().addingTimeInterval(-162_000)),
        MockChannelMessage(id: "cm-d4", author: "Wuhu Agent", isAgent: true, content: "Build #848 succeeded (main, 3m 14s). All 147 tests passed.", timestamp: Date().addingTimeInterval(-1800)),
      ],
    ),
  ]

  // MARK: Issues

  static let issues: IdentifiedArrayOf<MockIssue> = [
    MockIssue(
      id: "issue-1", title: "Auth token refresh fails silently", status: .inProgress, assignee: "minsheng", priority: .high,
      description: "When the access token expires, the refresh request returns 401 but the error is swallowed. Users see a blank screen instead of being redirected to login.",
      markdownContent: """
      ## Auth token refresh fails silently

      **Priority:** High | **Assignee:** minsheng

      ### Description
      When the access token expires, the refresh request returns 401 but the error is swallowed. Users see a blank screen instead of being redirected to login.

      ### Steps to reproduce
      1. Log in and wait for the token to expire (or manually invalidate it)
      2. Perform any authenticated action
      3. Observe blank screen — no error, no redirect

      ### Root cause
      `AuthClient.refresh()` catches the 401 and returns `nil` instead of throwing. Callers treat `nil` as "no token needed" rather than "auth failed".

      ### Fix
      - Make `refresh()` throw on 401
      - Add `.catch` handler in the middleware to redirect to `/login`
      - Add a toast notification for the user
      """,
    ),
    MockIssue(
      id: "issue-2", title: "WebSocket doesn't reconnect after sleep", status: .inProgress, assignee: "anna", priority: .critical,
      description: "Closing laptop and reopening causes the WebSocket to stay disconnected. No automatic reconnection attempt is made.",
      markdownContent: """
      ## WebSocket doesn't reconnect after sleep

      **Priority:** Critical | **Assignee:** anna

      ### Description
      Closing laptop and reopening causes the WebSocket to stay disconnected. No automatic reconnection attempt is made.

      ### Analysis
      The `NWConnection` state transitions to `.waiting` on sleep but we only observe `.ready` and `.failed`. The reconnection timer is based on explicit disconnects, not network path changes.

      ### Plan
      - Observe `NWPathMonitor` for `satisfiedConnectionRequired` → trigger reconnect
      - Add exponential backoff: 1s, 2s, 4s, 8s, max 30s
      - Cap at 10 retries before surfacing error to user

      ```swift
      // Proposed reconnect logic
      func handlePathUpdate(_ path: NWPath) {
        if path.status == .satisfied && connection.state != .ready {
          reconnect(attempt: 0)
        }
      }
      ```
      """,
    ),
    MockIssue(
      id: "issue-3", title: "Login page shows stale error message", status: .open, assignee: nil, priority: .medium,
      description: "After a successful login following a failed attempt, the error banner from the previous attempt persists until manual page refresh.",
      markdownContent: """
      ## Login page shows stale error message

      **Priority:** Medium | **Unassigned**

      ### Description
      After a successful login following a failed attempt, the error banner from the previous attempt persists until manual page refresh.

      ### Expected behavior
      Error banner should clear when login is re-attempted.

      ### Notes
      Likely a state management issue — the error state isn't reset on new submission.
      """,
    ),
    MockIssue(
      id: "issue-4", title: "Add rate limiting to API endpoints", status: .open, assignee: "kesou", priority: .low,
      description: "Public API endpoints have no rate limiting. Need to add token bucket rate limiter, 100 req/min per API key.",
      markdownContent: """
      ## Add rate limiting to API endpoints

      **Priority:** Low | **Assignee:** kesou

      ### Description
      Public API endpoints have no rate limiting. Need to add token bucket rate limiter, 100 req/min per API key.

      ### Requirements
      - Token bucket algorithm, 100 requests/minute per API key
      - Return `429 Too Many Requests` with `Retry-After` header
      - Store counters in Redis (or in-memory for single-node deploys)
      - Exempt internal service-to-service calls

      ### Open questions
      - Should we differentiate read vs write rate limits?
      - Do we need per-endpoint limits or just global per-key?
      """,
    ),
    MockIssue(
      id: "issue-5", title: "Database migration for session metadata", status: .done, assignee: "yihan", priority: .high,
      description: "Migrate sessions table to schema v5, adding metadata JSONB column for extensible session properties.",
      markdownContent: """
      ## Database migration for session metadata

      **Priority:** High | **Assignee:** yihan | **Status:** Done

      ### Description
      Migrated sessions table to schema v5, adding metadata JSONB column for extensible session properties.

      ### Migration details
      - Added `metadata JSONB DEFAULT '{}'` column
      - Backfilled existing rows with empty JSON
      - Added GIN index on metadata for query performance
      - Verified row counts: 12,847 sessions intact

      ### Verification
      Integrity check passed. All foreign keys valid, no orphaned entries.
      """,
    ),
    MockIssue(
      id: "issue-6", title: "Update CI to use Swift 6.2", status: .done, assignee: "kesou", priority: .medium,
      description: "Update GitHub Actions workflow to use Swift 6.2 toolchain and enable strict concurrency checking.",
      markdownContent: """
      ## Update CI to use Swift 6.2

      **Priority:** Medium | **Assignee:** kesou | **Status:** Done

      ### Changes
      - Updated `.swift-version` to 6.2
      - Updated GitHub Actions to `swift:6.2` Docker image
      - Enabled `-strict-concurrency=complete`
      - Fixed 3 sendability warnings in `WuhuRunner`
      """,
    ),
    MockIssue(
      id: "issue-7", title: "Runner timeout not respected for long tools", status: .open, assignee: nil, priority: .high,
      description: "When a tool execution exceeds the runner timeout, the process isn't killed. Leads to zombie processes accumulating.",
      markdownContent: """
      ## Runner timeout not respected for long tools

      **Priority:** High | **Unassigned**

      ### Description
      When a tool execution exceeds the runner timeout, the process isn't killed. Leads to zombie processes accumulating.

      ### Impact
      On the staging server, we found 23 zombie `bash` processes from timed-out tool calls over 48 hours.

      ### Proposed fix
      - Send `SIGTERM` on timeout, wait 5s, then `SIGKILL`
      - Track child PIDs in a process group
      - Add `onTimeout` callback to `ToolRunner` for cleanup
      """,
    ),
    MockIssue(
      id: "issue-8", title: "Add session fork UI", status: .open, assignee: "anna", priority: .medium,
      description: "Users need the ability to fork a session from any entry point to explore alternative approaches.",
      markdownContent: """
      ## Add session fork UI

      **Priority:** Medium | **Assignee:** anna

      ### Description
      Users need the ability to fork a session from any entry point to explore alternative approaches.

      ### Design
      - Right-click any message → "Fork from here"
      - Creates a new session with all entries up to that point
      - New session appears in the sidebar immediately
      - Parent session shows a "forked" indicator at the fork point

      ### Backend
      The `fork` API already exists (`POST /sessions/:id/fork`). This is purely a UI task.
      """,
    ),
  ]

  // MARK: Docs

  static let docs: IdentifiedArrayOf<MockDoc> = [
    MockDoc(
      id: "doc-1", title: "Architecture Overview",
      tags: ["architecture", "reference"],
      updatedAt: Date().addingTimeInterval(-86400),
      markdownContent: """
      # Architecture Overview

      Wuhu is built around a **client-server architecture** with support for multiple environments and runners.

      ## Core Components

      - **Server** — Manages sessions, entries, and environment lifecycle. Built with [Hummingbird](https://github.com/hummingbird-project/hummingbird).
      - **Client** — HTTP + WebSocket client for interacting with the server.
      - **Runner** — Executes tool calls in isolated environments. Communicates via WebSocket.
      - **CLI** — Command-line interface for session management.

      ## Data Flow

      ```
      User Input → Session → Agent Loop → Tool Execution → Entry Storage
      ```

      Sessions maintain an **append-only log** of entries. Each entry contains a payload (message, tool execution, compaction, etc.) and links to its parent entry for branching support.

      ## Environment Types

      | Type | Description |
      |------|-------------|
      | `local` | Runs in the user's local directory |
      | `folder-template` | Creates isolated copies from a template |

      ## Key Design Decisions

      1. **Append-only entries** — Enables branching, forking, and full history replay without data loss.
      2. **Snapshot environments** — Sessions capture environment state at creation for reproducibility.
      3. **Provider-agnostic** — Supports OpenAI, Anthropic, and is extensible to other providers.
      4. **Multi-agent sessions** — Multiple users and agents can participate in a single session thread.

      ## Session Lifecycle

      ```
      Created → Running → Idle
                  ↓
               Stopped
      ```

      A session starts in `Created` state, moves to `Running` when the agent loop begins processing, returns to `Idle` when waiting for input, and can be `Stopped` manually or on error.
      """,
    ),
    MockDoc(
      id: "doc-2", title: "API Reference",
      tags: ["api", "reference"],
      updatedAt: Date().addingTimeInterval(-172_800),
      markdownContent: """
      # API Reference

      Base URL: `http://localhost:8080/api/v1`

      ## Sessions

      ### `POST /sessions`

      Create a new session.

      **Request Body:**
      ```json
      {
        "provider": "anthropic",
        "model": "claude-sonnet-4-6",
        "environment": "wuhu-swift"
      }
      ```

      ### `GET /sessions/:id`

      Get session with full transcript.

      ### `POST /sessions/:id/messages`

      Send a user message to a session.

      **Request Body:**
      ```json
      {
        "content": "Fix the auth token refresh bug"
      }
      ```

      ### `GET /sessions/:id/stream`

      Stream session events via **Server-Sent Events** (SSE).

      Event types:
      - `entryAppended` — New entry added to transcript
      - `assistantTextDelta` — Streaming text from the model
      - `idle` — Agent is waiting for input
      - `done` — Session processing complete

      ## Environments

      ### `GET /environments`

      List all available environment definitions.

      ### `POST /environments`

      Create a new environment definition.
      """,
    ),
    MockDoc(
      id: "doc-3", title: "Getting Started",
      tags: ["guide", "onboarding"],
      updatedAt: Date().addingTimeInterval(-259_200),
      markdownContent: """
      # Getting Started with Wuhu

      ## Prerequisites

      - macOS 15+
      - Swift 6.0+ toolchain
      - An API key (Anthropic or OpenAI)

      ## Installation

      ```bash
      git clone https://github.com/isofucius/wuhu-swift
      cd wuhu-swift
      swift build
      ```

      ## Running the Server

      ```bash
      swift run wuhu serve --port 8080
      ```

      You should see:
      ```
      [INFO] Server started on http://localhost:8080
      [INFO] WebSocket endpoint: ws://localhost:8080/ws/runner
      ```

      ## Creating Your First Session

      In another terminal:

      ```bash
      swift run wuhu session new --env wuhu-swift --model claude-sonnet-4-6
      ```

      This creates a new coding session in the `wuhu-swift` environment using Claude Sonnet.

      ## Next Steps

      - Read the **Architecture Overview** to understand the system design
      - Check the **API Reference** for programmatic access
      - See **Runner Protocol** for custom tool execution
      """,
    ),
    MockDoc(
      id: "doc-4", title: "Runner Protocol",
      tags: ["protocol", "runner"],
      updatedAt: Date().addingTimeInterval(-345_600),
      markdownContent: """
      # Runner Protocol

      Runners communicate with the server via **WebSocket** using a JSON protocol.

      ## Connection

      ```
      ws://localhost:8080/ws/runner
      ```

      ## Message Types

      ### `hello`
      Runner announces itself on connection.

      ```json
      {"type": "hello", "runnerName": "local-runner", "version": 1}
      ```

      ### `registerSession`
      Server assigns a session to this runner.

      ### `toolRequest` / `toolResponse`
      Tool execution lifecycle.

      ```json
      {
        "type": "toolRequest",
        "id": "req-001",
        "sessionID": "s-001",
        "toolName": "bash",
        "arguments": {"command": "swift test"}
      }
      ```

      ## Lifecycle

      1. Runner connects and sends `hello`
      2. Server sends `registerSession` when a session needs tool execution
      3. Tool calls flow as `toolRequest` → runner executes → `toolResponse`
      4. Runner can handle multiple sessions concurrently
      """,
    ),
  ]

  // MARK: Activity Feed

  static let activityFeed: [MockActivityEvent] = [
    MockActivityEvent(id: "ev-1", description: "Session 'Fix auth token refresh' is running", timestamp: Date().addingTimeInterval(-120), icon: "terminal"),
    MockActivityEvent(id: "ev-2", description: "minsheng sent a message in #general", timestamp: Date().addingTimeInterval(-600), icon: "bubble.left.and.bubble.right"),
    MockActivityEvent(id: "ev-3", description: "Issue 'WebSocket reconnect' moved to In Progress", timestamp: Date().addingTimeInterval(-1800), icon: "checklist"),
    MockActivityEvent(id: "ev-4", description: "CI Build #848 passed on main", timestamp: Date().addingTimeInterval(-1800), icon: "checkmark.circle"),
    MockActivityEvent(id: "ev-5", description: "anna merged PR #41: WebSocket reconnection", timestamp: Date().addingTimeInterval(-3600), icon: "arrow.triangle.merge"),
    MockActivityEvent(id: "ev-6", description: "Doc 'Architecture Overview' updated by yihan", timestamp: Date().addingTimeInterval(-86400), icon: "doc.text"),
    MockActivityEvent(id: "ev-7", description: "Issue 'Database migration' marked as Done", timestamp: Date().addingTimeInterval(-172_800), icon: "checkmark.circle"),
  ]
}
