#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Something with an address, a SQLite database of its own, and mail. `kind` is durable: it is the first half of every address of this type.
public protocol Addressable: SendableMetatype {
  associatedtype Message: Codable & Sendable
  static var kind: String { get }
  /// Applied in order, each statement once, tracked by `PRAGMA user_version`.
  static var schema: [String] { get }
}

extension Addressable {
  public typealias ID = Address<Self>

  public static var schema: [String] {
    []
  }

  /// The column that makes a table owned: a row belongs to the addressable whose step wrote it, and `cell()` fills it in. A read keeps to its own rows with `WHERE owner = cell()`, the same on both backends; on the shared backend, a statement writing another addressable's row aborts.
  public static var ownerColumn: String {
    "owner TEXT NOT NULL DEFAULT (cell())"
  }
}

public struct Address<Target: Addressable>: Hashable, Sendable, Codable, CustomStringConvertible {
  public let key: String

  public init(_ key: String) {
    self.key = key
  }

  public var description: String {
    "\(Target.kind)/\(key)"
  }

  public var recipient: Recipient<Target.Message> {
    Recipient(raw: description)
  }
}

/// An address known only by the messages it takes, for replies to callers of any type.
public struct Recipient<Message: Codable & Sendable>: Hashable, Sendable, Codable {
  let raw: String

  /// The address `key` has among the addressables of `kind`, for a sender that cannot name the type.
  public init(kind: String, key: String) {
    raw = "\(kind)/\(key)"
  }

  init(raw: String) {
    self.raw = raw
  }

  /// Mail from the host program's own write on the shared backend: one row in the transaction open on `handle`, durable with it. Nothing pokes the recipient: the host does once it has committed, or the scan finds the mail.
  public func post(_ message: Message, on handle: OpaquePointer) throws {
    try Connection(borrowing: handle).execute("INSERT INTO wuwei_mail (recipient, payload) VALUES (?, ?)", .text(raw), .blob(Wuwei.encode(message)))
  }

  /// The same address, for a sender that knows only some of its messages: `Other` must encode as one of them (an enum whose cases are the recipient's own), which only the recipient's decoding checks.
  public func retyped<Other>(_: Other.Type = Other.self) -> Recipient<Other> {
    Recipient<Other>(raw: raw)
  }
}

/// Clients the runtime hands to addressables, one value per type.
public struct Dependencies: Sendable {
  private var values: [ObjectIdentifier: any Sendable] = [:]

  public init() {}

  public mutating func register<Client: Sendable>(_ client: Client) {
    values[ObjectIdentifier(Client.self)] = client
  }

  func get<Client: Sendable>(_: Client.Type) -> Client {
    guard let client = values[ObjectIdentifier(Client.self)] as? Client else { preconditionFailure("no \(Client.self) registered") }
    return client
  }
}

func encode(_ value: some Encodable) -> [UInt8] {
  do { return try Array(JSONEncoder().encode(value)) } catch { preconditionFailure("\(value) does not encode: \(error)") }
}

func decode<Value: Decodable>(_: Value.Type, from bytes: [UInt8]) throws -> Value {
  try JSONDecoder().decode(Value.self, from: Data(bytes))
}
