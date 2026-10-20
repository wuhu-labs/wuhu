import Dependencies
import Fetch
import let MainHub.scriptBufferBytes
import struct MainHub.ScriptError
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import JSONValue
import OrderedCollections
import QuickJSKit
import SpaceClient
import struct SpaceContract.ConversationPostOutput
import SpaceCore
import SpaceTools
import Synchronization

struct ScriptBuffers {
  private var next = 0
  private(set) var held = 0
  private var bodies: [Int: Data] = [:]

  var room: Int {
    scriptBufferBytes - held
  }

  mutating func hold(_ body: Data) throws -> Int {
    held += try reserve(body.count, for: .responseBody)
    next += 1
    bodies[next] = body
    return next
  }

  // Machine output is claimed up front, at its bound: a process's un-acked
  // window, an exec's whole output budget.
  mutating func claim(_ bytes: Int, for buffer: ScriptBuffer) throws {
    held += try reserve(bytes, for: buffer)
  }

  mutating func unclaim(_ bytes: Int) {
    held -= bytes
  }

  mutating func take(_ body: Int) -> Data? {
    guard let data = bodies.removeValue(forKey: body) else { return nil }
    held -= data.count
    return data
  }

  private func reserve(_ bytes: Int, for buffer: ScriptBuffer) throws -> Int {
    guard bytes <= room else { throw overBudget(buffer) }
    return bytes
  }
}

enum ScriptBuffer {
  case fileResult
  case queryResult
  case responseBody
  case processOutput
  case execOutput
}

func overBudget(_ buffer: ScriptBuffer) -> ScriptError {
  let (what, advice) = switch buffer {
  case .fileResult:
    ("file result", "read a smaller file or directory, or read earlier response bodies first")
  case .queryResult:
    ("query result", "narrow the query (fewer columns, a filter, a LIMIT), or read earlier response bodies first")
  case .responseBody:
    ("response body", "read earlier response bodies first")
  case .processOutput:
    ("the 1 MB output window of another machine process", "let earlier processes exit, or read what they buffered")
  case .execOutput:
    ("the output budget of this machine exec", "lower maxOutput, or let other machine work finish first")
  }
  return ScriptError("""
  \(what) does not fit in the \(scriptBufferBytes >> 20) MB this script may buffer (unread response \
  bodies and machine process output together); \(advice)
  """)
}

// The script's own primitives, over main's API as the session where they touch
// the space: channels, conversation pages, DMs, secrets and the identity token.
final class ScriptBindings: Sendable {
  private let execution: ScriptExecution
  private let client: SpaceClient
  private let secrets: ScriptSecrets

  init(execution: ScriptExecution, client: SpaceClient, secrets: ScriptSecrets) {
    self.execution = execution
    self.client = client
    self.secrets = secrets
  }

  func install(in engine: JSEngine) {
    engine.define("__wuhu_result") { [execution, secrets] in
      try execution.recordResult(secrets.mask(string($0, 0)))
      return .null
    }
    engine.define("__wuhu_update") { [execution, secrets] in
      try execution.recordUpdate(secrets.mask(string($0, 0)))
      return .null
    }
    engine.define("__wuhu_console") { [execution, secrets] in
      execution.log(string($0, 0), secrets.mask(string($0, 1)))
      return .null
    }
    engine.define("__wuhu_stopped", keepsAlive: false) { [execution] _ in
      .string(try await execution.nextAbort())
    }
    engine.define("__wuhu_sleep", promising: sleep)
    engine.define("__wuhu_timer", keepsAlive: false, promising: sleep)
    engine.defineCancel("__wuhu_cancel")
    engine.define("__wuhu_channel", promising: { [client] arguments in
      await spaceAnswer { try await channel(arguments, client: client) }
    })
    engine.define("__wuhu_conversation", promising: { [client] arguments in
      try await conversationPage(arguments, client: client)
    })
    engine.define("__wuhu_dm", promising: { [client] arguments in
      guard arguments.count == 2, case let .string(a) = arguments[0], case let .string(b) = arguments[1], !a.isEmpty, !b.isEmpty
      else { throw ScriptError("dm(a, b) wants two session ids") }
      struct Named: Decodable { let id: String? }
      do {
        return try await (client.api(.get, queryPath("/v1/dm", [("a", a), ("b", b)])) as Named).id.map(JSONValue.string) ?? .null
      } catch { throw scriptFailure(error) }
    })
    engine.define("__wuhu_fetch", promising: fetch)
    engine.define("__wuhu_body", body)
    engine.define("__wuhu_secret") { [secrets] arguments in
      let group: String? = if case let .string(named)? = arguments[safe: 1] { named } else { nil }
      return .string(try secrets.placeholder(for: string(arguments, 0), group: group))
    }
    engine.define("__wuhu_secret_set", promising: { [secrets] in
      try await secrets.set(string($0, 0), to: string($0, 1))
      return .null
    })
    engine.define("__wuhu_secret_list", promising: { [secrets] arguments in
      let group: String? = if case let .string(named)? = arguments[safe: 0] { named } else { nil }
      return .array(try await secrets.names(in: group).map(JSONValue.string))
    })
    engine.define("__wuhu_secret_remove", promising: { [secrets] in
      try await secrets.remove(string($0, 0))
      return .null
    })
    engine.define("__wuhu_encode") { .string(Data(string($0, 0).utf8).base64EncodedString()) }
    engine.define("__wuhu_decode") { arguments in
      guard let data = Data(base64Encoded: string(arguments, 0)) else { throw ScriptError("invalid base64") }
      return .string(String(decoding: data, as: UTF8.self))
    }
  }

