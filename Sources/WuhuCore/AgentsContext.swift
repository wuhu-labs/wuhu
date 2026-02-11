import Foundation

struct WuhuContextFileSnapshot: Sendable, Hashable {
  var path: String
  var modifiedAt: Date
  var size: UInt64
}

struct WuhuContextFile: Sendable, Hashable {
  var path: String
  var content: String
}

enum WuhuAgentsContextFormatter {
  static func render(files: [WuhuContextFile]) -> String {
    guard !files.isEmpty else { return "" }

    var s = "\n\n# Project Context\n\n"
    s += "Project-specific instructions and guidelines:\n\n"
    for f in files {
      s += "## \(f.path)\n\n"
      s += f.content
      if !s.hasSuffix("\n") { s += "\n" }
      s += "\n"
    }
    return s
  }
}

actor WuhuAgentsContextActor {
  private let cwd: String

  private var cachedSnapshot: [WuhuContextFileSnapshot]?
  private var cachedRendered: String?

  init(cwd: String) {
    self.cwd = cwd
  }

  func contextSection() -> String {
    let candidates = [
      URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.md").path,
      URL(fileURLWithPath: cwd).appendingPathComponent("AGENTS.local.md").path,
    ]

    let (snapshots, files) = Self.loadFilesIfChanged(candidates: candidates, cachedSnapshot: cachedSnapshot)
    if let snapshots {
      cachedSnapshot = snapshots
      cachedRendered = WuhuAgentsContextFormatter.render(files: files)
    }

    return cachedRendered ?? ""
  }

  private static func loadFilesIfChanged(
    candidates: [String],
    cachedSnapshot: [WuhuContextFileSnapshot]?,
  ) -> (snapshots: [WuhuContextFileSnapshot]?, files: [WuhuContextFile]) {
    var snapshots: [WuhuContextFileSnapshot] = []
    snapshots.reserveCapacity(candidates.count)

    for path in candidates {
      do {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs[.type] as? FileAttributeType, type == .typeRegular else { continue }
        guard let modifiedAt = attrs[.modificationDate] as? Date else { continue }

        let size: UInt64 = if let n = attrs[.size] as? NSNumber {
          n.uint64Value
        } else {
          0
        }

        snapshots.append(.init(path: path, modifiedAt: modifiedAt, size: size))
      } catch {
        continue
      }
    }

    snapshots.sort { $0.path < $1.path }

    if let cachedSnapshot, cachedSnapshot == snapshots {
      return (snapshots: nil, files: [])
    }

    var files: [WuhuContextFile] = []
    files.reserveCapacity(snapshots.count)

    for snap in snapshots {
      do {
        let content = try String(contentsOfFile: snap.path, encoding: .utf8)
        files.append(.init(path: snap.path, content: content))
      } catch {
        continue
      }
    }

    return (snapshots: snapshots, files: files)
  }
}
