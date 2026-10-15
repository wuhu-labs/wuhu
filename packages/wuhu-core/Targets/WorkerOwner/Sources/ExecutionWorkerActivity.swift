#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import struct WorkerProtocol.WorkerCall

public struct ExecutionWorkerActivity: Codable, Sendable {
  public let session: SessionID
  public let pass: UUID
  public let active: Bool

  public init(session: SessionID, pass: UUID, active: Bool) {
    self.session = session
    self.pass = pass
    self.active = active
  }

  public init(call: WorkerCall) throws {
    self = try ownerDecode(Self.self, call.payload)
  }

  public func call() throws -> WorkerCall {
    WorkerCall(operation: "worker.activity", payload: try ownerEncode(self))
  }
}
