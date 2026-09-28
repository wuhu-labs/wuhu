import Dependencies
import Foundation
import JSONValue
import SessionDomain
import struct SpaceClient.ObserveRequest
import struct SpaceClient.PostedFile
import struct SpaceClient.SpaceClient
import SpaceContract

extension Executor {
  // The server enforces the same limits; checking sizes here refuses an
  // over-limit send before any bytes are uploaded.
  func attachmentFiles(_ paths: [String]) throws -> [PostedFile] {
    var tally = AttachmentTally()
    var sources: [URL] = []
    for path in paths {
      let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
      guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular else {
        throw UsageError(message: "send: --attach \(path) is not a file")
      }
      do {
        try tally.admit(path, size: (attributes[.size] as? Int) ?? 0)
      } catch {
        throw UsageError(message: "send: \(error.message)")
      }
      sources.append(source)
    }
    return try sources.map { PostedFile(name: $0.lastPathComponent, bytes: try Data(contentsOf: $0, options: .mappedIfSafe)) }
  }

  mutating func send(_ command: SendCommand) async throws -> Int32 {
    let session = try sessionKey(command.session)
    // A session waits on a child through a request, not by holding an exec
    // open, and posts space files by path rather than uploading local ones.
    if self.session != nil, command.wait || !command.attachments.isEmpty {
      throw CLIError(message: "send \(command.wait ? "--wait" : "--attach"): \(sessionRefusal)")
    }
    let space = try self.wallet.pinnedSpace()
    let identity = try await self.persona(space: space)
    let timezone = TimeZone.current.identifier
    let client = try await self.authenticated(space)
    let files = try self.attachmentFiles(command.attachments)

    var body: JSONValue = .object([
      "message": .string(command.text),
      "session": .string(session),
      "timezone": .string(timezone),
    ])
    body.set("identity", identity.map(JSONValue.string))
    let post = try await client.postMessage(body, files: files)
    guard command.wait else {
      await self.runner.stdout("posted \(post.messageId) in \(post.conversationId)\n")
      return 0
    }
    return try await self.waitForReply(
      client: client,
      session: session,
      post: post,
      timeout: command.timeout,
    )
  }

  private func waitForReply(
    client: SpaceClient,
    session: String,
    post: ConversationPostOutput,
    timeout: Double?,
  ) async throws -> Int32 {
    // Cursor = the posted message itself, NOT the page max: a fast session can
    // reply before this page read, and skipping past that reply waits forever.
    let after = max(post.n - 1, 0)
    let messageEvents = try await client.sse(
      "/v1/conversation/\(post.conversationId)/observe?after=\(after)",
    )
    // The sessions-row observation doubles as the subscribe-time state check:
    // its first snapshot arrives immediately, so an already-errored session
    // terminates the wait before any reply could.
    let stateEvents = try await client.observe(ObserveRequest(
      mode: .sql("SELECT work, error_message FROM sessions WHERE id = '\(session)'"),
    ))

    enum Outcome: Sendable {
      case reply(ConversationMessagePayload)
      case errored(String)
      case timedOut
    }
    let outcome: Outcome? = try await withThrowingTaskGroup(of: Outcome?.self) { group in
      group.addTask {
        for try await frame in messageEvents {
          guard let value = JSONValue.parse(frame.data) else { continue }
          let message = try JSONValueDecoder().decode(ConversationMessagePayload.self, from: value)
          if message.senderSession == session, message.messageId != post.messageId {
            return .reply(message)
          }
        }
        return nil
      }
      group.addTask {
        for try await frame in stateEvents {
          guard let value = JSONValue.parse(frame.data),
                let snapshot = try? JSONValueDecoder().decode(QueryOutput.self, from: value),
                let row = snapshot.rows.first, row.count == 2
          else { continue }
          if row[0] == .string("errored") {
            let message: String = if case let .string(text) = row[1] { text } else { "unknown error" }
            return .errored(message)
          }
        }
        return nil
      }
      if let timeout {
        group.addTask {
          @Dependency(\.continuousClock) var clock
          try await clock.sleep(for: .seconds(timeout))
          return .timedOut
        }
      }
      defer { group.cancelAll() }
      while let next = try await group.next() {
        if let next { return next }
      }
      return nil
    }

    switch outcome {
    case let .reply(message):
      await self.runner.stdout(message.text + "\n")
      return 0
    case let .errored(message):
      await self.runner.stderr("session errored: \(message)\n")
      return 1
    case .timedOut:
      await self.runner.stderr("send --wait: timed out waiting for a reply\n")
      return 1
    case nil:
      await self.runner.stderr("send --wait: observation ended before a reply arrived\n")
      return 1
    }
  }

