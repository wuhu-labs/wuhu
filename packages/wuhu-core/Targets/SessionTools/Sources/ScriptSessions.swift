import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import QuickJSKit
import SessionDomain
import SpaceCore
import SpaceTools

// wuhu:session: create sessions, open requests on them, and the operator verbs
// over the calling session and its descendants; archive and unarchive also
// reach a session it created and, from a top-level agent, any session of its
// group. Every call is checked when it runs, against the script's session as
// it stands then.
struct ScriptSessions {
  let session: SessionID
  let tools: ToolExecutor

  private struct CreateOptions: Decodable {
    var executor: String?
    var title: String
    var kind: String?
    var topLevel: Bool?
    var group: String?
    var provider: String?
    var model: String?
    var effort: String?
    var template: String?
    var tags: [String]?
    var message: String?
    var expectsReply: Bool?
    var key: String?
  }

  func install(in engine: JSEngine) throws {
    engine.define("__wuhu_session_create", promising: { [session, tools] arguments in
      try await scripted {
        let options = try decoded(CreateOptions.self, arguments.first)
        try await tools.refuseUnlessLive(session)
        let callID: ToolCallID
        if let key = options.key {
          guard !key.isEmpty else { throw ToolProblem("createSession: key is a non-empty string") }
          callID = ToolCallID("script-key:\(key)")
        } else {
          @Dependency(\.uuid) var uuid
          callID = ToolCallID("script:\(uuid().uuidString.lowercased())")
        }
        let spawned: Spawned
        do {
          spawned = try await tools.spawn(session, callID, SpawnOrder(
            executor: options.executor,
            title: options.title,
            kind: options.kind,
            topLevel: options.topLevel ?? false,
            group: options.group,
            provider: options.provider,
            model: options.model,
            effort: options.effort,
            tags: options.tags,
            template: options.template,
            expectsReply: options.expectsReply ?? false,
            message: options.message,
          ))
        } catch let error as ExecutorUnavailableError {
          return .object(["error": .string(error.description), "code": "executorNoLongerSupported"])
        } catch let problem as ToolProblem {
          throw ToolProblem("createSession: \(problem.message)")
        }
        var made: OrderedDictionary<String, JSONValue> = ["id": .string(spawned.id.rawValue)]
        if let requestID = spawned.requestID {
          made["requestId"] = .string(requestID.rawValue)
        }
        if let unfinished = spawned.unfinished {
          made["error"] = .string("createSession: session \(spawned.id.rawValue) was created, but \(unfinished)")
        }
        return .object(made)
      }
    })
    engine.define("__wuhu_session_request", promising: { [session, tools] arguments in
      try await scripted {
        guard case let .string(task)? = arguments[safe: 0], case let .string(message)? = arguments[safe: 1] else {
          throw ToolProblem("request(id, message, { deadlineSeconds }) wants a session id and a message")
        }
        let deadline: Double? = switch arguments[safe: 2] {
        case let .integer(seconds)?: Double(seconds)
        case let .number(seconds)?: seconds
        default: nil
        }
        try await tools.refuseUnlessLive(session)
        @Dependency(\.uuid) var uuid
        let result = try await tools.request(
          session,
          ToolCallID("script:\(uuid().uuidString.lowercased())"),
          RequestArguments(task: task, message: message, deadlineSeconds: deadline),
        )
        guard case let .request(opened) = result else {
          preconditionFailure("request answered with \(result)")
        }
        return .object(["requestId": .string(opened.requestID.rawValue)])
      }
    })
    engine.define("__wuhu_session_tags", promising: { [session, tools] arguments in
      try await scripted {
        guard case let .string(target)? = arguments[safe: 0], case let .array(values)? = arguments[safe: 1] else {
          throw ToolProblem("setTags(id, tags) wants a session id and an array of strings")
        }
        let tags = try values.map { value in
          guard case let .string(tag) = value else { throw ToolProblem("setTags: every tag is a string") }
          return tag
        }
        try await tools.setTags(session, of: SessionID(target), to: tags)
        return .null
      }
    })
    engine.define("__wuhu_session_control", promising: { [session, tools] arguments in
      try await scripted {
        guard case let .string(raw)? = arguments[safe: 0], let verb = SessionControl.Verb(rawValue: raw),
              case let .string(target)? = arguments[safe: 1]
        else {
          throw ToolProblem("\(verbName(arguments[safe: 0])) wants a session id")
        }
        let force: Bool
        switch arguments[safe: 2] {
        case .bool(let value)?: force = value
        case nil: force = false
        default: throw ToolProblem("archive: force must be a boolean")
        }
        try await tools.control(verb, session, of: SessionID(target), force: force)
        return .null
      }
    })
    try engine.defineModule("wuhu:session", source: sessionModule)
  }
}

private func verbName(_ value: JSONValue?) -> String {
  if case let .string(text)? = value { text } else { "a session verb" }
}

private func decoded<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
  guard let value, case .object = value else {
    throw ToolProblem("createSession wants an options object: { title, kind, topLevel, ... }")
  }
  do {
    return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
  } catch let DecodingError.keyNotFound(key, _) {
    throw ToolProblem("createSession needs \(key.stringValue)")
  } catch let DecodingError.typeMismatch(_, context) {
    throw ToolProblem("createSession: \(context.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type")
  } catch {
    throw ToolProblem("createSession: malformed options: \(error)")
  }
}

private func scripted(_ body: () async throws -> JSONValue) async throws -> JSONValue {
  do {
    return try await body()
  } catch let problem as ToolProblem {
    throw ScriptError(problem.message)
  } catch is CancellationError {
    throw CancellationError()
  } catch {
    throw ScriptError(renderedFailure(Wire.failure(error)))
  }
}

private let sessionModule = #"""
import { failure } from "wuhu:space-core"
const discover = __wuhu_discovery
const create = __wuhu_session_create
const ask = __wuhu_session_request
const retag = __wuhu_session_tags
const act = __wuhu_session_control

export async function toolRoster() {
  const reply = await discover("toolRoster")
  if (reply.error) throw failure(reply.error)
  return reply.ok
}

export async function createSession(options) {
  if (options === null || typeof options !== "object") {
    throw new TypeError("createSession needs { title, kind, topLevel, group, provider, model, effort, template, tags, message, expectsReply, key }")
  }
  const made = await create(options)
  if (made.error !== undefined) {
    const error = new Error(made.error)
    if (made.id !== undefined) error.id = made.id
    if (made.code !== undefined) error.code = made.code
    throw error
  }
  return made.requestId === undefined ? { id: made.id } : { id: made.id, requestId: made.requestId }
}

export function request(id, message, { deadlineSeconds } = {}) {
  return ask(String(id), String(message), deadlineSeconds ?? null)
}

export async function setTags(id, tags) {
  if (!Array.isArray(tags)) throw new TypeError("setTags(id, tags) wants an array of strings")
  await retag(String(id), tags)
}

export async function archive(id, { force = false } = {}) {
  await act("archive", String(id), force)
}

export async function unarchive(id) {
  await act("unarchive", String(id))
}

export async function interrupt(id) {
  await act("interrupt", String(id))
}

export async function resume(id) {
  await act("resume", String(id))
}
"""#
