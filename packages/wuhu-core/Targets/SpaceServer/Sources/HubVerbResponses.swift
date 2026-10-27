import Fetch
import JSONValue
import struct MainHub.CreateSessionArguments
import class MainHub.Hub
import struct MainHub.IncompleteSession
import struct MainHub.RequestArguments
import struct MainHub.RequestTermsArguments
import struct MainHub.SendMessageArguments
import Serve
import ServeRouting
import SessionDomain
import SpaceContract
import SpaceCore

// createSession and sendMessage as the session gate, a person's routes and a
// page's `wuhu:space` answer them: one hub call, only the caller differs.

func createSessionResponse(
  _ hub: Hub, as caller: Caller, _ callID: ToolCallID, _ arguments: CreateSessionArguments,
  render: (CreateSessionResult) async throws -> Response,
) async throws -> Response {
  let payload: ToolResultPayload
  do {
    payload = try await hub.answering(as: caller) { try await hub.createSession(caller, callID, arguments) }
  } catch let incomplete as IncompleteSession {
    // The session exists: the failure names it.
    return jsonResponse(
      .object(["code": .string(IncompleteSession.code), "message": .string(incomplete.message), "id": .string(incomplete.id.rawValue)]),
      status: .unprocessableContent,
    )
  }
  guard case let .createSession(created) = payload else { return hubRefusal(payload) }
  return try await render(created)
}

func sendMessageResponse(
  _ hub: Hub, as caller: Caller, _ callID: ToolCallID, _ arguments: SendMessageArguments,
  render: (SendMessageResult) throws -> Response,
) async throws -> Response {
  let payload = try await hub.answering(as: caller) { try await hub.sendMessage(caller, callID, arguments) }
  guard case let .sendMessage(sent) = payload else { return hubRefusal(payload) }
  return try render(sent)
}

/// The API's view of a session a create made, as it stands now.
func sessionCreateOutput(_ created: CreateSessionResult, store: SessionStore) async throws -> Response {
  do {
    let record = try await store.record(created.sessionID)
    let (model, effort): (String?, String?) = switch record.executor {
    case .kernel(let specifier): (specifier.model, specifier.effort)
    case let .modelGroup(_, effort): (try await store.modelRoute(record.id)?.specifier.model, effort)
    case .retired: (nil, nil)
    }
    return try Response.json(SessionCreateOutput(
      id: record.id.rawValue,
      executor: record.executor.kind,
      model: model,
      provider: await activeModelSpecifier(record, store: store)?.provider,
      modelGroup: { if case let .modelGroup(id, _) = record.executor { id } else { nil } }(),
      effort: effort,
      kind: record.kind == .agent ? .agent : .task,
      parent: record.parent?.rawValue,
      title: created.title,
      requestId: created.requestID?.rawValue,
      member: created.member,
      existing: created.existing,
    ))
  } catch {
    return sessionErrorResponse(error)
  }
}

/// A hub verb's typed failure: a refusal of who is asking is a 403, any other
/// a 422, each carrying its code.
func hubRefusal(_ payload: ToolResultPayload) -> Response {
  guard case let .failure(failure) = payload else {
    return errorResponse(.unprocessableContent, code: "refused", message: "unexpected tool result")
  }
  let code = failure.code ?? "refused"
  let status: Status = forbiddingCodes.contains(code) ? .forbidden : .unprocessableContent
  return errorResponse(status, code: code, message: failure.message)
}

private let forbiddingCodes: Set<String> = ["groupForbidden", "taskInput", "outsidePageGroup"]

// The verbs a session and an observer share, as their gates serve them.

func postSession(_ request: Request, as caller: Caller, callID: ToolCallID, owner: Hub) async throws -> Response {
  let arguments: CreateSessionArguments
  do {
    arguments = try CreateSessionArguments(body: try await request.json(JSONValue.self, upTo: maximumPostFieldsBytes))
  } catch {
    return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-create body: \(error)")
  }
  return try await createSessionResponse(owner, as: caller, callID, arguments) { created in
    try await sessionCreateOutput(created, store: owner.space.sessions)
  }
}

func postRequest(_ request: Request, _ parameters: RouteParameters, as caller: Caller, callID: ToolCallID, owner: Hub) async throws -> Response {
  guard let id = sessionID(parameters) else { return unknownSession(parameters) }
  let input: SessionRequestInput
  do {
    input = try await request.json(SessionRequestInput.self)
  } catch {
    return errorResponse(.badRequest, code: "invalidArgument", message: "expected a session-request body: \(error)")
  }
  let payload = try await owner.answering(as: caller) {
    try await owner.request(caller, callID, RequestArguments(
      task: id.rawValue, message: input.message, deadlineSeconds: input.deadlineSeconds, stallSeconds: input.stallSeconds,
      terms: RequestTermsArguments(kind: input.kind, key: input.key, schema: input.schema, fields: input.fields),
    ))
  }
  guard case let .request(opened) = payload else { return hubRefusal(payload) }
  return try Response.json(SessionRequestOutput(
    requestId: opened.requestID.rawValue,
    task: opened.task.rawValue,
    conversationId: opened.conversationID.rawValue,
    deadline: opened.deadline?.timeIntervalSince1970,
    existing: opened.existing,
  ))
}

func postMessage(_ request: Request, as caller: Caller, callID: ToolCallID, owner: Hub) async throws -> Response {
  let contentType = request.headers[.contentType] ?? request.body?.contentType ?? ""
  guard MultipartReader.boundary(of: contentType) == nil else {
    return errorResponse(.badRequest, code: "invalidArgument", message: "a session's exec uploads no files; name space files in attachments instead")
  }
  let input: ConversationPostInput
  let body: JSONValue
  do {
    body = try await request.json(JSONValue.self, upTo: maximumPostFieldsBytes)
    input = try JSONValueDecoder().decode(ConversationPostInput.self, from: body)
  } catch {
    return errorResponse(.badRequest, code: "invalidArgument", message: "expected a conversation-post body: \(error)")
  }
  if case let .object(fields) = body, fields["viewing"] != nil {
    return errorResponse(.badRequest, code: "invalidArgument", message: "viewing is set only on a person's message, never by a session")
  }
  if case let .object(fields) = body, fields["user"] != nil {
    return errorResponse(.unprocessableContent, code: "refused", message: SessionStoreError.humanAgentDirectMessageExplanation)
  }
  let arguments = SendMessageArguments(
    message: input.message, conversation: input.conversation, session: input.session, replyTarget: input.replyTarget, attachments: input.attachments,
  )
  return try await sendMessageResponse(owner, as: caller, callID, arguments) { sent in
    try Response.json(ConversationPostOutput(
      messageId: sent.messageID.rawValue, conversationId: sent.conversationID.rawValue, n: Int(sent.n), delivered: [],
    ))
  }
}
