import Foundation
import PiAgent
import PiAI

public extension WuhuTools {
  static func codingAgentTools(cwd: String) -> [AnyAgentTool] {
    [
      readTool(cwd: cwd),
      writeTool(cwd: cwd),
      editTool(cwd: cwd),
      lsTool(cwd: cwd),
      findTool(cwd: cwd),
      grepTool(cwd: cwd),
      bashTool(cwd: cwd),
      swiftTool(cwd: cwd),
    ]
  }
}

// MARK: - read

private func readTool(cwd: String) -> AnyAgentTool {
  // Tool argument types are intentionally strict (no coercion). Some models may emit incorrect JSON
  // types (e.g. booleans for integer fields); we prefer fixing this at the prompt/schema level.
  // See https://github.com/wuhu-labs/wuhu/issues/12
  struct Params: Sendable {
    var path: String
    var offset: Int?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.requireString("path")
      let offset = try a.optionalInt("offset")
      let limit = try a.optionalInt("limit")
      return .init(path: path, offset: offset, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Path to the file to read (relative or absolute)")]),
      "offset": .object(["type": .string("integer"), "description": .string("Line number to start reading from (1-indexed)")]),
      "limit": .object(["type": .string("integer"), "description": .string("Maximum number of lines to read")]),
    ]),
    "required": .array([.string("path")]),
    "additionalProperties": .bool(false),
  ])

  let description =
    "Read the contents of a text file. Output is truncated to \(ToolTruncation.defaultMaxLines) lines or \(ToolTruncation.defaultMaxBytes / 1024)KB (whichever is hit first). Use offset/limit for large files.\n\nNote: offset/limit must be integers (see https://github.com/wuhu-labs/wuhu/issues/12)."

  let tool = Tool(name: "read", description: description, parameters: schema)

  return AnyAgentTool(tool: tool, label: "read") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)

    let resolved = ToolPath.resolveReadPath(params.path, cwd: cwd)
    let raw = try String(contentsOfFile: resolved, encoding: .utf8)
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let totalLines = allLines.count

    let startLine = max(0, (params.offset ?? 1) - 1)
    if startLine >= totalLines {
      throw ToolError.message("Offset \(params.offset ?? 1) is beyond end of file (\(totalLines) lines total)")
    }

    var selected: [String]
    var userLimitedLines: Int?
    if let limit = params.limit {
      let end = min(startLine + max(0, limit), totalLines)
      selected = Array(allLines[startLine ..< end])
      userLimitedLines = end - startLine
    } else {
      selected = Array(allLines[startLine...])
    }

    let selectedContent = selected.joined(separator: "\n")
    let truncation = ToolTruncation.truncateHead(selectedContent)

    let startDisplay = startLine + 1
    let endDisplay = startDisplay + max(0, truncation.outputLines - 1)

    var outputText: String
    var details: JSONValue = .object([:])

    if truncation.firstLineExceedsLimit {
      let firstLineSize = ToolTruncation.formatSize(allLines[startLine].utf8.count)
      outputText =
        "[Line \(startDisplay) is \(firstLineSize), exceeds \(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit. Use bash: sed -n '\(startDisplay)p' \(params.path) | head -c \(ToolTruncation.defaultMaxBytes)]"
      details = .object(["truncation": truncation.toJSON()])
    } else if truncation.truncated {
      outputText = truncation.content
      let nextOffset = endDisplay + 1
      if truncation.truncatedBy == "lines" {
        outputText += "\n\n[Showing lines \(startDisplay)-\(endDisplay) of \(totalLines). Use offset=\(nextOffset) to continue.]"
      } else {
        outputText +=
          "\n\n[Showing lines \(startDisplay)-\(endDisplay) of \(totalLines) (\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit). Use offset=\(nextOffset) to continue.]"
      }
      details = .object(["truncation": truncation.toJSON()])
    } else if let userLimitedLines, startLine + userLimitedLines < totalLines {
      outputText = truncation.content
      let remaining = totalLines - (startLine + userLimitedLines)
      let nextOffset = startLine + userLimitedLines + 1
      outputText += "\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue.]"
    } else {
      outputText = truncation.content
      details = .null
    }

    let resultDetails: JSONValue =
      (details == .null || (details.object?.isEmpty ?? false))
        ? .object([:])
        : details

    return AgentToolResult(
      content: [.text(outputText)],
      details: resultDetails,
    )
  }
}

