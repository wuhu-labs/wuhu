import Dependencies
import struct MainHub.CreateSessionArguments
import struct MainHub.IncompleteSession
import func MainHub.renderedFailure
import struct MainHub.RequestArguments
import struct MainHub.RequestTermsArguments
import struct MainHub.ScriptError
import func MainHub.seconds
import struct MainHub.SendMessageArguments
import struct MainHub.ToolProblem
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import QuickJSKit
import SessionDomain
import struct SpaceClient.SpaceClient
import SpaceCore
import SpaceTools

// wuhu:session: create sessions, open requests on them, and the operator verbs
// over the calling session and its descendants; archive and unarchive also
// reach a session it created and, from a top-level agent, any session of its
// group. Every call is checked when it runs, against the script's session as
// it stands then.
struct ScriptSessions {
  let actor: ScriptActor
  let tools: ToolExecutor

  func install(in engine: JSEngine) {
    engine.define("__wuhu_session_create", promising: { [actor, tools] arguments in
      try await scripted {
        guard case let .object(options)? = arguments.first else {
          throw ToolProblem("createSession wants an options object: { title, kind, topLevel, ... }")
        }
        @Dependency(\.uuid) var uuid
        let callID = "script:\(uuid().uuidString.lowercased())"
        let reply: ToolResultPayload
        do {
          reply = try await tools.createSession(actor, callID, createArguments(.object(options)))
        } catch let problem as ToolProblem {
          throw ToolProblem(scriptNamed(problem.message), code: problem.code)
        } catch let incomplete as IncompleteCreate {
          throw IncompleteCreate(id: incomplete.id, message: scriptNamed(incomplete.message))
        }
        guard case let .createSession(spawned) = reply else { preconditionFailure("create_session returned \(reply)") }
        var made: OrderedDictionary<String, JSONValue> = ["id": .string(spawned.sessionID.rawValue)]
        if let group = spawned.modelGroup { made["modelGroup"] = .string(group) }
        if let member = spawned.member { made["member"] = .string(member) }
        if let provider = spawned.provider { made["provider"] = .string(provider) }
        if let model = spawned.model { made["model"] = .string(model) }
        if let requestID = spawned.requestID {
          made["requestId"] = .string(requestID.rawValue)
        }
        return .object(made)
      }
    })
    engine.define("__wuhu_session_send", promising: { [actor, tools] arguments in
      try await scripted {
        guard case let .object(options)? = arguments.first else { throw ToolProblem("sendMessage wants an options object") }
        let allowed: Set<String> = ["message", "conversation", "session", "reply_target", "attachments"]
        guard Set(options.keys).isSubset(of: allowed) else { throw ToolProblem("sendMessage: unsupported options") }
        let input = try JSONDecoder().decode(SendMessageArguments.self, from: Data(JSONValue.object(options).jsonString().utf8))
        @Dependency(\.uuid) var uuid
        let reply = try await tools.sendMessage(actor, "script:\(uuid().uuidString.lowercased())", input)
        guard case let .sendMessage(sent) = reply else { preconditionFailure("send_message returned \(reply)") }
        return .object(["messageId": .string(sent.messageID.rawValue), "conversationId": .string(sent.conversationID.rawValue)])
      }
    })
    engine.define("__wuhu_session_request", promising: { [actor, tools] arguments in
      try await scripted {
        guard case let .string(task)? = arguments[safe: 0], case let .string(message)? = arguments[safe: 1] else {
          throw ToolProblem("request(id, message, { stallSeconds, schema, fields }) wants a session id and a message")
        }
        func seconds(_ value: JSONValue?) -> Double? {
          switch value {
          case let .integer(seconds)?: Double(seconds)
          case let .number(seconds)?: seconds
          default: nil
          }
        }
        @Dependency(\.uuid) var uuid
        let result = try await tools.request(
          actor,
          "script:\(uuid().uuidString.lowercased())",
          RequestArguments(
            task: task, message: message, stallSeconds: seconds(arguments[safe: 2]),
            terms: try decoded(RequestTermsArguments.self, arguments[safe: 3], in: "request"),
          ),
        )
        guard case let .request(opened) = result else {
          preconditionFailure("request answered with \(result)")
        }
        return .object(["requestId": .string(opened.requestID.rawValue)])
      }
    })
    engine.define("__wuhu_session_tags", promising: { [actor, tools] arguments in
      try await scripted {
        let session = try ownSession(actor)
        guard case let .string(target)? = arguments[safe: 0], case let .array(values)? = arguments[safe: 1] else {
          throw ToolProblem("setTags(id, tags) wants a session id and an array of strings")
        }
        let tags = try values.map { value in
          guard case let .string(tag) = value else { throw ToolProblem("setTags: every tag is a string") }
          return tag
        }
        do {
          let _: JSONValue = try await tools.client(session).api(.post, "/v1/session/\(pathSegment(target))/tags", body: .object(["tags": .array(tags.map(JSONValue.string))]))
        } catch { throw scriptFailure(error) }
        return .null
      }
    })
    engine.define("__wuhu_session_control", promising: { [actor, tools] arguments in
      try await scripted {
        let session = try ownSession(actor)
        guard case let .string(verb)? = arguments[safe: 0], ["archive", "unarchive", "interrupt", "resume"].contains(verb),
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
        do {
          let _: JSONValue = try await tools.client(session).api(.post, "/v1/session/\(pathSegment(target))/\(verb)", body: verb == "archive" ? .object(["force": .bool(force)]) : nil)
        } catch { throw scriptFailure(error) }
        return .null
      }
    })
    engine.define("__wuhu_session_cancel", promising: { [actor, tools] arguments in
      try await scripted {
        let session = try ownSession(actor)
        guard case let .string(id)? = arguments.first else { throw ToolProblem("cancel(id) wants an id", code: "invalidArgument") }
        switch try await tools.cancel(session, id: id) {
        case let .failure(failure):
          throw ToolProblem(failure.message, code: failure.code ?? "invalidArgument")
        case let payload:
          return .object(["id": .string(id), "message": .string(payload.renderedText)])
        }
      }
    })
    engine.define("__wuhu_session_observer", promising: { [actor, tools] arguments in
      try await scripted {
        let session = try ownSession(actor)
        guard case let .string(verb)? = arguments[safe: 0], case let .string(group)? = arguments[safe: 1], !group.isEmpty else {
          throw ToolProblem("\(verbName(arguments[safe: 0])) wants a group id or alias", code: "invalidArgument")
        }
        let path = "/v1/group/\(pathSegment(group))/observers"
        do {
          switch (verb, arguments[safe: 2]) {
          case let ("createObserver", options?):
            return try await tools.client(session).api(.post, path, body: options)
          case let ("cancelObserver", .string(name)?):
            return try await tools.client(session).api(.delete, "\(path)/\(pathSegment(name))")
          case ("observers", _):
            let listed: JSONValue = try await tools.client(session).api(.get, path)
            guard case let .object(fields) = listed, let observers = fields["observers"] else { throw ToolProblem("observers: the server answered \(listed.jsonString())") }
            return observers
          default:
            throw ToolProblem("\(verb) wants \(verb == "cancelObserver" ? "an observer name" : "an options object")", code: "invalidArgument")
          }
        } catch let failure as SpaceClient.ToolFailure {
          throw ToolProblem(failure.error.message, code: failure.error.code.rawValue)
        }
      }
    })
  }
}

