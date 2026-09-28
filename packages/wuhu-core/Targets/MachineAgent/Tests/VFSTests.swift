import Foundation
@testable import MachineAgent
import MachineContract
import Scratch
import Testing

@Suite
struct VFSTests {
  @Test func writeReadStatRoundTrip() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    let path = root + "/hello.txt"
    let written = MachineVFS.execute(.write(path: path, data: Base64Data(Array("hi".utf8)), ifMatch: nil))
    guard case let .written(token) = written else {
      Issue.record("expected written, got \(written)")
      return
    }
    guard case let .file(readToken, data) = MachineVFS.execute(.read(path: path)) else {
      Issue.record("expected file")
      return
    }
    #expect(readToken == token)
    #expect(data.bytes == Array("hi".utf8))
    guard case let .entry(entry) = MachineVFS.execute(.stat(path: path)) else {
      Issue.record("expected entry")
      return
    }
    #expect(entry.name == "hello.txt")
    #expect(entry.kind == .file)
    #expect(entry.size == 2)
    #expect(entry.token == token)
    #expect(MachineVFS.token(mtime: entry.mtime) == token)
  }

  @Test func lsSortsAndClassifiesEntries() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    _ = MachineVFS.execute(.write(path: root + "/b.txt", data: Base64Data([]), ifMatch: nil))
    _ = MachineVFS.execute(.mkdir(path: root + "/a"))
    try FileManager.default.createSymbolicLink(atPath: root + "/c", withDestinationPath: root + "/b.txt")
    guard case let .entries(entries) = MachineVFS.execute(.ls(path: root)) else {
      Issue.record("expected entries")
      return
    }
    #expect(entries.map(\.name) == ["a", "b.txt", "c"])
    #expect(entries.map(\.kind) == [.directory, .file, .symlink])
  }

  @Test func ifMatchGatesWriteAndRm() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    let path = root + "/guarded.txt"
    guard case let .written(token) = MachineVFS.execute(.write(path: path, data: Base64Data(Array("v1".utf8)), ifMatch: nil)) else {
      Issue.record("expected written")
      return
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
      ofItemAtPath: path,
    )
    guard case let .error(error) = MachineVFS.execute(.write(path: path, data: Base64Data(Array("v2".utf8)), ifMatch: token)) else {
      Issue.record("expected conflict")
      return
    }
    #expect(error.code == .conflict)
    guard case let .entry(entry) = MachineVFS.execute(.stat(path: path)) else {
      Issue.record("expected entry")
      return
    }
    guard case .written = MachineVFS.execute(.write(path: path, data: Base64Data(Array("v2".utf8)), ifMatch: entry.token)) else {
      Issue.record("expected fresh-token write to succeed")
      return
    }
    guard case let .error(rmError) = MachineVFS.execute(.rm(path: path, ifMatch: token)) else {
      Issue.record("expected rm conflict")
      return
    }
    #expect(rmError.code == .conflict)
    guard case let .entry(current) = MachineVFS.execute(.stat(path: path)) else {
      Issue.record("expected entry")
      return
    }
    #expect(MachineVFS.execute(.rm(path: path, ifMatch: current.token)) == .ok)
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func ifMatchOnMissingEntryConflicts() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    guard case let .error(error) = MachineVFS.execute(.write(path: root + "/absent", data: Base64Data([]), ifMatch: "1.0")) else {
      Issue.record("expected conflict")
      return
    }
    #expect(error.code == .conflict)
  }

  @Test func missingEntriesAreNotFound() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    for op in [VFSOp.stat(path: root + "/nope"), .ls(path: root + "/nope"), .rm(path: root + "/nope", ifMatch: nil)] {
      guard case let .error(error) = MachineVFS.execute(op) else {
        Issue.record("expected error for \(op)")
        continue
      }
      #expect(error.code == .notFound)
    }
  }

  @Test func mkdirCreatesIntermediatesAndMvMoves() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    #expect(MachineVFS.execute(.mkdir(path: root + "/a/b/c")) == .ok)
    _ = MachineVFS.execute(.write(path: root + "/a/b/c/f.txt", data: Base64Data(Array("x".utf8)), ifMatch: nil))
    #expect(MachineVFS.execute(.mv(from: root + "/a/b/c/f.txt", to: root + "/a/f.txt")) == .ok)
    guard case let .file(_, data) = MachineVFS.execute(.read(path: root + "/a/f.txt")) else {
      Issue.record("expected moved file")
      return
    }
    #expect(data.bytes == Array("x".utf8))
    guard case let .error(conflict) = MachineVFS.execute(.mv(from: root + "/a/b", to: root + "/a/f.txt")) else {
      Issue.record("expected mv conflict")
      return
    }
    #expect(conflict.code == .conflict)
    guard case let .error(missing) = MachineVFS.execute(.mv(from: root + "/ghost", to: root + "/g2")) else {
      Issue.record("expected mv notFound")
      return
    }
    #expect(missing.code == .notFound)
  }

  @Test func rmRemovesDirectoriesRecursively() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    _ = MachineVFS.execute(.mkdir(path: root + "/tree/deep"))
    _ = MachineVFS.execute(.write(path: root + "/tree/deep/f", data: Base64Data([]), ifMatch: nil))
    #expect(MachineVFS.execute(.rm(path: root + "/tree", ifMatch: nil)) == .ok)
    #expect(!FileManager.default.fileExists(atPath: root + "/tree"))
  }

  @Test func readBeyondTheWireBoundFailsLoudlyInsteadOfSeveringTheChannel() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    let path = root + "/big.bin"
    _ = MachineVFS.execute(.write(path: path, data: Base64Data(Array(repeating: 7, count: 32)), ifMatch: nil))
    guard case let .error(error) = MachineVFS.execute(.read(path: path), maxReadBytes: 31) else {
      Issue.record("expected error")
      return
    }
    #expect(error.code == .tooLarge)
    #expect(error.message.contains("big.bin"))
    guard case .file = MachineVFS.execute(.read(path: path), maxReadBytes: 32) else {
      Issue.record("expected file at the exact bound")
      return
    }
  }

  @Test func aRangedReadReturnsThoseBytesWithinTheWireBoundOfAFileBeyondIt() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    let path = root + "/big.bin"
    let bytes = (0 ..< 40).map { UInt8($0) }
    _ = MachineVFS.execute(.write(path: path, data: Base64Data(bytes), ifMatch: nil))
    guard case let .entry(entry) = MachineVFS.execute(.stat(path: path)) else {
      Issue.record("expected entry")
      return
    }
    var read: [UInt8] = []
    for offset in stride(from: 0, to: 40, by: 16) {
      guard case let .file(token, data) = MachineVFS.execute(.read(path: path, offset: offset, length: 16), maxReadBytes: 16) else {
        Issue.record("expected the range at \(offset)")
        return
      }
      #expect(token == entry.token)
      read += data.bytes
    }
    #expect(read == bytes)
    guard case let .file(_, past) = MachineVFS.execute(.read(path: path, offset: 64, length: 16), maxReadBytes: 16) else {
      Issue.record("expected an empty range past the end")
      return
    }
    #expect(past.bytes.isEmpty)
  }

  @Test func aRangeOverTheWireBoundOrNegativeIsRefused() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    let path = root + "/big.bin"
    _ = MachineVFS.execute(.write(path: path, data: Base64Data(Array(repeating: 7, count: 40)), ifMatch: nil))
    guard case let .error(tooLong) = MachineVFS.execute(.read(path: path, offset: 0, length: 17), maxReadBytes: 16) else {
      Issue.record("expected error")
      return
    }
    #expect(tooLong.code == .tooLarge)
    guard case let .error(negative) = MachineVFS.execute(.read(path: path, offset: -1, length: 4), maxReadBytes: 16) else {
      Issue.record("expected error")
      return
    }
    #expect(negative.code == .invalidArgument)
  }
}