  private func fetch(_ arguments: [JSONValue]) async throws -> JSONValue {
    guard case let .object(fields)? = arguments.first,
          case let .string(address)? = fields["url"],
          case let .string(method)? = fields["method"]
    else { throw ScriptError("malformed request") }
    if let identity = fields["identity"] {
      guard case .bool = identity else { return fetchFailure("invalidArgument", "identity must be a boolean") }
    }
    let identity = fields["identity"] == .bool(true)
    guard let url = URL(string: try await secrets.reveal(address)), url.scheme == "http" || url.scheme == "https" else {
      throw ScriptError("unsupported URL: \(address)")
    }
    guard let method = HTTPRequest.Method(method) else { throw ScriptError("invalid method: \(method)") }
    var headers = HTTPFields()
    if case let .array(pairs)? = fields["headers"] {
      for case let .array(pair) in pairs {
        guard pair.count == 2, case let .string(name) = pair[0], case let .string(value) = pair[1],
              let field = HTTPField.Name(name)
        else { throw ScriptError("malformed header") }
        headers.append(HTTPField(name: field, value: try await secrets.reveal(value)))
      }
    }
    let body: Body? = switch fields["body"] {
    case let .object(body)?:
      switch (body["text"], body["base64"]) {
      case let (.string(text)?, _): .bytes(Data(try await secrets.reveal(Array(text.utf8))))
      case let (_, .string(base64)?):
        .bytes(Data(try await secrets.reveal(Array(try Data(base64Encoded: base64).orThrow(ScriptError("invalid base64"))))))
      default: throw ScriptError("malformed body")
      }
    default: nil
    }
    @Dependency(\.fetch) var transport
    let request = Request(url: url, method: method, headers: headers, body: body)
    let response: Response
    if identity {
      guard headers[.authorization] == nil else {
        return fetchFailure("invalidArgument", "identity: true cannot be combined with Authorization")
      }
      do {
        response = try await identityResponse(request, client: client) { [secrets] token in
          secrets.protect(token)
          secrets.protect(token.lowercased())
        }
      } catch let error as ScriptIdentityFailure {
        return fetchFailure(error.code, secrets.mask(error.message))
      } catch {
        throw masked(error)
      }
    } else {
      do {
        response = try await transport(request)
      } catch {
        throw masked(error)
      }
    }
    let room = execution.buffers.withLock(\.room)
    let data: Data
    do {
      data = try await response.body.bytes(upTo: room)
    } catch FetchError.bodyLimitExceeded {
      throw overBudget(.responseBody)
    } catch {
      let message = "reading the response body failed: \(error)"
      throw ScriptError(secrets.mask(message))
    }
    let masked = Data(secrets.mask(Array(data)))
    let handle = try execution.buffers.withLock { try $0.hold(masked) }
    return .object([
      "status": .integer(response.status.code),
      "statusText": .string(secrets.mask(response.status.reasonPhrase)),
      "headers": .array(response.headers.map { .array([.string(secrets.mask($0.name.canonicalName)), .string(secrets.mask($0.value))]) }),
      "url": .string(address),
      "body": .integer(handle),
    ])
  }

  private func masked(_ error: any Error) -> any Error {
    let message = String(describing: error)
    let protected = secrets.mask(message)
    return message == protected ? error : ScriptError(protected)
  }

  private func body(_ arguments: [JSONValue]) throws -> JSONValue {
    let handle = int(arguments)
    guard let data = execution.buffers.withLock({ $0.take(handle) }) else {
      throw ScriptError("body has already been read")
    }
    return string(arguments, 1) == "text"
      ? .string(String(decoding: data, as: UTF8.self))
      : .string(data.base64EncodedString())
  }
}

