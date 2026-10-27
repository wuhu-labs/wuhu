import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

/// Who asks the hub to create a session or post a message.
public enum Caller: Hashable, Sendable {
  case session(SessionID)
  /// A page acting as the person viewing it, confined to the page's group.
  case page(Person)
  case observer(Observer)

  /// The sender and creator the hub records.
  public var name: String {
    switch self {
    case let .session(id): id.rawValue
    case let .page(person): person.persona
    case let .observer(observer): observer.member
    }
  }

  /// Where its receipts and derived message ids live. A page's are its
  /// viewer's in its group only, so a key the viewer used from another group's
  /// page never replays here.
  public var receiptHolder: String {
    switch self {
    case let .session(id): id.rawValue
    case let .page(person): "\(person.persona) in \(person.group.rawValue)"
    case let .observer(observer): observer.member
    }
  }

  public var session: SessionID? {
    if case let .session(id) = self { id } else { nil }
  }

  public var person: Person? {
    if case let .page(person) = self { person } else { nil }
  }

  /// The one group it acts in: a page's, an observer's.
  public var confinement: GroupID? {
    switch self {
    case .session: nil
    case let .page(person): person.group
    case let .observer(observer): observer.group
    }
  }

  public var observer: Observer? {
    if case let .observer(observer) = self { observer } else { nil }
  }

  /// The firing what it makes records; a session's or a page's records none.
  public var firing: String? { observer?.firing }

  /// Who it acts as when it is not a session.
  public var principal: Principal? {
    switch self {
    case .session: nil
    case let .page(person): person.principal
    case let .observer(observer): observer.principal
    }
  }
}

/// A group observer's handler firing, acting as its group.
public struct Observer: Hashable, Sendable {
  public let group: GroupID
  public let name: String
  /// Nil outside a firing: the observation query that decides one.
  public let firing: String?

  public init(group: GroupID, name: String, firing: String?) {
    self.group = group
    self.name = name
    self.firing = firing
  }

  /// The sender, creator and requester its creations record.
  public var member: String { "\(name)@\(group.rawValue)" }

  public var principal: Principal { Principal(actor: .observer(self), group: group) }

  /// Whether a recorded caller (an exec's, a script's) is an observer's
  /// member rather than a session's id.
  public static func isMember(_ caller: String) -> Bool { caller.contains("@") }
}

/// A person speaking as `persona`, acting in `group`; no account is the
/// --dev seat.
public struct Person: Hashable, Sendable {
  public let persona: String
  public let account: AccountID?
  public let group: GroupID

  public init(persona: String, account: AccountID?, group: GroupID) {
    self.persona = persona
    self.account = account
    self.group = group
  }

  public var principal: Principal {
    Principal(actor: account.map { .person(persona: persona, account: $0) } ?? .anonymous, group: group)
  }
}
