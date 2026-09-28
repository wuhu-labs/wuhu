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

  var currentLink: URL { self.root.appendingPathComponent("wuhu") }
  private var previousFile: URL { self.root.appendingPathComponent(".previous") }

  func currentVersion() -> String? {
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: self.currentLink.path) else {
      return nil
    }
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

  @discardableResult
  func flip(to version: String) throws -> String? {
    let temp = self.root.appendingPathComponent(".link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: "\(version)/wuhu")
    let displaced = self.currentVersion()
    guard rename(temp.path, self.currentLink.path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? FileManager.default.removeItem(at: temp)
      throw CLIError(message: "could not flip \(self.currentLink.path): \(reason)")
    }
    if let displaced, displaced != version {
      try Data((displaced + "\n").utf8).write(to: self.previousFile, options: .atomic)
    }
    return displaced
  }

  func rollback() throws -> (from: String, to: String) {
    guard let current = self.currentVersion() else {
      throw CLIError(message: "nothing installed at \(self.currentLink.path); run wuhu upgrade first")
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
