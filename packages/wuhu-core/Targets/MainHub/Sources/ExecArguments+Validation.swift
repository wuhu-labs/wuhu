import SessionDomain
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public func execLifetime(_ arguments: ExecArguments) throws -> Double {
  if arguments.timeoutSeconds != nil {
    throw ToolProblem("exec: timeout_seconds is renamed to max_lifetime_seconds", code: "invalidArgument")
  }
  let lifetime = arguments.maxLifetimeSeconds ?? ToolLifetimes.execDefault
  guard lifetime > 0, lifetime <= ToolLifetimes.ceiling else {
    throw ToolProblem("exec: max_lifetime_seconds must be more than 0 and at most \(seconds(.seconds(ToolLifetimes.ceiling)))", code: "invalidArgument")
  }
  return lifetime
}

/// How long the call waits before it returns `running`. Past the lifetime the
/// exec is killed anyway, so the wait stops a little after it, where that end
/// is the call's result.
public func execWait(_ arguments: ExecArguments, lifetime: Double) throws -> Double {
  let wait = arguments.waitSeconds ?? ToolLifetimes.waitDefault
  guard wait > 0 else { throw ToolProblem("exec: wait_seconds must be more than 0", code: "invalidArgument") }
  return min(wait, lifetime + ToolLifetimes.lifetimeSlack)
}

public func execEnvironment(_ arguments: ExecArguments) throws -> ExecEnvironment {
  try execEnvironment(env: arguments.env ?? [:], secrets: arguments.secrets ?? [:])
}
