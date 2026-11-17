/// What a role lets its holder do, in order: an admin writes and reads.
public enum GroupRole: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
  case read
  case write
  case admin

  private var rank: Int {
    switch self {
    case .read: 0
    case .write: 1
    case .admin: 2
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A switch between the owner group alone and everyone who can reach it.
public enum ReachScope: String, Hashable, Codable, Sendable {
  case owner
  case reachable
}
