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

public struct DeploymentAdminPolicy: Sendable {
  private struct PolicyFile: Decodable { let allowedUIDs: Set<UInt32> }
  public let allowedUIDs: Set<UInt32>
  enum Refusal: Error, Equatable { case policy, machineAgentUID, machineInventory }

  public static func load() throws -> Self? { try load(path: "/etc/wuhu/admin-exec.json", owner: 0) }

  static func load(path: String, owner: UInt32) throws -> Self? {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else { throw Refusal.policy }
    defer { _ = close(fd) }
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == owner, state.st_mode & S_IFMT == S_IFREG,
          state.st_mode & 0o022 == 0, state.st_nlink == 1, state.st_size > 0, state.st_size <= 65536 else { throw Refusal.policy }
    var bytes = Data(count: Int(state.st_size))
    guard bytes.withUnsafeMutableBytes({ pread(fd, $0.baseAddress!, $0.count, 0) }) == bytes.count else { throw Refusal.policy }
    let policy = try JSONDecoder().decode(PolicyFile.self, from: bytes)
    guard !policy.allowedUIDs.isEmpty else { throw Refusal.policy }
    return Self(allowedUIDs: policy.allowedUIDs)
  }

  public static func requireMachineAgentUser() throws {
    try load()?.requireMachineAgentUser(uid: UInt32(geteuid()))
  }

  func requireMachineAgentUser(uid: UInt32) throws {
    guard !allowedUIDs.contains(uid) else { throw Refusal.machineAgentUID }
  }

  public func requireNoMachineAgents() throws {
    for uid in allowedUIDs {
      try Self.requireMachineRoleIdle(uid)
      let result = process_has_machine_agent(uid)
      guard result >= 0 else { throw Refusal.machineInventory }
      guard result == 0 else { throw Refusal.machineAgentUID }
    }
  }
}

extension DeploymentAdminPolicy {
  public final class MachineAdmission: Sendable {
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { _ = close(descriptor) }
  }

  public static func admitMachineAgent() throws -> MachineAdmission {
    let path = machineRolePath(UInt32(geteuid()))
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw Refusal.machineInventory }
    do {
      try validateRole(fd, uid: UInt32(geteuid()))
      guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw Refusal.machineAgentUID }
      try requireMachineAgentUser()
      return MachineAdmission(descriptor: fd)
    } catch { _ = close(fd); throw error }
  }

  private static func machineRolePath(_ uid: UInt32) -> String {
    #if os(Linux)
      "/tmp/wuhu-machine-role-" + String(uid)
    #else
      "/private/tmp/wuhu-machine-role-" + String(uid)
    #endif
  }

  private static func validateRole(_ fd: Int32, uid: UInt32) throws {
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == uid, state.st_mode & S_IFMT == S_IFREG,
          state.st_mode & 0o777 == 0o600, state.st_nlink == 1 else { throw Refusal.machineInventory }
  }

  private static func requireMachineRoleIdle(_ uid: UInt32) throws {
    let fd = open(machineRolePath(uid), O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0, errno == ENOENT { return }
    guard fd >= 0 else { throw Refusal.machineInventory }
    defer { _ = close(fd) }
    try validateRole(fd, uid: uid)
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Refusal.machineAgentUID }
  }
}
