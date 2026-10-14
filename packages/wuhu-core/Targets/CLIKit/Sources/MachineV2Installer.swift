#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import Dependencies

struct MachineV2InstallError: Error, CustomStringConvertible, Equatable {
  enum Code: String { case invalidMachine, busy, missingBinary, serviceFailure, localNetworkDenied, preflightFailed, drainFailed }
  var code: Code
  var message: String
  var description: String { "\(self.code.rawValue): \(self.message)" }
}

struct MachineV2Installer {
  enum Platform { case linux, macOS }
  var home: URL
  var machine: String
  var platform: Platform
  var userID: UInt32
  var command: @Sendable ([String]) async throws -> String

  var root: URL { self.home.appendingPathComponent(".wuhu/machine-v2/\(self.machine)") }
  var binary: URL { self.root.appendingPathComponent("bin/wuhu") }
  var previous: URL { self.root.appendingPathComponent("bin/previous") }
  var label: String { "ai.wuhu.machine-v2.\(self.machine)" }
  var unit: String { "wuhu-machine-v2@\(self.machine).service" }
  var serviceFile: URL {
    switch self.platform {
    case .linux: self.home.appendingPathComponent(".config/systemd/user/\(self.unit)")
    case .macOS: self.home.appendingPathComponent("Library/LaunchAgents/\(self.label).plist")
    }
  }