// MARK: - write

private func writeTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String
    var content: String

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.requireString("path")
      let content = try a.requireString("content")
      return .init(path: path, content: content)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Path to the file to write (relative or absolute)")]),
      "content": .object(["type": .string("string"), "description": .string("Content to write to the file")]),
    ]),
    "required": .array([.string("path"), .string("content")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "write",
    description: "Write content to a file. Creates parent directories if needed. Overwrites if the file already exists.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "write") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let abs = ToolPath.resolveToCwd(params.path, cwd: cwd)
    let dir = (abs as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    try params.content.write(toFile: abs, atomically: true, encoding: .utf8)
    let bytes = params.content.utf8.count
    return AgentToolResult(content: [.text("Successfully wrote \(bytes) bytes to \(params.path)")], details: .object([:]))
  }
}

// MARK: - edit

private func editTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String
    var oldText: String
    var newText: String

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.requireString("path")
      let oldText = try a.requireString("oldText")
      let newText = try a.requireString("newText")
      return .init(path: path, oldText: oldText, newText: newText)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Path to the file to edit (relative or absolute)")]),
      "oldText": .object(["type": .string("string"), "description": .string("Exact text to find and replace (must match exactly; minor whitespace/quote differences are tolerated)")]),
      "newText": .object(["type": .string("string"), "description": .string("New text to replace the old text with")]),
    ]),
    "required": .array([.string("path"), .string("oldText"), .string("newText")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "edit",
    description: "Edit a file by replacing a unique text span. Prefers exact match, then applies a fuzzy normalization (trailing whitespace, smart quotes, unicode dashes/spaces). Preserves original line endings and UTF-8 BOM.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "edit") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let abs = ToolPath.resolveToCwd(params.path, cwd: cwd)
    guard FileManager.default.fileExists(atPath: abs) else {
      throw ToolError.message("File not found: \(params.path)")
    }

    // Read via Data to preserve UTF-8 BOM (String(contentsOf:) may strip it).
    let rawData = try Data(contentsOf: URL(fileURLWithPath: abs))
    let raw = String(decoding: rawData, as: UTF8.self)
    let (bom, contentNoBom) = stripBom(raw)
    let originalEnding = detectLineEnding(contentNoBom)

    let normalizedContent = normalizeToLF(contentNoBom)
    let normalizedOldText = normalizeToLF(params.oldText)
    let normalizedNewText = normalizeToLF(params.newText)

    let match = fuzzyFindText(content: normalizedContent, needle: normalizedOldText)
    guard match.found else {
      throw ToolError.message(
        "Could not find the exact text in \(params.path). The old text must match exactly including all whitespace and newlines.",
      )
    }

    let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
    let fuzzyNeedle = normalizeForFuzzyMatch(normalizedOldText)
    let occurrences = fuzzyContent.components(separatedBy: fuzzyNeedle).count - 1
    if occurrences > 1 {
      throw ToolError.message(
        "Found \(occurrences) occurrences of the text in \(params.path). The text must be unique. Please provide more context to make it unique.",
      )
    }

    let baseContent = match.contentForReplacement
    let range = match.range
    let newContent = baseContent.replacingCharacters(in: range, with: normalizedNewText)

    if baseContent == newContent {
      throw ToolError.message(
        "No changes made to \(params.path). The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.",
      )
    }

    let firstChangedLine = 1 + baseContent[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count - 1
    let final = bom + restoreLineEndings(newContent, ending: originalEnding)
    try final.write(toFile: abs, atomically: true, encoding: .utf8)

    let diff = formatSimpleDiff(oldText: normalizedOldText, newText: normalizedNewText, line: firstChangedLine)
    return AgentToolResult(
      content: [.text("Successfully replaced text in \(params.path).")],
      details: .object([
        "diff": .string(diff),
        "firstChangedLine": .number(Double(firstChangedLine)),
      ]),
    )
  }
}

// MARK: - ls

private func lsTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.optionalString("path")
      let limit = try a.optionalInt("limit")
      return .init(path: path, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Directory to list (default: current directory)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of entries to return (default: 500)")]),
    ]),
    "required": .array([]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "ls",
    description: "List directory contents (includes dotfiles). Returns entries sorted alphabetically, with '/' suffix for directories. Truncated to 500 entries or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "ls") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let effectiveLimit = max(1, params.limit ?? 500)
    let dirPath = ToolPath.resolveToCwd(params.path ?? ".", cwd: cwd)

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir) else {
      throw ToolError.message("Path not found: \(dirPath)")
    }
    guard isDir.boolValue else {
      throw ToolError.message("Not a directory: \(dirPath)")
    }

    let entries = try FileManager.default.contentsOfDirectory(atPath: dirPath)
    let sorted = entries.sorted { $0.lowercased() < $1.lowercased() }

    var results: [String] = []
    results.reserveCapacity(min(sorted.count, effectiveLimit))

    var entryLimitReached = false
    for entry in sorted {
      if results.count >= effectiveLimit {
        entryLimitReached = true
        break
      }
      let full = (dirPath as NSString).appendingPathComponent(entry)
      var isEntryDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: full, isDirectory: &isEntryDir) else { continue }
      results.append(isEntryDir.boolValue ? "\(entry)/" : entry)
    }

    if results.isEmpty {
      return AgentToolResult(content: [.text("(empty directory)")], details: .object([:]))
    }

    let rawOutput = results.joined(separator: "\n")
    let truncation = ToolTruncation.truncateHead(rawOutput, options: .init(maxLines: .max, maxBytes: ToolTruncation.defaultMaxBytes))
    var output = truncation.content

    var notices: [String] = []
    var details: [String: JSONValue] = [:]

    if entryLimitReached {
      notices.append("\(effectiveLimit) entries limit reached. Use limit=\(effectiveLimit * 2) for more")
      details["entryLimitReached"] = .number(Double(effectiveLimit))
    }
    if truncation.truncated {
      notices.append("\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit reached")
      details["truncation"] = truncation.toJSON()
    }

    if !notices.isEmpty {
      output += "\n\n[\(notices.joined(separator: ". "))]"
    }

    return AgentToolResult(
      content: [.text(output)],
      details: details.isEmpty ? .object([:]) : .object(details),
    )
  }
}

