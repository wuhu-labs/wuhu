#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import enum JSONValue.JSONValue
import OperationProtocol
import OperationRuntime
import Scratch
import Testing

@Suite(.timeLimit(.minutes(2))) struct StagedWriteTests {
  @Test(arguments: ["digest", "length", "missing", "matching"])
  func aStagedWriteLandsOnlyOnAMatchingCommit(_ commit: String) async throws {
    let folder = try ScratchFolder("staged-commit")
    let target = folder.url.appending(path: "target.txt").path
    let bytes = Data("staged".utf8)
    let ending = try await MetadataOperationTests().withClient { wire in
      let operation = try await wire.start(.init(kind: "stagedWrite.v1", input: ["path": .string(target), "replace": false]))
      try await operation.write("data", .init(data: bytes), end: true)
      let record: JSONValue = switch commit {
      case "digest": ["bytes": .string(String(bytes.count)), "sha256": .string(String(repeating: "0", count: 64))]
      case "length": ["bytes": .string(String(bytes.count + 1)), "sha256": .string(sha256(bytes))]
      default: ["bytes": .string(String(bytes.count)), "sha256": .string(sha256(bytes))]
      }
      try await operation.write("commit", commit == "missing" ? .init(records: []) : .init(records: [record]), end: true)
      return try await operation.verdict()
    }
    #expect(ending.tag == (commit == "matching" ? .completed : .failed))
    #expect(ending.error?.code == (commit == "matching" ? nil : .invalidInput))
    if commit == "matching" {
      #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
      let token = try #require(ending.result?.object?["version"]?.stringValue)
      #expect(token == (try await ComputerFileSystem.local.status(target).version))
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["target.txt"])
    } else {
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }
  }
}
