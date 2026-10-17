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
  var disclaimResponsibility: Bool? = nil
}

/// Reads `<directory>/manifest.json` of a supervisor an older agent launched; the directory and file must be this user's own.
func loadSupervisorManifest(_ path: String) throws -> SupervisorManifest {
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
}

/// A version-2 supervisor, one per operation, dials the machine's rendezvous socket. Version 1 (its own listening socket) is no
/// longer adopted.
func validateManifest(_ manifest: SupervisorManifest, directory: String) throws {
  let root = String(directory[..<(directory.lastIndex(of: "/") ?? directory.startIndex)])
  guard manifest.version == 2, manifest.socket == Rendezvous.socketPath(operationsDirectory: root), manifest.socket.utf8.count <= Rendezvous.maximumSocketPathBytes,
        !manifest.machine.isEmpty, manifest.nonce.count == 72, directory.hasSuffix("/" + manifest.operation.uuidString)
  else {
    throw OperationError(.invalidConfiguration, message: "Unsupported supervisor manifest or Unix socket path")
  }
}
