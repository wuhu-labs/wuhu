import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MainHub.EventSources
import struct SessionDomain.SessionID
import SessionTools
import struct SpaceContract.GroupID
import SpaceCore

extension EventSources {
  /// Streams dialled with a 60-second token naming the subscriber: its
  /// session and group, or a group observer's group alone.
  static func signed(by identity: IdentityController, in space: Space) -> EventSources {
    @Dependency(\.scriptHop) var hop
    return EventSources(token: { owner, audience in
      @Dependency(\.date) var date
      @Dependency(\.uuid) var uuid
      let group: GroupID
      var session: SessionID?
      switch owner {
      case let .session(id):
        group = try await space.principal(of: id).group
        session = id
      case let .group(owner):
        group = owner
      }
      return try await identity.token(
        audience: audience, space: space.identity().rawValue, group: group.rawValue, session: session?.rawValue,
        now: date.now, id: uuid(), lifetime: 60,
      )
    }, fetch: hop)
  }
}
