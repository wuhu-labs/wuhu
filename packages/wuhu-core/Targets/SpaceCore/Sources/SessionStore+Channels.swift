import Dependencies
import SessionDomain
import struct SpaceContract.GroupID

public enum ChannelError: Error, Equatable, Sendable {
  case sessionMember(String)
  case unknownPerson(String)
  case notChannel(String)
  case invalidTitle
}

/// A channel is made and managed by calls to its conversation's cell.
extension SessionStore {
  /// `group` homes it: the group its opener acts in.
  @discardableResult
  public func createConversation(members: [String], title: String? = nil, in group: GroupID) async throws -> ConversationID {
    @Dependency(\.uuid) var uuid
    let id = ConversationID(uuid().uuidString.lowercased())
    let now = dateGen.now
    try await runtime.worker().call(ConversationCell.ID(id.rawValue)) { try $0.open(members: members, title: title, in: group, at: now) }
    return id
  }

  public func addChannelMembers(_ id: ConversationID, people: [String], as principal: Principal) async throws {
    let now = dateGen.now
    try await runtime.worker().call(ConversationCell.ID(id.rawValue)) { try $0.add(people, as: principal, at: now) }
  }

  public func removeChannelMembers(_ id: ConversationID, people: [String], as principal: Principal) async throws {
    try await runtime.worker().call(ConversationCell.ID(id.rawValue)) { try $0.remove(people, as: principal) }
  }

  public func renameChannel(_ id: ConversationID, title: String?, as principal: Principal) async throws {
    try await runtime.worker().call(ConversationCell.ID(id.rawValue)) { try $0.rename(title, as: principal) }
  }
}
