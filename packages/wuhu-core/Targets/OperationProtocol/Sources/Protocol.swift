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
  /// An open set of error codes. The wire carries the raw string; a peer's code this build doesn't know decodes as itself instead of failing the envelope, so a newer machine's refusal reaches an older client intact. Switches over codes need a `default`.
  public struct Code: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var description: String { rawValue }
    /// Whether this build defines the code.
    public var isKnown: Bool { Self.known.contains(self) }
    public static let known: Set<Self> = [.unknownMachine, .unknownKind, .unknownOperation, .unknownChannel, .unsupportedProtocol, .operationExists, .invalidOffset, .offsetExpired, .operationEnded, .leaving, .invalidInput, .inputTooLarge, .recordTooLarge, .resultTooLarge, .capacityExceeded, .invocationConflict, .machineUnavailable, .callerDeadline, .requestDeadline, .requestCancelled, .transport, .invalidResponse, .kindFailed, .machineNotAuthorized, .traceUnavailable, .storeUnavailable, .fileChanged, .fileUnavailable, .credentialExpired, .spawnFailed, .supervisorUnavailable, .supervisorIdentityMismatch, .invalidConfiguration, .kindUnavailable, .permissionDenied, .deviceLocked]
    public static let unknownMachine = Self("unknownMachine")
    public static let unknownKind = Self("unknownKind")
    public static let unknownOperation = Self("unknownOperation")
    public static let unknownChannel = Self("unknownChannel")
    public static let unsupportedProtocol = Self("unsupportedProtocol")
    public static let operationExists = Self("operationExists")
    public static let invalidOffset = Self("invalidOffset")
    public static let offsetExpired = Self("offsetExpired")
    public static let operationEnded = Self("operationEnded")
    public static let leaving = Self("leaving")
    public static let invalidInput = Self("invalidInput")
    public static let inputTooLarge = Self("inputTooLarge")
    public static let recordTooLarge = Self("recordTooLarge")
    public static let resultTooLarge = Self("resultTooLarge")
    public static let capacityExceeded = Self("capacityExceeded")
    public static let invocationConflict = Self("invocationConflict")
    public static let machineUnavailable = Self("machineUnavailable")
    public static let callerDeadline = Self("callerDeadline")
    public static let requestDeadline = Self("requestDeadline")
    public static let requestCancelled = Self("requestCancelled")
    public static let transport = Self("transport")
    public static let invalidResponse = Self("invalidResponse")
    public static let kindFailed = Self("kindFailed")
    public static let machineNotAuthorized = Self("machineNotAuthorized")
    public static let traceUnavailable = Self("traceUnavailable")
    public static let storeUnavailable = Self("storeUnavailable")
    public static let fileChanged = Self("fileChanged")
    public static let fileUnavailable = Self("fileUnavailable")
    public static let credentialExpired = Self("credentialExpired")
    public static let spawnFailed = Self("spawnFailed")
    public static let supervisorUnavailable = Self("supervisorUnavailable")
    public static let supervisorIdentityMismatch = Self("supervisorIdentityMismatch")
    public static let invalidConfiguration = Self("invalidConfiguration")
    public static let kindUnavailable = Self("kindUnavailable")
    public static let permissionDenied = Self("permissionDenied")
    public static let deviceLocked = Self("deviceLocked")
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
    case .operationExists, .invalidOffset, .offsetExpired, .operationEnded, .leaving, .invocationConflict, .kindUnavailable: 409
    case .inputTooLarge, .recordTooLarge, .resultTooLarge: 413
    case .capacityExceeded: 429
    case .fileChanged: 412
    case .machineUnavailable, .deviceLocked: 503
    case .machineNotAuthorized, .permissionDenied: 403
    default: 400
    }
  }
}

