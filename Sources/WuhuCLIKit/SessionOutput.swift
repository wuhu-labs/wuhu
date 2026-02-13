import ArgumentParser
import Foundation
import PiAI
import WuhuAPI

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public enum SessionOutputVerbosity: String, CaseIterable, ExpressibleByArgument, Sendable {
  case full
  case compact
  case minimal
}

public struct TerminalCapabilities: Sendable {
  public var stdoutIsTTY: Bool
  public var stderrIsTTY: Bool
  public var colorEnabled: Bool

  public init(
    stdoutIsTTY: Bool,
    stderrIsTTY: Bool,
    colorEnabled: Bool,
  ) {
    self.stdoutIsTTY = stdoutIsTTY
    self.stderrIsTTY = stderrIsTTY
    self.colorEnabled = colorEnabled
  }

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    // Avoid referencing C stdio globals (`stdout` / `stderr`), which Swift 6 strict
    // concurrency treats as unsafe shared mutable state (notably on Linux).
    stdoutIsTTY = isatty(STDOUT_FILENO) != 0
    stderrIsTTY = isatty(STDERR_FILENO) != 0

    let noColor = environment["WUHU_NO_COLOR"] != nil || environment["NO_COLOR"] != nil
    colorEnabled = !noColor
  }
}

enum ANSI {
  static let reset = "\u{001B}[0m"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"
  static let blue = "\u{001B}[34m"
  static let green = "\u{001B}[32m"
  static let cyan = "\u{001B}[36m"

  static func wrap(_ text: String, _ code: String, enabled: Bool) -> String {
    guard enabled else { return text }
    return code + text + reset
  }
}

public struct SessionOutputStyle: Sendable {
  public var verbosity: SessionOutputVerbosity
  public var terminal: TerminalCapabilities

  public init(verbosity: SessionOutputVerbosity, terminal: TerminalCapabilities) {
    self.verbosity = verbosity
    self.terminal = terminal
  }

  public func displayTimestamp(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy/MM/dd HH:mm:ss'Z'"
    return fmt.string(from: date)
  }

  public var separator: String {
    let base = "-----"
    return ANSI.wrap(base, ANSI.dim, enabled: terminal.colorEnabled && terminal.stdoutIsTTY)
  }

  public func userLabel() -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap("User:", ANSI.bold + ANSI.blue, enabled: enabled)
  }

  public func userLabel(cursor: Int64, createdAt: Date) -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    let base = "User (\(cursor), \(displayTimestamp(createdAt))):"
    return ANSI.wrap(base, ANSI.bold + ANSI.blue, enabled: enabled)
  }

  public func userLabel(user: String, cursor: Int64, createdAt: Date) -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    let base = "User \(user) (\(cursor), \(displayTimestamp(createdAt))):"
    return ANSI.wrap(base, ANSI.bold + ANSI.blue, enabled: enabled)
  }

  public func systemLabel() -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap("System:", ANSI.bold + ANSI.cyan, enabled: enabled)
  }

  public func systemLabel(cursor: Int64, createdAt: Date) -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    let base = "System (\(cursor), \(displayTimestamp(createdAt))):"
    return ANSI.wrap(base, ANSI.bold + ANSI.cyan, enabled: enabled)
  }

  public func agentLabel() -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap("Agent:", ANSI.bold + ANSI.green, enabled: enabled)
  }

  public func agentLabel(cursor: Int64, createdAt: Date) -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    let base = "Agent (\(cursor), \(displayTimestamp(createdAt))):"
    return ANSI.wrap(base, ANSI.bold + ANSI.green, enabled: enabled)
  }

  public func meta(_ text: String) -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap(text, ANSI.dim, enabled: enabled)
  }

  public func tool(_ text: String) -> String {
    let enabled = terminal.colorEnabled && terminal.stderrIsTTY
    return ANSI.wrap(text, ANSI.cyan, enabled: enabled)
  }
}

struct DisplayTruncation: Sendable {
  var maxLines: Int
  var maxChars: Int

  static let messageFull = DisplayTruncation(maxLines: 200, maxChars: 24000)
  static let messageCompact = DisplayTruncation(maxLines: 40, maxChars: 6000)

  static let toolFull = DisplayTruncation(maxLines: 12, maxChars: 2000)
}

