#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import struct MainHub.CreateSessionArguments
import struct MainHub.IncompleteSession
import struct MainHub.ManipulateUIArguments
import struct MainHub.ReportArguments
import struct MainHub.RequestArguments
import struct MainHub.RequestTermsArguments
import struct MainHub.SendMessageArguments
import struct MainHub.SetTitleArguments
import struct MainHub.ToolProblem
import OrderedCollections
import SessionDomain
import SpaceContract
import SpaceCore

// A create that left a session behind unfinished (its template not cloned,
// its brief not handed over): the id is the session, and a retry of the same
// call finishes it.
struct IncompleteCreate: Error {
  let id: String
  let message: String
}

// The session verbs, run in the worker as plain calls on main's API. Every
// call names the tool call it runs for, so main answers a retry with the first
// result: the message, request, session or slot is made once.
extension ToolExecutor {
  func sendMessage(_ session: SessionID, _ call: String, _ arguments: SendMessageArguments, user: JSONValue? = nil) async throws -> ToolResultPayload {
    var body: OrderedDictionary<String, JSONValue> = ["message": .string(arguments.message)]
    body["conversation"] = arguments.conversation.map(JSONValue.string)
    body["session"] = arguments.session.map(JSONValue.string)
    body["replyTarget"] = arguments.replyTarget.map(JSONValue.string)
    body["attachments"] = arguments.attachments.map { .array($0.map(JSONValue.string)) }
    body["user"] = user
    let sent: ConversationPostOutput = try await verb(session, call, .post, "/v1/conversation/message", body: .object(body))
    return .sendMessage(.init(
      messageID: MessageID(sent.messageId), conversationID: ConversationID(sent.conversationId), n: Int64(sent.n),
      replyTarget: arguments.replyTarget.map { MessageID($0) },
    ))
  }

  func request(_ session: SessionID, _ call: String, _ arguments: RequestArguments) async throws -> ToolResultPayload {
    var body: OrderedDictionary<String, JSONValue> = ["message": .string(arguments.message)]
    body["deadlineSeconds"] = arguments.deadlineSeconds.map(JSONValue.number)
    body["stallSeconds"] = arguments.stallSeconds.map(JSONValue.number)
    body.merge(arguments.terms.body) { $1 }
    let opened: SessionRequestOutput = try await verb(session, call, .post, "/v1/session/\(arguments.task)/request", body: .object(body))
    return .request(.init(
      requestID: RequestID(opened.requestId), task: SessionID(opened.task), conversationID: ConversationID(opened.conversationId),
      deadline: opened.deadline.map { Date(timeIntervalSince1970: $0) }, existing: opened.existing,
    ))
  }

  func report(_ session: SessionID, _ call: String, _ arguments: ReportArguments) async throws -> ToolResultPayload {
    guard let kind = MessageKind(rawValue: arguments.kind) else {
      throw ToolProblem("report kind is progress or final; got \(arguments.kind)")
    }
    let reported: RequestReportOutput = try await verb(
      session, call, .post, "/v1/request/\(arguments.requestID)/report",
      body: .object(["kind": .string(arguments.kind), "content": .string(arguments.content)]),
    )
    return .report(.init(
      messageID: MessageID(reported.messageId), requestID: RequestID(arguments.requestID), conversationID: ConversationID(reported.conversationId), kind: kind,
    ))
  }