  mutating func inbox() async throws {
    let space = try self.wallet.pinnedSpace()
    let identity = try await self.persona(space: space)
    let cursor = self.wallet.inboxCursor(space: space)
    let query = "after=\(cursor)" + (identity.map { "&identity=\($0)" } ?? "")
    let output: NotificationsOutput = try await self.authenticated(space).api(
      .get, "/v1/notifications?\(query)",
    )
    for notification in output.notifications {
      await self.runner.stdout(rendered(notification))
    }
    if let last = output.notifications.last?.n {
      try self.wallet.advanceInboxCursor(last, space: space)
    }
  }

  mutating func sessionCreate(_ command: SessionCreateCommand) async throws {
    let space = try self.wallet.pinnedSpace()
    let identity = try await self.persona(space: space)
    // A session's create defaults server-side to a child task; a human's to
    // a top-level agent, as before.
    var body: JSONValue = .object(["title": .string(command.title)])
    body.set("kind", (self.session == nil ? command.kind ?? "agent" : command.kind).map(JSONValue.string))
    if command.topLevel {
      guard self.session != nil else {
        throw UsageError(message: "session create: --top-level is for a session's exec; what a human creates is top-level already")
      }
      body.set("topLevel", .bool(true))
    }
    if let group = command.homeGroup {
      guard self.session == nil || command.topLevel else {
        throw UsageError(message: "session create: --home-group places a top-level agent; a child lives in its creator's group")
      }
      body.set("group", .string(group))
    }
    body.set("identity", identity.map(JSONValue.string))
    body.set("provider", command.provider.map(JSONValue.string))
    body.set("model", command.model.map(JSONValue.string))
    body.set("effort", command.effort.map(JSONValue.string))
    body.set("template", command.template.map(JSONValue.string))
    if !command.tags.isEmpty {
      body.set("tags", .array(command.tags.map(JSONValue.string)))
    }
    let output: SessionCreateOutput = try await self.authenticated(space).api(.post, "/v1/session", body: body)
    await self.runner.stdout(output.id + "\n")
  }

  mutating func sessionRequest(id: String, message: String, deadline: Double?) async throws {
    let task = try sessionKey(id)
    guard self.session != nil else {
      throw UsageError(message: "session request: only a session opens requests, from its own exec (WUHU_EXEC=1)")
    }
    let space = try self.wallet.pinnedSpace()
    var body: JSONValue = .object(["message": .string(message)])
    body.set("deadlineSeconds", deadline.map(JSONValue.number))
    let output: SessionRequestOutput = try await self.authenticated(space).api(
      .post, "/v1/session/\(task)/request", body: body,
    )
    await self.runner.stdout("requested \(output.requestId) in \(output.conversationId)\n")
  }

