#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// No public constructor, argv parser or environment lookup can install this policy.
struct AdminExecTesting: Sendable {
  @TaskLocal static var current: Self?
  let allowedUIDs: Set<UInt32>
  let workerExecutable: String?
  var beforeSuccessorValidation: @Sendable (Bool?) throws -> Void = { _ in }
  var beforeWorkerCommit: @Sendable () throws -> Void = {}
  var afterWorkerResume: @Sendable () async throws -> Void = {}
  var beforeAcceptingConnections: @Sendable () async throws -> Void = {}
  var beforeCommittedWrite: @Sendable () throws -> Void = {}
  var beforeReadyWrite: @Sendable (String) throws -> Void = { _ in }
}
