// The presentation seam: transports may buffer megabytes (exec's crash-replay
// window), but one oversized tool result in the transcript can poison every
// inference attempt, including the compact call that would rescue the session.
public enum ToolOutput {
  public static let maxLines: Int = 2000
  public static let maxBytes: Int = 50 << 10
  public static let matchedLineBytes: Int = 500
  public static let backstopBytes: Int = 128 << 10
  public static let maxImageDataBytes: Int = 4 << 20

  public struct Clamp: Hashable, Sendable {
    public var text: String
    // 1-indexed; nil when not even one whole line fit and text is a partial
    // slice of a single oversized line.
    public var shownLines: ClosedRange<Int>?
    public var totalLines: Int
    public var totalBytes: Int
    public var clamped: Bool
  }

  public static func head(_ content: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> Clamp {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let totalBytes = content.utf8.count
    var taken = 0
    var bytes = 0
    while taken < min(lines.count, maxLines) {
      let cost = lines[taken].utf8.count + (taken == 0 ? 0 : 1)
      guard bytes + cost <= maxBytes else { break }
      bytes += cost
      taken += 1
    }
    if taken == lines.count {
      return Clamp(text: content, shownLines: shown(1, taken), totalLines: lines.count, totalBytes: totalBytes, clamped: false)
    }
    guard taken > 0 else {
      return Clamp(
        text: String(prefixBytes(lines[0], maxBytes)),
        shownLines: nil,
        totalLines: lines.count,
        totalBytes: totalBytes,
        clamped: true,
      )
    }
    return Clamp(
      text: lines[..<taken].joined(separator: "\n"),
      shownLines: shown(1, taken),
      totalLines: lines.count,
      totalBytes: totalBytes,
      clamped: true,
    )
  }

  public static func tail(_ content: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> Clamp {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let totalBytes = content.utf8.count
    var taken = 0
    var bytes = 0
    while taken < min(lines.count, maxLines) {
      let line = lines[lines.count - 1 - taken]
      let cost = line.utf8.count + (taken == 0 ? 0 : 1)
      guard bytes + cost <= maxBytes else { break }
      bytes += cost
      taken += 1
    }
    if taken == lines.count {
      return Clamp(text: content, shownLines: shown(1, taken), totalLines: lines.count, totalBytes: totalBytes, clamped: false)
    }
    guard taken > 0 else {
      return Clamp(
        text: String(suffixBytes(lines[lines.count - 1], maxBytes)),
        shownLines: nil,
        totalLines: lines.count,
        totalBytes: totalBytes,
        clamped: true,
      )
    }
    return Clamp(
      text: lines[(lines.count - taken)...].joined(separator: "\n"),
      shownLines: shown(lines.count - taken + 1, taken),
      totalLines: lines.count,
      totalBytes: totalBytes,
      clamped: true,
    )
  }

  public static func clampedLine(_ line: String, maxBytes: Int = matchedLineBytes) -> String {
    guard line.utf8.count > maxBytes else { return line }
    return prefixBytes(line[...], maxBytes) + "…[line clamped: \(line.utf8.count) bytes]"
  }

  private static func shown(_ first: Int, _ count: Int) -> ClosedRange<Int>? {
    count > 0 ? first ... (first + count - 1) : nil
  }
}

// A clamp must never split a code point.
private func prefixBytes(_ text: Substring, _ maxBytes: Int) -> Substring {
  var bytes = 0
  var end = text.startIndex
  for index in text.indices {
    bytes += text[index].utf8.count
    guard bytes <= maxBytes else { break }
    end = text.index(after: index)
  }
  return text[..<end]
}

private func suffixBytes(_ text: Substring, _ maxBytes: Int) -> Substring {
  var bytes = 0
  var start = text.endIndex
  for index in text.indices.reversed() {
    bytes += text[index].utf8.count
    guard bytes <= maxBytes else { break }
    start = index
  }
  return text[start...]
}

extension ToolResultPayload {
  public func clamped(limit: Int = ToolOutput.backstopBytes) -> ToolResultPayload {
    switch self {
    case let .read(result):
      var result = result
      result.content = backstopped(result.content, limit)
      // Only bytes carried in the row can poison it; a stored image is fitted
      // to the model when the request is built.
      if let image = result.image, case .inline = image.source, image.byteCount > ToolOutput.maxImageDataBytes {
        result.image = nil
        result.content += "\n[kernel backstop: attached image was \(image.byteCount) bytes; dropped]"
      }
      return .read(result)
    case let .exec(result):
      var result = result
      result.output = backstopped(result.output, limit)
      return .exec(result)
    case let .grep(result):
      var result = result
      result.output = backstopped(result.output, limit)
      return .grep(result)
    case let .find(result):
      var result = result
      result.output = backstopped(result.output, limit)
      return .find(result)
    case let .query(result):
      var result = result
      result.output = backstopped(result.output, limit)
      return .query(result)
    case let .script(result):
      var result = result
      result.output = backstopped(result.output, limit)
      return .script(result)
    case let .failure(failure):
      var failure = failure
      failure.message = backstopped(failure.message, limit)
      return .failure(failure)
    case .write, .edit, .mount, .machines, .templates, .observe, .timer, .cancelObservation, .cancelTimer,
         .sendMessage, .request, .report, .createSession, .setTitle, .manipulateUI, .compact:
      return self
    }
  }
}

private func backstopped(_ text: String, _ limit: Int) -> String {
  ToolOutput.backstopped(text, naming: "tool result", limit: limit)
}

extension ToolOutput {
  static func backstopped(_ text: String, naming what: String, limit: Int = backstopBytes) -> String {
    guard text.utf8.count > limit else { return text }
    let clamp = head(text, maxLines: .max, maxBytes: limit)
    return clamp.text + "\n[kernel backstop: \(what) was \(text.utf8.count) bytes; showing the first \(clamp.text.utf8.count)]"
  }
}
