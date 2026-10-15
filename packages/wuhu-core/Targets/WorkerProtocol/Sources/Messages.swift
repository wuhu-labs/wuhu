import ServerTelemetry
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue

public struct WorkerProtocolError: Error, Codable, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case incompatibleABI, missingCapability, invalidMessage, unauthorized, notNegotiated
    case unavailable, invalidConfiguration, remoteFailure, capacityExceeded
    case unknownOutcome, consumedReceipt, cancelled
  }

  public let code: Code
  public let message: String
  public init(_ code: Code, message: String) { self.code = code; self.message = message }
}

public struct WorkerHello: Codable, Equatable, Sendable {
  public static let baseline: Set<String> = ["owner.control.v1", "owner.bytes.v1"]
  public let abis: [Int]
  public let capabilities: Set<String>
  public let required: Set<String>
  public let release: String
  public let continuityID: UUID?
  public init(abis: [Int] = [1], capabilities: Set<String> = baseline, required: Set<String> = baseline, release: String, continuityID: UUID? = nil) {
    self.abis = abis; self.capabilities = capabilities; self.required = required; self.release = release; self.continuityID = continuityID
  }

  public func retainingReplies(_ id: UUID) -> Self {
    .init(abis: abis, capabilities: capabilities.union(["owner.continuity.v1"]), required: required, release: release, continuityID: id)
  }

  public func negotiate(with peer: Self) throws -> WorkerAgreement {
    guard abis.contains(1), peer.abis.contains(1) else {
      throw WorkerProtocolError(.incompatibleABI, message: "No supported execution ABI intersection (supported: 1)")
    }
    let agreed = capabilities.intersection(peer.capabilities)
    let missing = required.union(peer.required).subtracting(agreed)
    guard missing.isEmpty else {
      throw WorkerProtocolError(.missingCapability, message: "Missing execution capabilities: \(missing.sorted().joined(separator: ", "))")
    }
    return WorkerAgreement(abi: 1, capabilities: agreed)
  }
}

public struct WorkerAgreement: Codable, Equatable, Sendable {
  public let abi: Int
  public let capabilities: Set<String>
  public init(abi: Int, capabilities: Set<String>) { self.abi = abi; self.capabilities = capabilities }
}

public struct WorkerReceipt: Codable, Equatable, Sendable {
  public let endpoint: UUID
  public let client: UUID
  public let sequence: Int
  public init(endpoint: UUID, client: UUID, sequence: Int) { self.endpoint = endpoint; self.client = client; self.sequence = sequence }
}

public struct WorkerCallInventory: Codable, Equatable, Sendable {
  public let id: UUID
  public let operation: String
  public let receipt: WorkerReceipt?
  public let terminal: Bool
  public init(_ call: WorkerCall, terminal: Bool = false) { id = call.id; operation = call.operation; receipt = call.receipt; self.terminal = terminal }
}

public struct WorkerCall: Codable, Equatable, Sendable {
  public let abi: Int
  public let id: UUID
  public let operation: String
  public let payload: JSONValue
  public let traceContext: TraceContext?
  public let receipt: WorkerReceipt?
  public init(abi: Int = 1, id: UUID = UUID(), operation: String, payload: JSONValue = .null, traceContext: TraceContext? = ServerTracing.context, receipt: WorkerReceipt? = nil) {
    self.abi = abi; self.id = id; self.operation = operation; self.payload = payload; self.traceContext = traceContext; self.receipt = receipt
  }

  func validate() throws {
    guard abi == 1 else { throw WorkerProtocolError(.incompatibleABI, message: "Unsupported execution ABI \(abi)") }
    guard !operation.isEmpty, operation.utf8.count <= 128,
          operation.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48 ... 57).contains($0) || (97 ... 122).contains($0) })
    else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid execution operation name")
    }
  }
}

public struct WorkerReply: Codable, Equatable, Sendable {
  public let abi: Int
  public let id: UUID
  public let result: JSONValue?
  public let error: WorkerProtocolError?
  public init(id: UUID, result: JSONValue) { abi = 1; self.id = id; self.result = result; error = nil }
  public init(id: UUID, error: WorkerProtocolError) { abi = 1; self.id = id; self.error = error; result = nil }
  private enum CodingKeys: String, CodingKey { case abi, id, result, error }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    abi = try fields.decode(Int.self, forKey: .abi)
    id = try fields.decode(UUID.self, forKey: .id)
    result = fields.contains(.result) ? try fields.decode(JSONValue.self, forKey: .result) : nil
    error = fields.contains(.error) ? try fields.decode(WorkerProtocolError.self, forKey: .error) : nil
  }

  func value(for call: WorkerCall) throws -> JSONValue {
    guard abi == call.abi, id == call.id, (result != nil) != (error != nil) else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid execution reply correlation or shape")
    }
    if let error { throw error }
    return result!
  }
}
