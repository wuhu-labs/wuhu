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
import CProcessIdentity
import Crypto

final class AdminExecImage: Sendable {
  let descriptor: Int32
  let path: String
  let digest: String

  init(inherited descriptor: Int32, path: String, digest: String) {
    self.descriptor = descriptor; self.path = path; self.digest = digest
  }

  func validateInherited() throws {
    var state = stat()
    guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_uid == geteuid(),
          state.st_mode & 0o7777 == 0o500, state.st_nlink <= 1,
          try adminExecDigest(descriptor) == digest else { throw AdminExecError.refused("sameImageRequired") }
  }

  init(taking descriptor: Int32, path: String, digest: String? = nil, privateImage: Bool = false, inherited: Bool = false) throws {
    do {
      try AdminExecDescriptors.protect([descriptor])
      var state = stat()
      guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
            state.st_uid == geteuid(), (state.st_nlink == 1 || inherited && state.st_nlink == 0), state.st_mode & 0o022 == 0,
            state.st_mode & 0o100 != 0, !privateImage || state.st_mode & 0o7777 == 0o500 else { throw AdminExecError.refused("imageIdentity") }
      let actual = try adminExecDigest(descriptor)
      guard digest == nil || digest == actual else { throw AdminExecError.refused("sameImageRequired") }
      self.descriptor = descriptor; self.path = path; self.digest = actual
    } catch { _ = close(descriptor); throw error }
  }

  convenience init(path: String) throws {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw AdminExecError.refused("imageIdentity") }
    try self.init(taking: fd, path: path)
  }

  deinit { _ = close(descriptor) }

  func execute(metadata: Int32?, inheritedImage: Int32? = nil, inherited: [Int32] = []) throws {
    try AdminExecError.requireSupportedPlatform()
    if let metadata { guard setenv(AdminExecController.environmentKey, String(metadata), 1) == 0 else { throw AdminExecError.refused("execEnvironment") } }
    guard try adminExecDigest(descriptor) == digest else { throw AdminExecError.refused("sameImageRequired") }
    let executingFD = inheritedImage ?? descriptor
    let arguments = [path] + Array(CommandLine.arguments.dropFirst())
    let pointers = arguments.map { strdup($0) }
    defer { for pointer in pointers { free(pointer) } }
    guard pointers.allSatisfy({ $0 != nil }) else { throw AdminExecError.refused("execArguments") }
    var argv = pointers + [nil]
    #if os(Linux)
      _ = inherited.withUnsafeBufferPointer { intended in
        argv.withUnsafeMutableBufferPointer { process_exec_pinned_image(executingFD, $0.baseAddress!, environ, intended.baseAddress, intended.count) }
      }
    #endif
    throw AdminExecError.refused("execSystemCall")
  }
}

func adminExecDigest(_ descriptor: Int32) throws -> String {
  var hash = SHA256()
  var bytes = [UInt8](repeating: 0, count: 65536)
  var offset: off_t = 0
  while true {
    let count = pread(descriptor, &bytes, bytes.count, offset)
    if count < 0, errno == EINTR { continue }
    guard count >= 0 else { throw AdminExecError.refused("imageIdentity") }
    if count == 0 { break }
    hash.update(data: bytes.prefix(count)); offset += off_t(count)
  }
  return hash.finalize().map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
}
