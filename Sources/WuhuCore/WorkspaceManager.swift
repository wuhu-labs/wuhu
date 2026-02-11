import Foundation

public enum WuhuWorkspaceError: Error, Sendable, CustomStringConvertible {
  case invalidPath(String)
  case templateNotFound(String)
  case templateNotDirectory(String)
  case failedToCopyTemplate(source: String, destination: String, underlying: String)
  case startupScriptNotFound(String)
  case startupScriptFailed(path: String, cwd: String, exitCode: Int32, output: String)

  public var description: String {
    switch self {
    case let .invalidPath(path):
      "Invalid path: \(path)"
    case let .templateNotFound(path):
      "Template folder not found: \(path)"
    case let .templateNotDirectory(path):
      "Template path is not a directory: \(path)"
    case let .failedToCopyTemplate(source, destination, underlying):
      "Failed to copy template folder: \(source) -> \(destination) (\(underlying))"
    case let .startupScriptNotFound(path):
      "Startup script not found: \(path)"
    case let .startupScriptFailed(path, cwd, exitCode, output):
      "Startup script failed (exit \(exitCode)) at \(path) (cwd=\(cwd)):\n\(output)"
    }
  }
}

public enum WuhuWorkspaceManager {
  public static func defaultWorkspacesPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/workspaces")
      .path
  }

  public static func resolveWorkspacesPath(_ raw: String?, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return defaultWorkspacesPath() }
    return ToolPath.resolveToCwd(trimmed, cwd: cwd)
  }

  /// Copies `templatePath` to a new workspace directory under `workspacesPath` and optionally executes `startupScript`.
  ///
  /// - `templatePath` is expected to be an absolute path (tilde-expanded).
  /// - If `startupScript` is a relative path, it is resolved relative to the copied workspace root.
  public static func materializeFolderTemplateWorkspace(
    sessionID: String,
    templatePath: String,
    startupScript: String?,
    workspacesPath: String,
  ) async throws -> String {
    let fm = FileManager.default

    let expandedTemplate = ToolPath.expand(templatePath)
    let expandedWorkspaces = ToolPath.expand(workspacesPath)

    guard !expandedTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WuhuWorkspaceError.invalidPath(templatePath)
    }

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: expandedTemplate, isDirectory: &isDir) else {
      throw WuhuWorkspaceError.templateNotFound(expandedTemplate)
    }
    guard isDir.boolValue else {
      throw WuhuWorkspaceError.templateNotDirectory(expandedTemplate)
    }

    try fm.createDirectory(atPath: expandedWorkspaces, withIntermediateDirectories: true)

    let destURL = uniqueWorkspaceURL(workspacesPath: expandedWorkspaces, baseName: sessionID)
    do {
      try fm.copyItem(at: URL(fileURLWithPath: expandedTemplate), to: destURL)
    } catch {
      throw WuhuWorkspaceError.failedToCopyTemplate(
        source: expandedTemplate,
        destination: destURL.path,
        underlying: String(describing: error),
      )
    }

    if let startupScript, !startupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let scriptPath: String = {
        let expanded = ToolPath.expand(startupScript)
        if expanded.hasPrefix("/") { return expanded }
        return destURL.appendingPathComponent(expanded).path
      }()
      guard fm.fileExists(atPath: scriptPath) else {
        throw WuhuWorkspaceError.startupScriptNotFound(scriptPath)
      }
      try await runStartupScript(scriptPath: scriptPath, cwd: destURL.path)
    }

    return destURL.path
  }

  private static func uniqueWorkspaceURL(workspacesPath: String, baseName: String) -> URL {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: workspacesPath)

    let base = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeBase = base.isEmpty ? UUID().uuidString.lowercased() : base

    var candidate = root.appendingPathComponent(safeBase, isDirectory: true)
    if !fm.fileExists(atPath: candidate.path) { return candidate }

    for i in 1 ... 999 {
      candidate = root.appendingPathComponent("\(safeBase)-\(i)", isDirectory: true)
      if !fm.fileExists(atPath: candidate.path) { return candidate }
    }

    return root.appendingPathComponent("\(safeBase)-\(UUID().uuidString.lowercased())", isDirectory: true)
  }

  private static func runStartupScript(scriptPath: String, cwd: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", "set -euo pipefail; bash \(shellEscape(scriptPath))"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-startup-\(UUID().uuidString.lowercased()).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    process.standardOutput = outputHandle
    process.standardError = outputHandle

    try process.run()
    process.waitUntilExit()
    try? outputHandle.close()

    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let output = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 {
      throw WuhuWorkspaceError.startupScriptFailed(
        path: scriptPath,
        cwd: cwd,
        exitCode: process.terminationStatus,
        output: output,
      )
    }
  }

  private static func shellEscape(_ s: String) -> String {
    if s.isEmpty { return "''" }
    if s.range(of: #"[^A-Za-z0-9_\/\.\-]"#, options: .regularExpression) == nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