// MARK: - find

private func findTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var pattern: String
    var path: String?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let pattern = try a.requireString("pattern")
      let path = try a.optionalString("path")
      let limit = try a.optionalInt("limit")
      return .init(pattern: pattern, path: path, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "pattern": .object(["type": .string("string"), "description": .string("Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'")]),
      "path": .object(["type": .string("string"), "description": .string("Directory to search in (default: current directory)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of results (default: 1000)")]),
    ]),
    "required": .array([.string("pattern")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "find",
    description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects basic .gitignore patterns. Truncated to 1000 results or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "find") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let searchRoot = ToolPath.resolveToCwd(params.path ?? ".", cwd: cwd)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: searchRoot, isDirectory: &isDir) else {
      throw ToolError.message("Path not found: \(searchRoot)")
    }
    guard isDir.boolValue else {
      throw ToolError.message("Not a directory: \(searchRoot)")
    }

    let ignore = GitIgnore(searchRoot: searchRoot)
    let effectiveLimit = max(1, params.limit ?? 1000)

    let matches = try walkFiles(
      root: searchRoot,
      shouldSkipDescendants: { rel, abs, isDir in
        guard isDir else { return false }
        if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return true }
        return ignore.isIgnored(absolutePath: abs, isDirectory: true)
      },
      include: { rel, abs, isDir in
        if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return false }
        if ignore.isIgnored(absolutePath: abs, isDirectory: isDir) { return false }
        if isDir { return false }
        return ToolGlob.matches(pattern: params.pattern, path: rel, anchored: true)
      },
    )

    let sorted = matches.sorted { $0.lowercased() < $1.lowercased() }
    let limited = Array(sorted.prefix(effectiveLimit))

    if limited.isEmpty {
      return AgentToolResult(content: [.text("No files found matching pattern")], details: .object([:]))
    }

    let resultLimitReached = sorted.count > effectiveLimit
    let rawOutput = limited.joined(separator: "\n")
    let truncation = ToolTruncation.truncateHead(rawOutput, options: .init(maxLines: .max, maxBytes: ToolTruncation.defaultMaxBytes))
    var output = truncation.content

    var notices: [String] = []
    var details: [String: JSONValue] = [:]

    if resultLimitReached {
      notices.append("\(effectiveLimit) results limit reached. Use limit=\(effectiveLimit * 2) for more, or refine pattern")
      details["resultLimitReached"] = .number(Double(effectiveLimit))
    }
    if truncation.truncated {
      notices.append("\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit reached")
      details["truncation"] = truncation.toJSON()
    }
    if !notices.isEmpty {
      output += "\n\n[\(notices.joined(separator: ". "))]"
    }

    return AgentToolResult(content: [.text(output)], details: details.isEmpty ? .object([:]) : .object(details))
  }
}

