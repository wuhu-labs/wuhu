#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

struct _SSEParser {
  private var pendingLine = Data()
  private var hasStrippedUTF8BOM = false
  private var pendingLineFeedAfterCarriageReturn = false
  private var state = _SSEEventState()
  private var lastEventID: String?

  mutating func parse(_ bytes: Bytes) throws -> [SSEEvent] {
    var events: [SSEEvent] = []
    var index = bytes.startIndex

    while index < bytes.endIndex {
      let byte = bytes[index]

      if self.pendingLineFeedAfterCarriageReturn {
        self.pendingLineFeedAfterCarriageReturn = false

        if byte == 0x0A {
          index = bytes.index(after: index)
          continue
        }
      }

      switch byte {
      case 0x0A:
        try self.parseCompletedLine(into: &events)
        index = bytes.index(after: index)

      case 0x0D:
        try self.parseCompletedLine(into: &events)
        self.pendingLineFeedAfterCarriageReturn = true
        index = bytes.index(after: index)

      default:
        self.pendingLine.append(byte)
        index = bytes.index(after: index)
      }
    }

    return events
  }

  mutating func finish() throws -> [SSEEvent] {
    var events: [SSEEvent] = []

    if !self.pendingLine.isEmpty {
      try self.parseCompletedLine(into: &events)
    }

    if let event = self.state.dispatch(lastEventID: self.lastEventID) {
      events.append(event)
    }

    return events
  }

  private mutating func parseCompletedLine(into events: inout [SSEEvent]) throws {
    if !self.hasStrippedUTF8BOM {
      self.stripUTF8BOMIfNeeded()
      self.hasStrippedUTF8BOM = true
    }

    defer { self.pendingLine.removeAll(keepingCapacity: true) }

    if self.pendingLine.isEmpty {
      if let event = self.state.dispatch(lastEventID: self.lastEventID) {
        events.append(event)
      }
      return
    }

    if self.pendingLine[self.pendingLine.startIndex] == 0x3A {
      return
    }

    let (field, value) = try self.parseField(self.pendingLine)

    switch field {
    case "data":
      self.state.dataLines.append(value)

    case "event":
      self.state.event = value.isEmpty ? nil : value

    case "id":
      guard !value.utf8.contains(0) else { return }
      self.lastEventID = value.isEmpty ? nil : value

    case "retry":
      guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) else { return }
      self.state.retry = Int(value)

    default:
      return
    }
  }

  private mutating func stripUTF8BOMIfNeeded() {
    let bom = Data([0xEF, 0xBB, 0xBF])
    guard self.pendingLine.count >= bom.count else { return }

    if self.pendingLine.prefix(bom.count) == bom {
      self.pendingLine.removeFirst(bom.count)
    }
  }

  private func parseField(_ line: Bytes) throws -> (String, String) {
    if let colonIndex = line.firstIndex(of: 0x3A) {
      let fieldBytes = line[..<colonIndex]
      var valueStart = line.index(after: colonIndex)

      if valueStart < line.endIndex, line[valueStart] == 0x20 {
        valueStart = line.index(after: valueStart)
      }

      let valueBytes = line[valueStart...]
      return (try self.decode(fieldBytes), try self.decode(valueBytes))
    }

    return (try self.decode(line), "")
  }

  private func decode(_ bytes: Data) throws -> String {
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw FetchError.invalidTextEncoding
    }
    return string
  }
}

private struct _SSEEventState {
  var event: String?
  var dataLines: [String] = []
  var retry: Int?

  mutating func dispatch(lastEventID: String?) -> SSEEvent? {
    defer { self = Self() }

    guard !self.dataLines.isEmpty else {
      return nil
    }

    return SSEEvent(
      event: self.event ?? "message",
      data: self.dataLines.joined(separator: "\n"),
      id: lastEventID,
      retry: self.retry,
    )
  }
}
