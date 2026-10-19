import Credentials
import SessionDomain
import SpaceContract
import SpaceCore

extension Hub {
  nonisolated public func secretNames(in group: String?, session: SessionID) async throws -> [String] {
    if let group { try SpaceSecrets.validate(group: group) }
    return try await secretStore(in: group, session: session).names()
  }

  nonisolated public func secretValue(_ name: String, in group: String?, session: SessionID) async throws -> String {
    try await secretStore(in: group, session: session).value(of: name)
  }

  nonisolated public func setSecret(_ name: String, value: String, session: SessionID) async throws {
    let acting = try await space.principal(of: session).group
    guard try await space.isAdmin(.session(session), of: acting) else {
      throw ScriptError("setting a secret needs an admin of group \(acting.rawValue)" + (await notAdmin(session, of: acting, space: space)))
    }
    try await secretStore(in: nil, session: session).set(name, to: value)
  }

  nonisolated private func secretStore(in named: String?, session: SessionID) async throws -> SpaceSecrets {
    guard let secrets else { throw ScriptError("this server has no secret store") }
    let acting = try await space.principal(of: session).group
    guard let named, named != acting.rawValue else { return try secrets.group(acting.rawValue) }
    guard try await space.reads(acting).contains(GroupID(rawValue: named)) else {
      throw ScriptError("group \(acting.rawValue) does not read group \(named), so its secrets are out of reach")
    }
    return try secrets.group(named)
  }
}

/// Why `session` is no admin of `group`, worded for the caller: only a live
/// top-level agent of a group administers it.
func notAdmin(_ session: SessionID, of group: GroupID, space: Space) async -> String {
  guard let caller = try? await space.sessions.record(session) else { return "" }
  if caller.kind == .task { return "; a task never is one" }
  if caller.parent != nil { return "; a child agent never is one" }
  if caller.group != group { return "; you are a top-level agent of group \(caller.group.rawValue), not of \(group.rawValue)" }
  return ""
}
