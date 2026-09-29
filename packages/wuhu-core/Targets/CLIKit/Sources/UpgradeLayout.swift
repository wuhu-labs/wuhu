#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct UpgradeLayout {
  var root: URL

  static func locate(environment: [String: String]) throws -> UpgradeLayout {
    let config = try ServerTrust.userConfigDirectory(environment: environment)
    return UpgradeLayout(root: config.appendingPathComponent("bin", isDirectory: true))
  }

  var currentBinary: URL { self.root.appendingPathComponent("wuhu") }
  private var currentFile: URL { self.root.appendingPathComponent(".current") }
  private var previousFile: URL { self.root.appendingPathComponent(".previous") }

  // A symlink wins over `.current`: a release from before the fixed path (reached by a rollback) writes
  // one and leaves `.current` stale.
  func currentVersion() -> String? {
    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: self.currentBinary.path) {
      return Self.version(linkTarget: target)
    }
    guard let text = try? String(contentsOf: self.currentFile, encoding: .utf8) else { return nil }
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  private static func version(linkTarget target: String) -> String? {
    let parts = target.split(separator: "/")
    guard !target.hasPrefix("/"), parts.count == 2, parts[1] == "wuhu" else { return nil }
    return String(parts[0])
  }

  func previousVersion() -> String? {
    guard let text = try? String(contentsOf: self.previousFile, encoding: .utf8) else { return nil }
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, self.versionDirectoryExists(name) else { return nil }
    return name
  }

  private func binary(of version: String) -> URL {
    self.root.appendingPathComponent(version, isDirectory: true).appendingPathComponent("wuhu")
  }

  // `.current` goes stale when someone replaces the binary by hand (`install <old> ~/.wuhu/bin/wuhu`),
  // so claiming a version is installed takes a byte comparison.
  func holds(_ version: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: self.currentBinary.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let installed = try? Data(contentsOf: self.currentBinary),
          let source = try? Data(contentsOf: self.binary(of: version))
    else { return false }
    return installed == source
  }

  func versionDirectoryExists(_ name: String) -> Bool {
    let path = self.root.appendingPathComponent(name, isDirectory: true).path
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.type] as? FileAttributeType == .typeDirectory
  }

  func acquireLock() throws -> URL {
    try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    let lock = self.root.appendingPathComponent(".lock")
    let descriptor = open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw CLIError(message: "another wuhu upgrade appears to be running; if not, remove \(lock.path)")
      }
      throw CLIError(message: "could not create \(lock.path): \(String(cString: strerror(errno)))")
    }
    close(descriptor)
    return lock
  }

  func stagingDirectory() throws -> URL {
    let staging = self.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    return staging
  }

  func install(payload: URL, version: String) throws {
    let destination = self.root.appendingPathComponent(version, isDirectory: true)
    let binary = payload.appendingPathComponent("wuhu")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw CLIError(message: "extracted artifact has no wuhu binary at its root")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    if FileManager.default.fileExists(atPath: destination.path) {
      guard self.currentVersion() != version else {
        throw CLIError(message: "refusing to replace \(version): it is the current version")
      }
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: payload, to: destination)
  }

  // A real file at a fixed path, since macOS keys privacy grants by it; replaced by rename, never written
  // into, since the kernel caches a signature per inode. The caller holds the lock, so flip may sweep the
  // copies an interrupted flip left behind.
  @discardableResult
  func flip(to version: String) throws -> String? {
    let manager = FileManager.default
    for name in (try? manager.contentsOfDirectory(atPath: self.root.path)) ?? [] where name.hasPrefix(".wuhu-") {
      try? manager.removeItem(at: self.root.appendingPathComponent(name))
    }
    let source = self.binary(of: version)
    let temp = self.root.appendingPathComponent(".wuhu-\(UUID().uuidString)")
    do {
      try manager.copyItem(at: source, to: temp)
      try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
    } catch {
      try? manager.removeItem(at: temp)
      throw CLIError(message: "could not copy \(source.path): \(error)")
    }
    let displaced = self.currentVersion()
    guard rename(temp.path, self.currentBinary.path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? manager.removeItem(at: temp)
      throw CLIError(message: "could not replace \(self.currentBinary.path): \(reason)")
    }
    try Data((version + "\n").utf8).write(to: self.currentFile, options: .atomic)
    if let displaced, displaced != version {
      try Data((displaced + "\n").utf8).write(to: self.previousFile, options: .atomic)
    }
    return displaced
  }

  func rollback() throws -> (from: String, to: String) {
    guard let current = self.currentVersion() else {
      throw CLIError(message: "nothing installed at \(self.currentBinary.path); run wuhu upgrade first")
    }
    guard let previous = self.previousVersion() else {
      throw CLIError(message: "no previous version recorded under \(self.root.path); nothing to roll back to")
    }
    try self.flip(to: previous)
    return (from: current, to: previous)
  }

  @discardableResult
  func prune(keep: Int) throws -> [String] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: self.root.path) else { return [] }
    let protected = Set([self.currentVersion(), self.previousVersion()].compactMap { $0 })
    let versions = names
      .filter { !$0.hasPrefix(".") }
      .compactMap { name -> (name: String, url: URL, modified: Date)? in
        let url = self.root.appendingPathComponent(name, isDirectory: true)
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory
        else { return nil }
        return (name, url, attributes[.modificationDate] as? Date ?? .distantPast)
      }
      .sorted { $0.modified > $1.modified }
    var removed: [String] = []
    for (index, version) in versions.enumerated() where index >= keep && !protected.contains(version.name) {
      try manager.removeItem(at: version.url)
      removed.append(version.name)
    }
    return removed
  }
}
