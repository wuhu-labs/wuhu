import Foundation
@testable import MachineAgent
import MachineContract
import Scratch
import Testing

private func fixtureTree(in scratch: ScratchFolder) throws -> String {
  let root = scratch.path
  let files: [String: String] = [
    "/a.txt": "alpha\nbeta\nalpha beta",
    "/a/inner.txt": "beta\nalpha",
    "/a/sub/deep.md": "alpha",
    "/z.log": "gamma\nalpha",
  ]
  for (path, contents) in files {
    let full = root + path
    try FileManager.default.createDirectory(
      atPath: (full as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true,
    )
    try contents.write(toFile: full, atomically: true, encoding: .utf8)
  }
  try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: root + "/a.txt")
  return root
}

private func grepMatches(_ result: SearchResult) throws -> ([SearchMatch], String?) {
  guard case let .matches(matches, cursor) = result else {
    throw WireFailure(.io, "expected matches, got \(result)")
  }
  return (matches, cursor)
}

private func findPaths(_ result: SearchResult) throws -> ([String], String?) {
  guard case let .paths(paths, cursor) = result else {
    throw WireFailure(.io, "expected paths, got \(result)")
  }
  return (paths, cursor)
}

@Suite
struct SearchTests {
  @Test func grepReturnsMatchesInTraversalOrder() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (matches, cursor) = try grepMatches(MachineSearch.execute(.grep(pattern: "alpha", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    #expect(cursor == nil)
    #expect(matches.map(\.path) == [root + "/a.txt", root + "/a.txt", root + "/a/inner.txt", root + "/a/sub/deep.md", root + "/z.log"])
    #expect(matches.map(\.line) == [1, 3, 2, 1, 2])
    #expect(matches.first?.text == "alpha")
    #expect(matches.allSatisfy { $0.context.isEmpty })
  }

  @Test func grepMatchLimitPagesToTheSameTotal() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (all, _) = try grepMatches(MachineSearch.execute(.grep(pattern: "alpha", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    var paged: [SearchMatch] = []
    var step: String?
    var pages = 0
    repeat {
      let (matches, cursor) = try grepMatches(MachineSearch.execute(.grep(pattern: "alpha", path: root, matchLimit: 2, entryLimit: nil, step: step)))
      #expect(matches.count <= 2)
      paged += matches
      step = cursor
      pages += 1
    } while step != nil && pages < 10
    #expect(paged == all)
    #expect(pages == 3)
  }

  @Test func grepEntryLimitBoundsFilesScanned() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (all, _) = try grepMatches(MachineSearch.execute(.grep(pattern: "alpha", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    var paged: [SearchMatch] = []
    var step: String?
    repeat {
      let (matches, cursor) = try grepMatches(MachineSearch.execute(.grep(pattern: "alpha", path: root, matchLimit: nil, entryLimit: 1, step: step)))
      paged += matches
      step = cursor
    } while step != nil
    #expect(paged == all)
  }

  @Test func grepFileRootScansJustThatFile() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (matches, cursor) = try grepMatches(MachineSearch.execute(.grep(pattern: "beta", path: root + "/a.txt", matchLimit: nil, entryLimit: nil, step: nil)))
    #expect(cursor == nil)
    #expect(matches.map(\.line) == [2, 3])
  }

  @Test func grepRejectsBadInputs() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    guard case let .error(badPattern) = MachineSearch.execute(.grep(pattern: "(", path: root, matchLimit: nil, entryLimit: nil, step: nil)) else {
      Issue.record("expected invalid pattern error")
      return
    }
    #expect(badPattern.code == .invalidArgument)
    guard case let .error(badLimit) = MachineSearch.execute(.grep(pattern: "x", path: root, matchLimit: 0, entryLimit: nil, step: nil)) else {
      Issue.record("expected invalid limit error")
      return
    }
    #expect(badLimit.code == .invalidArgument)
    guard case let .error(missing) = MachineSearch.execute(.grep(pattern: "x", path: root + "/nope", matchLimit: nil, entryLimit: nil, step: nil)) else {
      Issue.record("expected notFound")
      return
    }
    #expect(missing.code == .notFound)
  }

  @Test func findMatchesGlobOverAbsolutePaths() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (paths, cursor) = try findPaths(MachineSearch.execute(.find(glob: "**/*.txt", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    #expect(cursor == nil)
    #expect(paths == [root + "/a.txt", root + "/a/inner.txt", root + "/link.txt"])
  }

  @Test func findPagesDeterministically() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = try fixtureTree(in: scratch)
    let (all, _) = try findPaths(MachineSearch.execute(.find(glob: "**", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    #expect(all == [root + "/a.txt", root + "/a/inner.txt", root + "/a/sub/deep.md", root + "/link.txt", root + "/z.log"])
    for limit in 1 ... 3 {
      var paged: [String] = []
      var step: String?
      repeat {
        let (paths, cursor) = try findPaths(MachineSearch.execute(.find(glob: "**", path: root, matchLimit: limit, entryLimit: nil, step: step)))
        #expect(paths.count <= limit)
        paged += paths
        step = cursor
      } while step != nil
      #expect(paged == all, "matchLimit \(limit)")
    }
    var paged: [String] = []
    var step: String?
    repeat {
      let (paths, cursor) = try findPaths(MachineSearch.execute(.find(glob: "**", path: root, matchLimit: nil, entryLimit: 2, step: step)))
      paged += paths
      step = cursor
    } while step != nil
    #expect(paged == all)
  }

  @Test func traversalOrderMatchesFlatLexicographicSort() throws {
    let scratch = try ScratchFolder("machine-agent-tests")
    defer { scratch.remove() }
    let root = scratch.path
    // "/a.txt" sorts before "/a/b" because "." < "/"; the streamed traversal
    // must reproduce that flat order.
    try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
    try "x".write(toFile: root + "/a/b", atomically: true, encoding: .utf8)
    try "x".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "x".write(toFile: root + "/ab", atomically: true, encoding: .utf8)
    let (paths, _) = try findPaths(MachineSearch.execute(.find(glob: "**", path: root, matchLimit: nil, entryLimit: nil, step: nil)))
    #expect(paths == [root + "/a.txt", root + "/a/b", root + "/ab"])
    #expect(paths == paths.sorted())
  }
}
