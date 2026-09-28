public enum MediaType {
  public static let fallback: String = "application/octet-stream"

  public static func of(path: String) -> String {
    let name = path.split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return fallback }
    return types[name[name.index(after: dot)...].lowercased()] ?? fallback
  }

  private static let types: [String: String] = [
    "7z": "application/x-7z-compressed",
    "aac": "audio/aac",
    "avi": "video/x-msvideo",
    "css": "text/css",
    "csv": "text/csv",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "flac": "audio/flac",
    "gif": "image/gif",
    "gz": "application/gzip",
    "heic": "image/heic",
    "htm": "text/html",
    "html": "text/html",
    "ico": "image/x-icon",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "js": "text/javascript",
    "json": "application/json",
    "log": "text/plain",
    "m4a": "audio/mp4",
    "m4v": "video/x-m4v",
    "map": "application/json",
    "md": "text/markdown",
    "mjs": "text/javascript",
    "mkv": "video/x-matroska",
    "mov": "video/quicktime",
    "mp3": "audio/mpeg",
    "mp4": "video/mp4",
    "ogg": "audio/ogg",
    "pdf": "application/pdf",
    "png": "image/png",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "svg": "image/svg+xml",
    "tar": "application/x-tar",
    "tgz": "application/gzip",
    "txt": "text/plain",
    "view": "application/json",
    "wav": "audio/wav",
    "webm": "video/webm",
    "webmanifest": "application/manifest+json",
    "webp": "image/webp",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "xml": "application/xml",
    "zip": "application/zip",
  ]
}

public enum AttachmentLimits {
  public static let maxPerMessage: Int = 8
  public static let maxFileBytes: Int = 50 << 20
  public static let maxTotalBytes: Int = 150 << 20
}

public enum AttachmentRefusal: Error, Equatable, Sendable {
  case tooMany(name: String)
  case fileTooLarge(name: String)
  case totalTooLarge(name: String)

  public var code: String {
    switch self {
    case .tooMany: "tooManyAttachments"
    case .fileTooLarge: "attachmentTooLarge"
    case .totalTooLarge: "attachmentsTooLarge"
    }
  }

  public var message: String {
    switch self {
    case let .tooMany(name):
      "a message carries at most \(AttachmentLimits.maxPerMessage) attachments; \(name) would be number \(AttachmentLimits.maxPerMessage + 1)"
    case let .fileTooLarge(name):
      "attachment \(name) is over \(AttachmentLimits.maxFileBytes >> 20) MiB; one file is at most \(AttachmentLimits.maxFileBytes) bytes"
    case let .totalTooLarge(name):
      "attachments pass \(AttachmentLimits.maxTotalBytes >> 20) MiB in total at \(name); a message carries at most \(AttachmentLimits.maxTotalBytes) bytes"
    }
  }
}

// Counts a message's attachments as they arrive, so an upload is refused at
// the byte that breaks a limit rather than after the whole body is read.
public struct AttachmentTally: Sendable {
  private var count: Int = 0
  private var total: Int = 0
  private var current: Int = 0

  public init() {}

  public mutating func open(_ name: String) throws(AttachmentRefusal) {
    guard count < AttachmentLimits.maxPerMessage else { throw .tooMany(name: name) }
    count += 1
    current = 0
  }

  public mutating func add(_ bytes: Int, to name: String) throws(AttachmentRefusal) {
    current += bytes
    total += bytes
    guard current <= AttachmentLimits.maxFileBytes else { throw .fileTooLarge(name: name) }
    guard total <= AttachmentLimits.maxTotalBytes else { throw .totalTooLarge(name: name) }
  }

  public mutating func admit(_ name: String, size: Int) throws(AttachmentRefusal) {
    try open(name)
    try add(size, to: name)
  }
}
