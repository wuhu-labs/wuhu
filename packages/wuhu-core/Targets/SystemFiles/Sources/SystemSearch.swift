#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct FileSearch.SearchChild
import enum FileSearch.SearchEntryKind
import struct FileSearch.SearchListing
import protocol FileSearch.SearchReader
import protocol FileSearch.SearchSource
import struct FileSearch.SearchUnreadable

extension SystemVFS: SearchSource {
  func kind(_ path: String) async throws -> SearchEntryKind? {
    files[path] != nil ? .file : directories[path] != nil ? .directory : nil
  }

  func children(of directory: String, from start: String, limit: Int) async throws -> SearchListing {
    let prefix = directory == "/" ? "" : directory
    let names = (directories[directory] ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      .drop { $0.utf8.lexicographicallyPrecedes(start.utf8) }
    let page = names.prefix(limit).map { SearchChild(name: $0, kind: files[prefix + "/" + $0] == nil ? .directory : .file) }
    return SearchListing(children: page, next: names.dropFirst(page.count).first)
  }

  func open(_ file: String) async throws -> any SearchReader {
    guard let bytes = files[file] else { throw SearchUnreadable("not a file: \(SystemFiles.address(file))") }
    return Bytes(bytes: bytes)
  }

  func isHidden(_ path: String) -> Bool {
    path.split(separator: "/").last?.hasPrefix(".") == true
  }

  private struct Bytes: SearchReader {
    let bytes: Data

    func read(at offset: Int, count: Int) async throws -> Data {
      let start = min(offset, bytes.count)
      return bytes.subdata(in: start ..< min(start + count, bytes.count))
    }

    func close() async {}
  }
}
