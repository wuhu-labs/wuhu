#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue

public struct Offset: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    let text = try c.decode(String.self)
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt64(text) else {
      throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected unsigned decimal offset")
    }
    self.rawValue = n
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer(); try c.encode(String(rawValue))
  }

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  public static let zero = Self(rawValue: 0)
  public func advanced(by count: Int) throws -> Self {
    guard count >= 0 else { throw OperationError(.invalidOffset) }
    let (n, overflow) = rawValue.addingReportingOverflow(UInt64(count))
    guard !overflow else { throw OperationError(.invalidOffset) }
    return Self(rawValue: n)
  }
}

public struct OperationError: Error, Codable, Equatable, Sendable {
  public enum Code: String, Codable, Sendable {
    case unknownMachine, unknownKind, unknownOperation, unknownChannel, unsupportedProtocol
    case operationExists, invalidOffset, offsetExpired, operationEnded, leaving, invalidInput
    case inputTooLarge, recordTooLarge, resultTooLarge, capacityExceeded, invocationConflict
    case machineUnavailable, callerDeadline, requestDeadline, requestCancelled, transport, invalidResponse, kindFailed
    case machineNotAuthorized, traceUnavailable, storeUnavailable, fileChanged, unsupportedDialect, fileUnavailable, credentialExpired
    case spawnFailed, supervisorUnavailable, supervisorIdentityMismatch, invalidConfiguration
  }

  public let code: Code
  public let message: String
  public let operation: UUID?
  public let details: JSONValue?
  public init(_ code: Code, message: String = "", operation: UUID? = nil, details: JSONValue? = nil) {
    self.code = code; self.message = message; self.operation = operation; self.details = details
  }

  public var statusCode: Int {
    switch code {
    case .unknownMachine, .unknownKind, .unknownOperation: 404
    case .operationExists, .invalidOffset, .offsetExpired, .operationEnded, .leaving, .invocationConflict: 409
    case .inputTooLarge, .recordTooLarge, .resultTooLarge: 413
    case .capacityExceeded: 429
    case .fileChanged: 412
    case .machineUnavailable: 503
    case .machineNotAuthorized: 403
    default: 400
    }
  }
}

public struct ErrorEnvelope: Codable, Sendable {
  public let error: OperationError
  public init(_ error: OperationError) { self.error = error }
}

public struct OperationClock: Sendable {
  public let now: @Sendable () -> Duration
  public let sleep: @Sendable (Duration) async throws -> Void
  public init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.now = now; self.sleep = sleep
  }

  public static var continuous: Self {
    let clock = ContinuousClock(); let origin = clock.now
    return Self(now: { origin.duration(to: clock.now) }, sleep: { try await clock.sleep(for: $0) })
  }
}

public struct OperationLimits: Codable, Equatable, Sendable {
  public static let responseBytes = 256 * 1024
  public var leaseMs = 60000
  public var pollHoldMs = 20000
  public var inputBytes = 128 * 1024
  public var resultBytes = 64 * 1024
  public var pollBytes = 64 * 1024
  public var activeOperations = 32
  public var bufferBytes = 64 * 1024 * 1024
  public var receipts = 4096
  public var receiptMs = 86_400_000
  public init() {}
  public var isValid: Bool {
    leaseMs > 0 && pollHoldMs >= 0 && pollHoldMs < leaseMs && inputBytes > 0 && resultBytes > 0
      && pollBytes > 0 && pollBytes <= Self.responseBytes / 2 && resultBytes <= Self.responseBytes && activeOperations > 0 && bufferBytes > 0 && receipts >= activeOperations && receiptMs >= leaseMs
  }
}

public struct ChannelDescriptor: Codable, Equatable, Sendable {
  public enum Unit: String, Codable, Sendable { case bytes, records }
  public let name: String
  public let unit: Unit
  public let windowBytes: Int
  public let maxRecordBytes: Int
  public let schema: JSONValue?
  public init(
    _ name: String,
    unit: Unit = .bytes,
    windowBytes: Int = 256 * 1024,
    maxRecordBytes: Int = 64 * 1024,
    schema: JSONValue? = nil,
  ) {
    self.name = name; self.unit = unit; self.windowBytes = windowBytes
    self.maxRecordBytes = maxRecordBytes; self.schema = schema
  }
}

public struct KindDescriptor: Codable, Equatable, Sendable {
  public enum Policy: String, Codable, Sendable { case suspend, boundedResult }
  public let name: String
  public let schemaDialect: String
  public let inputSchema: JSONValue
  public let resultSchema: JSONValue
  public let inputChannels: [ChannelDescriptor]
  public let outputChannels: [ChannelDescriptor]
  public let deliveryPolicy: Policy
  public init(
    _ name: String,
    inputSchema: JSONValue,
    resultSchema: JSONValue,
    inputChannels: [ChannelDescriptor] = [],
    outputChannels: [ChannelDescriptor] = [],
    deliveryPolicy: Policy = .suspend,
    schemaDialect: String = "https://json-schema.org/draft/2020-12/schema",
  ) {
    self.name = name; self.inputSchema = inputSchema; self.resultSchema = resultSchema
    self.inputChannels = inputChannels; self.outputChannels = outputChannels
    self.deliveryPolicy = deliveryPolicy; self.schemaDialect = schemaDialect
  }
}

