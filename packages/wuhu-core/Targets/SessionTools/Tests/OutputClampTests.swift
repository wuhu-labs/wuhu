import Foundation
import JSONValue
import MachineChannel
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct ReadClampTests {
  @Test func bigFileReadClampsWithAContinuationNotice() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let content = (1 ... 3000).map { "line-\($0)" }.joined(separator: "\n")
      _ = try await space.fs(.shared).write("/big.txt", Data(content.utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(first) = try await world.run("read", .object(["path": "/big.txt"])) else {
        throw Mismatch("read failed")
      }
      #expect(first.content.hasSuffix("[showing lines 1-2000 of 3000; pass lines: \"2001-\" to continue]"))
      #expect(first.content.contains("line-2000\n\n["))
      #expect(!first.content.contains("line-2001"))

      guard case let .read(rest) = try await world.run(
        "read", .object(["path": "/big.txt", "lines": "2001-"]),
      ) else { throw Mismatch("continuation read failed") }
      #expect(rest.content == (2001 ... 3000).map { "line-\($0)" }.joined(separator: "\n"))
    }
  }

  @Test func explicitLineWindowReadsExactly() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let content = (1 ... 20).map { "line-\($0)" }.joined(separator: "\n")
      _ = try await space.fs(.shared).write("/small.txt", Data(content.utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .read(window) = try await world.run(
        "read", .object(["path": "/small.txt", "lines": "5-8"]),
      ) else { throw Mismatch("windowed read failed") }
      #expect(window.content == "line-5\nline-6\nline-7\nline-8")

      let beyond = try await world.run("read", .object(["path": "/small.txt", "lines": "21-"]))
      #expect(try failureMessage(beyond).contains("beyond the end"))

      let malformed = try await world.run("read", .object(["path": "/small.txt", "lines": "8-5"]))
      #expect(try failureMessage(malformed).contains("lines must be"))
    }
  }

  @Test func binaryFilesAreRefusedNotMojibaked() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/blob.dat", Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0x00, 0xC3]), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let refused = try await world.run("read", .object(["path": "/blob.dat"]))
      #expect(try failureMessage(refused).contains("not UTF-8 text"))
    }
  }
}

@Suite struct GrepLineClampTests {
  @Test func longMatchedLinesAreShortened() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let minified = "needle " + String(repeating: "a", count: 700)
      _ = try await space.fs(.shared).write("/bundle.js", Data(minified.utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .grep(result) = try await world.run(
        "grep", .object(["pattern": "needle", "path": "/"]),
      ) else { throw Mismatch("grep failed") }
      #expect(result.output.contains("[line clamped: 707 bytes]"))
      #expect(result.output.utf8.count < 700)
    }
  }
}
