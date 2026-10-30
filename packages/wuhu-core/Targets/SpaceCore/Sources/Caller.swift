import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import struct SpaceFS.SpacePath

/// Who asks the hub to create a session or post a message.
public enum Caller: Hashable, Sendable {
  case session(SessionID)
  /// A person acting in one group: a page's viewer or a terminal script.
  case person(Person)
  case observer(Observer)

  /// The sender and creator the hub records.
  public var name: String {
    switch self {
    case let .session(id): id.rawValue
    case let .person(person): person.persona
    case let .observer(observer): observer.member
    }
  }

  /// Where its receipts and derived message ids live. A person's are theirs
  /// in its group only, so a key they used from another group never replays
  /// here.
  public var receiptHolder: String {
    switch self {
    case let .session(id): id.rawValue
    case let .person(person): "\(person.persona) in \(person.group.rawValue)"
    case let .observer(observer): observer.member
    }
  }

  public var session: SessionID? {
    if case let .session(id) = self { id } else { nil }
  }

  /// The one group it acts in: a person's, an observer's.
  public var confinement: GroupID? {
    switch self {
    case .session: nil
    case let .person(person): person.group
    case let .observer(observer): observer.group
    }
  }

  public var observer: Observer? {
    if case let .observer(observer) = self { observer } else { nil }
  }

  /// The firing what it makes records; a session's or a person's records none.
  public var firing: String? { observer?.firing }

  /// Who it acts as when it is not a session.
  public var principal: Principal? {
    switch self {
    case .session: nil
    case let .person(person): person.principal
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

  /// Whether a recorded caller (an exec's, a script's) is a sessionless
  /// script's, an observer's member or a person's `Person.execCaller`, rather
  /// than a session's id.
  public static func isMember(_ caller: String) -> Bool { caller.contains("@") }
}

/// A page on its group's host, writing for its viewer (a Person in that
/// group) as a non-admin agent of the group, into only what the viewer reads.
public struct Page: Hashable, Sendable {
  public let path: SpacePath
  public let viewer: Person

  public init(path: SpacePath, viewer: Person) {
    self.path = path
    self.viewer = viewer
  }

  public var group: GroupID { viewer.group }

  public var principal: Principal { Principal(actor: .page(self), group: group) }
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

  /// Whom a person's execs are recorded as: `@<account>`, which no observer
  /// member (`<name>@<group>`) or session id takes.
  public static func execCaller(_ account: AccountID) -> String { "@" + account.rawValue }

  public static func account(ofExecCaller caller: String) -> AccountID? {
    caller.first == "@" ? AccountID(rawValue: String(caller.dropFirst())) : nil
  }

  public var principal: Principal {
    Principal(actor: account.map { .person(persona: persona, account: $0) } ?? .anonymous, group: group)
  }
}