// MARK: - grep

private func grepTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var pattern: String
    var path: String?
    var glob: String?
    var ignoreCase: Bool?
    var literal: Bool?
    var context: Int?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let pattern = try a.requireString("pattern")
      let path = try a.optionalString("path")
      let glob = try a.optionalString("glob")
      let ignoreCase = try a.optionalBool("ignoreCase")
      let literal = try a.optionalBool("literal")
      let context = try a.optionalInt("context")
      let limit = try a.optionalInt("limit")
      return .init(
        pattern: pattern,
        path: path,
        glob: glob,
        ignoreCase: ignoreCase,
        literal: literal,
        context: context,
        limit: limit,
      )
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "pattern": .object(["type": .string("string"), "description": .string("Search pattern (regex or literal string)")]),
      "path": .object(["type": .string("string"), "description": .string("Directory or file to search (default: current directory)")]),
      "glob": .object(["type": .string("string"), "description": .string("Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'")]),
      "ignoreCase": .object(["type": .string("boolean"), "description": .string("Case-insensitive search (default: false)")]),
      "literal": .object(["type": .string("boolean"), "description": .string("Treat pattern as literal string instead of regex (default: false)")]),
      "context": .object(["type": .string("number"), "description": .string("Number of lines to show before and after each match (default: 0)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of matches to return (default: 100)")]),
    ]),
    "required": .array([.string("pattern")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "grep",
    description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects basic .gitignore patterns. Truncated to 100 matches or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "grep") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let searchPath = ToolPath.resolveToCwd(params.path ?? ".", cwd: cwd)

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir) else {
      throw ToolError.message("Path not found: \(searchPath)")
    }

    let contextLines = max(0, params.context ?? 0)
    let effectiveLimit = max(1, params.limit ?? 100)
    let ignoreCase = params.ignoreCase ?? false
    let literal = params.literal ?? false

    let rootForRelPaths = isDir.boolValue ? searchPath : (searchPath as NSString).deletingLastPathComponent
    let ignore = GitIgnore(searchRoot: rootForRelPaths)

    let files: [String] = if isDir.boolValue {
      try walkFiles(
        root: searchPath,
        shouldSkipDescendants: { rel, abs, isDir in
          guard isDir else { return false }
          if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return true }
          return ignore.isIgnored(absolutePath: abs, isDirectory: true)
        },
        include: { rel, abs, isDir in
          if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return false }
          if ignore.isIgnored(absolutePath: abs, isDirectory: isDir) { return false }
          if isDir { return false }
          if let glob = params.glob {
            return ToolGlob.matches(pattern: glob, path: rel, anchored: true)
          }
          return true
        },
      )
      .map { URL(fileURLWithPath: searchPath).appendingPathComponent($0).path }
    } else {
      [searchPath]
    }

    var outputLines: [String] = []
    outputLines.reserveCapacity(min(effectiveLimit * (contextLines * 2 + 1), 4096))

    var matchCount = 0
    var matchLimitReached = false
    var linesTruncated = false

    let regex: NSRegularExpression? = {
      if literal { return nil }
      let opts: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
      return try? NSRegularExpression(pattern: params.pattern, options: opts)
    }()

    for file in files {
      if matchCount >= effectiveLimit { break }

      let content: String
      do {
        content = try String(contentsOfFile: file, encoding: .utf8)
      } catch {
        continue
      }

      let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

      func matchesLine(_ line: String) -> Bool {
        if literal {
          if ignoreCase { return line.lowercased().contains(params.pattern.lowercased()) }
          return line.contains(params.pattern)
        }
        guard let regex else { return false }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.firstMatch(in: line, options: [], range: range) != nil
      }

      for (idx, line) in lines.enumerated() {
        if matchCount >= effectiveLimit {
          matchLimitReached = true
          break
        }
        if !matchesLine(line) { continue }
        matchCount += 1

        let rel = ToolGlob.normalize(relativePathForGrep(file: file, root: rootForRelPaths, isDirectoryRoot: isDir.boolValue))
        let lineNumber = idx + 1

        let start = max(1, lineNumber - contextLines)
        let end = min(lines.count, lineNumber + contextLines)

        for current in start ... end {
          let rawLine = lines[current - 1]
          let (trunc, wasTruncated) = ToolTruncation.truncateLine(rawLine)
          if wasTruncated { linesTruncated = true }
          if current == lineNumber {
            outputLines.append("\(rel):\(current): \(trunc)")
          } else {
            outputLines.append("\(rel)-\(current)- \(trunc)")
          }
        }
      }
    }

    if matchCount == 0 {
      return AgentToolResult(content: [.text("No matches found")], details: .object([:]))
    }

    let rawOutput = outputLines.joined(separator: "\n")
    let truncation = ToolTruncation.truncateHead(rawOutput, options: .init(maxLines: .max, maxBytes: ToolTruncation.defaultMaxBytes))
    var output = truncation.content

    var notices: [String] = []
    var details: [String: JSONValue] = [:]

    if matchLimitReached {
      notices.append("\(effectiveLimit) matches limit reached. Use limit=\(effectiveLimit * 2) for more, or refine pattern")
      details["matchLimitReached"] = .number(Double(effectiveLimit))
    }
    if truncation.truncated {
      notices.append("\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit reached")
      details["truncation"] = truncation.toJSON()
    }
    if linesTruncated {
      notices.append("Some lines truncated to \(ToolTruncation.grepMaxLineLength) chars. Use read tool to see full lines")
      details["linesTruncated"] = .bool(true)
    }

    if !notices.isEmpty {
      output += "\n\n[\(notices.joined(separator: ". "))]"
    }

    return AgentToolResult(content: [.text(output)], details: details.isEmpty ? .object([:]) : .object(details))
  }
}

