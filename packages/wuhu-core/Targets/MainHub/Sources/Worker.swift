#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct FetchSSE.SSEEvent
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.ScriptOutput
import SpaceCore

/// How main knows a worker: minted by main with the worker's credential,
/// presented back when the worker announces itself.
public struct WorkerID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// No worker has announced itself, so a session's verb has nowhere to go.
public struct NoWorkerError: Error, CustomStringConvertible {
  public init() {}
  public var description: String { "no worker is announced to main" }
}

/// Main could not reach a worker for now: none is announced, or the line to
/// the one holding the session closed. A worker announcing (again) ends it,
/// so the verb is retried, never failed.
public func isWorkerUnreachable(_ error: any Error) -> Bool {
  error is NoWorkerError || error is WorkerLineSevered
}

public enum WorkerInput: Sendable, Codable {
  case wake, interrupt, resume, reload, archived
}

public enum RevocationPolicy: Sendable, Codable {
  /// Once the turn is over: archive and restart take a settled session.
  case whenSettled
  /// At the end of the step in flight, for the session to go on elsewhere:
  /// an inference or a script finishes here first; an exec is left pending,
  /// and the next worker rejoins it. What the loop knows is in the store.
  case handOff
  case cancel
}

/// How a running script is named to its session (`script.<id>`).
public func scriptHandle(_ id: String) -> String { "script.\(id)" }

public struct ScriptRunID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WorkerActivity: Sendable {
  public let scripts: [ScriptRunID: SessionID]

  public init(scripts: [ScriptRunID: SessionID]) {
    self.scripts = scripts
  }
}

public struct ScriptHandlerResult: Sendable {
  public let stateJSON: String
  public let wakes: [String]
  public init(stateJSON: String, wakes: [String]) {
    self.stateJSON = stateJSON
    self.wakes = wakes
  }
}

public struct ScriptHandlerInvocation: Sendable {
  public enum Input: Sendable {
    case rows(Rows)
    case timer(Date)
    case event(SSEEvent)
  }

  /// Whom the handler runs as: its session, or its group's observer in this
  /// firing.
  public enum Runner: Hashable, Sendable {
    case session(SessionID)
    case observer(Observer)
  }

  public let id: UUID
  public let path: String
  public let runner: Runner
  public let input: Input
  public let stateJSON: String?
  /// What an observer's handler calls main with, minted for this firing
  /// alone by whoever hands the invocation to a worker.
  public var token: String?

  public init(id: UUID, path: String, runner: Runner, input: Input, stateJSON: String?, token: String? = nil) {
    self.id = id
    self.path = path
    self.runner = runner
    self.input = input
    self.stateJSON = stateJSON
    self.token = token
  }

  /// The id the handler's script runs under, and owns its machine processes by.
  public var scriptID: String { Self.scriptID(id) }

  public static func scriptID(_ id: UUID) -> String { "handler-" + id.uuidString.lowercased() }
}

/// A file run as a space script by its session, from the CLI (`wuhu script`).
public struct ScriptRun: Sendable, Codable, Equatable {
  public let session: SessionID
  public let group: GroupID
  public let source: String
  public let arguments: [String]

  public init(session: SessionID, group: GroupID, source: String, arguments: [String]) {
    self.session = session
    self.group = group
    self.source = source
    self.arguments = arguments
  }
}

/// What main asks of a worker. A worker runs from when it is made until
/// `shutdown`; main never runs it, and never executes a tool.
public protocol Worker: Sendable {
  func deliver(_ session: SessionID, _ input: WorkerInput) async throws
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool
  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  /// Runs `script` until it ends, `output` taking what it says as it says it;
  /// cancelling the call kills it.
  func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws
  func activity() async -> WorkerActivity
  /// The cancel ids of what runs for the session outside its loop
  /// (`script.<id>`, `exec.<id>`), as a Start over lists them.
  func runningWork(_ session: SessionID) async throws -> [String]
  func shutdown() async
}
