import Foundation
import PiAI
import WuhuAPI
import Yams

enum WuhuWorkspaceDocsStoreError: Error, Sendable, CustomStringConvertible {
  case invalidRelativePath(String)
  case notFound(String)
  case notMarkdown(String)
  case failedToRead(String, underlying: String)

  var description: String {
    switch self {
    case let .invalidRelativePath(path):
      "Invalid workspace doc path: \(path)"
    case let .notFound(path):
      "Workspace doc not found: \(path)"
    case let .notMarkdown(path):
      "Workspace doc is not a markdown file: \(path)"
    case let .failedToRead(path, underlying):
      "Failed to read workspace doc: \(path) (\(underlying))"
    }
  }
}

struct WuhuWorkspaceDocsStore: Sendable {
  let dataRoot: URL
  let workspaceRoot: URL

  init(dataRoot: URL) {
    self.dataRoot = dataRoot
    workspaceRoot = dataRoot.appendingPathComponent("workspace", isDirectory: true)
  }

  func ensureDefaultDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    try fm.createDirectory(
      at: workspaceRoot.appendingPathComponent("issues", isDirectory: true),
      withIntermediateDirectories: true,
    )
  }

  func listDocs() throws -> [WuhuWorkspaceDocSummary] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: workspaceRoot.path, isDirectory: &isDir), isDir.boolValue else {
      return []
    }

    let keys: [URLResourceKey] = [.isRegularFileKey]
    let enumerator = fm.enumerator(
      at: workspaceRoot,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles],
    )

    var out: [WuhuWorkspaceDocSummary] = []
    if let enumerator {
      for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "md" else { continue }
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile == true else { continue }

        let rel = relativePath(for: url)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
          out.append(.init(path: rel, frontmatter: [:]))
          continue
        }

        let parsed = parseMarkdown(raw: raw)
        out.append(.init(path: rel, frontmatter: parsed.frontmatter))
      }
    }

    return out.sorted { $0.path < $1.path }
  }

  func readDoc(relativePath rawRelativePath: String) throws -> WuhuWorkspaceDoc {
    let relativePath = try sanitizeRelativePath(rawRelativePath)
    guard relativePath.lowercased().hasSuffix(".md") else {
      throw WuhuWorkspaceDocsStoreError.notMarkdown(relativePath)
    }

    let docURL = workspaceRoot.appendingPathComponent(relativePath)
    let standardizedDoc = docURL.standardizedFileURL
    let standardizedRoot = workspaceRoot.standardizedFileURL

    let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : (standardizedRoot.path + "/")
    guard standardizedDoc.path.hasPrefix(rootPath) else {
      throw WuhuWorkspaceDocsStoreError.invalidRelativePath(rawRelativePath)
    }

    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: standardizedDoc.path, isDirectory: &isDir), !isDir.boolValue else {
      throw WuhuWorkspaceDocsStoreError.notFound(relativePath)
    }

    let raw: String
    do {
      raw = try String(contentsOf: standardizedDoc, encoding: .utf8)
    } catch {
      throw WuhuWorkspaceDocsStoreError.failedToRead(relativePath, underlying: String(describing: error))
    }

    let parsed = parseMarkdown(raw: raw)
    return .init(path: relativePath, frontmatter: parsed.frontmatter, body: parsed.body)
  }

  private func relativePath(for absoluteURL: URL) -> String {
    let root = workspaceRoot.standardizedFileURL.path
    let abs = absoluteURL.standardizedFileURL.path
    if abs == root { return "" }
    let prefix = root.hasSuffix("/") ? root : (root + "/")
    if abs.hasPrefix(prefix) {
      return String(abs.dropFirst(prefix.count))
    }
    return absoluteURL.lastPathComponent
  }

  private func sanitizeRelativePath(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WuhuWorkspaceDocsStoreError.invalidRelativePath(raw) }
    guard !trimmed.contains("\u{0}") else { throw WuhuWorkspaceDocsStoreError.invalidRelativePath(raw) }

    var candidate = trimmed.replacingOccurrences(of: "\\", with: "/")
    while candidate.contains("//") {
      candidate = candidate.replacingOccurrences(of: "//", with: "/")
    }

    guard !candidate.hasPrefix("/") else { throw WuhuWorkspaceDocsStoreError.invalidRelativePath(raw) }

    let components = candidate.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty else { throw WuhuWorkspaceDocsStoreError.invalidRelativePath(raw) }

    for c in components {
      if c == "." || c == ".." { throw WuhuWorkspaceDocsStoreError.invalidRelativePath(raw) }
    }

    return components.joined(separator: "/")
  }

  private struct ParsedMarkdown: Sendable, Hashable {
    var frontmatter: [String: JSONValue]
    var body: String
  }

  private func parseMarkdown(raw: String) -> ParsedMarkdown {
    var lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return .init(frontmatter: [:], body: raw)
    }
    lines.removeFirst()

    var fmLines: [Substring] = []
    while let line = lines.first {
      lines.removeFirst()
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
      fmLines.append(line)
    }

    let fmText = fmLines.map(String.init).joined(separator: "\n")

    let frontmatter: [String: JSONValue] = {
      guard !fmText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
      do {
        return try YAMLDecoder().decode([String: JSONValue].self, from: fmText)
      } catch {
        return [:]
      }
    }()

    let body = lines.map(String.init).joined(separator: "\n")
    return .init(frontmatter: frontmatter, body: body)
  }
}
