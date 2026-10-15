#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public actor WorkerCredentials {
  private var current: String
  private var successor: String?
  private var deadline: ContinuousClock.Instant?
  private let now: @Sendable () -> ContinuousClock.Instant
  private let admission: @Sendable (String) -> Bool

  public init(token: String, admission: @escaping @Sendable (String) -> Bool = { _ in true }) throws {
    try Self.validate(token)
    current = token
    now = { .now }
    self.admission = admission
  }

  init(token: String, now: @escaping @Sendable () -> ContinuousClock.Instant) throws {
    try Self.validate(token)
    current = token
    self.now = now
    admission = { _ in true }
  }

  public var outgoingToken: String { successor ?? current }

  func accepts(_ token: String) -> Bool {
    guard admission(token) else { return false }
    if let successor {
      return token == successor || (token == current && deadline.map { now() < $0 } == true)
    }
    return token == current
  }

  public func stage(successor token: String) throws {
    try Self.validate(token)
    if successor == token { return }
    guard successor == nil else { throw WorkerProtocolError(.invalidMessage, message: "Worker credential rotation is already pending") }
    if current == token { return }
    successor = token
    deadline = now().advanced(by: .seconds(10))
  }

  public func confirm(successor token: String) throws {
    if successor == nil, current == token { return }
    guard successor == token else { throw WorkerProtocolError(.unauthorized, message: "Worker successor credential is required") }
    current = token
    successor = nil
    deadline = nil
  }

  func stage(successor: String, authenticatedBy token: String) throws {
    guard accepts(token) else { throw WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted") }
    try stage(successor: successor)
  }

  func confirm(authenticatedBy token: String) throws {
    try confirm(successor: token)
  }

  private static func validate(_ token: String) throws {
    guard !token.isEmpty, token.utf8.count <= 512, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Invalid worker credential")
    }
  }
}

struct WorkerCredentialStage: Codable, Sendable {
  let successor: String
}
