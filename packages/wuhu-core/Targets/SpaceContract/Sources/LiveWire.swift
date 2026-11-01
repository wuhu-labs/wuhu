import Contract
import JSONValue

/// The live channel of one `.wmd` or `.canvas` document: `GET /v1/live/<path>`
/// upgraded to a WebSocket. Text frames carry these JSON controls; binary frames carry
/// ``LiveFrame``. The first frame is always a client `hello`.
public enum LiveChannel {
  public static let routePrefix: String = "/v1/live"
  /// A presence entry not refreshed for this long expires in every store.
  public static let presenceTimeoutMilliseconds: Int = 30000
}

@Contract
public enum LiveAccess: String, Codable, Equatable, Sendable {
  case read
  case write
}

@Contract
public struct LivePeer: Codable, Equatable, Sendable {
  public let connection: String
  public let peer: String
  public let name: String
  public let access: LiveAccess
}

@Contract
public enum LiveErrorCode: String, Codable, Equatable, Sendable {
  case unauthorized
  case forbidden
  case notFound
  case notLive
  case protocolViolation
  case readOnly
  case invalidUpdate
  case missingDependencies
  case `internal`
}

@Contract(discriminator: "type")
public enum LiveClientControl: Codable, Equatable, Sendable {
  case hello(authorization: String?, group: String?, peer: String, create: Bool?)
}

@Contract(discriminator: "type")
public enum LiveServerControl: Codable, Equatable, Sendable {
  case welcome(connection: String, name: String, access: LiveAccess, peers: [LivePeer], rev: Int?)
  case ack(count: Int)
  case peers(peers: [LivePeer])
  case checkpoint(rev: Int)
  case error(code: LiveErrorCode, message: String)
}

/// A binary frame: one tag byte, then raw Loro bytes.
public enum LiveFrame: Equatable, Sendable {
  /// Client → server, once after `welcome`: `VersionVector.encode()` of the client's doc.
  case sync(versionVector: [UInt8])
  /// Both ways: Loro update bytes.
  case update([UInt8])
  /// Both ways: `EphemeralStore` encoded bytes; never logged.
  case presence([UInt8])
  /// Server → client, after the catch-up `update`: the server doc's `VersionVector.encode()`.
  case synced(versionVector: [UInt8])

  public struct Malformed: Error, Equatable, Sendable {
    public let tag: UInt8?
  }

  public init(bytes: some Collection<UInt8>) throws(Malformed) {
    guard let tag = bytes.first else { throw Malformed(tag: nil) }
    let payload = Array(bytes.dropFirst())
    switch tag {
    case 0x01: self = .sync(versionVector: payload)
    case 0x02: self = .update(payload)
    case 0x03: self = .presence(payload)
    case 0x04: self = .synced(versionVector: payload)
    default: throw Malformed(tag: tag)
    }
  }

  public var bytes: [UInt8] {
    switch self {
    case let .sync(payload): [0x01] + payload
    case let .update(payload): [0x02] + payload
    case let .presence(payload): [0x03] + payload
    case let .synced(payload): [0x04] + payload
    }
  }
}
