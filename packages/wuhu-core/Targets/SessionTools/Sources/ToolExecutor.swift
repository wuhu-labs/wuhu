import struct MainHub.CancelArguments
import struct MainHub.CreateSessionArguments
import struct MainHub.ExecArguments
import struct MainHub.IncompleteSession
import struct MainHub.ManipulateUIArguments
import struct MainHub.ObserveArguments
import func MainHub.renderedFailure
import struct MainHub.ReportArguments
import struct MainHub.RequestArguments
import enum MainHub.RosterTool
import struct MainHub.SendMessageArguments
import struct MainHub.SetTitleArguments
import struct MainHub.TimerArguments
import struct MainHub.ToolProblem
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import struct ProviderCapabilities.CapabilityError
import SessionDomain
import SpaceClient
import enum SpaceContract.ToolCallHeader
import struct SpaceContract.ToolError
import SpaceCore
import SpaceTools
import TaskLifetime
import struct WuhuAI.InvalidToolArguments
import struct WuhuAI.ToolCall

public struct ToolExecutor: Sendable {
  let main: MainConnection
  let credential: @Sendable (SessionID) async throws -> String
  /// What the worker brings to the inferences it runs itself (the loop's and scripts' `complete()`).
  let access: InferenceAccess
  let cancelScript: @Sendable (SessionID, String) async throws -> ToolResultPayload

  /// `credential` is the token main issued the session; every call the worker
  /// makes to main's API carries it.
  public init(
    main: MainConnection,
    credential: @escaping @Sendable (SessionID) async throws -> String,
    access: InferenceAccess = InferenceAccess(),
    cancelScript: @escaping @Sendable (SessionID, String) async throws -> ToolResultPayload = { _, _ in throw ToolProblem("cancel: scripts are not available here") },
  ) {
    self.main = main
    self.credential = credential
    self.access = access
    self.cancelScript = cancelScript
  }

  /// Main's API as `session`; with `toolCall`, every request names the tool
  /// call it runs for, and main answers a repeat with its first response.
  func client(_ session: SessionID, toolCall: String? = nil) -> SpaceClient {
    client(.session(session), toolCall: toolCall)
  }

  func client(_ actor: ScriptActor, toolCall: String? = nil) -> SpaceClient {
    let main = main
    return SpaceClient(space: "http://main", fetch: FetchClient { request in
      var request = request
      request.headers[.authorization] = "Bearer " + (try await bearer(actor))
      if let toolCall { request.headers[ToolCallHeader.name] = toolCall }
      return try await main.fetch(request)
    }, dial: { url, headers in
      var headers = headers + [("authorization", "Bearer " + (try await bearer(actor)))]
      if let toolCall { headers.append((ToolCallHeader.name, toolCall)) }
      return try await main.dial(url, headers: headers)
    })
  }

  /// `yielded` returns true once the call is told to yield, which makes an exec or a script answer `running`.
  public func execute(session: SessionID, call: ToolCall, state: ToolExecutionState, yielded: @escaping @Sendable () async -> Bool = { false }) async throws -> ToolOutcome {
    guard let tool = RosterTool(rawValue: call.name) else {
      return ToolOutcome(payload: .failure(.init(message: "unknown tool: \(call.name)")))
    }
    if tool.finishesWhenCancelled {
      return try await uncancellable("A tool that ends nothing by stopping runs to its answer") {
        try await answer(session, tool, call, state: state, yielded: yielded)
      }
    }
    try Task.checkCancellation()
    return try await answer(session, tool, call, state: state, yielded: yielded)
  }

  private func answer(_ session: SessionID, _ tool: RosterTool, _ call: ToolCall, state: ToolExecutionState, yielded: @escaping @Sendable () async -> Bool) async throws -> ToolOutcome {
    let (call, touched) = await resolvingMachine(session, tool, call)
    let payload = try await result(session, tool, call, state: state, yielded: yielded)
    if case .failure = payload { return ToolOutcome(payload: payload) }
    return ToolOutcome(payload: payload, context: await deliverContext(session, touching: touched, state: state))
  }

