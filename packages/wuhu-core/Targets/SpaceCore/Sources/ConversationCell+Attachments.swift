#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

/// A file a message brought: the conversation's row, read as a file of its group at `path`.
@Table("attachments")
struct AttachmentRow {
  @Column("conversation_id") var conversationID: String
  var path: String
  var blob: String
  var size: Int
  @Column("created_at") var createdAt: String
}

extension ConversationCell {
  func attachment(_ path: String) -> AttachmentRow? {
    db.rows(AttachmentRow.where { $0.conversationID.eq(id.key) && $0.path.eq(path) }).first
  }

  func attachments() -> [AttachmentRow] {
    db.rows(AttachmentRow.where { $0.conversationID.eq(id.key) }.order(by: \.path))
  }

  /// Places each upload in the folder of the post's second, under its own name or the next free one.
  mutating func attach(_ uploads: [Post.Upload], at date: Date) throws -> [Attachment] {
    guard !uploads.isEmpty else { return [] }
    let folder = try AttachmentFolder.path(conversation: ConversationID(id.key), at: date)
    let now = SQLiteDateFormat.string(from: date)
    var placed: [Attachment] = []
    for upload in uploads {
      let dot = upload.name.lastIndex(of: ".").flatMap { $0 == upload.name.startIndex ? nil : $0 }
      let stem = dot.map { String(upload.name[..<$0]) } ?? upload.name
      let suffix = dot.map { String(upload.name[$0...]) } ?? ""
      var path = try SpacePath(components: folder.components + [upload.name]).rawValue
      var ordinal = 1
      while attachment(path) != nil {
        ordinal += 1
        path = try SpacePath(components: folder.components + ["\(stem)-\(ordinal)\(suffix)"]).rawValue
      }
      try db.execute(AttachmentRow.insert {
        AttachmentRow(conversationID: id.key, path: path, blob: upload.blob, size: upload.size, createdAt: now)
      })
      placed.append(upload.file.at(path))
    }
    return placed
  }
}
