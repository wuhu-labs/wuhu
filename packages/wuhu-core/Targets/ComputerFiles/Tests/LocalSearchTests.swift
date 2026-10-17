#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import FileSearch
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Scratch
import Testing

@Suite struct LocalSearchTests {
  @Test func aDirectoryLargerThanAPageIsWalkedWholeAcrossPages() async throws {
    let folder = try ScratchFolder("local-search-paging")
    let names = (0 ..< 10010).map { "f" + String(100_000 + $0).dropFirst() }
    for name in names { try Data().write(to: folder.url.appending(path: name)) }
    let source = LocalSearchSource(root: folder.url.path, effects: DiskEffects())
    var found: [String] = []
    var step: String?
    repeat {
      let page = try await SearchQuery(mode: .find, pattern: "*", root: folder.url.path, scope: "test", limit: 1000, step: step).run(in: source)
      found += page.hits.map { String($0.path.split(separator: "/").last!) }
      step = page.cursor
    } while step != nil
    #expect(found == names)
  }

  @Test func aReadCancelledBeforeItRanLeavesNoDescriptorOnceClosed() async throws {
    let folder = try ScratchFolder("local-search-cancelled-read")
    let file = folder.url.appending(path: "a.txt")
    try Data("needle\n".utf8).write(to: file)
    let reader = try await LocalSearchSource(root: folder.url.path, effects: DiskEffects()).open(file.path)
    #expect(descriptors(to: file.path) == 1)
    let read = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await reader.read(at: 0, count: 7)
    }
    await #expect(throws: CancellationError.self) { try await read.value }
    await reader.close()
    #expect(descriptors(to: file.path) == 0)
  }
}

/// Descriptors this process holds open on `path`.
private func descriptors(to path: String) -> Int {
  guard let resolved = realpath(path, nil) else { return 0 }
  defer { free(resolved) }
  let target = String(cString: resolved)
  #if os(Linux)
    let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
    return fds.count { (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + $0)) == target }
  #else
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return (0 ..< getdtablesize()).count { fcntl($0, F_GETPATH, &buffer) == 0 && String(cString: buffer) == target }
  #endif
}
