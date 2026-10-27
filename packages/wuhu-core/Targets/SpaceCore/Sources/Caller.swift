import struct SessionDomain.SessionID
import struct SpaceContract.GroupID

/// Who asks the hub to create a session or post a message.
public enum Caller: Hashable, Sendable {
  case session(SessionID)
  /// A page acting as the person viewing it, confined to the page's group.
  case page(Person)

  /// The sender and creator the hub records.
  public var name: String {
    switch self {
    case let .session(id): id.rawValue
    case let .page(person): person.persona
    }
  }

  /// Where its receipts and derived message ids live. A page's are its
  /// viewer's in its group only, so a key the viewer used from another group's
  /// page never replays here.
  public var receiptHolder: String {
    switch self {
    case let .session(id): id.rawValue
    case let .page(person): "\(person.persona) in \(person.group.rawValue)"
    }
  }

  public var session: SessionID? {
    if case let .session(id) = self { id } else { nil }
  }

  public var person: Person? {
    if case let .page(person) = self { person } else { nil }
  }
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
