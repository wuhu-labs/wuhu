#if os(Linux)
  import Foundation
  @testable import ImageRetention
  import Scratch
  import Subprocess
  import Testing

  @Suite struct OpsRetentionTests {
    @Test func outsidePrunerReadsSwiftReferencesAndFailsClosedOnCorruption() async throws {
      let scratch = try ScratchFolder("ops-retention")
      defer { scratch.remove() }
      let binary = scratch.url.appendingPathComponent("wuhu")
      try Data("version bytes".utf8).write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
      let root = scratch.url.appendingPathComponent("execution-images").path
      let helper = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_IMAGE_RETENTION_OPS_HELPER"])).standardizedFileURL.path
      let script = "source \"$1\"; image_retention_lock \"$2\" || exit 2; rc=0; image_retention_remove_allowed \"$3\" || rc=$?; image_retention_unlock || exit 2; exit \"$rc\""
      func gate() async throws -> TerminationStatus {
        try await Subprocess.run(.path("/bin/bash"), arguments: ["-c", script, "retention-test", helper, scratch.url.path, binary.path], input: .none, output: .discarded, error: .discarded).terminationStatus
      }
      #expect(!FileManager.default.fileExists(atPath: root))
      #expect(try await gate() == .exited(0))
      #expect(try ImageRetention.transaction(root: root) { try $0.references().isEmpty })
      let reference = try ImageRetention.transaction(root: root) { try $0.retain(source: binary.path, id: UUID(), owner: "prepared") }
      #expect(try await gate() == .exited(1))
      for peer in [reference.id.uuidString + ".json", reference.digest] {
        let stage = root + "/.stage-" + UUID().uuidString
        try FileManager.default.linkItem(atPath: root + "/" + peer, toPath: stage)
        #expect(try await gate() == .exited(1))
        #expect(!FileManager.default.fileExists(atPath: stage))
      }
      try FileManager.default.removeItem(atPath: root + "/" + reference.id.uuidString + ".json")
      #expect(try await gate() == .exited(0))
      #expect(!FileManager.default.fileExists(atPath: root + "/" + reference.digest))
      _ = try ImageRetention.transaction(root: root) { try $0.retain(source: binary.path, id: reference.id, owner: "prepared") }
      var preparation: ImagePreparation? = try ImageRetention.transaction(root: root) { try $0.prepare(source: binary.path, id: UUID(), owner: "prepared") }
      #expect(preparation != nil)
      #expect(try await gate() == .exited(1))
      preparation = nil
      try Data("not retained".utf8).write(to: binary)
      #expect(try await gate() == .exited(0))
      try Data("{}".utf8).write(to: URL(fileURLWithPath: root + "/" + reference.id.uuidString + ".json"))
      #expect(try await gate() == .exited(2))
    }
  }
#endif
