public struct ClaudeStreamReader: Sendable {
  private var buffer: [UInt8] = []
  private var lineStart = 0
  private var scanned = 0

  public init() {}

  public mutating func read(_ chunk: some Sequence<UInt8>) -> [ClaudeStreamFrame] {
    buffer.append(contentsOf: chunk)
    var frames: [ClaudeStreamFrame] = []
    while let newline = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
      if newline > lineStart {
        frames.append(ClaudeStreamFrame(line: buffer[lineStart ..< newline]))
      }
      lineStart = newline + 1
      scanned = lineStart
    }
    scanned = buffer.count
    if lineStart == buffer.count || lineStart > buffer.count / 2 {
      buffer.removeFirst(lineStart)
      scanned -= lineStart
      lineStart = 0
    }
    return frames
  }

  public mutating func finish() -> ClaudeStreamFrame? {
    defer { self = Self() }
    return lineStart < buffer.count ? ClaudeStreamFrame(line: buffer[lineStart...]) : nil
  }
}
