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
import struct OperationProtocol.OperationError

struct SupervisorManifest: Codable, Equatable, Sendable {
  let version: Int
  let machine: String
  let operation: UUID
  let nonce: String
  let socket: String
}

struct SupervisorFiles: Sendable {
  var create: @Sendable (String, SupervisorManifest) async throws -> Void
  var load: @Sendable (String) async throws -> SupervisorManifest
  var list: @Sendable (String) async throws -> [String]

  static let live = Self(create: { path, manifest in
    guard mkdir(path, 0o700) == 0 else { throw OperationError(errno == EEXIST ? .operationExists : .invalidConfiguration) }
    let file = path + "/manifest.json"
    let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw OperationError(.invalidConfiguration) }
    defer { _ = close(fd) }
    let data = try JSONEncoder().encode(manifest)
    let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard count == data.count, fsync(fd) == 0 else { throw OperationError(.invalidConfiguration) }
  }, load: { path in
    let file = path + "/manifest.json"
    do {
      var state = stat()
      guard lstat(path, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700,
            state.st_mode & S_IFMT == S_IFDIR else { throw OperationError(.invalidConfiguration, message: "Supervisor directory must be owner-private") }
      let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard fd >= 0 else { throw OperationError(.invalidConfiguration) }
      defer { _ = close(fd) }
      guard fstat(fd, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o600, state.st_mode & S_IFMT == S_IFREG, state.st_size > 0, state.st_size <= 4096 else { throw OperationError(.invalidConfiguration) }
      var bytes = [UInt8](repeating: 0, count: Int(state.st_size))
      guard read(fd, &bytes, bytes.count) == bytes.count else { throw OperationError(.invalidConfiguration) }
      return try JSONDecoder().decode(SupervisorManifest.self, from: Data(bytes))
    } catch {
      let failure = error as? OperationError ?? .init(.invalidConfiguration, message: "Malformed supervisor manifest")
      throw OperationError(failure.code, message: failure.message, details: ["path": .string(file)])
    }
  }, list: { root in
    try FileManager.default.contentsOfDirectory(atPath: root).filter { !$0.hasPrefix(".") }.map { root + "/" + $0 }
  })
}

/// Version 2 names the machine's rendezvous socket the supervisor dials. Version 1 names the supervisor's own listening socket,
/// `control.sock` or #607's compact `s`; only supervisors an older agent started carry it.
func validateManifest(_ manifest: SupervisorManifest, directory: String) throws {
  let socket: Bool
  switch manifest.version {
  case 1:
    socket = (manifest.socket == directory + "/control.sock" || manifest.socket == directory + "/s") && manifest.socket.utf8.count < 104
  case 2:
    let root = String(directory[..<(directory.lastIndex(of: "/") ?? directory.startIndex)])
    socket = manifest.socket == Rendezvous.socketPath(operationsDirectory: root) && manifest.socket.utf8.count <= Rendezvous.maximumSocketPathBytes
  default:
    socket = false
  }
  guard socket, !manifest.machine.isEmpty, manifest.nonce.count == 72, directory.hasSuffix("/" + manifest.operation.uuidString) else {
    throw OperationError(.invalidConfiguration, message: "Unsupported supervisor manifest or Unix socket path")
  }
}
