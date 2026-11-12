#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.ScriptOutput
import SpaceCore

/// How a running script is named to its session (`script.<id>`).
public func scriptHandle(_ id: String) -> String { "script.\(id)" }

public struct ScriptHandlerResult: Sendable {
  public let wakes: [String]
  public init(wakes: [String]) {
    self.wakes = wakes
  }
}

/// The id a handler firing's script runs under, and owns its machine processes by.
public func handlerScriptID(_ firing: UUID) -> String { "handler-" + firing.uuidString.lowercased() }

/// A file run as a space script from the CLI (`wuhu script`): by a session
/// from its exec, or by a signed-in person from a terminal.
public struct ScriptRun: Sendable, Codable, Equatable {
  public enum Runner: Sendable, Codable, Equatable {
    case session(SessionID, group: GroupID)
    case person(TerminalRun)
  }

  public let runner: Runner
  public let source: String
  public let arguments: [String]
  /// What a terminal run calls main with, minted for this run alone by
  /// whoever hands it to a worker.
  public var token: String?

  public init(runner: Runner, source: String, arguments: [String], token: String? = nil) {
    self.runner = runner
    self.source = source
    self.arguments = arguments
    self.token = token
  }
}

/// A person's terminal script: the id its machine processes are owned by and
/// its inferences name as their firing, the person, the group it acts in and
/// the person's own group its inferences are attributed to.
public struct TerminalRun: Hashable, Sendable, Codable {
  public let id: String
  public let persona: String
  public let account: AccountID
  public let group: GroupID
  public let personalGroup: GroupID

  public init(id: String, persona: String, account: AccountID, group: GroupID, personalGroup: GroupID) {
    self.id = id
    self.persona = persona
    self.account = account
    self.group = group
    self.personalGroup = personalGroup
  }

  public var person: Person { Person(persona: persona, account: account, group: group) }
}
