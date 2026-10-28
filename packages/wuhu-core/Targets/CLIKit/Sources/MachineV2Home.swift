#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Crypto

public struct MachineV2RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Code: String, Sendable { case serverUnavailable, invalidConfiguration, enrollmentFailed, machineNotV2, missingKey, localNetworkDenied, preflightFailed, localStopFailed, revoked }
  public let code: Code
  public let message: String
  public init(_ code: Code, message: String = "") { self.code = code; self.message = message }
  public var description: String { "\(code.rawValue): \(message)" }
}

struct MachineV2Config: Codable, Equatable, Sendable {
  var machine: String
  var name: String
  var server: String
  var fingerprint: String? = nil
}

struct MachineV2Home: Sendable {
  let root: URL
  let machine: String
  var directory: URL { root.appendingPathComponent(machine, isDirectory: true) }
  var configFile: URL { directory.appendingPathComponent("config.json") }
  var keyFile: URL { directory.appendingPathComponent("machine.key") }
  var operationsDirectory: URL { directory.appendingPathComponent("operations", isDirectory: true) }
  var binary: URL { directory.appendingPathComponent("bin/wuhu") }
  static func locate(environment: [String: String], machine: String) throws -> Self {
    guard let home = environment["HOME"], home.hasPrefix("/") else { throw MachineV2RuntimeError(.invalidConfiguration, message: "HOME must be absolute") }
    return Self(root: URL(fileURLWithPath: home).appendingPathComponent(".wuhu/machine-v2"), machine: machine)
  }

  func validate() throws {
    guard !machine.isEmpty, machine.utf8.count <= 80, machine.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }), root.path.hasPrefix("/") else {
      throw MachineV2RuntimeError(.invalidConfiguration, message: "Unsafe v2 machine id or home")
    }
    var current = directory
    while current.path != "/" {
      var state = stat()
      if lstat(current.path, &state) == 0 {
        guard state.st_mode & S_IFMT == S_IFDIR else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Non-directory or symlink: \(current.path)") }
        if current == directory { guard state.st_uid == getuid(), state.st_mode & 0o777 == 0o700 else { throw MachineV2RuntimeError(.invalidConfiguration, message: "V2 home must be owner-private 0700") } }
      } else if errno != ENOENT { throw MachineV2RuntimeError(.invalidConfiguration, message: current.path) }
      current.deleteLastPathComponent()
    }
  }

  func prepare() throws {
    try validate()
    for path in [directory, operationsDirectory, directory.appendingPathComponent("bin")] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var state = stat()
      guard lstat(path.path, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700 else { throw MachineV2RuntimeError(.invalidConfiguration, message: "V2 state must be owner-private 0700: \(path.path)") }
    }
  }

  func load() throws -> MachineV2Config {
    try validate(); try privateFile(configFile)
    let config: MachineV2Config
    do { config = try JSONDecoder().decode(MachineV2Config.self, from: Data(contentsOf: configFile)) }
    catch { throw MachineV2RuntimeError(.invalidConfiguration, message: "Malformed or missing \(configFile.path)") }
    try validate(config)
    return config
  }

  func validate(_ config: MachineV2Config) throws {
    guard config.fingerprint.map(ServerTrust.isFingerprint) ?? true else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Malformed v2 certificate pin") }
    guard config.machine == machine, let url = URL(string: config.server), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
      throw MachineV2RuntimeError(.invalidConfiguration, message: "Expected explicit v2 machine and HTTPS origin")
    }
  }

  func loadKey() throws -> Curve25519.Signing.PrivateKey {
    try validate(); try privateFile(keyFile)
    guard let key = try Ed25519KeyFile.read(keyFile, hint: "rejoin this v2 machine") else { throw MachineV2RuntimeError(.missingKey) }
    return key
  }

  func save(_ config: MachineV2Config, key: Curve25519.Signing.PrivateKey) throws {
    try validate(config); try prepare()
    for file in [configFile, keyFile] where FileManager.default.fileExists(atPath: file.path) { try privateFile(file) }
    try Ed25519KeyFile.write(key, to: keyFile)
    try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
    guard chmod(configFile.path, 0o600) == 0 else { throw MachineV2RuntimeError(.invalidConfiguration) }
  }

  private func privateFile(_ file: URL) throws {
    var state = stat()
    guard lstat(file.path, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_uid == getuid(), state.st_mode & 0o777 == 0o600, state.st_size <= 8192 else { throw MachineV2RuntimeError(.invalidConfiguration, message: "Missing or unsafe owner-private file: \(file.path)") }
  }
}
