#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.OperationError
import struct OperationProtocol.Verdict

public protocol OperationKind: Sendable {
  associatedtype Input: Decodable & Sendable
  associatedtype Result: Encodable & Sendable
  var descriptor: KindDescriptor { get }
  func validate(_ input: Input) throws
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> Result
}

extension OperationKind { public func validate(_ input: Input) throws {} }

public struct AnyOperationKind: Sendable {
  public let descriptor: KindDescriptor
  let prepare: @Sendable (JSONValue) throws -> (@Sendable (OperationChannels, OperationCancellation) async throws -> JSONValue)
  public init<K: OperationKind>(_ kind: K) {
    descriptor = kind.descriptor
    prepare = { value in
      let input = try JSONDecoder().decode(K.Input.self, from: Data(value.jsonString().utf8))
      try kind.validate(input)
      return { channels, cancellation in
        let result = try await kind.run(input, channels: channels, cancellation: cancellation)
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
      }
    }
  }
}

public struct OperationCancellation: Sendable {
  let checkImpl: @Sendable () async throws -> Void
  let reasonImpl: @Sendable () async -> String?
  public func reason() async -> String? { await reasonImpl() }
  public func check() async throws { try Task.checkCancellation(); try await checkImpl() }
}

public struct OperationChannels: Sendable {
  let sendImpl: @Sendable (String, ChannelPayload) async throws -> Void
  let readImpl: @Sendable (String, Int) async throws -> ChannelPayload?
  let finishImpl: @Sendable (String) async throws -> Void
  let capacityImpl: @Sendable (String) async throws -> Int
  let availableInputImpl: @Sendable (String, Int) async throws -> ChannelPayload?
  let publishImpl: @Sendable (Verdict) async throws -> Void
  public func writableBytes(_ name: String) async throws -> Int { try await capacityImpl(name) }
  public func availableInput(_ name: String, upTo bytes: Int) async throws -> ChannelPayload? { try await availableInputImpl(name, bytes) }
  public func publish(_ verdict: Verdict) async throws { try await publishImpl(verdict) }
  public func send(_ payload: ChannelPayload, to name: String) async throws { try await sendImpl(name, payload) }
  public func read(_ name: String, upTo bytes: Int) async throws -> ChannelPayload? { try await readImpl(name, bytes) }
  public func finish(_ name: String) async throws { try await finishImpl(name) }
}