  private func result(_ session: SessionID, _ tool: RosterTool, _ call: ToolCall, state: ToolExecutionState, yielded: @escaping @Sendable () async -> Bool) async throws -> ToolResultPayload {
    do {
      switch tool {
      case .runScript: preconditionFailure("run_script is owned by ScriptJob")
      case .cancel: return try await cancel(session, decoded(CancelArguments.self, call), call: call, state: state)
      case .grep: return try await grep(session, decoded(GrepArguments.self, call))
      case .find: return try await find(session, decoded(FindArguments.self, call))
      case .query: return try await query(session, decoded(QueryArguments.self, call))
      case .read: return try await read(session, decoded(ReadArguments.self, call))
      case .write: return try await write(session, call.id, decoded(WriteArguments.self, call), state: state)
      case .edit: return try await edit(session, call.id, decoded(EditArguments.self, call), state: state)
      case .machines: return try await machines(session, call.id)
      case .templates: return try await templates(session, call.id)
      case .observe: return try await observe(session, call.id, decoded(ObserveArguments.self, call))
      case .timer: return try await timer(session, call.id, decoded(TimerArguments.self, call))
      case .sendMessage:
        return try await sendMessage(.session(session), call.id, decoded(SendMessageArguments.self, call), user: call.arguments.object?["user"])
      case .request: return try await request(.session(session), call.id, decoded(RequestArguments.self, call))
      case .report: return try await report(session, call.id, decoded(ReportArguments.self, call))
      case .createSession: return try await createSession(.session(session), call.id, decoded(CreateSessionArguments.self, call))
      case .setTitle: return try await setTitle(session, call.id, decoded(SetTitleArguments.self, call))
      case .manipulateUI: return try await manipulateUI(session, call.id, decoded(ManipulateUIArguments.self, call))
      case .exec: preconditionFailure("exec is owned by ToolCallJob")
      }
    } catch let error as CapabilityError { return .failure(.init(message: error.description)) }
    catch let error as OperationError { return .failure(.init(message: error.message.isEmpty ? error.code.rawValue : error.message, code: error.code.rawValue)) }
    catch let error as ToolProblem { return .failure(.init(message: error.message, code: error.code)) }
    catch let error as IncompleteCreate { return .failure(.init(message: error.message, code: IncompleteSession.code)) }
    catch let error as ToolRunError { return .failure(.init(message: renderedFailure(error), code: error.payload.object?["code"]?.stringValue)) }
    catch let error as SpaceError { return .failure(.init(message: renderedFailure(Wire.failure(error)))) }
    catch let error as SpaceClient.ToolFailure { return .failure(.init(message: rendered(error.error), code: error.error.code.rawValue)) }
    catch let error as SpaceClient.TransportFailure { return .failure(.init(message: error.message, code: error.code)) }
    catch let error as MainUnavailable { return .failure(.init(message: error.description)) }
    catch is CancellationError { throw CancellationError() }
  }

  private func decoded<Arguments: Decodable>(
    _ type: Arguments.Type,
    _ call: ToolCall,
  ) throws(ToolProblem) -> Arguments {
    do {
      return try call.arguments.decode(type)
    } catch let error as InvalidToolArguments {
      throw ToolProblem("\(call.name): \(error)")
    } catch {
      throw ToolProblem("\(call.name): arguments do not match the tool schema: \(error)")
    }
  }
}

// Main's refusal as the model reads it, the same line `renderedFailure` makes
// of a tool run that failed in process.
private func rendered(_ error: ToolError) -> String {
  var text = "\(error.code.rawValue): \(error.message)"
  if let hint = error.hint { text += " (\(hint))" }
  if let token = error.token { text += " [current token: \(token)]" }
  return text
}
