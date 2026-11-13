#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import enum OperationProtocol.KindAvailability
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.Verdict

public protocol OperationKind: Sendable {
  associatedtype Input: Decodable & Sendable
  associatedtype Result: Encodable & Sendable
  var descriptor: KindDescriptor { get }
  func validate(_ input: Input) throws
  /// One look at the world serves both: the window each channel of this start must be admitted for, and the work those
  /// windows bound. A channel the start does not name keeps the descriptor's window.
  func start(_ input: Input, limits: OperationLimits) async throws -> OperationStart<Result>
}

extension OperationKind {
  public func validate(_ input: Input) throws {}
}

public struct OperationStart<Result: Sendable>: Sendable {
  public let windows: [String: Int]
  public let run: @Sendable (OperationChannels, OperationCancellation) async throws -> Result
  public init(windows: [String: Int] = [:], run: @escaping @Sendable (OperationChannels, OperationCancellation) async throws -> Result) {
    self.windows = windows; self.run = run
  }
}

public struct AnyOperationKind: Sendable {
  public let descriptor: KindDescriptor
  let prepare: @Sendable (JSONValue, OperationLimits) async throws -> OperationStart<JSONValue>
  public init<K: OperationKind>(_ kind: K) {
    descriptor = kind.descriptor
    prepare = { value, limits in
      let input = try JSONDecoder().decode(K.Input.self, from: Data(value.jsonString().utf8))
      try kind.validate(input)
      let start = try await kind.start(input, limits: limits)
      return OperationStart(windows: start.windows) { channels, cancellation in
        let result = try await start.run(channels, cancellation)
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
      }
    }
  }
}

/// The machine's current gate per kind. A linked kind it doesn't name is available; a name it marks unavailable needn't be linked, so a known-but-absent kind (exec on a sandboxed build) is refused with its reason instead of unknownKind. The owner yields on `changes` after every gate change; the agent then re-reads `current` and stops each running operation whose kind is no longer available.
public struct KindAvailabilityProvider: Sendable {
  let current: @Sendable () async -> [String: KindAvailability]
  let changes: AsyncStream<Void>?
  public init(_ current: @escaping @Sendable () async -> [String: KindAvailability], changes: AsyncStream<Void>? = nil) { self.current = current; self.changes = changes }

  public func describe(linked: some Sequence<String>) async -> [String: KindAvailability] {
    var described = Dictionary(uniqueKeysWithValues: linked.map { ($0, KindAvailability.available) })
    for (name, state) in await current() where state != .available || described[name] != nil { described[name] = state }
    return described
  }

  public func admit(_ kind: String) async throws {
    if let refusal = await current()[kind]?.refusal(kind: kind) { throw refusal }
  }
}

public struct OperationCancellation: Sendable {
  let checkImpl: @Sendable () async throws -> Void
  let stopImpl: @Sendable (String) async throws -> Void
  let reasonImpl: @Sendable () async -> String?
  let stoppedImpl: @Sendable () async -> Void
  public func reason() async -> String? { await reasonImpl() }
  public func check() async throws { try Task.checkCancellation(); try await checkImpl() }
  public func stop(reason: String) async throws { try await stopImpl(reason) }

  /// `work`, cancelled with a `CancellationError` the moment a stop or lease expiry lands: neither is task cancellation.
  public func unlessStopped<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      defer { group.cancelAll() }
      group.addTask { try await work() }
      group.addTask { await stoppedImpl(); throw CancellationError() }
      return try await group.next()!
    }
  }
}

public struct OperationChannels: Sendable {
  let sendImpl: @Sendable (String, ChannelPayload) async throws -> Void
  let readImpl: @Sendable (String, Int) async throws -> ChannelPayload?
  let finishImpl: @Sendable (String) async throws -> Void
  let capacityImpl: @Sendable (String) async throws -> Int
  let availableInputImpl: @Sendable (String, Int) async throws -> ChannelPayload?
  let publishImpl: @Sendable (Verdict) async throws -> Void
  let windowImpl: @Sendable (String) async -> Int
  public func writableBytes(_ name: String) async throws -> Int { try await capacityImpl(name) }
  public func availableInput(_ name: String, upTo bytes: Int) async throws -> ChannelPayload? { try await availableInputImpl(name, bytes) }
  public func publish(_ verdict: Verdict) async throws { try await publishImpl(verdict) }
  public func send(_ payload: ChannelPayload, to name: String) async throws { try await sendImpl(name, payload) }
  public func read(_ name: String, upTo bytes: Int) async throws -> ChannelPayload? { try await readImpl(name, bytes) }
  public func finish(_ name: String) async throws { try await finishImpl(name) }
  /// The most this operation's channel may hold at once: the piece a file read or write moves.
  public func windowBytes(_ name: String) async -> Int { await windowImpl(name) }
}
