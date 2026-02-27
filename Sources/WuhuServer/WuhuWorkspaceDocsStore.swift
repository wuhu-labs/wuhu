import Foundation
import PiAI
import WorkspaceContracts
import WorkspaceEngine
import WorkspaceScanner
import WuhuAPI

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
  let engine: WorkspaceEngine
  let scanner: WorkspaceScanner

  init(dataRoot: URL) throws {
    self.dataRoot = dataRoot
    workspaceRoot = dataRoot.appendingPathComponent("workspace", isDirectory: true)
    scanner = WorkspaceScanner(root: workspaceRoot)
    let config = try scanner.loadConfiguration()
    engine = try WorkspaceEngine(configuration: config)
  }

  func ensureDefaultDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    try fm.createDirectory(
      at: workspaceRoot.appendingPathComponent("issues", isDirectory: true),
      withIntermediateDirectories: true,
    )

    // Create a default wuhu.yml if one doesn't exist.
    let configURL = workspaceRoot.appendingPathComponent("wuhu.yml")
    if !fm.fileExists(atPath: configURL.path) {
      let defaultConfig = """
      kinds:
        - kind: issue
          properties:
            - status
            - priority
            - assignee

      rules:
        - path: "issues/**"
          kind: issue

      """
      try defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
    }
  }

  /// Starts the file watcher in a background task. Call once at server startup.
  func startWatching() {
    Task {
      try await scanner.watch(engine: engine)
    }
  }

  func listDocs() async throws -> [WuhuWorkspaceDocSummary] {
    let documents = try await engine.allDocuments()
    return documents.map { doc in
      WuhuWorkspaceDocSummary(path: doc.path, frontmatter: buildFrontmatter(from: doc))
    }
  }

  func readDoc(relativePath rawRelativePath: String) async throws -> WuhuWorkspaceDoc {
    let relativePath = try sanitizeRelativePath(rawRelativePath)
    guard relativePath.lowercased().hasSuffix(".md") else {
      throw WuhuWorkspaceDocsStoreError.notMarkdown(relativePath)
    }

    guard let doc = try await engine.document(at: relativePath) else {
      throw WuhuWorkspaceDocsStoreError.notFound(relativePath)
    }

    // Read the body from disk — the engine intentionally does not store bodies.
    let docURL = workspaceRoot.appendingPathComponent(relativePath)
    let standardizedDoc = docURL.standardizedFileURL
    let standardizedRoot = workspaceRoot.standardizedFileURL

    let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : (standardizedRoot.path + "/")
    guard standardizedDoc.path.hasPrefix(rootPath) else {
      throw WuhuWorkspaceDocsStoreError.invalidRelativePath(rawRelativePath)
    }

    let raw: String
    do {
      raw = try String(contentsOf: standardizedDoc, encoding: .utf8)
    } catch {
      throw WuhuWorkspaceDocsStoreError.failedToRead(relativePath, underlying: String(describing: error))
    }

    // Strip frontmatter from the raw content to get the body.
    let body = stripFrontmatter(raw)

    return WuhuWorkspaceDoc(path: relativePath, frontmatter: buildFrontmatter(from: doc), body: body)
  }

  // MARK: - Private

  private func buildFrontmatter(from doc: WorkspaceDocument) -> [String: JSONValue] {
    var frontmatter: [String: JSONValue] = [:]
    frontmatter["kind"] = .string(doc.record.kind.rawValue)
    if let title = doc.record.title {
      frontmatter["title"] = .string(title)
    }
    for (key, value) in doc.properties {
      frontmatter[key] = .string(value)
    }
    return frontmatter
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

  private func stripFrontmatter(_ raw: String) -> String {
    var lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return raw
    }
    lines.removeFirst()

    while let line = lines.first {
      lines.removeFirst()
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
    }

    return lines.map(String.init).joined(separator: "\n")
  }
}
