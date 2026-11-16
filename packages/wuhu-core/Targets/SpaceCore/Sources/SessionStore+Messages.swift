import struct SpaceIDs.ConversationID
import struct SpaceIDs.MessageID
import struct SpaceIDs.RequestID
import struct SpaceIDs.SessionID
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceFS
import struct SpaceIDs.GroupID

extension SessionStore {
  /// Whether `member` reads `path` in `group` because it is a member of the conversation homed there whose attachment folder holds it, whatever its own group reads.
  public func readsAttachment(_ path: String, in group: GroupID, member: String) -> Bool {
    attachmentConversation(path, in: group)?.members.contains { $0.member == member } == true
  }

  /// The conversation homed in `group` whose folder holds `path`.
  public func attachmentConversation(_ path: String, in group: GroupID) -> ConversationRecord? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations",
          let record = conversationCell(ConversationID(String(parts[2]))).record(), record.group == group else { return nil }
    return record
  }

  public func readsFile(_ path: String, in group: GroupID, as principal: Principal) async throws -> Bool {
    let conversation = attachmentConversation(path, in: group)
    if let conversation, conversation.kind == .users {
      return try await reads(conversation, reader: principal.member, group: principal.group)
    }
    if group == principal.group { return true }
    if groupCell(group).reads(principal) { return true }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 4, parts[3] == "attachments", let member = principal.member else { return false }
    return conversation?.members.contains { $0.member == member } == true
  }

  /// A post is a call to its conversation's cell.
  public func post(
    _ target: ConversationTarget,
    messageID: MessageID,
    sender: Sender,
    senderSession: SessionID? = nil,
    kind: MessageKind = .message,
    requestID: RequestID? = nil,
    replyTarget: MessageID? = nil,
    viewing: Viewing? = nil,
    content: MessageContent,
    uploads: [AttachmentUpload] = [],
    acting: Principal? = nil,
  ) async throws -> MessageDelivery {
    precondition(viewing == nil || senderSession == nil, "only a person's message carries viewing")
    let now = dateGen.now
    let me = senderSession?.rawValue ?? sender.id
    let conversation: ConversationID
    let place: Post.Target
    switch target {
    case let .conversation(id):
      (conversation, place) = (id, .conversation)
    case let .box(owner):
      (conversation, place) = (ConversationID(owner.rawValue), .box)
    case let .dm(spelling):
      guard let other = spaceCell.directMessageTarget(spelling) else { throw SessionStoreError.unknownPerson(spelling) }
      guard me != other else { throw SessionStoreError.selfDirectMessage(me) }
      (conversation, place) = (Conversations.dmID(me, other), .dm(with: other))
    }
    var post = Post(
      target: place, messageID: messageID, sender: sender, senderSession: senderSession, kind: kind, requestID: requestID, replyTarget: replyTarget,
      viewing: viewing, content: content, acting: acting, at: now,
    )
    // The post's step puts the bytes, so a refused post takes them back too; only a large upload's object store entry stays.
    var staged: [Blob] = []
    for upload in uploads {
      let blob = try await bucket.stage(upload.bytes)
      staged.append(blob)
      post.uploads.append(Post.Upload(name: upload.name, blob: blob.hash, size: upload.bytes.count, file: upload.attachment(at: upload.name)))
    }
    return try await runtime.worker().call(ConversationCell.ID(conversation.rawValue)) { [post, staged] in
      try $0.post(post, storing: staged)
    }
  }

  public func message(_ id: MessageID) -> MessageRecord? {
    spaceCell.message(id)
  }

  private func conversationCell(_ id: ConversationID) -> ConversationCell {
    runtime.worker().cell(ConversationCell.ID(id.rawValue))
  }

  private func groupCell(_ group: GroupID) -> GroupCell {
    runtime.worker().cell(GroupCell.ID(group.rawValue))
  }
}

extension ConversationRecord {
  func reads(_ reader: String?, isSession: Bool, group: GroupID, reach: () throws -> Set<GroupID>) rethrows -> Bool {
    if ownerSession != nil || (kind == .users && isSession) { return try reach().contains(self.group) }
    guard let reader else { return kind != .users && self.group == group }
    if members.contains(where: { $0.member == reader && (kind != .users || $0.kind == .user) }) { return true }
    return kind != .users && self.group == group
  }
}
