import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.CatalogError
import SessionDomain
import struct SpaceContract.AttachmentTally
import SpaceCore
import SpaceTools
import SystemFiles

extension Hub {
  nonisolated public func sendMessage(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: SendMessageArguments,
  ) async throws -> ToolResultPayload {
    // Scoped like every receipt key: (session id, kernel tool call id).
    let messageID = MessageID(UUID.deterministic("post", session.rawValue, callID.rawValue).uuidString.lowercased())
    // A retry of a send that already committed must not read its attachments
    // again: the machine may be gone by now, and a failure here would make the
    // model send the message twice.
    if let posted = try await store.message(messageID) {
      let delivery = try await deliver(
        .conversation(posted.conversation), session: session, messageID: messageID,
        text: arguments.message, replyTarget: arguments.replyTarget.map { MessageID($0) }, uploads: [],
      )
      return sendReceipt(delivery.message)
    }
    let target: ConversationTarget
    switch (arguments.conversation, arguments.session) {
    case (nil, nil):
      target = .box(session)
    case let (id?, nil):
      target = .conversation(ConversationID(id))
    case let (nil, other?):
      target = try await dm(to: SessionID(other))
    default:
      throw ToolProblem("send_message wants at most one of conversation or session")
    }
    let delivery = try await deliver(
      target,
      session: session,
      messageID: messageID,
      text: arguments.message,
      replyTarget: arguments.replyTarget.map { MessageID($0) },
      uploads: attachmentUploads(arguments.attachments ?? [], by: session),
    )
    return sendReceipt(delivery.message)
  }

  nonisolated private func sendReceipt(_ message: MessageRecord) -> ToolResultPayload {
    .sendMessage(.init(
      messageID: message.id,
      conversationID: message.conversation,
      n: message.n,
      replyTarget: message.replyTarget,
    ))
  }