// `channel.create({title, people})` → id; `add`/`remove` `{id, people}` and
// `rename` `{id, title}` → null. The shape is checked here, the act is the
// session's route, whose refusal comes back as the SpaceError.
private func channel(_ arguments: [JSONValue], client: SpaceClient) async throws -> JSONValue {
  guard arguments.count == 2, let operation = arguments[0].stringValue, let fields = arguments[1].object else {
    throw ScriptError("channel operation wants an object")
  }
  func people() throws -> JSONValue {
    guard case let .array(values)? = fields["people"], values.allSatisfy({ $0.stringValue != nil }) else {
      throw ScriptError("people must be an array of person identities")
    }
    return .array(values)
  }
  func title() throws -> JSONValue {
    switch fields["title"] {
    case nil, .null?: .null
    case let .string(value)?: .string(value)
    default: throw ScriptError("title must be a string or null")
    }
  }
  func id() throws -> String {
    guard let id = fields["id"]?.stringValue, !id.isEmpty else { throw ScriptError("channel id must be a nonempty string") }
    return pathSegment(id)
  }
  switch operation {
  case "create":
    guard Set(fields.keys).isSubset(of: ["title", "people"]) else { throw ScriptError("unsupported channel create option") }
    let created: ConversationPostOutput = try await client.api(.post, "/v1/conversation", body: .object(["members": try people(), "title": try title()]))
    return .string(created.conversationId)
  case "add", "remove":
    guard Set(fields.keys).isSubset(of: ["id", "people"]) else { throw ScriptError("unsupported channel member option") }
    _ = try await client.api(.post, "/v1/channel/\(try id())/\(operation)", body: .object(["people": try people()])) as JSONValue
  case "rename":
    guard Set(fields.keys).isSubset(of: ["id", "title"]) else { throw ScriptError("unsupported channel rename option") }
    _ = try await client.api(.post, "/v1/channel/\(try id())/rename", body: .object(["title": try title()])) as JSONValue
  default: throw ScriptError("unknown channel operation")
  }
  return .null
}

// `conversation(id, {after, before, limit})` → `{messages, next}`; the route
// reads the cursors and the limit, the JS shapes are checked here.
private func conversationPage(_ arguments: [JSONValue], client: SpaceClient) async throws -> JSONValue {
  guard case let .string(id)? = arguments.first, !id.isEmpty else {
    throw ScriptError("conversation(id) wants a conversation id: a box is its agent's session id, a DM comes from dm(a, b)")
  }
  let options: OrderedDictionary<String, JSONValue> = switch arguments.dropFirst().first {
  case nil, .null?: [:]
  case let .object(fields)?: fields
  default: throw ScriptError("conversation(id, options) takes options as { after, before, limit }")
  }
  func cursor(_ name: String) throws -> String? {
    switch options[name] {
    case nil, .null?: nil
    case let .string(text)?: text
    default: throw ScriptError("\(name) takes a message id or an ISO time")
    }
  }
  let limit: String? = switch options["limit"] {
  case nil, .null?: nil
  case let .integer(number)?: String(number)
  case let .number(number)? where number.rounded() == number && abs(number) <= 1e9: String(Int(number))
  default: throw ScriptError("limit is a whole number from 1 to 500")
  }
  do {
    return try await client.api(.get, queryPath("/v1/conversation/\(pathSegment(id))/page", [
      ("after", try cursor("after")), ("before", try cursor("before")), ("limit", limit),
    ]))
  } catch { throw scriptFailure(error) }
}

private func sleep(_ arguments: [JSONValue]) async throws -> JSONValue {
  @Dependency(\.continuousClock) var clock
  let milliseconds: Double = switch arguments.first {
  case let .integer(value)?: Double(value)
  case let .number(value)?: value.isFinite ? value : 0
  default: 0
  }
  try await clock.sleep(for: .milliseconds(min(max(0, milliseconds), scriptSecondsCeiling * 1000)))
  return .null
}

func string(_ arguments: [JSONValue], _ index: Int) -> String {
  guard case let .string(text)? = arguments[safe: index] else { return "" }
  return text
}

private func int(_ arguments: [JSONValue]) -> Int {
  guard case let .integer(value)? = arguments.first else { return 0 }
  return value
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

extension Optional {
  fileprivate func orThrow(_ error: some Error) throws -> Wrapped {
    guard let self else { throw error }
    return self
  }
}

private func fetchFailure(_ code: String, _ message: String) -> JSONValue {
  .object(["error": .object(["code": .string(code), "message": .string(message)])])
}
