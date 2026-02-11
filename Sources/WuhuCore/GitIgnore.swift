import Foundation

struct GitIgnore: Sendable {
  struct Rule: Sendable, Hashable {
    var baseDir: String
    var pattern: String
    var isDirOnly: Bool
    var anchored: Bool
    var hasSlash: Bool
  }

  private var searchRoot: String
  private var rules: [Rule]

  init(searchRoot: String) {
    self.searchRoot = URL(fileURLWithPath: searchRoot).resolvingSymlinksInPath().standardizedFileURL.path
    rules = GitIgnore.loadRules(searchRoot: searchRoot)
  }

  func isIgnored(absolutePath: String, isDirectory: Bool) -> Bool {
    // Gitignore semantics are complex; we implement the subset we need:
    // - No negation (!)
    // - Patterns with no slash match basenames anywhere
    // - Patterns with slash match path relative to the .gitignore directory
    // - Trailing '/' means directory-only
    // - Leading '/' anchors to the .gitignore directory root
    let abs = URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().standardizedFileURL.path
    let root = searchRoot
    let relFromRoot = ToolGlob.normalize(Self.relativePath(from: root, to: abs) ?? abs)
    let basename = relFromRoot.split(separator: "/").last.map(String.init) ?? relFromRoot

    for rule in rules {
      if rule.isDirOnly, !isDirectory { continue }

      let base = URL(fileURLWithPath: rule.baseDir).resolvingSymlinksInPath().standardizedFileURL.path
      guard abs == base || abs.hasPrefix(base + "/") else { continue }
      let relFromBase = ToolGlob.normalize(Self.relativePath(from: base, to: abs) ?? relFromRoot)

      if rule.hasSlash {
        if ToolGlob.matches(pattern: rule.pattern, path: relFromBase, anchored: rule.anchored) {
          return true
        }
      } else if ToolGlob.matches(pattern: rule.pattern, path: basename, anchored: true) {
        return true
      }
    }
    return false
  }

  private static func loadRules(searchRoot: String) -> [Rule] {
    let fm = FileManager.default
    var out: [Rule] = []

    guard let enumerator = fm.enumerator(atPath: searchRoot) else { return [] }

    for case let rel as String in enumerator {
      if rel.hasPrefix(".git/") {
        enumerator.skipDescendants()
        continue
      }
      if rel == ".build" || rel.hasPrefix(".build/") {
        enumerator.skipDescendants()
        continue
      }
      if rel == ".swiftpm" || rel.hasPrefix(".swiftpm/") {
        enumerator.skipDescendants()
        continue
      }
      if rel == "DerivedData" || rel.hasPrefix("DerivedData/") {
        enumerator.skipDescendants()
        continue
      }
      if rel == "node_modules" || rel.hasPrefix("node_modules/") {
        enumerator.skipDescendants()
        continue
      }

      if (rel as NSString).lastPathComponent == ".gitignore" {
        let abs = URL(fileURLWithPath: searchRoot).appendingPathComponent(rel).resolvingSymlinksInPath().standardizedFileURL.path
        let baseDir = URL(fileURLWithPath: (abs as NSString).deletingLastPathComponent).resolvingSymlinksInPath().standardizedFileURL.path
        guard let text = try? String(contentsOfFile: abs, encoding: .utf8) else { continue }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
          let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          if line.isEmpty || line.hasPrefix("#") { continue }
          if line.hasPrefix("!") { continue } // not supported

          var pattern = line
          var anchored = false
          if pattern.hasPrefix("/") {
            anchored = true
            pattern = String(pattern.dropFirst())
          }

          var isDirOnly = false
          if pattern.hasSuffix("/") {
            isDirOnly = true
            pattern = String(pattern.dropLast())
          }

          let hasSlash = pattern.contains("/")
          if pattern.isEmpty { continue }

          out.append(.init(baseDir: baseDir, pattern: pattern, isDirOnly: isDirOnly, anchored: anchored, hasSlash: hasSlash))
        }
      }
    }

    return out
  }

  private static func relativePath(from base: String, to abs: String) -> String? {
    let baseURL = URL(fileURLWithPath: base).standardizedFileURL
    let absURL = URL(fileURLWithPath: abs).standardizedFileURL
    let rel = absURL.path.replacingOccurrences(of: baseURL.path + "/", with: "")
    if rel == absURL.path { return nil }
    return rel
  }
}