func truncateForDisplay(_ text: String, options: DisplayTruncation) -> String {
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
      let prefix = String(line.prefix(remainingChars))
      outputLines.append(prefix)
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

func collapseWhitespace(_ text: String) -> String {
  text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func commandPrefix(_ command: String, maxChars: Int) -> String {
  let collapsed = collapseWhitespace(command)
  if collapsed.count <= maxChars { return collapsed }
  return String(collapsed.prefix(maxChars)) + "..."
}

func renderCustomEntryMetaLine(customType: String, data: JSONValue?) -> String? {
  guard let data else { return nil }

  if customType == WuhuLLMCustomEntryTypes.retry, let evt = decodeFromJSONValue(data, as: WuhuLLMRetryEvent.self) {
    let purpose = evt.purpose.map { " \($0)" } ?? ""
    let err = commandPrefix(collapseWhitespace(evt.error), maxChars: 240)
    return "LLM retry\(purpose): \(evt.retryIndex)/\(evt.maxRetries) in \(String(format: "%.2f", evt.backoffSeconds))s (\(err))"
  }

  if customType == WuhuLLMCustomEntryTypes.giveUp, let evt = decodeFromJSONValue(data, as: WuhuLLMGiveUpEvent.self) {
    let purpose = evt.purpose.map { " \($0)" } ?? ""
    let err = commandPrefix(collapseWhitespace(evt.error), maxChars: 240)
    return "LLM failed\(purpose) after \(evt.maxRetries) retries (\(err))"
  }

  return nil
}

func decodeFromJSONValue<T: Decodable>(_ value: JSONValue, as _: T.Type) -> T? {
  guard JSONSerialization.isValidJSONObject(value.toAny()),
        let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [])
  else { return nil }
  return try? JSONDecoder().decode(T.self, from: data)
}

func renderTextBlocks(_ blocks: [WuhuContentBlock]) -> String {
  blocks.compactMap { block -> String? in
    switch block {
    case let .text(text, _):
      text
    case .toolCall, .reasoning:
      nil
    }
  }.joined()
}

struct ToolRenderInput: Sendable {
  var toolName: String
  var args: JSONValue?
  var result: WuhuToolResult?
  var isError: Bool
}

func toolSummaryLine(_ input: ToolRenderInput, verbosity: SessionOutputVerbosity) -> String {
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

func toolDetailsForDisplay(_ input: ToolRenderInput, verbosity: SessionOutputVerbosity) -> String? {
  guard verbosity == .full else { return nil }

  if input.toolName == "read" || input.toolName == "write" || input.toolName == "edit" {
    return nil
  }

  guard let result = input.result else { return nil }
  let text = renderTextBlocks(result.content)
  if text.isEmpty { return nil }
  return truncateForDisplay(text, options: .toolFull)
}

public struct SessionTranscriptRenderer: Sendable {
  public var style: SessionOutputStyle

  public init(style: SessionOutputStyle) {
    self.style = style
  }

  public func render(_ response: WuhuGetSessionResponse) -> String {
    var out = ""
    out.reserveCapacity(16384)

    let session = response.session
    out += "session \(session.id)\n"
    out += "provider \(session.provider.rawValue)\n"
    out += "model \(session.model)\n"
    out += "environment \(session.environment.name)\n"
    out += "cwd \(session.cwd)\n"
    out += "createdAt \(session.createdAt)\n"
    out += "updatedAt \(session.updatedAt)\n"
    out += "headEntryID \(session.headEntryID)\n"
    out += "tailEntryID \(session.tailEntryID)\n"

    var toolArgsById: [String: JSONValue] = [:]
    var toolEndsHandled: Set<String> = []

    var pendingTools = 0
    var pendingCompactions = 0
    var printedAnyVisibleMessage = false

    func flushPendingMetaIfNeeded() {
      guard style.verbosity == .minimal else { return }
      guard printedAnyVisibleMessage else {
        pendingTools = 0
        pendingCompactions = 0
        return
      }

      if pendingTools > 0 {
        let suffix = pendingTools == 1 ? "" : "s"
        out += "\(style.meta("Executed \(pendingTools) tool\(suffix)"))\n"
        pendingTools = 0
      }
      if pendingCompactions > 0 {
        let suffix = pendingCompactions == 1 ? "" : "s"
        out += "\(style.meta("Compacted context \(pendingCompactions) time\(suffix)"))\n"
        pendingCompactions = 0
      }
    }

    func appendVisibleMessage(label: String, text: String) {
      out += "\n\(style.separator)\n"
      out += "\(label)\n"
      let trunc: DisplayTruncation = (style.verbosity == .full) ? .messageFull : .messageCompact
      out += truncateForDisplay(text, options: trunc).trimmingCharacters(in: .newlines)
      out += "\n"
      printedAnyVisibleMessage = true
    }

    for entry in response.transcript {
      switch entry.payload {
      case let .message(m):
        switch m {
        case let .user(u):
          let text = renderTextBlocks(u.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          flushPendingMetaIfNeeded()
          appendVisibleMessage(label: style.userLabel(user: u.user, cursor: entry.id, createdAt: entry.createdAt), text: text)

        case let .assistant(a):
          let text = renderTextBlocks(a.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          flushPendingMetaIfNeeded()
          appendVisibleMessage(label: style.agentLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)

        case let .toolResult(t):
          if toolEndsHandled.contains(t.toolCallId) { break }
          if style.verbosity == .minimal {
            pendingTools += 1
            break
          }

          let line = toolSummaryLine(
            .init(
              toolName: t.toolName,
              args: toolArgsById[t.toolCallId],
              result: .init(content: t.content, details: t.details),
              isError: t.isError,
            ),
            verbosity: style.verbosity,
          )
          out += "\(style.meta("Tool: \(line)\(t.isError ? " (error)" : "")"))\n"
          if style.verbosity == .full {
            let details = toolDetailsForDisplay(
              .init(
                toolName: t.toolName,
                args: toolArgsById[t.toolCallId],
                result: .init(content: t.content, details: t.details),
                isError: t.isError,
              ),
              verbosity: style.verbosity,
            )
            if let details {
              out += details + "\n"
            }
          }

        case let .customMessage(c):
          guard c.display else { break }
          let text = renderTextBlocks(c.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          flushPendingMetaIfNeeded()
          appendVisibleMessage(label: style.systemLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)

        case .unknown:
          break
        }

      case let .toolExecution(t):
        switch t.phase {
        case .start:
          toolArgsById[t.toolCallId] = t.arguments
        case .end:
          toolEndsHandled.insert(t.toolCallId)
          if style.verbosity == .minimal {
            pendingTools += 1
            break
          }

          let toolResult = t.result.flatMap { decodeFromJSONValue($0, as: WuhuToolResult.self) }
          let isError = t.isError ?? false
          let line = toolSummaryLine(
            .init(toolName: t.toolName, args: toolArgsById[t.toolCallId], result: toolResult, isError: isError),
            verbosity: style.verbosity,
          )
          out += "\(style.meta("Tool: \(line)\(isError ? " (error)" : "")"))\n"
          if let details = toolDetailsForDisplay(
            .init(toolName: t.toolName, args: toolArgsById[t.toolCallId], result: toolResult, isError: isError),
            verbosity: style.verbosity,
          ) {
            out += details + "\n"
          }
        }

      case let .compaction(c):
        if style.verbosity == .minimal {
          pendingCompactions += 1
          break
        }

        if style.verbosity == .compact { break }
        out += "\(style.meta("Compaction: tokensBefore=\(c.tokensBefore) firstKeptEntryID=\(c.firstKeptEntryID)"))\n"
        out += truncateForDisplay(c.summary, options: .toolFull) + "\n"

      case let .header(h):
        if style.verbosity == .minimal || style.verbosity == .compact { break }
        out += "\(style.meta("System prompt:"))\n"
        out += truncateForDisplay(h.systemPrompt, options: .messageCompact) + "\n"

      case let .sessionSettings(s):
        flushPendingMetaIfNeeded()
        let effort = s.reasoningEffort?.rawValue ?? "default"
        out += "\(style.meta("Model changed: \(s.provider.rawValue) / \(s.model) (reasoning=\(effort))"))\n"

      case let .custom(customType, data):
        if let line = renderCustomEntryMetaLine(customType: customType, data: data) {
          flushPendingMetaIfNeeded()
          out += "\(style.meta(line))\n"
          printedAnyVisibleMessage = true
        }

      case .unknown:
        break
      }
    }

    if style.verbosity == .minimal, pendingTools > 0 || pendingCompactions > 0 {
      flushPendingMetaIfNeeded()
    }

    return out
  }
}

public struct SessionStreamPrinter {
  public var style: SessionOutputStyle
  public var stdout: FileHandle
  public var stderr: FileHandle

  private var toolArgsById: [String: JSONValue] = [:]
  private var toolEndsHandled: Set<String> = []

  private var printedAnyAssistantText = false
  private var printedAssistantPreamble = false

  public init(
    style: SessionOutputStyle,
    stdout: FileHandle = .standardOutput,
    stderr: FileHandle = .standardError,
  ) {
    self.style = style
    self.stdout = stdout
    self.stderr = stderr
  }

  public mutating func printEntryIfVisible(_ entry: WuhuSessionEntry) {
    switch entry.payload {
    case let .message(m):
      switch m {
      case let .user(u):
        let text = renderTextBlocks(u.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        appendVisibleMessage(label: style.userLabel(user: u.user, cursor: entry.id, createdAt: entry.createdAt), text: text)
      case let .assistant(a):
        let text = renderTextBlocks(a.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        appendVisibleMessage(label: style.agentLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)
      case let .customMessage(c):
        guard c.display else { return }
        let text = renderTextBlocks(c.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        appendVisibleMessage(label: style.systemLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)
      default:
        break
      }
    default:
      break
    }
  }

  public mutating func handle(_ event: WuhuSessionStreamEvent) {
    switch event {
    case let .entryAppended(entry):
      handleAppendedEntry(entry)

    case let .assistantTextDelta(delta):
      if !printedAssistantPreamble {
        writeStdout("\n\(style.separator)\n")
        writeStdout("\(style.agentLabel())\n")
        printedAssistantPreamble = true
      }
      printedAnyAssistantText = true
      writeStdout(delta)

    case .idle:
      writeStdout("\n\(style.meta("[idle]"))\n")

    case .done:
      if printedAnyAssistantText { writeStdout("\n") }
      printedAnyAssistantText = false
      printedAssistantPreamble = false
    }
  }

  private mutating func handleAppendedEntry(_ entry: WuhuSessionEntry) {
    switch entry.payload {
    case let .message(m):
      switch m {
      case let .user(u):
        resetAssistantStreamingState()
        let text = renderTextBlocks(u.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        appendVisibleMessage(label: style.userLabel(user: u.user, cursor: entry.id, createdAt: entry.createdAt), text: text)

      case let .assistant(a):
        let text = renderTextBlocks(a.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }

        if printedAnyAssistantText {
          resetAssistantStreamingState()
          writeStdout(style.meta("Agent cursor \(entry.id), \(style.displayTimestamp(entry.createdAt))") + "\n")
          return
        }

        resetAssistantStreamingState()
        appendVisibleMessage(label: style.agentLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)

      case let .customMessage(c):
        resetAssistantStreamingState()
        guard c.display else { return }
        let text = renderTextBlocks(c.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        appendVisibleMessage(label: style.systemLabel(cursor: entry.id, createdAt: entry.createdAt), text: text)

      case let .toolResult(t):
        if toolEndsHandled.contains(t.toolCallId) { return }
        if style.verbosity == .minimal { return }

        let line = toolSummaryLine(
          .init(
            toolName: t.toolName,
            args: toolArgsById[t.toolCallId],
            result: .init(content: t.content, details: t.details),
            isError: t.isError,
          ),
          verbosity: style.verbosity,
        )
        writeStderr(style.tool("[tool] \(line)\(t.isError ? " (error)" : "")") + "\n")

      default:
        break
      }

    case let .toolExecution(t):
      switch t.phase {
      case .start:
        toolArgsById[t.toolCallId] = t.arguments
      case .end:
        toolEndsHandled.insert(t.toolCallId)
        defer { toolArgsById.removeValue(forKey: t.toolCallId) }
        guard style.verbosity != .minimal else { return }

        let toolResult = t.result.flatMap { decodeFromJSONValue($0, as: WuhuToolResult.self) }
        let isError = t.isError ?? false
        let line = toolSummaryLine(
          .init(toolName: t.toolName, args: toolArgsById[t.toolCallId], result: toolResult, isError: isError),
          verbosity: style.verbosity,
        )
        writeStderr(style.tool("[tool] \(line)\(isError ? " (error)" : "")") + "\n")
        if let details = toolDetailsForDisplay(
          .init(toolName: t.toolName, args: toolArgsById[t.toolCallId], result: toolResult, isError: isError),
          verbosity: style.verbosity,
        ) {
          writeStderr(details + "\n")
        }
      }

    case let .sessionSettings(s):
      resetAssistantStreamingState()
      let effort = s.reasoningEffort?.rawValue ?? "default"
      writeStdout("\n\(style.meta("Model changed: \(s.provider.rawValue) / \(s.model) (reasoning=\(effort))"))\n")

    case let .custom(customType, data):
      resetAssistantStreamingState()
      guard let line = renderCustomEntryMetaLine(customType: customType, data: data) else { return }
      writeStdout("\n\(style.meta(line))\n")

    case .compaction, .header, .unknown:
      break
    }
  }

  private mutating func resetAssistantStreamingState() {
    if printedAnyAssistantText {
      writeStdout("\n")
    }
    printedAnyAssistantText = false
    printedAssistantPreamble = false
  }

  private mutating func appendVisibleMessage(label: String, text: String) {
    let trunc: DisplayTruncation = (style.verbosity == .full) ? .messageFull : .messageCompact
    let rendered = truncateForDisplay(text, options: trunc).trimmingCharacters(in: .newlines)

    writeStdout("\n\(style.separator)\n")
    writeStdout("\(label)\n")
    writeStdout(rendered + "\n")
  }

  private func writeStdout(_ s: String) {
    stdout.write(Data(s.utf8))
  }

  private func writeStderr(_ s: String) {
    stderr.write(Data(s.utf8))
  }
}