// MARK: - bash

private func bashTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var command: String
    var timeout: Double?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let command = try a.requireString("command")
      let timeout = try a.optionalDouble("timeout")
      return .init(command: command, timeout: timeout)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "command": .object(["type": .string("string"), "description": .string("Bash command to execute")]),
      "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (optional, no default timeout)")]),
    ]),
    "required": .array([.string("command")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "bash",
    description: "Execute a bash command in the current working directory. Returns stdout and stderr (combined). Output is truncated to last \(ToolTruncation.defaultMaxLines) lines or \(ToolTruncation.defaultMaxBytes / 1024)KB. Optionally provide a timeout in seconds.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "bash") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
      throw ToolError.message("Working directory does not exist: \(cwd)\nCannot execute bash commands.")
    }

    let run = try await runBash(
      command: params.command,
      cwd: cwd,
      timeoutSeconds: params.timeout,
    )
    let exitCode = run.exitCode
    let output = run.output
    let timedOut = run.timedOut
    let terminated = run.terminated
    let fullOutputPath = run.fullOutputPath

    let truncation = ToolTruncation.truncateTail(output)
    var outputText = truncation.content.isEmpty ? "(no output)" : truncation.content

    var details: [String: JSONValue] = [:]
    if truncation.truncated {
      details["truncation"] = truncation.toJSON()
      details["fullOutputPath"] = .string(fullOutputPath)

      let startLine = truncation.totalLines - truncation.outputLines + 1
      let endLine = truncation.totalLines
      if truncation.lastLinePartial {
        let last = output.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lastSize = ToolTruncation.formatSize(last.utf8.count)
        if !outputText.isEmpty { outputText += "\n\n" }
        outputText += "[Showing last \(ToolTruncation.formatSize(truncation.outputBytes)) of line \(endLine) (line is \(lastSize)). Full output: \(fullOutputPath)]"
      } else if truncation.truncatedBy == "lines" {
        outputText += "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines). Full output: \(fullOutputPath)]"
      } else {
        outputText +=
          "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines) (\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit). Full output: \(fullOutputPath)]"
      }
    }

    if timedOut {
      try? FileManager.default.removeItem(atPath: fullOutputPath)
      throw ToolError.message(outputText + "\n\nCommand timed out")
    }
    if terminated {
      try? FileManager.default.removeItem(atPath: fullOutputPath)
      throw ToolError.message(outputText + "\n\nCommand aborted")
    }
    if exitCode != 0 {
      // Keep full output around for debugging.
      throw ToolError.message(outputText + "\n\nCommand exited with code \(exitCode)")
    }

    if !truncation.truncated {
      try? FileManager.default.removeItem(atPath: fullOutputPath)
    }
    return AgentToolResult(content: [.text(outputText)], details: details.isEmpty ? .object([:]) : .object(details))
  }
}

