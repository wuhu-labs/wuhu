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

  public var separator: String {
    let base = "-----"
    return ANSI.wrap(base, ANSI.dim, enabled: terminal.colorEnabled && terminal.stdoutIsTTY)
  }

  public func userLabel() -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap("User:", ANSI.bold + ANSI.blue, enabled: enabled)
  }

  public func agentLabel() -> String {
    let enabled = terminal.colorEnabled && terminal.stdoutIsTTY
    return ANSI.wrap("Agent:", ANSI.bold + ANSI.green, enabled: enabled)
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
          appendVisibleMessage(label: style.userLabel(), text: text)

        case let .assistant(a):
          let text = renderTextBlocks(a.content).trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { break }
          flushPendingMetaIfNeeded()
          appendVisibleMessage(label: style.agentLabel(), text: text)

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

        case .customMessage:
          break

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

      case .custom, .unknown:
        break
      }
    }

    if style.verbosity == .minimal, pendingTools > 0 || pendingCompactions > 0 {
      flushPendingMetaIfNeeded()
    }

    return out
  }
}

public struct PromptStreamPrinter {
  public var style: SessionOutputStyle
  public var stdout: FileHandle
  public var stderr: FileHandle

  private var toolArgsById: [String: JSONValue] = [:]
  private var printedAnyAssistantText = false

  public init(
    style: SessionOutputStyle,
    stdout: FileHandle = .standardOutput,
    stderr: FileHandle = .standardError,
  ) {
    self.style = style
    self.stdout = stdout
    self.stderr = stderr
  }

  public mutating func printPromptPreamble(userText: String) {
    let trunc: DisplayTruncation = (style.verbosity == .full) ? .messageFull : .messageCompact
    let user = truncateForDisplay(userText, options: trunc).trimmingCharacters(in: .newlines)

    writeStdout("\(style.userLabel())\n")
    writeStdout(user + "\n")
    writeStdout("\n\(style.separator)\n")
    writeStdout("\(style.agentLabel())\n")
  }

  public mutating func handle(_ event: WuhuPromptEvent) {
    switch event {
    case let .toolExecutionStart(toolCallId, _, args):
      toolArgsById[toolCallId] = args

    case let .toolExecutionEnd(toolCallId, toolName, result, isError):
      defer { toolArgsById.removeValue(forKey: toolCallId) }
      guard style.verbosity != .minimal else { return }

      let args = toolArgsById[toolCallId]
      let summary = toolSummaryLine(
        .init(toolName: toolName, args: args, result: result, isError: isError),
        verbosity: style.verbosity,
      )
      var line = "[tool] \(summary)"
      if isError { line += " (error)" }
      writeStderr(style.tool(line) + "\n")

      if let details = toolDetailsForDisplay(
        .init(toolName: toolName, args: args, result: result, isError: isError),
        verbosity: style.verbosity,
      ) {
        writeStderr(details + "\n")
      }

    case let .assistantTextDelta(delta):
      printedAnyAssistantText = true
      writeStdout(delta)

    case .done:
      if printedAnyAssistantText { writeStdout("\n") }
    }
  }

  private func writeStdout(_ s: String) {
    stdout.write(Data(s.utf8))
  }

  private func writeStderr(_ s: String) {
    stderr.write(Data(s.utf8))
  }
}
