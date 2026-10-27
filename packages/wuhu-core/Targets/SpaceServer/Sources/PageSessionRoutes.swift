import Dependencies
import Fetch
import JSONValue
import struct MainHub.CreateSessionArguments
import class MainHub.Hub
import struct MainHub.SendMessageArguments
import Serve
import SessionDomain
import SpaceContract
import SpaceCore

/// `/_/space/session` and `/_/space/message`: a page's `createSession` and
/// `sendMessage`, as the person viewing it; the hub holds the page's bound.
func pageSessionResponse(space: Space, caller: WebCaller, dev: Bool, hub: Hub?, request: Request) async throws -> Response {
  guard request.method == .post else { return plainStatus(.methodNotAllowed) }
  guard let hub else { return errorResponse(.notFound, code: "notFound", message: "this server runs no sessions") }
  let write: PageWrite
  switch try await writeAdmission(space: space, caller: caller, dev: dev, request: request) {
  case let .refused(wall): return wall
  case let .admitted(admitted): write = admitted
  }
  guard let person = Person(write.context.principal) else { preconditionFailure("a page's viewer is a person") }
  var body = write.body
  body.removeValue(forKey: "page")
  @Dependency(\.uuid) var uuid
  let response: Response
  if request.url.path == "/_/space/session" {
    let callID: ToolCallID
    switch body.removeValue(forKey: "key") {
    case let .string(key)? where !key.isEmpty: callID = ToolCallID("page-key:\(key)")
    case nil, .null?: callID = ToolCallID("page:\(uuid().uuidString.lowercased())")
    default: return errorResponse(.badRequest, code: "invalidArgument", message: "key is a non-empty string")
    }
    let arguments: CreateSessionArguments
    do {
      arguments = try CreateSessionArguments(body: .object(body))
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected createSession options: \(error)")
    }
    response = try await createSessionResponse(hub, as: .page(person), callID, arguments) { created in
      try await sessionCreateOutput(created, store: space.sessions)
    }
  } else {
    let arguments: SendMessageArguments
    do {
      arguments = try JSONValueDecoder().decode(SendMessageArguments.self, from: .object(body))
    } catch {
      return errorResponse(.badRequest, code: "invalidArgument", message: "expected sendMessage options: \(error)")
    }
    response = try await sendMessageResponse(hub, as: .page(person), ToolCallID("page:\(uuid().uuidString.lowercased())"), arguments) { sent in
      try Response.json(ConversationPostOutput(
        messageId: sent.messageID.rawValue, conversationId: sent.conversationID.rawValue, n: Int(sent.n), delivered: [],
      ))
    }
  }
  return response.viewed(by: write.viewer)
}