// MARK: - swift

private func swiftTool(cwd: String) -> AnyAgentTool {
  struct Params: Sendable {
    var code: String
    var args: [String]?
    var timeout: Double?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let code = try a.requireString("code")
      let argList = try a.optionalStringArray("args")
      let timeout = try a.optionalDouble("timeout")
      return .init(code: code, args: argList, timeout: timeout)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "code": .object(["type": .string("string"), "description": .string("Swift code to run (a full file).")]),
      "args": .object(["type": .string("array"), "description": .string("Arguments passed to the Swift program."), "items": .object(["type": .string("string")])]),
      "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (optional).")]),
    ]),
    "required": .array([.string("code")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "swift",
    description: "Run a Swift snippet by writing a temporary .swift file and executing `swift <file> [args...]` in the session working directory.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "swift") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("wuhu-swift-tool", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)
    let fileURL = tmpDir.appendingPathComponent("snippet-\(UUID().uuidString.lowercased()).swift")
    try params.code.write(to: fileURL, atomically: true, encoding: .utf8)

    let argList = (params.args ?? []).map { String($0) }
    let command = (["swift", fileURL.path] + argList).map(shellEscape).joined(separator: " ")

    let run = try await runBash(
      command: command,
      cwd: cwd,
      timeoutSeconds: params.timeout,
    )
    let exitCode = run.exitCode
    let output = run.output
    let timedOut = run.timedOut
    let terminated = run.terminated
    let fullOutputPath = run.fullOutputPath

    var text = output.trimmingCharacters(in: .newlines)
    if text.isEmpty { text = "(no output)" }

    if timedOut {
      try? FileManager.default.removeItem(atPath: fullOutputPath)
      throw ToolError.message(text + "\n\nSwift execution timed out")
    }
    if terminated {
      try? FileManager.default.removeItem(atPath: fullOutputPath)
      throw ToolError.message(text + "\n\nSwift execution aborted")
    }
    if exitCode != 0 {
      // Keep full output around for debugging.
      throw ToolError.message(text + "\n\nSwift exited with code \(exitCode)")
    }

    try? FileManager.default.removeItem(atPath: fullOutputPath)
    return AgentToolResult(content: [.text(text)], details: .object([:]))
  }
}

// MARK: - helpers

private enum ToolError: Error, Sendable, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(m): m
    }
  }
}

private func walkFiles(
  root: String,
  shouldSkipDescendants: ((_ relativePath: String, _ absolutePath: String, _ isDirectory: Bool) -> Bool)? = nil,
  include: (_ relativePath: String, _ absolutePath: String, _ isDirectory: Bool) -> Bool,
) throws -> [String] {
  let fm = FileManager.default
  let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
  guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: nil)
  else { return [] }

  var results: [String] = []
  for case let url as URL in enumerator {
    let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
    let abs = resolvedURL.path
    let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let rel = ToolGlob.normalize(abs.replacingOccurrences(of: prefix, with: ""))
    if rel.isEmpty { continue }

    let values = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
    let isDir = values?.isDirectory ?? false

    if isDir,
       rel == ".git" || rel.hasPrefix(".git/") ||
       rel == "node_modules" || rel.hasPrefix("node_modules/") ||
       rel == ".build" || rel.hasPrefix(".build/") ||
       rel == ".swiftpm" || rel.hasPrefix(".swiftpm/") ||
       rel == "DerivedData" || rel.hasPrefix("DerivedData/")
    {
      enumerator.skipDescendants()
      continue
    }

    if isDir, shouldSkipDescendants?(rel, abs, isDir) == true {
      enumerator.skipDescendants()
      continue
    }

    if include(rel, abs, isDir) {
      results.append(rel)
    }
  }
  return results
}