  nonisolated public func request(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: RequestArguments,
  ) async throws -> ToolResultPayload {
    @Dependency(\.date) var date
    let deadline = try arguments.deadlineSeconds.map { seconds -> Date in
      guard seconds >= 1 else { throw ToolProblem("deadline_seconds must be at least 1") }
      return date.now.addingTimeInterval(seconds)
    }
    let stall = try stallSeconds(arguments.stallSeconds)
    let task = SessionID(arguments.task)
    do {
      let delivery = try await store.openRequest(
        on: task,
        from: session,
        messageID: MessageID(UUID.deterministic("request", session.rawValue, callID.rawValue).uuidString.lowercased()),
        text: arguments.message,
        deadline: deadline,
        stallSeconds: stall,
      )
      return .request(.init(
        requestID: delivery.message.requestID!,
        task: task,
        conversationID: delivery.message.conversation,
        deadline: delivery.message.deadline,
      ))
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  // Absent means the default; 0 turns the alert off.
  nonisolated func stallSeconds(_ seconds: Double?) throws -> Double? {
    guard let seconds else { return RequestStall.defaultSeconds }
    guard seconds != 0 else { return nil }
    guard seconds >= 1 else { throw ToolProblem("stall_seconds is 0 (off) or at least 1") }
    return seconds
  }

  nonisolated public func report(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: ReportArguments,
  ) async throws -> ToolResultPayload {
    guard let kind = MessageKind(rawValue: arguments.kind), kind == .progress || kind == .final else {
      throw ToolProblem("report kind is progress or final; got \(arguments.kind)")
    }
    do {
      let delivery = try await store.report(
        session,
        request: RequestID(arguments.requestID),
        kind: kind,
        messageID: MessageID(UUID.deterministic("report", session.rawValue, callID.rawValue).uuidString.lowercased()),
        text: arguments.content,
      )
      return .report(.init(
        messageID: delivery.message.id,
        requestID: RequestID(arguments.requestID),
        conversationID: delivery.message.conversation,
        kind: kind,
      ))
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  nonisolated func callerDefaults(_ session: SessionID, params: SessionCreationParams) async throws -> SessionCreationParams {
    switch try await store.record(session).executor {
    case let .kernel(specifier):
      guard params.modelGroup == nil, params.provider == nil || params.provider == specifier.provider else { return .init() }
      return .init(provider: specifier.provider, model: specifier.model, effort: specifier.effort)
    case let .modelGroup(id, effort):
      guard params.provider == nil, params.model == nil, params.modelGroup == nil || params.modelGroup == id else { return .init() }
      return .init(modelGroup: id, effort: effort)
    case .retired:
      return .init()
    }
  }

  // Session to session is always private: an agent's box is for people, and
  // a post there fans out to every recent poster.
  nonisolated private func dm(to other: SessionID) async throws -> ConversationTarget {
    do {
      _ = try await store.record(other)
    } catch let error as SessionStoreError {
      throw problem(error)
    }
    return .dm(with: other.rawValue)
  }

  nonisolated func deliver(
    _ target: ConversationTarget,
    session: SessionID,
    messageID: MessageID,
    text: String,
    replyTarget: MessageID?,
    uploads: [AttachmentUpload],
  ) async throws -> MessageDelivery {
    do {
      return try await store.post(
        target,
        messageID: messageID,
        sender: Sender(id: session.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: session,
        replyTarget: replyTarget,
        content: MessageContent(text: text),
        uploads: uploads,
      )
    } catch let error as SessionStoreError {
      throw problem(error)
    }
  }

  // Sizes are checked before any bytes are read, so an over-limit list fails
  // without pulling a file off a machine.
  nonisolated private func attachmentUploads(_ references: [String], by session: SessionID) async throws -> [AttachmentUpload] {
    let context = SpaceToolContext(space: space, principal: try await space.principal(of: session))
    var tally = AttachmentTally()
    var located: [(reference: String, address: Address, size: Int)] = []
    for reference in references {
      let address = try await resolve(reference, as: session)
      let size: Int
      switch address {
      case let .space(path, group):
        guard let entry = try? await space.fs(group ?? context.principal.group).stat(path), entry.kind == .file else {
          throw ToolProblem("attachment \(reference) is not a file in the space")
        }
        size = entry.size
      case let .machine(machine, path):
        guard let entry = try await machineStat(machine, path: path), entry.kind != .directory else {
          throw ToolProblem("attachment \(reference) is not a file on that machine")
        }
        size = entry.size
      case let .system(path):
        guard let entry = try? await SystemFiles.vfs.stat(path), entry.kind == .file else {
          throw ToolProblem("attachment \(reference) is not a system file")
        }
        size = entry.size
      }
      do {
        try tally.admit(reference, size: size)
      } catch {
        throw ToolProblem(error.message)
      }
      located.append((reference, address, size))
    }
    var uploads: [AttachmentUpload] = []
    for (reference, address, size) in located {
      let bytes: [UInt8]
      switch address {
      case .space: bytes = try await [UInt8](context.readBytes(reference).data)
      case let .machine(machine, path):
        // No more than the tally admitted: a file swapped since the stat is refused, not copied.
        do { bytes = try await machineBytes(machine, path: path, limit: size) } catch is MachineSeam.OverLimit {
          throw ToolProblem("attachment \(reference) changed while it was being read; send it again")
        }
      case let .system(path): bytes = try await [UInt8](SystemFiles.vfs.read(path).1)
      }
      uploads.append(AttachmentUpload(name: reference, bytes: bytes))
    }
    return uploads
  }

  nonisolated func problem(_ error: SessionStoreError) -> ToolProblem {
    switch error {
    case let .modelRouteInvalid(group, member):
      ToolProblem(CatalogError.modelRouteInvalid(group: group, member: member).description, code: "modelRouteInvalid")
    case let .unknownSession(key):
      ToolProblem("unknown session: \(key)")
    case let .unknownMessage(id):
      ToolProblem("unknown message: \(id)")
    case let .unknownConversation(id):
      ToolProblem("unknown conversation: \(id)")
    case let .replyTargetInAnotherConversation(id):
      ToolProblem("message \(id) is in another conversation; reply_target names a message in the one you are posting to")
    case .humanAgentDirectMessage:
      ToolProblem(SessionStoreError.humanAgentDirectMessageExplanation)
    case let .selfDirectMessage(id):
      ToolProblem("\(id) cannot open a DM with itself")
    case let .taskHasNoBox(key):
      ToolProblem("session \(key) is a task and has no box; name a conversation or session")
    case let .taskTakesNoHumanInput(key):
      ToolProblem("session \(key) is a task and takes no messages from people")
    case let .noParent(key):
      ToolProblem("session \(key) has no parent and cannot report")
    case let .notTheParent(key):
      ToolProblem("only the parent of session \(key) may open a request on it")
    case let .requestAlreadyOpen(id):
      ToolProblem("request \(id) is still open; wait for its final report before requesting again")
    case let .unknownRequest(id):
      ToolProblem("no open request \(id)")
    case let .archiveGraceExpired(key):
      ToolProblem("session \(key) is archived and no longer accepts messages")
    case let .requestDeadlineWithoutFireDate(id):
      ToolProblem("request deadline \(id) has no stored fire date")
    case let .busyForRestart(key):
      ToolProblem("session \(key) has unfinished work or an open run and cannot start over")
    case let .parentUnavailableForCreation(key):
      ToolProblem("session \(key) is being archived or is archived; it cannot create children")
    case let .restartOfArchivedSession(key):
      ToolProblem("session \(key) is archived and cannot start over")
    case .unusableTitle:
      ToolProblem("a title is one non-empty line of at most \(SessionStore.titleLimit) characters")
    case let .tooDeep(parent):
      ToolProblem("session \(parent) is at level \(SessionStore.depthLimit) of the session tree; a session under it would be deeper than \(SessionStore.depthLimit) levels")
    case let .notInCharge(target, actor):
      ToolProblem("\(actor) may not change session \(target): only the session itself, its ancestors and humans may")
    case let .mayNotArchive(target, actor):
      ToolProblem("\(actor) may not archive or unarchive session \(target): only the session itself, its creator and admins of its group may")
    }
  }

  nonisolated public func createSession(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: CreateSessionArguments,
  ) async throws -> ToolResultPayload {
    let spawned: Spawned
    do {
      spawned = try await spawn(session, callID, SpawnOrder(
        executor: arguments.executor,
        title: arguments.title,
        kind: arguments.kind,
        topLevel: arguments.topLevel ?? false,
        group: arguments.group,
        provider: arguments.provider,
        model: arguments.model,
        modelGroup: arguments.modelGroup,
        effort: arguments.effort,
        tags: arguments.tags,
        template: arguments.template,
        expectsReply: arguments.expectsReply ?? false,
        message: arguments.message,
        stallSeconds: arguments.stallSeconds,
      ))
    } catch let problem as ToolProblem {
      throw ToolProblem("create_session: \(problem.message)", code: problem.code)
    }
    if let unfinished = spawned.unfinished {
      throw IncompleteSession(id: spawned.id, message: "create_session: session \(spawned.id.rawValue) was created, but \(unfinished)")
    }
    return .createSession(.init(
      sessionID: spawned.id, title: spawned.title, requestID: spawned.requestID,
      modelGroup: spawned.modelGroup, member: spawned.member, provider: spawned.provider, model: spawned.model,
    ))
  }
}
