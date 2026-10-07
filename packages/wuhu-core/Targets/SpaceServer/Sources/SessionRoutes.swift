import Dependencies
import Fetch
import Foundation
import enum InferenceKit.CatalogError
import struct InferenceKit.ModelsDocument
import JSONValue
import LoopCore
import Serve
import ServeRouting
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools
import SystemFiles

func addSessionRoutes(
  _ router: inout Router, space: Space, runtime: SessionRuntime, dev: Bool,
  principalOf: @escaping @Sendable (Request) async throws -> PrincipalVerdict,
) {
  let store = space.sessions
  let service = runtime.service
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date) var dateGen

  router.post("/v1/session") { request, _ in
    let input: SessionCreateInput
    do {
      input = try await request.json(SessionCreateInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-create body: \(error)")
    }
    let identity: String
    switch try await identityVerdict(input.identity, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    let group: GroupID
    do {
      group = try await space.homeGroup(input.group.map(GroupID.init(rawValue:)), creator: principal.group)
    } catch SpaceError.groupForbidden(let named) {
      return errorResponse(
        .forbidden, code: "groupForbidden",
        message: "group \(named) is not readable from group \(principal.group.rawValue)",
      )
    }
    do {
      var params = SessionCreationParams(
        provider: input.provider,
        model: input.model,
        effort: input.effort,
        tags: input.tags,
      )
      var template: SessionTemplate?
      if let name = input.template {
        let resolved = try await space.sessionTemplate(named: name, in: principal.group)
        params = params.merged(over: resolved.params)
        template = resolved
      }
      guard let kind = input.kind.map({ $0 == .agent ? SessionKind.agent : .task }) ?? template?.kind else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "kind is agent or task; pass it or use a template that sets it")
      }
      // A task works for its parent; one a person creates has none and could
      // never be told anything.
      guard kind == .agent else {
        return errorResponse(.forbidden, code: "taskInput", message: "a person creates agents only; a task is created by its parent session")
      }
      let executor = try await SessionExecutor.resolve(params, resolveModelExecutor: runtime.resolveModelExecutor)
      let id = try await store.createSession(
        group: group,
        title: input.title,
        kind: kind,
        tags: params.tags ?? [],
        createdBy: identity,
        executor: executor,
        snapshot: .init(),
      )
      if let template {
        do {
          try await space.applySessionTemplate(template, to: id)
        } catch {
          return errorResponse(
            .internalServerError,
            code: "incompleteSession",
            message: "session \(id.rawValue) was created, but cloning template \(template.name) into its home failed: \(error)",
            hint: id.rawValue,
          )
        }
      }
      let (model, effort): (String?, String?) = switch executor {
      case .kernel(let specifier), .claudeCode(let specifier): (specifier.model, specifier.effort)
      case .contractor: (nil, nil)
      }
      return try Response.json(SessionCreateOutput(
        id: id.rawValue,
        executor: executor.kind,
        model: model,
        effort: effort,
        kind: kind == .agent ? .agent : .task,
        parent: nil,
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/templates") { request, _ in
    let group: GroupID
    switch try await principalOf(request) {
    case let .principal(principal): group = principal.group
    case let .refused(response): return response
    }
    do {
      let templates = try await space.sessionTemplates(in: group).map { template in
        SessionTemplateDescriptor(
          name: template.name,
          kind: template.kind.map { $0 == .agent ? .agent : .task },
          provider: template.params.provider,
          model: template.params.model,
          effort: template.params.effort,
          description: template.description,
        )
      }
      return try Response.json(SessionTemplatesOutput(templates: templates))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.post("/v1/session/:id/archive") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let input: SessionArchiveInput
    if request.body == nil {
      input = SessionArchiveInput(force: nil)
    } else {
      do { input = try await request.json(SessionArchiveInput.self) }
      catch { return errorResponse(.badRequest, code: "invalidArgument", message: "invalid archive body") }
    }
    do {
      if case let .principal(principal) = try await principalOf(request) {
        try await store.refuseArchiving(id, by: principal.actor)
      }
      try await service.archive(id, force: input.force ?? false)
      return jsonResponse(.object([:]))
    } catch { return sessionErrorResponse(error) }
  }

  for (verb, action) in [
    ("interrupt", SessionService.interrupt),
    ("resume", SessionService.resume),
    ("unarchive", SessionService.unarchive),
  ] {
    router.post("/v1/session/:id/\(verb)") { request, parameters in
      try request.requireNoBody()
      guard let id = sessionID(parameters) else { return unknownSession(parameters) }
      if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
      do {
        if verb == "unarchive", case let .principal(principal) = try await principalOf(request) {
          try await store.refuseArchiving(id, by: principal.actor)
        }
        try await action(service)(id)
        return jsonResponse(.object([:]))
      } catch {
        return sessionErrorResponse(error)
      }
    }
  }

  router.post("/v1/session/:id/tags") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let input: SessionTagsInput
    do {
      input = try await request.json(SessionTagsInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-tags body: \(error)")
    }
    do {
      try await store.setTags(id, to: input.tags)
      return jsonResponse(.object(["tags": .array(input.tags.map { .string($0) })]))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.post("/v1/session/:id/title") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let input: SessionTitleInput
    do {
      input = try await request.json(SessionTitleInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-title body: \(error)")
    }
    do {
      return jsonResponse(.object(["title": .string(try await store.setTitle(id, to: input.title))]))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  // One verb, every executor: Claude Code gets `/compact` on standard input,
  // the kernel loop takes the same row and pins its next turn to the compact
  // tool.
  router.post("/v1/session/:id/compact") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let input: SessionCompactInput
    if request.body == nil {
      input = SessionCompactInput(instructions: nil)
    } else {
      do {
        input = try await request.json(SessionCompactInput.self)
      } catch {
        return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-compact body: \(error)")
      }
    }
    do {
      if try await store.record(id).kind == .task, input.instructions?.isEmpty == false {
        throw SessionStoreError.taskTakesNoHumanInput(id.rawValue)
      }
      try await store.requestCommand(id, .compact(instructions: input.instructions))
      return jsonResponse(.object([:]))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.post("/v1/session/:id/restart") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let input: SessionRestartInput
    if request.body == nil {
      input = SessionRestartInput(provider: nil, model: nil, effort: nil, message: nil, identity: nil, timezone: nil)
    } else {
      do {
        input = try await request.json(SessionRestartInput.self)
      } catch {
        return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-restart body: \(error)")
      }
    }
    let identity: String
    switch try await identityVerdict(input.identity, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    guard let sender = resolvedSender(identity: identity, timezone: input.timezone) else {
      return unknownTimezone(input.timezone)
    }
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    do {
      let record = try await store.record(id)
      if record.kind == .task, input.message?.isEmpty == false {
        throw SessionStoreError.taskTakesNoHumanInput(id.rawValue)
      }
      var params = SessionCreationParams(provider: input.provider, model: input.model, effort: input.effort)
      // A restart on the same provider keeps what it does not name; another
      // provider's model and effort never carry over.
      let current = record.executor.creationParams
      if params.provider == nil || params.provider == current.provider {
        params = params.merged(over: current)
      }
      let executor = try await SessionExecutor.resolve(params, resolveModelExecutor: runtime.resolveModelExecutor)
      let restart = try await service.restart(
        id, executor: executor, note: restartOpening(executor: executor, at: dateGen.now),
      )
      var queued: Int?
      if let message = input.message, !message.isEmpty {
        @Dependency(\.uuid) var uuid
        queued = try await store.post(
          .box(id), messageID: MessageID(uuid().uuidString.lowercased()), sender: sender,
          content: MessageContent(text: message), acting: principal.speaking(as: identity),
        ).enqueued.count
      }
      let (model, effort): (String?, String?) = switch restart.executor {
      case let .kernel(specifier), let .claudeCode(specifier): (specifier.model, specifier.effort)
      case .contractor: (nil, nil)
      }
      return try Response.json(SessionRestartOutput(
        id: id.rawValue,
        generation: restart.generation,
        executor: restart.executor.kind,
        model: model,
        effort: effort,
        queued: queued,
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/session/:id/context") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    do {
      let record = try await store.record(id)
      return try Response.json(SessionContextOutput(
        context: await sessionContext(
          record, store: store, budget: runtime.budget, claudeCodeTokens: runtime.service.claudeCodeContextTokens,
        ),
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/session/:id/home") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    do {
      // What the session's prompt holds: the system files first, then the
      // space's and its home's as of its prompt revision.
      let home = try await space.sessionHome(id, at: try await store.promptRevision(id))
      let system = SystemFiles.instructions
      return try Response.json(SessionHomeOutput(
        home: home.path,
        chain: system.sections.map(\.path) + home.chain,
        skills: (system.skills + home.skills).map {
          SessionHomeSkill(name: $0.name, description: $0.description, path: $0.path)
        },
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.post("/v1/conversation") { request, _ in
    let input: ConversationCreateInput
    do {
      input = try await request.json(ConversationCreateInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a conversation-create body: \(error)")
    }
    let group: GroupID
    switch try await principalOf(request) {
    case let .principal(principal): group = principal.group
    case let .refused(response): return response
    }
    switch try await identityVerdict(input.identity, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved):
      var members = input.members
      if !members.contains(resolved) { members.append(resolved) }
      let id = try await store.createConversation(members: members, in: group)
      return try Response.json(ConversationPostOutput(
        messageId: "", conversationId: id.rawValue, n: 0, delivered: [],
      ))
    case let .refused(response):
      return response
    }
  }

  router.post("/v1/conversation/message") { request, _ in
    let input: ConversationPostInput
    let uploads: [AttachmentUpload]
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return response
    }
    switch await readPost(request, space: space, principal: principal) {
    case let .post(posted, files):
      input = posted
      uploads = files
    case let .refused(response):
      return response
    }
    let target: ConversationTarget
    switch (input.conversation, input.session, input.user) {
    case let (id?, nil, nil):
      target = .conversation(ConversationID(id))
    case let (nil, session?, nil):
      target = .box(SessionID(session))
    case let (nil, nil, user?):
      target = .dm(with: user)
    default:
      return errorResponse(
        .badRequest,
        code: "invalidArgument",
        message: "a conversation post wants exactly one of conversation, session, or user",
      )
    }
    let identity: String
    switch try await identityVerdict(input.identity, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    guard var sender = resolvedSender(identity: identity, timezone: input.timezone) else {
      return unknownTimezone(input.timezone)
    }
    sender.device = try await actingDevice(request: request, space: space, now: dateGen.now)
    @Dependency(\.uuid) var uuid
    do {
      let delivery = try await store.post(
        target,
        messageID: MessageID(uuid().uuidString.lowercased()),
        sender: sender,
        replyTarget: input.replyTarget.map { MessageID($0) },
        content: MessageContent(text: input.message),
        uploads: uploads,
        acting: principal.speaking(as: identity),
      )
      return try Response.json(ConversationPostOutput(
        messageId: delivery.message.id.rawValue,
        conversationId: delivery.message.conversation.rawValue,
        n: Int(delivery.message.n),
        delivered: delivery.enqueued.map(\.rawValue),
      ))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  // A conversation the caller does not read answers as a missing one.
  // The group the reader acts in, which names the attachments it is handed.
  @Sendable func readingGroup(_ id: ConversationID, _ request: Request) async throws -> Result<GroupID, RouteRefusal> {
    let principal: Principal
    switch try await principalOf(request) {
    case let .principal(resolved): principal = resolved
    case let .refused(response): return .failure(RouteRefusal(response: response))
    }
    do {
      guard try await store.reads(store.conversation(id), reader: principal.member, group: principal.group) else {
        throw SessionStoreError.unknownConversation(id.rawValue)
      }
      return .success(principal.group)
    } catch {
      return .failure(RouteRefusal(response: sessionErrorResponse(error)))
    }
  }

  @Sendable func refusingUnread(_ id: ConversationID, _ request: Request) async throws -> Response? {
    if case let .failure(refusal) = try await readingGroup(id, request) { return refusal.response }
    return nil
  }

  router.get("/v1/conversations") { request, _ in
    let identity: String
    switch try await identityVerdict(
      queryValues(of: request.url)["identity"], request: request, space: space, dev: dev, now: dateGen.now,
    ) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    let records = try await store.conversations(member: identity)
    return try Response.json(ConversationsOutput(conversations: try await conversationPayloads(records, space: space)))
  }

  router.get("/v1/session/:id/conversation") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    do {
      let record = try await store.record(id)
      guard record.kind == .agent else {
        return errorResponse(.conflict, code: "noBox", message: "session \(id.rawValue) is a task and has no box")
      }
      if let refused = try await refusingUnread(ConversationID(id.rawValue), request) { return refused }
      let conversation = try await store.conversation(ConversationID(id.rawValue))
      return try Response.json(try await conversationPayloads([conversation], space: space)[0])
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/conversation/:id/messages") { request, parameters in
    guard let raw = parameters["id"] else { return unknownConversation(parameters) }
    let id = ConversationID(raw)
    let query = queryValues(of: request.url)
    let viewer: GroupID
    switch try await readingGroup(id, request) {
    case let .success(group): viewer = group
    case let .failure(refusal): return refusal.response
    }
    do {
      if let rawTail = query["tail"] {
        guard let tail = Int(rawTail), tail > 0, tail <= maxLogLimit else {
          return errorResponse(.badRequest, code: "invalidArgument", message: "tail must be a positive integer up to \(maxLogLimit)")
        }
        let before: Int64?
        switch query["before"] {
        case nil:
          before = nil
        case let raw?:
          guard let value = Int64(raw), value >= 0 else {
            return errorResponse(.badRequest, code: "invalidArgument", message: "before must be a non-negative integer")
          }
          before = value
        }
        if query["paged"] == "true" {
          guard tail <= 100 else { return errorResponse(.badRequest, code: "invalidArgument", message: "paged tail must be at most 100") }
          let rows = try await store.messagesTail(conversation: id, before: before, limit: tail + 1)
          let records = Array(rows.suffix(tail))
          return try Response.json(ConversationHistoryOutput(messages: try await messagePayloads(records, sessions: store, space: space, viewer: viewer), before: records.first.map { Int($0.n) } ?? before.map(Int.init), hasEarlier: rows.count > tail, headPosition: records.last.map { Int($0.n) }))
        }
        let records = try await store.messagesTail(conversation: id, before: before, limit: tail)
        return try Response.json(ConversationReadOutput(messages: try await messagePayloads(records, sessions: store, space: space, viewer: viewer)))
      }
      guard let after = cursor(query["after"]) else {
        return errorResponse(.badRequest, code: "invalidArgument", message: "after must be a non-negative integer")
      }
      let records = try await store.messages(
        conversation: id, after: after, limit: query["limit"].flatMap(Int.init),
      )
      return try Response.json(ConversationReadOutput(messages: try await messagePayloads(records, sessions: store, space: space, viewer: viewer)))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/conversation/:id/observe") { request, parameters in
    guard let raw = parameters["id"] else { return unknownConversation(parameters) }
    let id = ConversationID(raw)
    guard let after = cursor(queryValues(of: request.url)["after"]) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "after must be a non-negative integer")
    }
    switch try await readingGroup(id, request) {
    case let .success(viewer):
      return conversationStreamResponse(space: space, store: store, conversation: id, after: after, viewer: viewer, clock: clock)
    case let .failure(refusal):
      return refusal.response
    }
  }

  router.get("/v1/session/:id/transcript/page") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let query = queryValues(of: request.url)
    guard let limit = Int(query["limit"] ?? "200"), (1 ... 200).contains(limit),
          query["generation"].map({ Int($0) != nil }) ?? true,
          query["before"].map({ Int($0) != nil }) ?? true
    else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "invalid transcript page cursor or limit")
    }
    do {
      let page: TranscriptHistoryPage
      do {
        page = try await store.transcriptHistory(id, limit: limit, generation: query["generation"].flatMap(Int.init), before: query["before"].flatMap(Int.init), epoch: query["epoch"])
      } catch let TranscriptHistoryError.preparing(generation) {
        guard try await store.prepareClaudeCodeHistory(id, generation: generation) else {
          return errorResponse(.serviceUnavailable, code: "transcriptPreparing", message: "Preparing history; retry this page")
        }
        page = try await store.transcriptHistory(id, limit: limit, generation: query["generation"].flatMap(Int.init), before: query["before"].flatMap(Int.init), epoch: query["epoch"])
      }
      return try Response.json(TranscriptHistoryOutput(
        historyEpoch: page.historyEpoch,
        generation: page.generation,
        entries: page.entries.map { TranscriptHistoryEntryPayload(position: $0.position, item: itemJSON($0.item)) },
        origins: page.origins.map { TranscriptHistoryEntryPayload(position: $0.position, item: itemJSON($0.item)) },
        before: page.before,
        hasEarlier: page.hasEarlier,
        headPosition: page.headPosition,
      ))
    } catch let error as TranscriptHistoryError {
      switch error {
      case .invalidPage:
        return errorResponse(.badRequest, code: "invalidArgument", message: "pass a valid generation and exclusive before together")
      case .generationChanged, .historyChanged:
        return errorResponse(.conflict, code: "generationChanged", message: "transcript generation changed; bootstrap the recent page")
      case .preparing:
        return errorResponse(.serviceUnavailable, code: "transcriptPreparing", message: "Preparing history; retry this page")
      }
    } catch { return sessionErrorResponse(error) }
  }

  router.get("/v1/session/:id/transcript") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    do {
      if case .contractor = try await store.record(id).executor { return contractorSession(id) }
      let (generation, items) = try await store.transcriptSnapshot(id)
      return try Response.json(TranscriptReadOutput(generation: generation, items: items.map(itemJSON)))
    } catch {
      return sessionErrorResponse(error)
    }
  }

  router.get("/v1/session/:id/direct") { request, parameters in
    guard let id = sessionID(parameters) else { return unknownSession(parameters) }
    if let refused = try await refusingUnseen(id, request, space: space, principalOf: principalOf) { return refused }
    let query = queryValues(of: request.url)
    let cursor: TranscriptCursor?
    switch (query["generation"].flatMap(Int.init), query["position"].flatMap(Int.init)) {
    case let (generation?, position?):
      cursor = TranscriptCursor(generation: generation, position: position)
    case (nil, nil):
      cursor = nil
    default:
      return errorResponse(.badRequest, code: "invalidArgument", message: "pass generation and position together, or neither")
    }
    do {
      if case .contractor = try await store.record(id).executor { return contractorSession(id) }
    } catch {
      return sessionErrorResponse(error)
    }
    return directStreamResponse(runtime: runtime, session: id, cursor: cursor, bounded: query["paged"] == "true", historyEpoch: query["epoch"])
  }

  router.post("/v1/watermark") { request, _ in
    let input: WatermarkInput
    do {
      input = try await request.json(WatermarkInput.self)
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected a watermark body: \(error)")
    }
    let identity: String
    switch try await identityVerdict(input.identity, request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    let newest = try await store.advanceWatermark(
      identity: identity,
      source: input.source,
    )
    return try Response.json(WatermarkOutput(lastReadN: Int(newest)))
  }

  router.get("/v1/notifications") { request, _ in
    let query = queryValues(of: request.url)
    guard let after = cursor(query["after"]) else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "after must be a non-negative integer")
    }
    let identity: String
    switch try await identityVerdict(query["identity"], request: request, space: space, dev: dev, now: dateGen.now) {
    case let .identity(resolved): identity = resolved
    case let .refused(response): return response
    }
    let records = try await store.notifications(recipient: identity, after: after)
    return try Response.json(NotificationsOutput(notifications: records.map(notificationPayload)))
  }
}

func sessionID(_ parameters: RouteParameters) -> SessionID? {
  parameters["id"].map { SessionID($0) }
}

private func cursor(_ raw: String?) -> Int64? {
  guard let raw else { return 0 }
  guard let value = Int64(raw), value >= 0 else { return nil }
  return value
}

private func resolvedSender(identity: String, timezone: String?) -> Sender? {
  guard let timezone else {
    return Sender(id: identity, timeZone: TimeZone(identifier: "UTC")!)
  }
  guard let zone = TimeZone(identifier: timezone) else { return nil }
  return Sender(id: identity, timeZone: zone)
}

// Attribution comes from the request credential alone: a body may name a
// sender identity, never a device.
private func actingDevice(request: Request, space: Space, now: Date) async throws -> String? {
  guard case let .verified(credential) = try await bearerVerdict(request: request, space: space, now: now) else {
    return nil
  }
  return try await space.device(pubkey: credential.key.pubkey)?.id
}

private func unknownTimezone(_ timezone: String?) -> Response {
  errorResponse(.badRequest, code: "invalidArgument", message: "unknown timezone: \(timezone ?? "")")
}

func contractorSession(_ id: SessionID) -> Response {
  errorResponse(
    .conflict,
    code: "contractorSession",
    message: "session \(id.rawValue) ran on the removed contractor executor; its transcript is no longer served",
    hint: "start it over on a model to use it again: wuhu session restart \(id.rawValue) --provider <p> --model <m>",
  )
}

func unknownSession(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown session: \(parameters["id"] ?? "")")
}

func sessionErrorResponse(_ error: any Error) -> Response {
  switch error {
  case let error as SessionStoreError:
    switch error {
    case let .unknownSession(key):
      return errorResponse(.notFound, code: "notFound", message: "unknown session: \(key)")
    case let .unknownMessage(id):
      return errorResponse(.notFound, code: "notFound", message: "unknown message: \(id)")
    case let .archiveGraceExpired(key):
      return errorResponse(.conflict, code: "archiveGraceExpired", message: "session \(key) is archived and its grace has expired")
    case let .busyForRestart(key):
      return errorResponse(
        .conflict,
        code: "conflict",
        message: "session \(key) has unfinished work or an open run; interrupt it or let it settle before starting over",
      )
    case let .parentUnavailableForCreation(key):
      return errorResponse(.conflict, code: "conflict", message: "session \(key) is being archived or is archived; it cannot create children")
    case let .restartOfArchivedSession(key):
      return errorResponse(.conflict, code: "conflict", message: "session \(key) is archived; unarchive it before starting over")
    case let .unknownConversation(id):
      return errorResponse(.notFound, code: "notFound", message: "unknown conversation: \(id)")
    case let .replyTargetInAnotherConversation(id):
      return errorResponse(.unprocessableContent, code: "invalidArgument", message: "message \(id) is in another conversation")
    case let .selfDirectMessage(id):
      return errorResponse(.unprocessableContent, code: "invalidArgument", message: "\(id) cannot open a DM with itself")
    case let .taskHasNoBox(key):
      return errorResponse(.conflict, code: "noBox", message: "session \(key) is a task and has no box")
    case let .taskTakesNoHumanInput(key):
      return errorResponse(
        .forbidden,
        code: "taskInput",
        message: "session \(key) is a task and takes no messages from people",
      )
    case let .noParent(key):
      return errorResponse(.conflict, code: "conflict", message: "session \(key) has no parent")
    case let .notTheParent(key):
      return errorResponse(.forbidden, code: "forbidden", message: "only the parent of session \(key) may open a request on it")
    case let .tooDeep(parent):
      return errorResponse(
        .unprocessableContent,
        code: "invalidArgument",
        message: "session \(parent) is at level \(SessionStore.depthLimit) of the session tree; a session under it would be deeper than \(SessionStore.depthLimit) levels",
      )
    case let .mayNotArchive(target, actor):
      return errorResponse(
        .forbidden,
        code: "forbidden",
        message: "\(actor) may not archive or unarchive session \(target): only the session itself, its creator and admins of its group may",
      )
    case let .notInCharge(target, actor):
      return errorResponse(
        .forbidden,
        code: "forbidden",
        message: "\(actor) may not change session \(target): only the session itself, its ancestors and humans may",
      )
    case let .requestAlreadyOpen(id):
      return errorResponse(.conflict, code: "conflict", message: "request \(id) is still open")
    case let .unknownRequest(id):
      return errorResponse(.notFound, code: "notFound", message: "no open request \(id)")
    case let .unusableTitle(title):
      return errorResponse(
        .unprocessableContent,
        code: "invalidArgument",
        message: "unusable title: a title is one non-empty line of at most \(SessionStore.titleLimit) characters",
        hint: String(title.prefix(80)),
      )
    }
  case let busy as SubtreeArchiveBusy:
    return errorResponse(.conflict, code: "conflict", message: busy.message)
  case let SessionError.unreadableData(id):
    return errorResponse(.conflict, code: "unreadableSessionData", message: SessionError.unreadableData(id).description)
  case SessionError.archiveInProgress:
    return errorResponse(.conflict, code: "conflict", message: "session is being archived; retry after the archive finishes")
  case SessionError.archiveReservationLost:
    return errorResponse(.conflict, code: "conflict", message: "session changed during archive; archive stopped, retry it")
  case SessionError.archiveGraceExpired:
    return errorResponse(.conflict, code: "archiveGraceExpired", message: "the archive grace has expired")
  case let error as CatalogError:
    return errorResponse(.unprocessableContent, code: "invalidArgument", message: error.description)
  case let error as ExecutorSpecError:
    return errorResponse(.unprocessableContent, code: "invalidArgument", message: error.message)
  case let error as SpaceError:
    return jsonResponse(Wire.failure(error).payload, status: .unprocessableContent)
  default:
    return errorResponse(.internalServerError, code: "internal", message: String(describing: error))
  }
}

// The wire projection of the sender's account kind: a sender is either a
// session id (senderSession attribution) or a human-facing identity.
func senderKind(_ sender: String, sessions: SessionStore) async -> SenderKind {
  (try? await sessions.record(SessionID(sender))) == nil ? .user : .session
}

func messagePayloads(
  _ records: [MessageRecord], sessions: SessionStore, space: Space, viewer: GroupID,
) async throws -> [ConversationMessagePayload] {
  let handles = try await handles(for: records.map(\.sender.id), space: space)
  var kinds: [String: SenderKind] = [:]
  var homes: [ConversationID: GroupID] = [:]
  var payloads: [ConversationMessagePayload] = []
  for record in records {
    let sender = record.sender.id
    let kind: SenderKind
    if let held = kinds[sender] {
      kind = held
    } else {
      kind = await senderKind(sender, sessions: sessions)
      kinds[sender] = kind
    }
    let home: GroupID
    if let known = homes[record.conversation] {
      home = known
    } else {
      home = try await sessions.conversation(record.conversation).group
      homes[record.conversation] = home
    }
    payloads.append(ConversationMessagePayload(
      n: Int(record.n),
      messageId: record.id.rawValue,
      conversationId: record.conversation.rawValue,
      kind: MessageKindPayload(rawValue: record.kind.rawValue)!,
      requestId: record.requestID?.rawValue,
      replyTarget: record.replyTarget?.rawValue,
      sender: sender,
      senderHandle: handles[sender],
      senderKind: kind,
      senderTimezone: record.sender.timeZone.identifier,
      senderSession: record.senderSession?.rawValue,
      senderGroup: record.senderGroup.rawValue,
      text: record.content.text,
      attachments: record.content.attachments.isEmpty ? nil : record.content.attachments.map { attachmentPayload($0.named(in: home, for: viewer)) },
      createdAt: record.createdAt.timeIntervalSince1970,
    ))
  }
  return payloads
}

struct RouteRefusal: Error {
  let response: Response
}

private func attachmentPayload(_ attachment: Attachment) -> AttachmentPayload {
  switch attachment {
  case let .image(path, mimeType, size, _): AttachmentPayload(kind: .image, path: path, mimeType: mimeType, size: size)
  case let .file(path, mimeType, size): AttachmentPayload(kind: .file, path: path, mimeType: mimeType, size: size)
  }
}

func conversationPayloads(_ records: [ConversationRecord], space: Space) async throws -> [ConversationPayload] {
  let handles = try await handles(for: records.flatMap { $0.members.map(\.member) }, space: space)
  return records.map { conversationPayload($0, handles: handles) }
}

private func conversationPayload(_ record: ConversationRecord, handles: [String: String]) -> ConversationPayload {
  ConversationPayload(
    id: record.id.rawValue,
    kind: ConversationKindPayload(rawValue: record.kind.rawValue)!,
    ownerSession: record.ownerSession?.rawValue,
    members: record.members.map {
      ConversationMemberPayload(member: $0.member, memberHandle: handles[$0.member], kind: $0.kind.rawValue)
    },
    windowMessages: record.windowMessages,
    windowSeconds: record.windowSeconds,
    lastMessageN: nil,
    lastMessageAt: nil,
  )
}

func unknownConversation(_ parameters: RouteParameters) -> Response {
  errorResponse(.notFound, code: "notFound", message: "unknown conversation: \(parameters["id"] ?? "")")
}

private func notificationPayload(_ record: NotificationRecord) -> NotificationPayload {
  NotificationPayload(
    n: Int(record.n),
    recipient: record.recipient,
    source: record.source,
    kind: SessionNotificationKind(rawValue: record.kind.rawValue)!,
    payload: JSONValue.parse(record.payload) ?? .string(record.payload),
    createdAt: record.createdAt.timeIntervalSince1970,
    group: record.group.rawValue,
  )
}

private func restartOpening(executor: SessionExecutor, at now: Date) -> String {
  let spec: String = switch executor {
  case let .kernel(model), let .claudeCode(model):
    "\(executor.kind) \(model.provider)/\(model.model) (\(model.effort))"
  case .contractor:
    executor.kind
  }
  return """
  Started over on \(spec) at \(now.ISO8601Format()); the previous transcript is archived and your box history is unchanged.
  """
}

extension SessionExecutor {
  fileprivate var creationParams: SessionCreationParams {
    switch self {
    case let .kernel(model), let .claudeCode(model):
      SessionCreationParams(provider: model.provider, model: model.model, effort: model.effort)
    case .contractor:
      SessionCreationParams()
    }
  }
}

/// A session in a group the acting group does not read answers as a missing
/// one, before the route does anything.
func refusingUnseen(
  _ id: SessionID, _ request: Request, space: Space,
  principalOf: @Sendable (Request) async throws -> PrincipalVerdict,
) async throws -> Response? {
  let principal: Principal
  switch try await principalOf(request) {
  case let .principal(resolved): principal = resolved
  case let .refused(response): return response
  }
  do {
    let record = try await space.sessions.record(id)
    guard try await space.reads(principal.group).contains(record.group) else {
      throw SessionStoreError.unknownSession(id.rawValue)
    }
    return nil
  } catch {
    return sessionErrorResponse(error)
  }
}