extension OperationError {
  /// A refusal at the bound named `reason`: message `<reason> <used>/<limit>`, details `{reason, used, limit}` plus `requested` when a start asked for more.
  public static func capacityExceeded(_ reason: String, used: Int, limit: Int, requested: Int? = nil, operation: UUID? = nil) -> Self {
    let details: JSONValue = if let requested {
      ["reason": .string(reason), "used": .number(Double(used)), "limit": .number(Double(limit)), "requested": .number(Double(requested))]
    } else {
      ["reason": .string(reason), "used": .number(Double(used)), "limit": .number(Double(limit))]
    }
    return Self(.capacityExceeded, message: "\(reason) \(used)/\(limit)" + (requested.map { " (requested \($0))" } ?? ""), operation: operation, details: details)
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
  /// Deprecated: advertised at its default for older servers, whose limit validation and claim checks require it; nothing reads it.
  public var activeOperations = 32
  public var bufferBytes = 64 * 1024 * 1024
  public var receipts = 4096
  /// Deprecated: advertised at its default for older servers, whose limit validation requires it; nothing reads it. A finished operation is held only until it settles or one receipt retention window (`OperationAgent`) after its caller's last request.
  public var receiptMs = 86_400_000
  public init() {}
  public var isValid: Bool {
    leaseMs > 0 && pollHoldMs >= 0 && pollHoldMs < leaseMs && inputBytes > 0 && resultBytes > 0
      && pollBytes > 0 && pollBytes <= Self.responseBytes / 2 && resultBytes <= Self.responseBytes && bufferBytes > 0 && receipts > 0
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
  public let summary: String?
  public init(
    _ name: String,
    inputSchema: JSONValue,
    resultSchema: JSONValue,
    inputChannels: [ChannelDescriptor] = [],
    outputChannels: [ChannelDescriptor] = [],
    deliveryPolicy: Policy = .suspend,
    summary: String? = nil,
    schemaDialect: String = "https://json-schema.org/draft/2020-12/schema",
  ) {
    self.name = name; self.inputSchema = inputSchema; self.resultSchema = resultSchema
    self.inputChannels = inputChannels; self.outputChannels = outputChannels
    self.deliveryPolicy = deliveryPolicy; self.summary = summary; self.schemaDialect = schemaDialect
  }
}

public enum KindAvailability: Codable, Equatable, Sendable {
  case available
  case unavailable(reason: String)
  case needsConsent
  case needsPermission(permission: String, state: String)

  enum CodingKeys: String, CodingKey { case state, reason, permission, permissionState }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .state) {
    case "available": self = .available
    case "unavailable": self = .unavailable(reason: try c.decode(String.self, forKey: .reason))
    case "needsConsent": self = .needsConsent
    case "needsPermission": self = .needsPermission(permission: try c.decode(String.self, forKey: .permission), state: try c.decode(String.self, forKey: .permissionState))
    default: throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "Unknown kind availability")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .available: try c.encode("available", forKey: .state)
    case let .unavailable(reason): try c.encode("unavailable", forKey: .state); try c.encode(reason, forKey: .reason)
    case .needsConsent: try c.encode("needsConsent", forKey: .state)
    case let .needsPermission(permission, state):
      try c.encode("needsPermission", forKey: .state); try c.encode(permission, forKey: .permission); try c.encode(state, forKey: .permissionState)
    }
  }

  /// The stop reason for operations already running when their kind enters this state: `consentRevoked`, `permissionRevoked` or `kindUnavailable`; nil while available.
  public var stopReason: String? {
    switch self {
    case .available: nil
    case .unavailable: "kindUnavailable"
    case .needsConsent: "consentRevoked"
    case .needsPermission: "permissionRevoked"
    }
  }

  public func refusal(kind: String) -> OperationError? {
    switch self {
    case .available: nil
    case let .unavailable(reason): OperationError(.kindUnavailable, message: "\(kind) is unavailable on this machine: \(reason)", details: ["kind": .string(kind), "reason": .string(reason)])
    case .needsConsent: OperationError(.kindUnavailable, message: "\(kind) needs the machine owner's consent", details: ["kind": .string(kind), "reason": "needsConsent"])
    case let .needsPermission(permission, state):
      OperationError(.permissionDenied, message: "\(kind) needs the \(permission) permission (\(state))", details: ["kind": .string(kind), "permission": .string(permission), "state": .string(state)])
    }
  }
}

public struct MachineDescription: Codable, Sendable {
  public let version: Int
  public let instance: UUID
  public let acceptingStarts: Bool
  public let limits: OperationLimits
  public let kinds: [KindDescriptor]
  public let availability: [String: KindAvailability]?
  public let upgrade: MachineUpgradeReport?
  public init(instance: UUID, acceptingStarts: Bool, limits: OperationLimits, kinds: [KindDescriptor], availability: [String: KindAvailability]? = nil, upgrade: MachineUpgradeReport? = nil) {
    version = 2; self.instance = instance; self.acceptingStarts = acceptingStarts; self.limits = limits; self.kinds = kinds; self.availability = availability; self.upgrade = upgrade
  }
}

/// A box agent's own automatic-upgrade outcome. `failed` names the target version it will not retry until the target changes.
public struct MachineUpgradeReport: Codable, Equatable, Sendable {
  public struct Failure: Codable, Equatable, Sendable {
    public let version: String
    public let reason: String
    public let at: String
    public init(version: String, reason: String, at: String) { self.version = version; self.reason = reason; self.at = at }
  }

  public let failed: Failure?
  public init(failed: Failure?) { self.failed = failed }
}

public struct StartRequest: Codable, Equatable, Sendable {
  /// Who asked for the start: the server fills it from the calling session so the machine's audit can name it. Display only — never an authorization input.
  public struct Caller: Codable, Equatable, Sendable {
    public let session: String
    public let title: String
    public let group: String
    public init(session: String, title: String, group: String) { self.session = session; self.title = title; self.group = group }
  }

  public let kind: String
  public let input: JSONValue
  /// Absent when no session made the call (a person's CLI, the server itself) and from servers that predate attribution.
  public let caller: Caller?
  public init(kind: String, input: JSONValue, caller: Caller? = nil) { self.kind = kind; self.input = input; self.caller = caller }
  /// The invocation identity, `kind` and `input` only: a replayed start whose caller title changed in between is the same invocation.
  public func canonicalData() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let normalized = try JSONDecoder().decode(Self.self, from: encoder.encode(Self(kind: kind, input: input)))
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

/// In-process routers bracket local preparation so it cannot be mistaken for silence from the machine.
public enum OperationPreparation {
  @TaskLocal public static var observer: (@Sendable (Bool) -> Void)?

  public static func run<T: Sendable>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
    observer?(true)
    defer { observer?(false) }
    return try await body()
  }
}