  mutating func sessionAction(_ verb: SessionActionVerb, id: String) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    struct Empty: Decodable {}
    let _: Empty = try await self.authenticated(space).api(.post, "/v1/session/\(session)/\(verb.rawValue)")
  }

  mutating func sessionRename(id: String, title: String) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    struct Renamed: Decodable { let title: String }
    let output: Renamed = try await self.authenticated(space).api(
      .post, "/v1/session/\(session)/title", body: .object(["title": .string(title)]),
    )
    await self.runner.stdout(output.title + "\n")
  }

  mutating func sessionTags(id: String, tags: [String]) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    struct Tagged: Decodable { let tags: [String] }
    let output: Tagged = try await self.authenticated(space).api(
      .post, "/v1/session/\(session)/tags", body: .object(["tags": .array(tags.map { .string($0) })]),
    )
    await self.runner.stdout(output.tags.map { $0 + "\n" }.joined())
  }

  mutating func sessionCompact(id: String, instructions: String?) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    struct Empty: Decodable {}
    var body: JSONValue = .object([:])
    if let instructions {
      body = .object(["instructions": .string(instructions)])
    }
    let _: Empty = try await self.authenticated(space).api(
      .post, "/v1/session/\(session)/compact", body: body,
    )
  }

  mutating func sessionRestart(_ command: SessionRestartCommand) async throws {
    let session = try sessionKey(command.id)
    let space = try self.wallet.pinnedSpace()
    let identity = try await self.persona(space: space)
    var body: JSONValue = .object([:])
    body.set("identity", identity.map(JSONValue.string))
    body.set("provider", command.provider.map(JSONValue.string))
    body.set("model", command.model.map(JSONValue.string))
    body.set("effort", command.effort.map(JSONValue.string))
    body.set("message", command.message.map(JSONValue.string))
    let output: SessionRestartOutput = try await self.authenticated(space).api(
      .post, "/v1/session/\(session)/restart", body: body,
    )
    let spec = output.model.map { " \($0)" } ?? ""
    await self.runner.stdout("\(output.id) generation \(output.generation) on \(output.executor)\(spec)\n")
  }

  mutating func sessionLog(id: String, view: SessionLogView) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space)
    switch view {
    case let .conversation(limit, before):
      var query = "tail=\(limit ?? 50)"
      if let before { query += "&before=\(before)" }
      let output: ConversationReadOutput = try await client.api(
        .get, "/v1/conversation/\(session)/messages?\(query)",
      )
      await self.runner.stdout(renderConversationLog(output.messages))
    case let .direct(level, limit, before):
      var query = "level=\(level)"
      if let limit { query += "&limit=\(limit)" }
      if let before { query += "&before=\(queryEncoded(before))" }
      let output: SessionLogOutput = try await client.api(
        .get, "/v1/session/\(session)/log?\(query)",
      )
      await self.runner.stdout(try renderSessionLog(output, level: level))
    }
  }

  mutating func sessionEntry(id: String, ref: String) async throws {
    let session = try sessionKey(id)
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space)
    let output: SessionEntryOutput = try await client.api(
      .get, "/v1/session/\(session)/entry/\(pathEncoded(ref))",
    )
    await self.runner.stdout(try renderSessionEntry(output))
  }

  mutating func sessionList() async throws {
    let space = try self.wallet.pinnedSpace()
    let sql = """
    SELECT id, title, hold, work, lifecycle, last_activity_at \
    FROM sessions ORDER BY allocation
    """
    let output: QueryOutput = try await self.authenticated(space).tool("query", ["sql": .string(sql)])
    await self.runner.stdout(formatQuery(output))
  }
}

private func pathEncoded(_ raw: String) -> String {
  raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
}

private let queryValueAllowed: CharacterSet = {
  var set = CharacterSet.urlQueryAllowed
  set.remove(charactersIn: "&=+?")
  return set
}()

private func queryEncoded(_ raw: String) -> String {
  raw.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? raw
}

// The shape gate doubles as the SQL-injection guard: session keys are
// interpolated into observe SQL, so only word-name characters may pass.
private func sessionKey(_ raw: String) throws -> String {
  let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
  guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } })
  else {
    throw UsageError(message: "not a session id: \(raw)")
  }
  return raw
}

private func rendered(_ notification: NotificationPayload) -> String {
  let fields = notification.payload.object ?? [:]
  func field(_ name: String) -> String {
    fields[name]?.stringValue ?? "?"
  }
  // One inbox spans every group: each line names its group, and a sender
  // from outside the conversation's group names theirs.
  let sender = fields["senderGroup"]?.stringValue.map { "\(field("sender")) (group \($0))" } ?? field("sender")
  let body = switch notification.kind {
  case .conversationMessage:
    "message from \(sender) in \(notification.source): \(field("text"))"
  case .childFailed:
    "task \(field("sessionID")) failed with request \(field("requestID")) open: \(field("error"))"
  case .requestDeadline:
    "request \(field("requestID")) on \(field("sessionID")) passed its deadline"
  case .sessionSettled:
    "session \(field("sessionID")) settled: \(field("message"))"
  case .sessionErrored:
    "session \(field("sessionID")) errored: \(field("error"))"
  case .sessionDisconnected:
    "session \(field("sessionID")) disconnected: contractor \(field("contractor")) stopped reporting its run"
  case .contractorDisconnected:
    "contractor \(field("contractor")) disconnected; session \(field("sessionID")) is unattended"
  }
  let group = notification.group.map { "group \($0) · " } ?? ""
  return "[\(notification.n)] \(group)\(body)\n"
}