  func install(candidate: URL) async throws {
    try self.validate()
    let lock = try self.lock()
    defer { close(lock) }
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
      throw MachineV2InstallError(code: .missingBinary, message: candidate.path)
    }
    let pending = self.root.appendingPathComponent("bin/.pending-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: candidate, to: pending)
    defer { try? FileManager.default.removeItem(at: pending) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pending.path)
    if self.platform == .macOS { try await self.preflight(executable: pending) }
    if !FileManager.default.contentsEqual(atPath: self.binary.path, andPath: candidate.path) {
      if FileManager.default.fileExists(atPath: self.binary.path) {
        let backup = self.root.appendingPathComponent("bin/.previous-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: self.binary, to: backup)
        try self.replace(backup, self.previous)
      }
      try self.replace(pending, self.binary)
    }
    try FileManager.default.createDirectory(at: self.serviceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existed = FileManager.default.fileExists(atPath: self.serviceFile.path)
    try Data(self.serviceDefinition.utf8).write(to: self.serviceFile, options: .atomic)
    try await self.control(.install(existed: existed))
  }

  func rollback() async throws {
    try self.validate()
    let lock = try self.lock()
    defer { close(lock) }
    guard FileManager.default.isExecutableFile(atPath: self.previous.path) else {
      throw MachineV2InstallError(code: .missingBinary, message: "no previous v2 binary for \(self.machine)")
    }
    let saved = self.root.appendingPathComponent("bin/.rollback-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: self.previous, to: saved)
    defer { try? FileManager.default.removeItem(at: saved) }
    try self.replace(saved, self.binary)
    try await self.control(.restart)
  }

  func uninstall(leave: @Sendable () async throws -> Void) async throws {
    try self.validate()
    let lock = try self.lock()
    defer { close(lock) }
    var unacknowledged: MachineV2RuntimeError?
    do { try await leave() }
    catch let error as MachineV2RuntimeError where error.code == .leaveUnacknowledged { unacknowledged = error }
    catch { throw MachineV2InstallError(code: .drainFailed, message: "v2 service left running: \(error)") }
    try await self.control(.uninstall)
    if FileManager.default.fileExists(atPath: self.serviceFile.path) { try FileManager.default.removeItem(at: self.serviceFile) }
    if self.platform == .linux { _ = try await self.run(["/usr/bin/systemctl", "--user", "daemon-reload"]) }
    if let unacknowledged { throw unacknowledged }
  }

  private func validate() throws {
    guard !self.machine.isEmpty, self.machine.utf8.count <= 80,
          self.machine.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 })
    else { throw MachineV2InstallError(code: .invalidMachine, message: "unsafe machine id") }
    for path in [self.home.appendingPathComponent(".wuhu"), self.home.appendingPathComponent(".wuhu/machine-v2"), self.root, self.root.appendingPathComponent("bin"), self.binary, self.previous] {
      if (try? FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
        throw MachineV2InstallError(code: .invalidMachine, message: "symlink in v2 installation: \(path.path)")
      }
    }
  }

  private func lock() throws -> Int32 {
    try FileManager.default.createDirectory(at: self.root.appendingPathComponent("bin"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = self.root.appendingPathComponent(".install-lock")
    let fd = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw MachineV2InstallError(code: .invalidMachine, message: "cannot open installation lock: \(path.path)") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
      close(fd)
      throw MachineV2InstallError(code: .invalidMachine, message: "installation lock must be an owner-private regular file: \(path.path)")
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw MachineV2InstallError(code: .busy, message: "installation locked: \(path.path)")
    }
    // Keep the inode in place: unlinking after unlock lets contenders lock different files.
    return fd
  }

  private func replace(_ source: URL, _ target: URL) throws {
    guard rename(source.path, target.path) == 0 else { throw MachineV2InstallError(code: .missingBinary, message: "binary rename failed: \(String(cString: strerror(errno)))") }
  }

  private enum Action { case install(existed: Bool), restart, uninstall }
  private func control(_ action: Action) async throws {
    switch self.platform {
    case .linux:
      let base = ["/usr/bin/systemctl", "--user"]
      switch action {
      case .install:
        _ = try await self.run(base + ["daemon-reload"])
        _ = try await self.run(base + ["enable", self.unit])
        _ = try await self.run(base + ["restart", self.unit])
      case .restart: _ = try await self.run(base + ["restart", self.unit])
      case .uninstall: _ = try await self.run(base + ["disable", "--now", self.unit])
      }
    case .macOS:
      let base = ["/bin/launchctl"]
      let domain = "gui/\(self.userID)"
      switch action {
      case let .install(existed):
        if existed { try await self.bootout("\(domain)/\(self.label)") }
        _ = try await self.run(base + ["bootstrap", domain, self.serviceFile.path])
      case .restart: _ = try await self.run(base + ["kickstart", "-k", "\(domain)/\(self.label)"])
      case .uninstall: try await self.bootout("\(domain)/\(self.label)")
      }
    }
  }

  private func bootout(_ service: String) async throws {
    do { _ = try await self.command(["/bin/launchctl", "bootout", service]) }
    catch {
      let diagnostic = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
      guard diagnostic.hasSuffix("Could not find specified service") || diagnostic.hasSuffix("Boot-out failed: 3: No such process") else {
        throw MachineV2InstallError(code: .serviceFailure, message: "launchctl bootout \(service): \(error)")
      }
    }
  }

  private func run(_ arguments: [String]) async throws -> String {
    do { return try await self.command(arguments) }
    catch { throw MachineV2InstallError(code: .serviceFailure, message: "\(arguments.joined(separator: " ")): \(error)") }
  }

  private func preflight(executable: URL) async throws {
    @Dependency(\.continuousClock) var clock
    let result = self.root.appendingPathComponent(".preflight-\(UUID().uuidString).json")
    let plist = self.root.appendingPathComponent(".preflight.plist")
    let preflightLabel = self.label + ".preflight"
    let domain = "gui/\(self.userID)"
    let definition = self.launchdDefinition(label: preflightLabel, arguments: [executable.path, "machine-v2", "preflight", self.machine, result.path], keepAlive: false)
    try await self.bootout("\(domain)/\(preflightLabel)")
    try Data(definition.utf8).write(to: plist, options: .atomic)
    defer { try? FileManager.default.removeItem(at: result); try? FileManager.default.removeItem(at: plist) }
    _ = try await self.run(["/bin/launchctl", "bootstrap", domain, plist.path])
    do {
      for _ in 0 ..< 250 {
        if FileManager.default.fileExists(atPath: result.path) {
          struct Receipt: Decodable { var ok: Bool; var code: String?; var message: String? }
          let receipt: Receipt
          do { receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: result)) }
          catch { throw MachineV2InstallError(code: .preflightFailed, message: "invalid launchd preflight receipt: \(error)") }
          guard receipt.ok else {
            throw MachineV2InstallError(code: receipt.code == "localNetworkDenied" ? .localNetworkDenied : .preflightFailed, message: receipt.message ?? "launchd network probe failed")
          }
          try await self.bootout("\(domain)/\(preflightLabel)")
          return
        }
        try await clock.sleep(for: .milliseconds(100))
      }
      throw MachineV2InstallError(code: .preflightFailed, message: "launchd Local Network preflight timed out; grant access and retry, no alternate execution path is used")
    } catch {
      try? await self.bootout("\(domain)/\(preflightLabel)")
      throw error
    }
  }

  var serviceDefinition: String {
    switch self.platform {
    case .linux:
      let executable = self.binary.path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      return """
      [Unit]
      Description=Wuhu machine v2 (\(self.machine))
      After=network-online.target
      [Service]
      Type=simple
      ExecStart="\(executable)" machine-v2 run \(self.machine)
      Restart=always
      RestartSec=2
      KillMode=process
      UMask=0077
      NoNewPrivileges=true
      [Install]
      WantedBy=default.target

      """
    case .macOS:
      return self.launchdDefinition(label: self.label, arguments: [self.binary.path, "machine-v2", "run", self.machine], keepAlive: true)
    }
  }

  private func launchdDefinition(label: String, arguments: [String], keepAlive: Bool) -> String {
    func xml(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(xml(label))</string>
    <key>ProgramArguments</key><array>\(arguments.map { "<string>\(xml($0))</string>" }.joined())</array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><\(keepAlive ? "true" : "false")/>
    <key>AbandonProcessGroup</key><true/>
    <key>Umask</key><integer>63</integer>
    <key>StandardOutPath</key><string>\(xml(self.root.appendingPathComponent("agent.log").path))</string>
    <key>StandardErrorPath</key><string>\(xml(self.root.appendingPathComponent("agent.log").path))</string>
    </dict></plist>
    """
  }
}