public struct MachineDescription: Codable, Sendable {
  public let version: Int
  public let instance: UUID
  public let acceptingStarts: Bool
  public let limits: OperationLimits
  public let kinds: [KindDescriptor]
  public init(instance: UUID, acceptingStarts: Bool, limits: OperationLimits, kinds: [KindDescriptor]) {
    version = 2; self.instance = instance; self.acceptingStarts = acceptingStarts; self.limits = limits; self.kinds = kinds
  }
}

public struct StartRequest: Codable, Equatable, Sendable {
  public let kind: String
  public let input: JSONValue
  public init(kind: String, input: JSONValue) { self.kind = kind; self.input = input }
  public func canonicalData() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let normalized = try JSONDecoder().decode(Self.self, from: encoder.encode(self))
    return try encoder.encode(normalized)
  }
}

public struct ChannelPayload: Codable, Equatable, Sendable {
  public let data: Data?
  public let records: [JSONValue]?
  public init(data: Data) { self.data = data; records = nil }
  public init(records: [JSONValue]) { self.records = records; data = nil }
  public var count: Int { data?.count ?? records?.count ?? 0 }
  public var byteCount: Int { data?.count ?? records?.reduce(0) { $0 + $1.jsonString().utf8.count } ?? 0 }
  public func slice(_ range: Range<Int>) -> Self {
    if let data { return Self(data: data.subdata(in: range)) }
    return Self(records: Array((records ?? [])[range]))
  }
}

public struct WriteRequest: Codable, Equatable, Sendable {
  public let offset: Offset
  public let payload: ChannelPayload
  public let end: Bool
  public init(offset: Offset, payload: ChannelPayload, end: Bool = false) {
    self.offset = offset; self.payload = payload; self.end = end
  }
}

public struct WriteReceipt: Codable, Sendable {
  public let acceptedThrough: Offset
  public let end: Bool
  public let blocked: Bool
  public init(acceptedThrough: Offset, end: Bool, blocked: Bool) {
    self.acceptedThrough = acceptedThrough; self.end = end; self.blocked = blocked
  }
}

public struct Verdict: Codable, Equatable, Sendable {
  public enum Tag: String, Codable, Sendable { case completed, failed, stopped }
  public let tag: Tag
  public let result: JSONValue?
  public let error: OperationError?
  public let reason: String?
  public init(_ tag: Tag, result: JSONValue? = nil, error: OperationError? = nil, reason: String? = nil) {
    precondition(
      (tag == .completed && result != nil && error == nil && reason == nil)
        || (tag == .failed && error != nil && result == nil && reason == nil)
        || (tag == .stopped && reason != nil && error == nil),
    )
    self.tag = tag; self.result = result; self.error = error; self.reason = reason
  }

  enum CodingKeys: String, CodingKey { case tag, result, error, reason }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tag = try c.decode(Tag.self, forKey: .tag)
    result = c.contains(.result) ? try c.decode(JSONValue.self, forKey: .result) : nil
    error = try c.decodeIfPresent(OperationError.self, forKey: .error)
    reason = try c.decodeIfPresent(String.self, forKey: .reason)
    guard (tag == .completed && result != nil && error == nil && reason == nil)
      || (tag == .failed && error != nil && result == nil && reason == nil)
      || (tag == .stopped && reason != nil && error == nil)
    else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid verdict evidence"))
    }
  }
}

public struct OperationSnapshot: Codable, Sendable {
  public let operation: UUID
  public let verdict: Verdict?
  public let terminalToken: UUID?
  public let finalOffsets: [String: Offset]
  public let outputConsumed: Bool
  public let bufferReservationBytes: Int?
  public let channel: String?
  public let from: Offset?
  public let through: Offset?
  public let payload: ChannelPayload?
  public let channelEnd: Bool
  public init(
    operation: UUID,
    verdict: Verdict?,
    terminalToken: UUID?,
    finalOffsets: [String: Offset],
    outputConsumed: Bool,
    channel: String? = nil,
    from: Offset? = nil,
    through: Offset? = nil,
    payload: ChannelPayload? = nil,
    channelEnd: Bool = false,
    bufferReservationBytes: Int? = nil,
  ) {
    self.operation = operation; self.verdict = verdict; self.terminalToken = terminalToken
    self.finalOffsets = finalOffsets; self.outputConsumed = outputConsumed; self.channel = channel
    self.from = from; self.through = through; self.payload = payload; self.channelEnd = channelEnd
    self.bufferReservationBytes = bufferReservationBytes
  }
}

public struct StopRequest: Codable, Sendable {
  public let reason: String
  public init(reason: String) { self.reason = reason }
}

public struct OperationTrace: Sendable {
  public enum Event: String, Sendable { case dispatch, head, complete, deadline, cancelled, failure }
  public let request: UUID
  public let correlation: String
  public let path: String
  public let event: Event
  public let elapsed: Duration
  public let status: Int?
  public let error: OperationError.Code?
  public init(
    request: UUID,
    correlation: String,
    path: String,
    event: Event,
    elapsed: Duration,
    status: Int? = nil,
    error: OperationError.Code? = nil,
  ) {
    self.request = request; self.correlation = correlation; self.path = path; self.event = event
    self.elapsed = elapsed; self.status = status; self.error = error
  }
}
