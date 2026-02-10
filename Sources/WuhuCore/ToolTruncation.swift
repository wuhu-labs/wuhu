import Foundation

public enum ToolTruncation {
  public static let defaultMaxLines = 2000
  public static let defaultMaxBytes = 50 * 1024
  public static let grepMaxLineLength = 500

  public struct Options: Sendable, Hashable {
    public var maxLines: Int
    public var maxBytes: Int

    public init(maxLines: Int = ToolTruncation.defaultMaxLines, maxBytes: Int = ToolTruncation.defaultMaxBytes) {
      self.maxLines = maxLines
      self.maxBytes = maxBytes
    }
  }

  public struct Result: Sendable, Hashable {
    public var content: String
    public var truncated: Bool
    public var truncatedBy: String?
    public var totalLines: Int
    public var totalBytes: Int
    public var outputLines: Int
    public var outputBytes: Int
    public var lastLinePartial: Bool
    public var firstLineExceedsLimit: Bool
    public var maxLines: Int
    public var maxBytes: Int

    public func toJSON() -> JSONValue {
      .object([
        "content": .string(content),
        "truncated": .bool(truncated),
        "truncatedBy": truncatedBy.map(JSONValue.string) ?? .null,
        "totalLines": .number(Double(totalLines)),
        "totalBytes": .number(Double(totalBytes)),
        "outputLines": .number(Double(outputLines)),
        "outputBytes": .number(Double(outputBytes)),
        "lastLinePartial": .bool(lastLinePartial),
        "firstLineExceedsLimit": .bool(firstLineExceedsLimit),
        "maxLines": .number(Double(maxLines)),
        "maxBytes": .number(Double(maxBytes)),
      ])
    }
  }

  public static func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
    return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
  }

  public static func truncateHead(_ content: String, options: Options = .init()) -> Result {
    let maxLines = options.maxLines
    let maxBytes = options.maxBytes

    let totalBytes = content.utf8.count
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let totalLines = lines.count

    if totalLines <= maxLines, totalBytes <= maxBytes {
      return .init(
        content: content,
        truncated: false,
        truncatedBy: nil,
        totalLines: totalLines,
        totalBytes: totalBytes,
        outputLines: totalLines,
        outputBytes: totalBytes,
        lastLinePartial: false,
        firstLineExceedsLimit: false,
        maxLines: maxLines,
        maxBytes: maxBytes,
      )
    }

    let firstLineBytes = lines.first?.utf8.count ?? 0
    if firstLineBytes > maxBytes {
      return .init(
        content: "",
        truncated: true,
        truncatedBy: "bytes",
        totalLines: totalLines,
        totalBytes: totalBytes,
        outputLines: 0,
        outputBytes: 0,
        lastLinePartial: false,
        firstLineExceedsLimit: true,
        maxLines: maxLines,
        maxBytes: maxBytes,
      )
    }

    var outputLinesArr: [String] = []
    outputLinesArr.reserveCapacity(min(lines.count, maxLines))

    var outputBytesCount = 0
    var truncatedBy = "lines"

    for i in 0 ..< lines.count {
      if i >= maxLines { break }
      let line = lines[i]
      let lineBytes = line.utf8.count + (i > 0 ? 1 : 0)
      if outputBytesCount + lineBytes > maxBytes {
        truncatedBy = "bytes"
        break
      }
      outputLinesArr.append(line)
      outputBytesCount += lineBytes
    }

    if outputLinesArr.count >= maxLines, outputBytesCount <= maxBytes {
      truncatedBy = "lines"
    }

    let outputContent = outputLinesArr.joined(separator: "\n")
    let finalOutputBytes = outputContent.utf8.count

    return .init(
      content: outputContent,
      truncated: true,
      truncatedBy: truncatedBy,
      totalLines: totalLines,
      totalBytes: totalBytes,
      outputLines: outputLinesArr.count,
      outputBytes: finalOutputBytes,
      lastLinePartial: false,
      firstLineExceedsLimit: false,
      maxLines: maxLines,
      maxBytes: maxBytes,
    )
  }

  public static func truncateTail(_ content: String, options: Options = .init()) -> Result {
    let maxLines = options.maxLines
    let maxBytes = options.maxBytes

    let totalBytes = content.utf8.count
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let totalLines = lines.count

    if totalLines <= maxLines, totalBytes <= maxBytes {
      return .init(
        content: content,
        truncated: false,
        truncatedBy: nil,
        totalLines: totalLines,
        totalBytes: totalBytes,
        outputLines: totalLines,
        outputBytes: totalBytes,
        lastLinePartial: false,
        firstLineExceedsLimit: false,
        maxLines: maxLines,
        maxBytes: maxBytes,
      )
    }

    var outputLinesArr: [String] = []
    outputLinesArr.reserveCapacity(min(lines.count, maxLines))

    var outputBytesCount = 0
    var truncatedBy = "lines"
    var lastLinePartial = false

    var i = lines.count - 1
    while i >= 0, outputLinesArr.count < maxLines {
      let line = lines[i]
      let lineBytes = line.utf8.count + (outputLinesArr.isEmpty ? 0 : 1)

      if outputBytesCount + lineBytes > maxBytes {
        truncatedBy = "bytes"
        if outputLinesArr.isEmpty {
          let truncatedLine = truncateStringToBytesFromEnd(line, maxBytes: maxBytes)
          outputLinesArr.insert(truncatedLine, at: 0)
          outputBytesCount = truncatedLine.utf8.count
          lastLinePartial = true
        }
        break
      }

      outputLinesArr.insert(line, at: 0)
      outputBytesCount += lineBytes

      if i == 0 { break }
      i -= 1
    }

    if outputLinesArr.count >= maxLines, outputBytesCount <= maxBytes {
      truncatedBy = "lines"
    }

    let outputContent = outputLinesArr.joined(separator: "\n")
    let finalOutputBytes = outputContent.utf8.count

    return .init(
      content: outputContent,
      truncated: true,
      truncatedBy: truncatedBy,
      totalLines: totalLines,
      totalBytes: totalBytes,
      outputLines: outputLinesArr.count,
      outputBytes: finalOutputBytes,
      lastLinePartial: lastLinePartial,
      firstLineExceedsLimit: false,
      maxLines: maxLines,
      maxBytes: maxBytes,
    )
  }

  private static func truncateStringToBytesFromEnd(_ str: String, maxBytes: Int) -> String {
    let data = Data(str.utf8)
    if data.count <= maxBytes { return str }

    var start = data.count - maxBytes
    // Find a UTF-8 boundary (start of character).
    while start < data.count, (data[start] & 0xC0) == 0x80 {
      start += 1
    }
    let slice = data.subdata(in: start ..< data.count)
    return String(decoding: slice, as: UTF8.self)
  }

  public static func truncateLine(_ line: String, maxChars: Int = ToolTruncation.grepMaxLineLength) -> (text: String, wasTruncated: Bool) {
    if line.count <= maxChars { return (line, false) }
    let idx = line.index(line.startIndex, offsetBy: maxChars)
    return ("\(line[..<idx])... [truncated]", true)
  }
}
