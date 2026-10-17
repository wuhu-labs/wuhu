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
@testable import DeploymentAdmin
import Testing

@Suite(.serialized) struct DeploymentAdminPolicyTests {
  @Test func absentPolicyLeavesMachineAgentsUnchanged() throws {
    let path = "/tmp/wuhu-admin-missing-" + UUID().uuidString
    let policy = try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid()))
    #expect(policy == nil)
    try policy?.requireMachineAgentUser(uid: UInt32(geteuid()))
  }

  @Test func rootOwnershipModesSymlinkAndUIDSeparationAreEnforced() throws {
    let directory = "/tmp/wuhu-admin-policy-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/policy.json"
    try Data("{\"allowedUIDs\":[123]}".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o644) == 0)
    let policy = try #require(try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid())))
    #expect(throws: DeploymentAdminPolicy.Refusal.machineAgentUID) { try policy.requireMachineAgentUser(uid: 123) }
    try policy.requireMachineAgentUser(uid: 456)
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid()) &+ 1) }
    #expect(chmod(path, 0o664) == 0)
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid())) }
    #expect(chmod(path, 0o644) == 0)
    #expect(symlink(path, directory + "/link") == 0)
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: directory + "/link", owner: UInt32(geteuid())) }
    #expect(link(path, directory + "/hardlink") == 0)
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid())) }
    #expect(unlink(directory + "/hardlink") == 0)
    try Data("{\"allowedUIDs\":[]}".utf8).write(to: URL(fileURLWithPath: path))
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid())) }
    try Data(repeating: 32, count: 65537).write(to: URL(fileURLWithPath: path))
    #expect(throws: (any Error).self) { try DeploymentAdminPolicy.load(path: path, owner: UInt32(geteuid())) }
  }

  @Test func admittedMachineAgentHoldsALifetimeCloseOnExecRoleLock() throws {
    let admission = try DeploymentAdminPolicy.admitMachineAgent()
    #expect(fcntl(admission.descriptor, F_GETFD) & FD_CLOEXEC != 0)
  }
}
