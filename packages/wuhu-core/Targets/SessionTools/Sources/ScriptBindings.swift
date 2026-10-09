import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import JSONValue
import QuickJSKit
import SpaceCore
import SpaceTools
import Synchronization

// Server memory the engine's own memory limit never sees. This caps
// everything one execution holds there: every unread fetched body, the output
// window of every machine process and the output budget of every running
// machine exec; a query result, read whole before it reaches the engine, and
// the query tool's one result must fit in what is left.
let scriptBufferBytes = 64 << 20

struct ScriptError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) {
    self.description = description
  }
}

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

final class ScriptBindings: Sendable {
  private let execution: ScriptExecution
  private let space: Space
  private let secrets: ScriptSecrets

  init(execution: ScriptExecution, space: Space, secrets: ScriptSecrets) {
    self.execution = execution
    self.space = space
    self.secrets = secrets
  }

  func install(in engine: JSEngine) {
    engine.define("__wuhu_result") { [execution, secrets] in
      execution.recordResult(secrets.mask(string($0, 0)))
      return .null
    }
    engine.define("__wuhu_update") { [execution, secrets] in
      execution.recordUpdate(secrets.mask(string($0, 0)))
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
    engine.define("__wuhu_conversation", promising: { [space, execution] in
      try await conversationPage($0, in: space, reader: execution.session)
    })
    engine.define("__wuhu_dm", promising: { [space, execution] in
      try await directMessage($0, in: space, reader: execution.session)
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
    @Dependency(\.fetch) var client
    let response = try await client(Request(url: url, method: method, headers: headers, body: body))
    let room = execution.buffers.withLock(\.room)
    let data: Data
    do {
      data = try await response.body.bytes(upTo: room)
    } catch FetchError.bodyLimitExceeded {
      throw overBudget(.responseBody)
    } catch {
      throw ScriptError("reading the response body failed: \(error)")
    }
    let masked = Data(secrets.mask(Array(data)))
    let handle = try execution.buffers.withLock { try $0.hold(masked) }
    return .object([
      "status": .integer(response.status.code),
      "statusText": .string(secrets.mask(response.status.reasonPhrase)),
      "headers": .array(response.headers.map { .array([.string($0.name.canonicalName), .string(secrets.mask($0.value))]) }),
      "url": .string(address),
      "body": .integer(handle),
    ])
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
