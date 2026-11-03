import struct DocIndex.PageHead
import SpaceFS

extension PageHead {
  /// Nil for anything but a readable HTML file: a page that can't be read
  /// still stats.
  static func read(_ entry: SpaceFS.Entry, at path: String, in backend: any SpaceVFS) async -> PageHead? {
    guard entry.kind == .file, isHTML(path),
          let reader = try? await backend.reader(path),
          let prefix = try? await reader.read(at: 0, count: scanBytes)
    else { return nil }
    return parse(prefix)
  }
}
