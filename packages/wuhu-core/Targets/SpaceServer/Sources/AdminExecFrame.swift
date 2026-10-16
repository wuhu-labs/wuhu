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

struct AdminExecFrame: Codable, Sendable {
  let version: Int
  let processID: Int32
  let birth: String
  let request: UUID
  let digest: String
  let lastGood: String
  let rollback: Bool
  let image: Int32
  let listener: Int32
  let listenerDevice: UInt64
  let listenerInode: UInt64
  let space: String
  let execution: ExecSpaceRecord

  var descriptors: [Int32] { [listener, image] + (execution.worker.map { [$0.carrier, $0.listener] } ?? []) }

  func replacingDescriptors(_ fds: [Int32], rollback: Bool) -> Self {
    let worker = execution.worker.map { record in
      ExecWorkerRecord(directory: record.directory, space: record.space, generation: record.generation, incarnation: record.incarnation, processID: record.processID, birth: record.birth, fence: record.fence, carrier: fds[2], listener: fds[3], listenerIdentity: record.listenerIdentity)
    }
    return .init(version: version, processID: processID, birth: birth, request: request, digest: digest, lastGood: lastGood, rollback: rollback, image: fds[1], listener: fds[0], listenerDevice: listenerDevice, listenerInode: listenerInode, space: space, execution: .init(worker: worker, assignments: execution.assignments, activePasses: execution.activePasses))
  }

  func validate() throws {
    guard version == 1, processID == getpid(), try processBirthIdentity(getpid()) == birth,
          Set(descriptors).count == descriptors.count, descriptors.allSatisfy({ $0 > 2 }),
          digest.count == 64, digest.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }),
          !space.isEmpty, execution.assignments.count <= 4096,
          Set(execution.assignments).count == execution.assignments.count,
          execution.activePasses.count <= 4096,
          Set(execution.activePasses.keys).isSubset(of: Set(execution.assignments)),
          execution.activePasses.values.allSatisfy({ $0.count <= 4096 && Set($0).count == $0.count }),
          execution.worker != nil || execution.assignments.isEmpty && execution.activePasses.isEmpty else { throw AdminExecError.refused("execIdentity") }
    var state = stat()
    guard fstat(listener, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK,
          UInt64(truncatingIfNeeded: state.st_dev) == listenerDevice,
          UInt64(truncatingIfNeeded: state.st_ino) == listenerInode else { throw AdminExecError.refused("publicListenerIdentity") }
  }
}

final class AdminExecDescriptors: Sendable {
  let descriptors: [Int32]
  init(duplicating descriptors: [Int32]) throws {
    var owned: [Int32] = []
    do {
      for fd in descriptors {
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        guard duplicate >= 0 else { throw AdminExecError.refused("descriptorCapacity") }
        owned.append(duplicate)
      }
    } catch { for fd in owned { _ = close(fd) }; throw error }
    self.descriptors = owned
  }

  deinit { for fd in descriptors { _ = close(fd) } }

  static func protect(_ descriptors: [Int32]) throws {
    for fd in descriptors {
      let flags = fcntl(fd, F_GETFD)
      guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw AdminExecError.refused("descriptorProtection") }
    }
  }
}

final class AdminExecEnvelope: Sendable {
  let descriptor: Int32
  init(frame: AdminExecFrame, directory: String) throws {
    let bytes = try JSONEncoder().encode(frame)
    guard bytes.count <= 65536 else { throw AdminExecError.refused("recordCapacity") }
    let path = directory + "/frame-" + UUID().uuidString
    descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw AdminExecError.refused("privateStorage") }
    guard unlink(path) == 0 else { _ = close(descriptor); throw AdminExecError.refused("privateStorage") }
    do {
      try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
          if written < 0, errno == EINTR { continue }
          guard written > 0 else { throw AdminExecError.refused("privateStorage") }
          offset += written
        }
      }
    } catch { _ = close(descriptor); throw error }
  }

  deinit { _ = close(descriptor) }

  static func take(_ fd: Int32) throws -> AdminExecFrame {
    defer { _ = close(fd) }
    try AdminExecDescriptors.protect([fd])
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_uid == geteuid(), state.st_mode & 0o077 == 0,
          state.st_nlink == 0, state.st_size > 0, state.st_size <= 65536 else { throw AdminExecError.refused("execEnvelope") }
    var data = Data(count: Int(state.st_size))
    let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
    guard count == data.count else { throw AdminExecError.refused("execEnvelope") }
    let frame = try JSONDecoder().decode(AdminExecFrame.self, from: data)
    try AdminExecDescriptors.protect(frame.descriptors)
    return frame
  }
}

func adminExecDigest(_ path: String) throws -> String {
  SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
}
