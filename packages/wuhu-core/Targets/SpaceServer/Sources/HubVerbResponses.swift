import Fetch
import JSONValue
import struct MainHub.CreateSessionArguments
import class MainHub.Hub
import struct MainHub.IncompleteSession
import struct MainHub.SendMessageArguments
import Serve
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
