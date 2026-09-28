import Foundation
import Scratch

/// What a rerun of this test binary left in the fresh TMPDIR it was given.
public struct LeakRun: Sendable {
  public let status: Int32
  public let leftovers: [String]
  public let output: String

  /// How many tests the child ran, from swift-testing's closing summary; 0 when it printed none.
  public var ran: Int {
    guard let range = output.range(of: "Test run with ", options: .backwards) else { return 0 }
    return Int(output[range.upperBound...].prefix { $0.isNumber }) ?? 0
  }
}

/// Reruns this test binary on a slice of its tests, with TMPDIR at a fresh folder, and reports what is left there
/// once the child exits. The child sees ``isChild`` set, so a guard test skips itself there.
public enum LeakGuard {
  private static let marker = "WUHU_TEMP_LEAK_CHILD"

  public static var isChild: Bool { ProcessInfo.processInfo.environment[marker] != nil }

  // The child reports nothing to Bazel: these belong to the parent run.
  static let parentOnly: Set<String> = [
    "XML_OUTPUT_FILE", "TEST_SHARD_STATUS_FILE", "TEST_TOTAL_SHARDS", "TEST_SHARD_INDEX", "TEST_PREMATURE_EXIT_FILE",
    "TEST_INFRASTRUCTURE_FAILURE_FILE", "TEST_WARNINGS_OUTPUT_FILE", "TEST_LOGSPLITTER_OUTPUT_FILE",
    "TEST_UNUSED_RUNFILES_LOG_FILE", "TEST_UNDECLARED_OUTPUTS_DIR", "TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR",
  ]

  public static func run(filter: String, environment extra: [String: String] = [:]) async throws -> LeakRun {
    let scratch = try ScratchFolder("leak-guard")
    defer { scratch.remove() }
    let tmp = scratch.url.appending(path: "tmp", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let log = scratch.url.appending(path: "child.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }

    var environment = ProcessInfo.processInfo.environment.filter { !parentOnly.contains($0.key) }
    environment["TESTBRIDGE_TEST_ONLY"] = filter
    environment["TMPDIR"] = tmp.path
    environment[marker] = "1"
    environment.merge(extra) { _, new in new }

    let process = Process()
    process.executableURL = URL(filePath: CommandLine.arguments[0])
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }

    let leftovers = try FileManager.default.subpathsOfDirectory(atPath: tmp.path).sorted()
    let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    return LeakRun(status: status, leftovers: leftovers, output: String(output.suffix(4000)))
  }
}
