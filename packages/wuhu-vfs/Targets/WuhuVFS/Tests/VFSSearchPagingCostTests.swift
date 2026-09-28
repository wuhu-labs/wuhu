import Foundation
import Synchronization
import Testing
import WuhuVFS

/// F55: a paged `find`/`grep` must NOT re-walk the already-scanned tree prefix on
/// every continuation. The old cursor was a bare relative path; a resumed page
/// re-entered the root and re-issued `status(at:)` for every entry preceding the
/// anchor plus `children(of:)` / `.gitignore` reads for every prefix directory —
/// O(N²/page) VFS round trips.
///
/// These tests wrap the backing filesystem in a ``CountingVFS`` that records every
/// metadata/read round trip and assert the per-page cost stays bounded (does not
/// grow with page index). RED proof: revert the structured fast-forward in
/// `VFSSearchImpl` and the per-page `status` count balloons with page index.
struct VFSSearchPagingCostTests {
  /// Shared, thread-safe round-trip counters. Boxed in a reference so the
  /// `CountingVFS` value can be copied freely while every copy reports into the
  /// same tallies.
  private final class Counters: Sendable {
    let status = Mutex(0)
    let children = Mutex(0)
    let read = Mutex(0)
  }

  /// A filesystem decorator that counts the `status` / `children` / `readData`
  /// round trips the default tree-walk `find`/`grep` issue against it.
  private struct CountingVFS: VirtualFileSystem {
    let base: any VirtualFileSystem
    let counters: Counters

    func status(at path: VFSPath) async throws -> VFSNodeStatus? {
      counters.status.withLock { $0 += 1 }
      return try await base.status(at: path)
    }

    func children(of path: VFSPath) async throws -> [VFSDirectoryEntry] {
      counters.children.withLock { $0 += 1 }
      return try await base.children(of: path)
    }

    func readData(at path: VFSPath) async throws -> Data {
      counters.read.withLock { $0 += 1 }
      return try await base.readData(at: path)
    }

    // Mutations / open are unused by the search walk.
    func writeData(_ data: Data, at path: VFSPath, append: Bool) async throws {
      try await base.writeData(data, at: path, append: append)
    }

    func createFile(at path: VFSPath, data: Data) async throws { try await base.createFile(at: path, data: data) }
    func createDirectory(at path: VFSPath, intermediates: Bool) async throws { try await base.createDirectory(at: path, intermediates: intermediates) }
    func remove(at path: VFSPath, recursive: Bool) async throws { try await base.remove(at: path, recursive: recursive) }
    func move(from: VFSPath, to: VFSPath) async throws { try await base.move(from: from, to: to) }
    func copy(from: VFSPath, to: VFSPath) async throws { try await base.copy(from: from, to: to) }
    func open(at path: VFSPath, mode: VFSOpenMode) async throws -> any VFSFileHandle { try await base.open(at: path, mode: mode) }
  }

  /// A flat directory of `count` files named `f0000…`. Wide and shallow, so the
  /// old prefix re-walk is dominated by `status` calls on already-scanned files.
  private func wideTree(count: Int) async throws -> InMemoryVFSNode {
    let root = InMemoryVFSNode()
    for index in 0 ..< count {
      let name = String(format: "f%04d.txt", index)
      try await root.seedFile(at: try path([name]), data: Data("needle \(index)".utf8))
    }
    return root
  }

  /// Paging through a wide tree with a small entry-limit must keep the per-page
  /// `status` cost bounded by the page size — it must NOT grow with the page
  /// index. RED: with the bare-path cursor, page `k` re-stats ~`k·pageSize`
  /// already-scanned files, so the last page's status count is many times the
  /// first page's.
  @Test func `find paging does not re-stat the scanned prefix`() async throws {
    let fileCount = 60
    let pageSize = 10
    let counting = CountingVFS(base: NodeTreeVFS(root: try await wideTree(count: fileCount)), counters: Counters())

    var cursor: SearchCursor? = nil
    var perPageStatus: [Int] = []
    var totalPaths = 0
    var pages = 0
    repeat {
      let before = counting.counters.status.withLock { $0 }
      let page = try await counting.find(root: try path([]), pattern: "**/*.txt", matchLimit: 1_000_000, entryLimit: pageSize, step: cursor)
      let after = counting.counters.status.withLock { $0 }
      perPageStatus.append(after - before)
      totalPaths += page.paths.count
      cursor = page.next
      pages += 1
      #expect(pages < 50, "paging did not terminate")
    } while cursor != nil

    // All files found exactly once.
    #expect(totalPaths == fileCount)
    #expect(pages == fileCount / pageSize)

    // Each page scans `pageSize` NEW entries. The per-page status count must stay
    // within a small constant factor of pageSize across ALL pages — no growth
    // with page index. (One status per scanned child + the root status.)
    let bound = pageSize * 3
    for (index, count) in perPageStatus.enumerated() {
      #expect(count <= bound, "page \(index) issued \(count) status calls (bound \(bound)); per-page=\(perPageStatus)")
    }

    // Total status round trips across all pages must be ~linear in N, not N²/P.
    let total = counting.counters.status.withLock { $0 }
    #expect(total <= fileCount * 4, "total status \(total) for N=\(fileCount) — re-walk suspected")
  }

  /// The same guard for a NESTED tree: paging across directory boundaries must
  /// not re-issue `children(of:)` / `.gitignore` reads for the whole prefix on
  /// every page. RED: prefix directories are re-entered each page, so
  /// `children` calls grow with page index.
  @Test func `find paging over a nested tree does not re-walk prefix directories`() async throws {
    // 6 directories × 8 files each = 48 files, paged 8 at a time.
    let root = InMemoryVFSNode()
    let dirCount = 6
    let filesPerDir = 8
    for dir in 0 ..< dirCount {
      for file in 0 ..< filesPerDir {
        let dirName = String(format: "d%02d", dir)
        let fileName = String(format: "f%02d.txt", file)
        try await root.seedFile(at: try path([dirName, fileName]), data: Data("x".utf8))
      }
    }
    let counting = CountingVFS(base: NodeTreeVFS(root: root), counters: Counters())

    var cursor: SearchCursor? = nil
    var perPageChildren: [Int] = []
    var total = 0
    var pages = 0
    repeat {
      let before = counting.counters.children.withLock { $0 }
      let page = try await counting.find(root: try path([]), pattern: "**/*.txt", matchLimit: 1_000_000, entryLimit: filesPerDir, step: cursor)
      let after = counting.counters.children.withLock { $0 }
      perPageChildren.append(after - before)
      total += page.paths.count
      cursor = page.next
      pages += 1
      #expect(pages < 50, "paging did not terminate")
    } while cursor != nil

    #expect(total == dirCount * filesPerDir)
    // A resumed page must enter at most the O(depth) ancestor directories of the
    // cursor plus the new directory it scans — never every prefix directory. With
    // depth 2 (root + one dir level), the per-page `children` count is a small
    // constant. RED: the bare-path cursor re-enters every prefix directory, so
    // later pages issue `children` proportional to the page index.
    let bound = 4
    for (index, count) in perPageChildren.enumerated() {
      #expect(count <= bound, "page \(index) issued \(count) children calls (bound \(bound)); per-page=\(perPageChildren)")
    }
  }
}
