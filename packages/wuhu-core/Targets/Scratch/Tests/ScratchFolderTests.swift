import Foundation
@testable import Scratch
import ScratchTesting
import Synchronization
import Testing

@Suite struct ScratchFolderTests {
  @Test func removeTakesTheFolder() throws {
    let folder = try ScratchFolder("remove")
    try Data("x".utf8).write(to: folder.url.appending(path: "file"))
    #expect(FileManager.default.fileExists(atPath: folder.path))
    folder.remove()
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test func releaseTakesTheFolder() throws {
    var folder: ScratchFolder? = try ScratchFolder("release")
    let path = try #require(folder?.path)
    #expect(FileManager.default.fileExists(atPath: path))
    folder = nil
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func foldersLiveUnderTheProcessRoot() throws {
    let folder = try ScratchFolder("root")
    defer { folder.remove() }
    #expect(folder.url.deletingLastPathComponent().lastPathComponent == "wuhu-scratch-\(getpid())")
    #expect(folder.url.lastPathComponent.hasPrefix("root-"))
  }

  @Test func aScratchURLIsFreshAndUncreated() throws {
    let first = try scratchURL("url")
    let second = try scratchURL("url")
    #expect(first != second)
    #expect(first.deletingLastPathComponent().lastPathComponent == "wuhu-scratch-\(getpid())")
    #expect(!FileManager.default.fileExists(atPath: first.path))
  }

  @Test func sweepTakesOnlyRootsOfGoneProcesses() throws {
    let base = try ScratchFolder("sweep")
    defer { base.remove() }
    let gone = base.url.appending(path: "wuhu-scratch-\(Int32.max)")
    let alive = base.url.appending(path: "wuhu-scratch-1")
    let mine = base.url.appending(path: "wuhu-scratch-\(getpid())")
    let other = base.url.appending(path: "unrelated-\(Int32.max)")
    for url in [gone, alive, mine, other] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    ScratchRoot.sweep(base.url)
    #expect(!FileManager.default.fileExists(atPath: gone.path))
    #expect(FileManager.default.fileExists(atPath: alive.path))
    #expect(FileManager.default.fileExists(atPath: mine.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
  }
}

private let held = Mutex<[ScratchFolder]>([])

// Children of the leak guard only: each holds a folder past its own end, one passing, one failing and throwing.
@Suite struct ScratchChildTests {
  static var failing: Bool { ProcessInfo.processInfo.environment["WUHU_SCRATCH_FAIL"] == "1" }

  @Test(.enabled(if: LeakGuard.isChild && !failing)) func holdsAFolderAndPasses() throws {
    let folder = try ScratchFolder("held")
    held.withLock { $0.append(folder) }
  }

  @Test(.enabled(if: LeakGuard.isChild && failing)) func holdsAFolderFailsAndThrows() throws {
    let folder = try ScratchFolder("held")
    held.withLock { $0.append(folder) }
    Issue.record("fails on purpose")
    throw CancellationError()
  }
}

@Suite struct ScratchExitTests {
  @Test(.enabled(if: !LeakGuard.isChild)) func aPassingRunLeavesNothingBehind() async throws {
    let run = try await LeakGuard.run(filter: "holdsAFolderAndPasses")
    #expect(run.status == 0, "\(run.output)")
    #expect(run.ran > 0, "\(run.output)")
    #expect(run.leftovers == [], "\(run.output)")
  }

  @Test(.enabled(if: !LeakGuard.isChild)) func aFailingRunLeavesNothingBehind() async throws {
    let run = try await LeakGuard.run(filter: "holdsAFolderFailsAndThrows", environment: ["WUHU_SCRATCH_FAIL": "1"])
    #expect(run.status != 0, "\(run.output)")
    #expect(run.ran > 0, "\(run.output)")
    #expect(run.leftovers == [], "\(run.output)")
  }
}

// Test code takes its folders from ScratchFolder; a bare temp path outlives the test.
@Suite struct TemporaryPathLintTests {
  static let targets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

  // Files allowed a bare temporary path, each with the reason it is not a test leak.
  static let allowed: [String: String] = [
    "CLIKit/Sources/Identity.swift": "a session exec's state, the fallback when its environment has no TMPDIR",
    "ClaudeInstall/Sources/ClaudeInstallLive.swift": "the Claude Code installer's extraction folder, removed by its own defer",
  ]

  @Test func codeMakesNoBareTemporaryPaths() throws {
    let bare = ["temporaryDirectory", "NSTemporaryDirectory", "mkdtemp", "mkstemp"]
    var offenders: [String] = []
    var scanned = 0
    for target in try FileManager.default.contentsOfDirectory(atPath: Self.targets.path) where target != "Scratch" {
      for part in ["Sources", "Tests"] {
        let folder = Self.targets.appending(path: target).appending(path: part)
        guard let files = FileManager.default.enumerator(atPath: folder.path) else { continue }
        for case let file as String in files where file.hasSuffix(".swift") {
          scanned += 1
          let relative = "\(target)/\(part)/\(file)"
          guard Self.allowed[relative] == nil else { continue }
          let text = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
          for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where bare.contains(where: { line.contains($0) })
          {
            offenders.append("\(relative):\(number + 1)")
          }
        }
      }
    }
    #expect(scanned > 500)
    #expect(offenders == [])
  }
}
