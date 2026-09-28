#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.ImageMedia
import enum SpaceContract.MediaType
import SpaceFS

// An upload is an image when its name says png, jpeg, gif or webp and its
// bytes agree; anything else is a file typed by its name, then by what the
// sender declared.
public struct AttachmentUpload: Sendable {
  public let name: String
  public let bytes: [UInt8]
  public let mimeType: String
  let isImage: Bool

  public init(name: String, bytes: [UInt8], declaredType: String? = nil) {
    let name = Self.fileName(name)
    self.name = name
    self.bytes = bytes
    if let named = ImageMedia.mimeType(ofPath: name), ImageMedia.mimeType(ofBytes: bytes) == named {
      mimeType = named
      isImage = true
      return
    }
    isImage = false
    let byName = MediaType.of(path: name)
    let declared = declaredType?.split(separator: ";").first.map { $0.trimmed.lowercased() }
    if byName == MediaType.fallback, let declared, declared.contains("/") {
      mimeType = declared
    } else {
      mimeType = byName
    }
  }

  func attachment(at path: String) -> Attachment {
    isImage
      ? .image(path: path, mimeType: mimeType, size: bytes.count, pixels: ImageMedia.pixelSize(ofBytes: bytes))
      : .file(path: path, mimeType: mimeType, size: bytes.count)
  }

  // A name becomes one path component, so what a component forbids is
  // replaced rather than refused.
  static func fileName(_ name: String) -> String {
    let last = name.split(separator: "/").last.map(String.init) ?? ""
    var cleaned = String.UnicodeScalarView()
    for scalar in last.unicodeScalars {
      cleaned.append(isForbidden(scalar) ? "_" : scalar)
    }
    let result = String(String(cleaned).trimmed)
    guard !result.isEmpty, result != ".", result != "..", (try? SpacePath(components: [result])) != nil else {
      return "attachment"
    }
    return result
  }

  private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if "@%#?".unicodeScalars.contains(scalar) { return true }
    if value < 0x20 || (0x7F ... 0x9F).contains(value) { return true }
    if value == 0x2028 || value == 0x2029 { return true }
    return scalar.properties.generalCategory == .format
  }
}

// A stored attachment path is hostless in its conversation's group; a reader
// acting in another group is handed it qualified.
extension Attachment {
  public func named(in home: GroupID, for viewer: GroupID) -> Attachment {
    guard home != viewer, path.hasPrefix("/") else { return self }
    let qualified = FSResolver.address(path, inGroup: home.rawValue)
    return switch self {
    case let .image(_, mimeType, size, pixels): .image(path: qualified, mimeType: mimeType, size: size, pixels: pixels)
    case let .file(_, mimeType, size): .file(path: qualified, mimeType: mimeType, size: size)
    }
  }
}

extension MessageContent {
  public func attachments(in home: GroupID, for viewer: GroupID) -> MessageContent {
    MessageContent(text: text, attachments: attachments.map { $0.named(in: home, for: viewer) })
  }
}

extension Space {
  /// The bytes of an attachment reference as a reader in `group` names it.
  public func attachmentBytes(_ reference: String, readingIn group: GroupID) async throws -> Data {
    if let qualified = try GroupID.address(reference) {
      return try await fs(qualified.group).read(qualified.path).1
    }
    return try await fs(group).read(reference).1
  }
}

enum AttachmentFolder {
  static func path(conversation: ConversationID, at date: Date) throws -> SpacePath {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let time = [parts.hour!, parts.minute!, parts.second!].map { padded($0, 2) }.joined() + "Z"
    return try SpacePath(components: [
      "_", "conversations", conversation.rawValue, "attachments",
      padded(parts.year!, 4), padded(parts.month!, 2), padded(parts.day!, 2), time,
    ])
  }

  static func write(
    _ staged: [(upload: AttachmentUpload, blob: Blob)],
    conversation: ConversationID,
    group: GroupID,
    at date: Date,
    mtime: String,
    in db: Database,
  ) throws -> (rev: Int64, attachments: [Attachment]) {
    let folder = try path(conversation: conversation, at: date)
    let rev = try Substrate.mintRevision(mtime: mtime, group: group, in: db)
    var attachments: [Attachment] = []
    for (upload, blob) in staged {
      let target = try freePath(for: upload.name, in: folder, group: group, db: db)
      try Substrate.writeFile(target, group: group, blob: blob, rev: rev, mtime: mtime, in: db)
      attachments.append(upload.attachment(at: target.rawValue))
    }
    return (rev, attachments)
  }

  private static func freePath(for name: String, in folder: SpacePath, group: GroupID, db: Database) throws -> SpacePath {
    let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
    let stem = dot.map { String(name[..<$0]) } ?? name
    let suffix = dot.map { String(name[$0...]) } ?? ""
    var candidate = try SpacePath(components: folder.components + [name])
    var ordinal = 1
    while try Substrate.head(candidate, group: group, in: db) != nil {
      ordinal += 1
      candidate = try SpacePath(components: folder.components + ["\(stem)-\(ordinal)\(suffix)"])
    }
    return candidate
  }

  private static func padded(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }
}

extension StringProtocol {
  fileprivate var trimmed: SubSequence {
    let start = firstIndex { $0 != " " && $0 != "\t" } ?? endIndex
    let end = lastIndex { $0 != " " && $0 != "\t" }.map(index(after:)) ?? start
    return self[start ..< end]
  }
}
