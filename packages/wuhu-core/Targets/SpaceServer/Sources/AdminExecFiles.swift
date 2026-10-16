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
import struct WorkerProtocol.WorkerProtocolError

struct AdminExecError: Error, Sendable, Equatable, CustomStringConvertible {
  let code: String
  static func refused(_ code: String) -> Self { .init(code: code) }
  var description: String { "adminExec: " + code }

  static func requireSupportedPlatform() throws {
    #if !os(Linux)
      throw Self.refused("unsupportedPlatform")
    #endif
  }

  static func reason(_ error: any Error) -> String {
    if let error = error as? Self { return error.code }
    guard let error = error as? WorkerProtocolError else { return "prepareRefused" }
    switch error.message {
    case "Parent has active non-transferable calls": return "parentActiveCalls"
    case "Parent has unfinished owner effects": return "parentOwnerEffects"
    case "Active operations or cancellation fences cannot be transferred": return "parentOperations"
    case "Machine frame resources cannot be transferred": return "parentMachineFrames"
    case "Identity request resources cannot be transferred": return "parentIdentityReplies"
    case "Attempt traces cannot be transferred": return "parentAttemptTraces"
    case "Active runtime scripts or attempts cannot be transferred": return "parentRuntimeAttempts"
    case "Compact claim handles cannot be transferred": return "parentCompactClaims"
    case "Legacy or opening script streams cannot be checkpointed": return "parentLegacyReaders"
    case "Legacy owner byte replies cannot be transferred": return "parentLegacyReplies"
    case "Invalid parent exec checkpoint": return "parentCheckpointIdentity"
    case "Invalid combined parent checkpoint": return "parentCheckpoint"
    case "Invalid retained owner receipt checkpoint": return "parentReceiptCheckpoint"
    default: return "workerProtocol-" + error.code.rawValue
    }
  }
}

final class AdminExecFiles: Sendable {
  let path: String
  private let descriptor: Int32
  init(folder: URL, create: Bool) throws {
    guard let resolved = realpath(folder.path, nil) else { throw AdminExecError.refused("privateStorage") }
    defer { free(resolved) }
    path = String(cString: resolved) + "/.admin-exec"
    if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw AdminExecError.refused("privateStorage") }
    descriptor = try ExecutionWorkerManifestStore.openDirectory(path)
  }

  deinit { _ = close(descriptor) }

  func read<Value: Decodable>(_ name: String, as: Value.Type = Value.self) throws -> Value? {
    let fd = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else { throw AdminExecError.refused("privateStorage") }
    defer { _ = close(fd) }
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == geteuid(), state.st_mode & 0o077 == 0,
          state.st_mode & S_IFMT == S_IFREG, state.st_nlink == 1, state.st_size > 0, state.st_size <= 65536 else { throw AdminExecError.refused("privateRecord") }
    var data = Data(count: Int(state.st_size))
    let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
    guard count == data.count else { throw AdminExecError.refused("privateRecord") }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  func write<Value: Encodable>(_ name: String, _ value: Value, exclusive: Bool = false) throws {
    let bytes = try JSONEncoder().encode(value)
    guard bytes.count <= 65536 else { throw AdminExecError.refused("recordCapacity") }
    let temporary = "record-" + UUID().uuidString
    let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw AdminExecError.refused("privateStorage") }
    defer { _ = close(fd); _ = unlinkat(descriptor, temporary, 0) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = pwrite(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { throw AdminExecError.refused("privateStorage") }
        offset += written
      }
    }
    guard fsync(fd) == 0 else { throw AdminExecError.refused("privateStorage") }
    if exclusive {
      guard linkat(descriptor, temporary, descriptor, name, 0) == 0 else { throw AdminExecError.refused("requestBusy") }
    } else {
      guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw AdminExecError.refused("privateStorage") }
    }
    guard fsync(descriptor) == 0 else { throw AdminExecError.refused("privateStorage") }
  }

  func openImage(_ name: String, digest: String) throws -> AdminExecImage {
    guard name == "last-good-" + digest else { throw AdminExecError.refused("lastGoodIdentity") }
    let fd = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw AdminExecError.refused("lastGoodStorage") }
    return try AdminExecImage(taking: fd, path: path + "/" + name, digest: digest, privateImage: true)
  }

  func stageImage(_ source: AdminExecImage) throws -> AdminExecImage {
    let name = "last-good-" + source.digest
    var existing = stat()
    if fstatat(descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
      return try openImage(name, digest: source.digest)
    }
    guard errno == ENOENT else { throw AdminExecError.refused("lastGoodStorage") }
    let temporary = "image-" + UUID().uuidString
    let fd = openat(descriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o700))
    guard fd >= 0 else { throw AdminExecError.refused("lastGoodStorage") }
    defer { _ = close(fd); _ = unlinkat(descriptor, temporary, 0) }
    var buffer = [UInt8](repeating: 0, count: 65536)
    var offset: off_t = 0
    while true {
      let count = pread(source.descriptor, &buffer, buffer.count, offset)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw AdminExecError.refused("lastGoodStorage") }
      if count == 0 { break }
      try buffer.withUnsafeBytes { bytes in
        var written = 0
        while written < count {
          let n = pwrite(fd, bytes.baseAddress!.advanced(by: written), count - written, offset + off_t(written))
          if n < 0, errno == EINTR { continue }
          guard n > 0 else { throw AdminExecError.refused("lastGoodStorage") }
          written += n
        }
      }
      offset += off_t(count)
    }
    guard fchmod(fd, 0o500) == 0, fsync(fd) == 0 else { throw AdminExecError.refused("lastGoodStorage") }
    // linkat publishes without replacing an operator-created entry, including a symlink.
    guard linkat(descriptor, temporary, descriptor, name, 0) == 0,
          unlinkat(descriptor, temporary, 0) == 0, fsync(descriptor) == 0 else { throw AdminExecError.refused("lastGoodStorage") }
    return try openImage(name, digest: source.digest)
  }

  func remove(_ name: String) throws {
    guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT, fsync(descriptor) == 0 else { throw AdminExecError.refused("privateStorage") }
  }
}