private func ownSession(_ actor: ScriptActor) throws -> SessionID {
  guard let session = actor.session else { throw ToolProblem("a script without a session has createSession, sendMessage and request; the other verbs act on a session's own tree", code: "invalidArgument") }
  return session
}

private func verbName(_ value: JSONValue?) -> String {
  if case let .string(text)? = value { text } else { "a session verb" }
}

// The tool's failure, named as the script's function.
private func scriptNamed(_ message: String) -> String {
  message.hasPrefix("create_session: ") ? "createSession: " + message.dropFirst("create_session: ".count) : message
}

private func createArguments(_ options: JSONValue) throws -> CreateSessionArguments {
  try decoding(in: "createSession") { try CreateSessionArguments(body: options) }
}

private func decoded<T: Decodable>(_ type: T.Type, _ value: JSONValue?, in verb: String) throws -> T {
  guard let value, case .object = value else {
    throw ToolProblem("\(verb) wants an options object")
  }
  return try decoding(in: verb) { try JSONValueDecoder().decode(type, from: value) }
}

private func decoding<T>(in verb: String, _ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let DecodingError.keyNotFound(key, _) {
    throw ToolProblem("\(verb) needs \(key.stringValue)")
  } catch let DecodingError.typeMismatch(_, context) {
    throw ToolProblem("\(verb): \(context.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type")
  } catch {
    throw ToolProblem("\(verb): malformed options: \(error)")
  }
}

private func scripted(_ body: () async throws -> JSONValue) async throws -> JSONValue {
  do {
    return try await body()
  } catch let problem as ToolProblem {
    if let code = problem.code { return .object(["error": .string(problem.message), "code": .string(code)]) }
    throw ScriptError(problem.message)
  } catch let incomplete as IncompleteCreate {
    return .object(["error": .string(incomplete.message), "code": .string(IncompleteSession.code), "id": .string(incomplete.id)])
  } catch is CancellationError {
    throw CancellationError()
  } catch let failure as ScriptError {
    throw failure
  } catch {
    throw ScriptError(renderedFailure(Wire.failure(error)))
  }
}
