#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import WorkerOwner
import WorkerProtocol

struct ExecWorkerRecord: Codable, Sendable {
  struct ListenerIdentity: Codable, Sendable {
    let descriptorDevice: UInt64
    let descriptorInode: UInt64
    let pathDevice: UInt64
    let pathInode: UInt64
    init(_ identity: WorkerListener.InheritedIdentity) {
      descriptorDevice = identity.descriptorDevice; descriptorInode = identity.descriptorInode
      pathDevice = identity.pathDevice; pathInode = identity.pathInode
    }

    var value: WorkerListener.InheritedIdentity {
      .init(descriptorDevice: descriptorDevice, descriptorInode: descriptorInode, pathDevice: pathDevice, pathInode: pathInode)
    }
  }

  let directory: String
  let space: String
  let generation: UUID
  let incarnation: UUID
  let processID: Int32
  let birth: String
  let carrier: Int32
  let listener: Int32
  let listenerIdentity: ListenerIdentity

  var identity: ParentExecutionIdentity { .init(space: space, generation: generation, incarnation: incarnation, processID: processID, birth: birth) }

  func manifest(configDirectory: String, space expectedSpace: String) async throws -> ExecutionWorkerManifest {
    guard space == expectedSpace, directory == configDirectory + "/workers/" + space + "/" + generation.uuidString else { throw AdminExecError.refused("workerLocation") }
    let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: space)
    guard let manifest = try await store.load(), manifest.space == space, manifest.generation == generation,
          manifest.incarnation == incarnation, manifest.processID == processID, manifest.birth == birth,
          manifest.credentials.successor == nil, manifest.sockets != nil,
          try await store.loadCleanup() == nil else { throw AdminExecError.refused("workerIdentity") }
    try manifest.verifyProcess()
    return manifest
  }
}

struct ExecWorkerExport: Sendable {
  let record: ExecWorkerRecord
  let transfer: ParentExecTransfer
  let listener: WorkerListener.ListenerExport
}

struct ExecSpaceRecord: Codable, Sendable {
  let worker: ExecWorkerRecord?
  let assignments: [String]
}

struct ExecSpaceExport: Sendable {
  let record: ExecSpaceRecord
  let worker: ExecWorkerExport?
}
