#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import func MainHub.seconds
import enum MainHub.ToolLifetimes
import struct MainHub.ToolProblem
import SessionDomain
import SpaceCore
import struct WuhuAI.InvalidToolArguments
import struct WuhuAI.ToolCall

public struct ScriptPlan: Codable, Sendable {
  public let source: String
  public let wait: Double
  public let lifetime: Double

  public init(_ call: ToolCall) throws {
    let arguments: Arguments
    do { arguments = try call.arguments.decode(Arguments.self) }
    catch let error as InvalidToolArguments { throw ToolProblem("\(call.name): \(error)") }
    catch { throw ToolProblem("\(call.name): arguments do not match the tool schema: \(error)") }
    if arguments.timeoutSeconds != nil { throw ToolProblem("run_script: timeout_seconds is renamed to wait_seconds", code: "invalidArgument") }
    if arguments.onTimeout != nil { throw ToolProblem("run_script: on_timeout is gone; past wait_seconds a script always runs on, and cancel stops it", code: "invalidArgument") }
    let wait = min(arguments.waitSeconds ?? ToolLifetimes.waitDefault, scriptSecondsCeiling)
    let lifetime = arguments.maxLifetimeSeconds ?? ToolLifetimes.scriptDefault
    guard wait > 0 else { throw ToolProblem("run_script: wait_seconds must be more than 0", code: "invalidArgument") }
    guard lifetime > 0 else { throw ToolProblem("run_script: max_lifetime_seconds must be positive", code: "invalidArgument") }
    guard lifetime <= ToolLifetimes.ceiling else { throw ToolProblem("run_script: max_lifetime_seconds is at most \(seconds(.seconds(ToolLifetimes.ceiling)))", code: "invalidArgument") }
    self.source = arguments.source
    self.wait = wait
    self.lifetime = lifetime
  }

  private struct Arguments: Decodable {
    let source: String
    let waitSeconds: Double?
    let timeoutSeconds: JSONValue?
    let onTimeout: JSONValue?
    let maxLifetimeSeconds: Double?
    enum CodingKeys: String, CodingKey {
      case source
      case waitSeconds = "wait_seconds"
      case timeoutSeconds = "timeout_seconds"
      case onTimeout = "on_timeout"
      case maxLifetimeSeconds = "max_lifetime_seconds"
    }
  }
}

public final class ScriptRuntime: Sendable {
  public struct End: Sendable, Codable {
    public let beforeResult: String
    public let afterResult: String?
  }

  public enum Event: Sendable, Codable {
    case result(String)
    case update(String)
    case ended(End)
  }

  private let execution: ScriptExecution
  private let say: @Sendable (Event) -> Void

  init(id: String, session: SessionID, plan: ScriptPlan, tools: ToolExecutor, scripts: Scripts, say: @escaping @Sendable (Event) -> Void) {
    let client = tools.client(session)
    execution = ScriptExecution(id: id, actor: .session(session), source: plan.source, lifetime: .seconds(plan.lifetime), client: client, secrets: ScriptSecrets(client: client), tools: tools, kind: .job(say), limits: scripts.limits)
    self.say = say
  }

  public var consoleTail: String { execution.consoleTail }
  public func abort(lifetime: Bool) { execution.abortForJob(lifetime: lifetime) }
  public func kill() { execution.killForJob() }

  @concurrent public func run() async {
    await execution.run()
    say(.ended(execution.termination))
  }
}

extension Scripts {
  public func runtime(id: String, session: SessionID, plan: ScriptPlan, tools: ToolExecutor, say: @escaping @Sendable (ScriptRuntime.Event) -> Void) -> ScriptRuntime {
    ScriptRuntime(id: id, session: session, plan: plan, tools: tools, scripts: self, say: say)
  }
}
