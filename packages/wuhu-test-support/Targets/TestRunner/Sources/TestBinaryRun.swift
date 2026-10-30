import Foundation

/// This test binary rerun on one test, with its own XML report instead of the parent's Bazel outputs.
public struct TestBinaryRun: Sendable {
  public let status: Int32
  public let output: String
  /// The XML report the child wrote; nil when it exited before writing one.
  public let xml: String?

  private static let parentOnly: Set<String> = [
    "XML_OUTPUT_FILE", "TEST_SHARD_STATUS_FILE", "TEST_TOTAL_SHARDS", "TEST_SHARD_INDEX", "TEST_PREMATURE_EXIT_FILE",
    "TEST_INFRASTRUCTURE_FAILURE_FILE", "TEST_WARNINGS_OUTPUT_FILE", "TEST_LOGSPLITTER_OUTPUT_FILE",
    "TEST_UNUSED_RUNFILES_LOG_FILE", "TEST_UNDECLARED_OUTPUTS_DIR", "TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR",
  ]

  public init(test: String, environment extra: [String: String]) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "test-binary-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let xml = directory.appending(path: "result.xml")
    let log = directory.appending(path: "output.log")
    _ = FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }

    let process = Process()
    process.executableURL = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    process.environment = ProcessInfo.processInfo.environment.filter { !Self.parentOnly.contains($0.key) }
      .merging(["TESTBRIDGE_TEST_ONLY": test, "XML_OUTPUT_FILE": xml.path]) { $1 }
      .merging(extra) { $1 }
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    status = process.terminationStatus
    output = try String(contentsOf: log, encoding: .utf8)
    self.xml = try? String(contentsOf: xml, encoding: .utf8)
  }
}
