import Foundation
import PiAI

public enum WuhuSessionVerbosity: String, CaseIterable, Sendable, Hashable, Codable {
  case full
  case compact
  case minimal
}

public enum WuhuSessionDisplayRole: String, Sendable, Hashable, Codable {
  case user
  case agent
  case system
  case tool
  case meta
}

public struct WuhuSessionDisplayItem: Identifiable, Sendable, Hashable {
  public var id: String
  public var role: WuhuSessionDisplayRole
  public var title: String
  public var text: String

  public init(id: String, role: WuhuSessionDisplayRole, title: String, text: String) {
    self.id = id
    self.role = role
    self.title = title
    self.text = text
  }
}

public struct WuhuSessionTranscriptFormatter: Sendable {
  public var verbosity: WuhuSessionVerbosity

  public init(verbosity: WuhuSessionVerbosity) {
    self.verbosity = verbosity
  }

  public func format(_ entries: [WuhuSessionEntry]) -> [WuhuSessionDisplayItem] {
    var items: [WuhuSessionDisplayItem] = []
    items.reserveCapacity(entries.count)

    var toolArgsById: [String: JSONValue] = [:]
    var toolEndsHandled: Set<String> = []

    var pendingTools = 0
    var pendingCompactions = 0
    var printedAnyVisibleMessage = false

    func appendMetaIfNeeded() {
      guard verbosity == .minimal else { return }
      guard printedAnyVisibleMessage else {
        pendingTools = 0
        pendingCompactions = 0
        return
      }

      if pendingTools > 0 {
        let suffix = pendingTools == 1 ? "" : "s"
        items.append(.init(
          id: "meta.tools.\(items.count)",
          role: .meta,
          title: "",
          text: "Executed \(pendingTools) tool\(suffix)",
        ))
        pendingTools = 0
      }

      if pendingCompactions > 0 {
        let suffix = pendingCompactions == 1 ? "" : "s"
        items.append(.init(
          id: "meta.compaction.\(items.count)",
          role: .meta,
          title: "",
          text: "Compacted context \(pendingCompactions) time\(suffix)",
        ))
        pendingCompactions = 0
      }
    }

    func appendVisibleMessage(id: String, role: WuhuSessionDisplayRole, title: String, text: String) {
      appendMetaIfNeeded()

      let truncation: DisplayTruncation = (verbosity == .full) ? .messageFull : .messageCompact
      let truncated = truncateForDisplay(text.trimmingCharacters(in: .whitespacesAndNewlines), options: truncation)
        .trimmingCharacters(in: .newlines)
      items.append(.init(id: id, role: role, title: title, text: truncated))
      printedAnyVisibleMessage = true
    }

    func appendToolLine(id: String, toolName: String, toolCallId: String, result: WuhuToolResult?, isError: Bool) {
      if verbosity == .minimal {
        pendingTools += 1
        return
      }

      let line = toolSummaryLine(
        .init(toolName: toolName, args: toolArgsById[toolCallId], result: result, isError: isError),
        verbosity: verbosity,
      )

      var text = line + (isError ? " (error)" : "")
      if let details = toolDetailsForDisplay(
        .init(toolName: toolName, args: toolArgsById[toolCallId], result: result, isError: isError),
        verbosity: verbosity,
      ) {
        text += "\n\n" + details
      }

      items.append(.init(id: id, role: .tool, title: "Tool:", text: text))
    }

    func appendMetaLine(id: String, text: String) {
      appendMetaIfNeeded()
      items.append(.init(id: id, role: .meta, title: "", text: text))
      printedAnyVisibleMessage = true
    }

    for entry in entries {
      switch entry.payload {
      case let .message(m):
        switch m {
        case let .user(u):
          let text = renderTextBlocks(u.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          appendVisibleMessage(id: "entry.\(entry.id)", role: .user, title: "User:", text: text)

        case let .assistant(a):
          let text = renderTextBlocks(a.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          appendVisibleMessage(id: "entry.\(entry.id)", role: .agent, title: "Agent:", text: text)

        case let .customMessage(c):
          guard c.display else { break }
          let text = renderTextBlocks(c.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          appendVisibleMessage(id: "entry.\(entry.id)", role: .system, title: "System:", text: text)

        case let .toolResult(t):
          if toolEndsHandled.contains(t.toolCallId) { break }
          let result = WuhuToolResult(content: t.content, details: t.details)
          appendToolLine(
            id: "entry.\(entry.id)",
            toolName: t.toolName,
            toolCallId: t.toolCallId,
            result: result,
            isError: t.isError,
          )

        case .unknown:
          break
        }

      case let .toolExecution(t):
        switch t.phase {
        case .start:
          toolArgsById[t.toolCallId] = t.arguments

        case .end:
          toolEndsHandled.insert(t.toolCallId)
          let result = t.result.flatMap { decodeFromJSONValue($0, as: WuhuToolResult.self) }
          let isError = t.isError ?? false
          appendToolLine(
            id: "entry.\(entry.id)",
            toolName: t.toolName,
            toolCallId: t.toolCallId,
            result: result,
            isError: isError,
          )
        }

      case let .compaction(c):
        if verbosity == .minimal {
          pendingCompactions += 1
          break
        }
        if verbosity == .compact { break }

        let prefix = "Compaction: tokensBefore=\(c.tokensBefore) firstKeptEntryID=\(c.firstKeptEntryID)"
        let summary = truncateForDisplay(c.summary, options: .toolFull)
        items.append(.init(
          id: "entry.\(entry.id)",
          role: .system,
          title: "System:",
          text: prefix + "\n\n" + summary,
        ))

      case let .header(h):
        guard verbosity == .full else { break }
        let text = truncateForDisplay(h.systemPrompt, options: .messageCompact)
        items.append(.init(id: "entry.\(entry.id)", role: .system, title: "System:", text: "System prompt:\n\n" + text))

      case let .sessionSettings(s):
        appendMetaIfNeeded()
        let effort = s.reasoningEffort?.rawValue ?? "default"
        items.append(.init(
          id: "entry.\(entry.id)",
          role: .meta,
          title: "",
          text: "Model changed: \(s.provider.rawValue) / \(s.model) (reasoning=\(effort))",
        ))
        printedAnyVisibleMessage = true

      case let .custom(customType, data):
        guard let data else { break }

        if customType == WuhuLLMCustomEntryTypes.retry, let evt = decodeFromJSONValue(data, as: WuhuLLMRetryEvent.self) {
          let purpose = evt.purpose.map { " \($0)" } ?? ""
          let err = commandPrefix(collapseWhitespace(evt.error), maxChars: 240)
          appendMetaLine(
            id: "entry.\(entry.id)",
            text: "LLM retry\(purpose): \(evt.retryIndex)/\(evt.maxRetries) in \(String(format: "%.2f", evt.backoffSeconds))s (\(err))",
          )
          break
        }

        if customType == WuhuLLMCustomEntryTypes.giveUp, let evt = decodeFromJSONValue(data, as: WuhuLLMGiveUpEvent.self) {
          let purpose = evt.purpose.map { " \($0)" } ?? ""
          let err = commandPrefix(collapseWhitespace(evt.error), maxChars: 240)
          appendMetaLine(
            id: "entry.\(entry.id)",
            text: "LLM failed\(purpose) after \(evt.maxRetries) retries (\(err))",
          )
          break
        }

      case .unknown:
        break
      }
    }

    if verbosity == .minimal, pendingTools > 0 || pendingCompactions > 0 {
      appendMetaIfNeeded()
    }

    return items
  }
}

private struct DisplayTruncation: Sendable {
  var maxLines: Int
  var maxChars: Int

  static let messageFull = DisplayTruncation(maxLines: 200, maxChars: 24000)
  static let messageCompact = DisplayTruncation(maxLines: 40, maxChars: 6000)
  static let toolFull = DisplayTruncation(maxLines: 12, maxChars: 2000)
}

private func truncateForDisplay(_ text: String, options: DisplayTruncation) -> String {
  if text.isEmpty { return text }

  var remainingChars = options.maxChars
  var outputLines: [String] = []
  outputLines.reserveCapacity(min(options.maxLines, 64))

  let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  for (idx, line) in lines.enumerated() {
    if idx >= options.maxLines { break }
    if remainingChars <= 0 { break }

    if line.count <= remainingChars {
      outputLines.append(line)
      remainingChars -= line.count
    } else {
      outputLines.append(String(line.prefix(remainingChars)))
      remainingChars = 0
      break
    }
  }

  let joined = outputLines.joined(separator: "\n")
  let truncatedByLines = lines.count > options.maxLines
  let truncatedByChars = text.count > options.maxChars

  if truncatedByLines || truncatedByChars {
    return joined + "\n" + "[truncated]"
  }
  return joined
}

private func collapseWhitespace(_ text: String) -> String {
  text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func commandPrefix(_ command: String, maxChars: Int) -> String {
  let collapsed = collapseWhitespace(command)
  if collapsed.count <= maxChars { return collapsed }
  return String(collapsed.prefix(maxChars)) + "..."
}

private func decodeFromJSONValue<T: Decodable>(_ value: JSONValue, as _: T.Type) -> T? {
  guard JSONSerialization.isValidJSONObject(value.toAny()),
        let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [])
  else { return nil }
  return try? JSONDecoder().decode(T.self, from: data)
}

private func renderTextBlocks(_ blocks: [WuhuContentBlock]) -> String {
  blocks.compactMap { block -> String? in
    switch block {
    case let .text(text, _):
      text
    case .toolCall, .reasoning:
      nil
    }
  }.joined()
}

private struct ToolRenderInput: Sendable {
  var toolName: String
  var args: JSONValue?
  var result: WuhuToolResult?
  var isError: Bool
}

private func toolSummaryLine(_ input: ToolRenderInput, verbosity: WuhuSessionVerbosity) -> String {
  func argString(_ key: String) -> String? {
    input.args?.object?[key]?.stringValue
  }

  switch input.toolName {
  case "read", "write", "edit":
    if let path = argString("path") { return "\(input.toolName) \(path)" }
    return input.toolName

  case "bash":
    if let command = argString("command") {
      let max = (verbosity == .compact) ? 80 : 140
      return "bash \(commandPrefix(command, maxChars: max))"
    }
    return "bash"

  case "grep":
    let pattern = argString("pattern")
    let path = argString("path")
    if let pattern, let path { return "grep \(commandPrefix(pattern, maxChars: 60)) \(path)" }
    if let pattern { return "grep \(commandPrefix(pattern, maxChars: 60))" }
    return "grep"

  case "ls":
    if let path = argString("path") { return "ls \(path)" }
    return "ls"

  case "find":
    if let pattern = argString("pattern") { return "find \(commandPrefix(pattern, maxChars: 60))" }
    return "find"

  case "swift":
    let args = input.args?.object?["args"]?.array?.compactMap(\.stringValue) ?? []
    if !args.isEmpty { return "swift args=\(args.joined(separator: ","))" }
    return "swift"

  default:
    return input.toolName
  }
}

private func toolDetailsForDisplay(_ input: ToolRenderInput, verbosity: WuhuSessionVerbosity) -> String? {
  guard verbosity == .full else { return nil }

  if input.toolName == "read" || input.toolName == "write" || input.toolName == "edit" {
    return nil
  }

  guard let result = input.result else { return nil }
  let text = renderTextBlocks(result.content)
  if text.isEmpty { return nil }
  return truncateForDisplay(text, options: .toolFull)
}