  func createSession(_ session: SessionID, _ call: String, _ arguments: CreateSessionArguments) async throws -> ToolResultPayload {
    var body: OrderedDictionary<String, JSONValue> = ["title": .string(arguments.title)]
    body["kind"] = arguments.kind.map(JSONValue.string)
    body["executor"] = arguments.executor.map(JSONValue.string)
    body["topLevel"] = arguments.topLevel.map(JSONValue.bool)
    body["group"] = arguments.group.map(JSONValue.string)
    body["provider"] = arguments.provider.map(JSONValue.string)
    body["model"] = arguments.model.map(JSONValue.string)
    body["modelGroup"] = arguments.modelGroup.map(JSONValue.string)
    body["effort"] = arguments.effort.map(JSONValue.string)
    body["tags"] = arguments.tags.map { .array($0.map(JSONValue.string)) }
    body["template"] = arguments.template.map(JSONValue.string)
    body["expectsReply"] = arguments.expectsReply.map(JSONValue.bool)
    body["message"] = arguments.message.map(JSONValue.string)
    body["stallSeconds"] = arguments.stallSeconds.map(JSONValue.number)
    body["request"] = arguments.request.map { .object($0.body) }
    let created: SessionCreateOutput = try await verb(session, call, .post, "/v1/session", body: .object(body)) { fields in
      guard fields.object?["code"]?.stringValue == IncompleteSession.code, let id = fields.object?["id"]?.stringValue else { return nil }
      return IncompleteCreate(id: id, message: fields.object?["message"]?.stringValue ?? "session \(id) was created, but not finished")
    }
    // A routed session reports the member it landed on; a concrete one
    // reports nothing beyond what was asked.
    return .createSession(.init(
      sessionID: SessionID(created.id), title: created.title, requestID: created.requestId.map { RequestID($0) }, existing: created.existing,
      modelGroup: created.modelGroup, member: created.member,
      provider: created.modelGroup == nil ? nil : created.provider, model: created.modelGroup == nil ? nil : created.model,
    ))
  }

  func setTitle(_ session: SessionID, _ call: String, _ arguments: SetTitleArguments) async throws -> ToolResultPayload {
    let titled: SessionTitleOutput = try await verb(session, call, .post, "/v1/session/\(session.rawValue)/title", body: .object(["title": .string(arguments.title)]))
    return .setTitle(.init(title: titled.title))
  }

  func manipulateUI(_ session: SessionID, _ call: String, _ arguments: ManipulateUIArguments) async throws -> ToolResultPayload {
    let issued: DeviceCommandOutput = try await verb(session, call, .post, "/v1/device/\(arguments.device)/command", body: .object(["payload": arguments.payload]))
    return .manipulateUI(.init(device: arguments.device, n: Int64(issued.n)))
  }

  /// One verb on main's API as `session`, for tool call `call`. A refusal
  /// comes back as the tool's own failure: main's `{code, message}` with the
  /// plain `refused` code dropped, since that is a failure with no code; a
  /// verb with a typed refusal of its own reads it from the fields first.
  func verb<Output: Decodable>(
    _ session: SessionID,
    _ call: String,
    _ method: Fetch.Method,
    _ path: String,
    body: JSONValue? = nil,
    refused: (JSONValue) -> (any Error)? = { _ in nil },
  ) async throws -> Output {
    guard let url = URL(string: "http://main" + path) else { throw ToolProblem("malformed route: \(path)") }
    var request = Request(url: url, method: method)
    request.headers[.authorization] = "Bearer " + (try await credential(session))
    request.headers[ToolCallHeader.name] = call
    if let body {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    let response = try await main.fetch(request)
    let text = try await response.text()
    let fields = JSONValue.parse(text)
    guard 200 ..< 300 ~= response.status.code else {
      if let fields, let typed = refused(fields) { throw typed }
      let code = fields?.object?["code"]?.stringValue
      throw ToolProblem(fields?.object?["message"]?.stringValue ?? "HTTP \(response.status.code): \(text)", code: code == "refused" ? nil : code)
    }
    guard let fields else { throw ToolProblem("HTTP \(response.status.code): invalid JSON response") }
    return try JSONValueDecoder().decode(Output.self, from: fields)
  }
}

extension RequestTermsArguments {
  fileprivate var body: OrderedDictionary<String, JSONValue> {
    var body: OrderedDictionary<String, JSONValue> = [:]
    body["kind"] = kind.map(JSONValue.string)
    body["key"] = key.map(JSONValue.string)
    body["schema"] = schema
    body["fields"] = fields
    return body
  }
}