private func relativePathForGrep(file: String, root: String, isDirectoryRoot: Bool) -> String {
  if isDirectoryRoot {
    let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    let filePath = URL(fileURLWithPath: file).resolvingSymlinksInPath().standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if let rel = filePath.replacingOccurrences(of: prefix, with: "").nilIfEqual(filePath) {
      return rel
    }
    return (filePath as NSString).lastPathComponent
  }
  return (file as NSString).lastPathComponent
}

private func stripBom(_ content: String) -> (bom: String, text: String) {
  if content.hasPrefix("\u{FEFF}") {
    return ("\u{FEFF}", String(content.dropFirst()))
  }
  return ("", content)
}

private func detectLineEnding(_ content: String) -> String {
  content.contains("\r\n") ? "\r\n" : "\n"
}

private func normalizeToLF(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func restoreLineEndings(_ text: String, ending: String) -> String {
  ending == "\r\n" ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
}

private func normalizeForFuzzyMatch(_ text: String) -> String {
  let stripped = text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { trimEnd(String($0)) }
    .joined(separator: "\n")

  return stripped
    .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201A}\u{201B}]", with: "'", options: .regularExpression)
    .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201E}\u{201F}]", with: "\"", options: .regularExpression)
    .replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]", with: "-", options: .regularExpression)
    .replacingOccurrences(of: "[\u{00A0}\u{2002}-\u{200A}\u{202F}\u{205F}\u{3000}]", with: " ", options: .regularExpression)
}

private func trimEnd(_ s: String) -> String {
  var end = s.endIndex
  while end > s.startIndex {
    let before = s.index(before: end)
    let ch = s[before]
    if ch == " " || ch == "\t" {
      end = before
      continue
    }
    break
  }
  return String(s[..<end])
}

private struct FuzzyMatch: Sendable {
  var found: Bool
  var range: Range<String.Index>
  var usedFuzzy: Bool
  var contentForReplacement: String
}

private func fuzzyFindText(content: String, needle: String) -> FuzzyMatch {
  if let range = content.range(of: needle) {
    return .init(found: true, range: range, usedFuzzy: false, contentForReplacement: content)
  }

  let fuzzyContent = normalizeForFuzzyMatch(content)
  let fuzzyNeedle = normalizeForFuzzyMatch(needle)
  if let range = fuzzyContent.range(of: fuzzyNeedle) {
    return .init(found: true, range: range, usedFuzzy: true, contentForReplacement: fuzzyContent)
  }

  return .init(found: false, range: content.startIndex ..< content.startIndex, usedFuzzy: false, contentForReplacement: content)
}

private func formatSimpleDiff(oldText: String, newText: String, line: Int) -> String {
  let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
  let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)

  var out: [String] = []
  out.append("@@ line \(line) @@")
  for l in oldLines {
    out.append("-\(l)")
  }
  for l in newLines {
    out.append("+\(l)")
  }
  return out.joined(separator: "\n")
}

private func shellEscape(_ s: String) -> String {
  if s.isEmpty { return "''" }
  if s.range(of: #"[^A-Za-z0-9_\/\.\-]"#, options: .regularExpression) == nil { return s }
  return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct BashRunResult: Sendable {
  var exitCode: Int32
  var output: String
  var timedOut: Bool
  var terminated: Bool
  var fullOutputPath: String
}

private func runBash(command: String, cwd: String, timeoutSeconds: Double?) async throws -> BashRunResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = ["-lc", command]
  process.currentDirectoryURL = URL(fileURLWithPath: cwd)

  let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("wuhu-bash-\(UUID().uuidString.lowercased()).log")
  FileManager.default.createFile(atPath: outputURL.path, contents: nil)
  let outputHandle = try FileHandle(forWritingTo: outputURL)
  process.standardOutput = outputHandle
  process.standardError = outputHandle

  try process.run()

  let start = Date()
  var timedOut = false
  while process.isRunning {
    if let timeoutSeconds, timeoutSeconds > 0, Date().timeIntervalSince(start) > timeoutSeconds {
      timedOut = true
      process.terminate()
      break
    }
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  process.waitUntilExit()
  try? outputHandle.close()

  let data = (try? Data(contentsOf: outputURL)) ?? Data()
  let output = String(decoding: data, as: UTF8.self)
  return .init(exitCode: process.terminationStatus, output: output, timedOut: timedOut, terminated: false, fullOutputPath: outputURL.path)
}

private extension String {
  func nilIfEqual(_ other: String) -> String? {
    self == other ? nil : self
  }
}
