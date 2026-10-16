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
import Dependencies
import DeploymentAdmin
import Logging
import ServeNIO
import struct SessionDomain.SessionID
import struct SpaceCore.SessionStore

struct AdminExecScope {
  @TaskLocal static var current: AdminExecController?
}

actor AdminExecController {
  struct Lease: Codable { let processID: Int32; let birth: String }
  struct Request: Codable { let id: UUID; var rollback = false }
  struct Reply: Codable { let id: UUID; let code: String; let processID: Int32; var reason: String? = nil }
  struct Status: Codable {
    let processID: Int32
    let birth: String
    let executable: String
    let port: Int
    let listenerDevice: UInt64
    let listenerInode: UInt64
    let workerProcessID: Int32?
    let workerBirth: String?
    let workerListenerDevice: UInt64?
    let workerListenerInode: UInt64?
    let phase: String
  }

  struct Intent: Codable { let lastGood: String; let digest: String; let phase: String }
  static let environmentKey = "WUHU_ADMIN_EXEC_FD"

  let files: AdminExecFiles
  let executable: String
  let digest: String
  let image: AdminExecImage
  let incoming: AdminExecFrame?
  private var rollbackDescriptors: AdminExecDescriptors?
  private var publicDescriptors: AdminExecDescriptors?
  private var server: ServeNIOServer?
  private var space: String?
  private var execution: LazyExecutionWorker?
  private var validateExecution: (@Sendable (ExecSpaceRecord) async throws -> Void)?
  private var pauseRequests: (@Sendable () async throws -> Void)?
  private var resumeRequests: (@Sendable () async -> Void)?
  private var adminSocket: AdminExecSocket?
  private var allowedUIDs: Set<UInt32> = []
  private let pending: AsyncStream<Request>
  private let submit: AsyncStream<Request>.Continuation
  private var busy = false
  private enum Readiness { case rollbackEligible, repairingForward, ready }
  private var readiness = Readiness.rollbackEligible
  private var readinessDeadline: AdminExecReadinessDeadline?

  private init(files: AdminExecFiles, image: AdminExecImage, incoming: AdminExecFrame?, rollbackDescriptors: AdminExecDescriptors?) {
    self.files = files; self.image = image; self.executable = image.path; self.digest = image.digest
    self.incoming = incoming; self.rollbackDescriptors = rollbackDescriptors
    (pending, submit) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }

  static func forTesting(files: AdminExecFiles, image: AdminExecImage, incoming: AdminExecFrame) throws -> AdminExecController {
    AdminExecController(files: files, image: image, incoming: incoming, rollbackDescriptors: try AdminExecDescriptors(duplicating: incoming.descriptors))
  }

  static func begin(folder: URL, placement: ExecutionPlacement) async throws -> AdminExecController {
    try AdminExecError.requireSupportedPlatform()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = try AdminExecFiles(folder: folder, create: true)
    let controller: AdminExecController
    if let raw = ProcessInfo.processInfo.environment[environmentKey] {
      guard let fd = Int32(raw), fd > 2 else { throw AdminExecError.refused("execEnvelope") }
      _ = unsetenv(environmentKey)
      let frame = try AdminExecEnvelope.take(fd)
      let backups = try AdminExecDescriptors(duplicating: frame.descriptors)
      let image = AdminExecImage(inherited: frame.image, path: frame.lastGood, digest: frame.digest)
      controller = AdminExecController(files: files, image: image, incoming: frame, rollbackDescriptors: backups)
    } else {
      guard let executable = try ExecutionPlacement.worker().executable else { throw AdminExecError.refused("standaloneProcessModeRequired") }
      let image = try AdminExecImage(path: executable)
      controller = AdminExecController(files: files, image: image, incoming: nil, rollbackDescriptors: nil)
    }
    await controller.armReadiness()
    return controller
  }

  func validateSuccessor(placement: ExecutionPlacement) async throws {
    guard (ProcessInfo.processInfo.environment["WUHU_EXEC"] ?? "").isEmpty,
          placement.executable == (try ExecutionPlacement.worker().executable) || AdminExecTesting.current?.workerExecutable == placement.executable else { throw AdminExecError.refused("standaloneProcessModeRequired") }
    if let testing = AdminExecTesting.current { allowedUIDs = testing.allowedUIDs }
    else {
      guard let policy = try DeploymentAdminPolicy.load() else { throw AdminExecError.refused("adminPolicyRequired") }
      try policy.requireNoMachineAgents()
      allowedUIDs = policy.allowedUIDs
    }
    try AdminExecTesting.current?.beforeSuccessorValidation(incoming?.rollback)
    if let incoming {
      try incoming.validate()
      try image.validateInherited()
      guard incoming.lastGood == files.path + "/last-good-" + digest,
            try adminExecDigest(try ExecutionPlacement.worker().executable!) == digest else { throw AdminExecError.refused("sameImageRequired") }
    } else {
      if let lease = try files.read("lease.json", as: Lease.self), (try? processBirthIdentity(lease.processID)) == lease.birth { throw AdminExecError.refused("alreadyEnabled") }
      try files.remove("request.json")
      if let intent = try files.read("intent.json", as: Intent.self), intent.phase == "replacing" {
        let lastGood = try files.openImage("last-good-" + intent.digest, digest: intent.digest)
        guard intent.lastGood == lastGood.path else { throw AdminExecError.refused("lastGoodIdentity") }
        try files.write("intent.json", Intent(lastGood: intent.lastGood, digest: intent.digest, phase: "restart-recovery"))
        try lastGood.execute(metadata: nil)
      }
    }
  }

  private func armReadiness() {
    guard let incoming, let rollbackDescriptors else { return }
    let frame = incoming.replacingDescriptors(rollbackDescriptors.descriptors, rollback: true)
    let files = files
    readinessDeadline = AdminExecReadinessDeadline {
      withExtendedLifetime(rollbackDescriptors) {
        if !incoming.rollback { try? Self.replace(frame, files: files) }
        _exit(78)
      }
    }
  }

  func validateSpace(_ id: String, configDirectory: URL?, sessions: SessionStore) async throws -> ExecutionWorkerBootFence.Result? {
    guard let configDirectory else { throw AdminExecError.refused("workerStorage") }
    space = id
    validateExecution = { record in try await Self.validateExecution(record, space: id, configDirectory: configDirectory, sessions: sessions) }
    guard let incoming else { return nil }
    guard incoming.space == id else { throw AdminExecError.refused("configuredSpaceIdentity") }
    try await Self.validateExecution(incoming.execution, space: id, configDirectory: configDirectory, sessions: sessions)
    return .init(credentials: .init())
  }

  private static func validateExecution(_ record: ExecSpaceRecord, space id: String, configDirectory: URL, sessions: SessionStore) async throws {
    let storage = ExecutionWorkerBootStorage(root: configDirectory.path + "/workers/" + id, space: id)
    let inventory = await storage.inventory()
    let expected = record.worker.map { [$0.directory] } ?? []
    switch inventory {
    case .missing where expected.isEmpty: break
    case let .directories(directories) where directories == expected: break
    default: throw AdminExecError.refused("workerInventory")
    }
    if let worker = record.worker {
      _ = try await worker.manifest(configDirectory: configDirectory.path, space: id)
      guard let assignments = try await sessions.sessionsOwnedByWorkers([worker.incarnation]), assignments == Set(record.assignments.map { SessionID(rawValue: $0) }) else { throw AdminExecError.refused("workerAssignments") }
    }
  }

  func register(_ execution: LazyExecutionWorker) {
    precondition(self.execution == nil)
    self.execution = execution
  }

  func installRequests(pause: @escaping @Sendable () async throws -> Void, resume: @escaping @Sendable () async -> Void) {
    pauseRequests = pause; resumeRequests = resume
  }

  func installPublic(_ server: ServeNIOServer, descriptor: Int32) throws {
    self.server = server
    publicDescriptors = try AdminExecDescriptors(duplicating: [descriptor])
  }

  func rollbackPublicDescriptor() throws -> Int32 {
    guard case .rollbackEligible = readiness, let rollbackDescriptors else { throw AdminExecError.refused("publicListenerIdentity") }
    return rollbackDescriptors.descriptors[0]
  }

  func ready() async throws {
    guard let execution, let server, space != nil else { throw AdminExecError.refused("incompleteAssembly") }
    try await execution.reconcileExec()
    try await execution.probeExec()
    if let incoming, !incoming.rollback, ProcessInfo.processInfo.environment["WUHU_ADMIN_EXEC_TEST_READY_FAILURE"] == "1" { throw AdminExecError.refused("injectedReadinessFailure") }
    try writeStatus("status.json", worker: incoming?.execution.worker, phase: incoming == nil ? "initial" : "preparing")
    adminSocket = try await AdminExecSocket(path: AdminExecSocket.location(folder: files.path, uid: UInt32(geteuid()), create: true))
    try AdminExecTesting.current?.beforeReadyWrite("lease.json")
    try files.write("lease.json", Lease(processID: getpid(), birth: processBirthIdentity(getpid())))
    if let incoming {
      try AdminExecTesting.current?.beforeReadyWrite("request.json")
      try files.remove("request.json")
      try AdminExecTesting.current?.beforeReadyWrite("intent.json")
      try files.write("intent.json", Intent(lastGood: incoming.lastGood, digest: digest, phase: "replacing"))
    }
    try AdminExecTesting.current?.beforeWorkerCommit()
    try await Task { try await self.finishReadiness(execution, server: server) }.value
    readiness = .ready
    if let incoming {
      do {
        try AdminExecTesting.current?.beforeCommittedWrite()
        try files.write("intent.json", Intent(lastGood: incoming.lastGood, digest: digest, phase: incoming.rollback ? "rolled-back" : "ready"))
      } catch { Logger(label: "wuhu.admin-exec").error("Committed readiness intent write failed; continuing to serve") }
    }
  }

  private func beginForwardRepair() throws {
    guard case .rollbackEligible = readiness else { return }
    if let incoming { try files.write("intent.json", Intent(lastGood: incoming.lastGood, digest: digest, phase: "repairing-forward")) }
    try readinessDeadline?.commit()
    readinessDeadline = nil
    readiness = .repairingForward
    rollbackDescriptors = nil
  }

  private func finishReadiness(_ execution: LazyExecutionWorker, server: ServeNIOServer) async throws {
    @Dependency(\.continuousClock) var clock
    var delay = Duration.milliseconds(100)
    while true {
      do {
        try await execution.commitExec(beforeResume: { try await self.beginForwardRepair() })
        try await AdminExecTesting.current?.afterWorkerResume()
        await resumeRequests?()
        try await AdminExecTesting.current?.beforeAcceptingConnections()
        try await server.setAcceptingConnections(true)
        if let incoming {
          try AdminExecTesting.current?.beforeReadyWrite("reply.json")
          try files.write("reply.json", Reply(id: incoming.request, code: incoming.rollback ? "rolledBack" : "ready", processID: getpid()))
          try writeStatus("status.json", worker: incoming.execution.worker, phase: incoming.rollback ? "rolled-back" : "ready")
        }
        return
      } catch {
        guard case .repairingForward = readiness else { throw error }
        Logger(label: "wuhu.admin-exec").warning("Repairing forward before readiness")
        try await clock.sleep(for: delay)
        delay = min(delay * 2, .seconds(5))
      }
    }
  }

  func rollbackIfReplacing() throws {
    guard case .rollbackEligible = readiness, let incoming, !incoming.rollback, let rollbackDescriptors else { return }
    let frame = incoming.replacingDescriptors(rollbackDescriptors.descriptors, rollback: true)
    try Self.replace(frame, files: files)
  }

  func runAdminSocket() async {
    guard let adminSocket else { return }
    let allowedUIDs = allowedUIDs
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await adminSocket.run(allowedUIDs: allowedUIDs) { uid, message in try await self.receive(message, uid: uid) } }
      group.addTask { for await request in self.pending { await self.trigger(probation: request, alreadyWritten: true) } }
      await group.waitForAll()
    }
  }

  private func receive(_ message: AdminExecSocket.Message, uid: UInt32) throws -> Reply {
    if AdminExecTesting.current == nil {
      guard let policy = try DeploymentAdminPolicy.load(), policy.allowedUIDs.contains(uid) else { throw AdminExecError.refused("deploymentAdminOnly") }
      try policy.requireNoMachineAgents()
    }
    guard case .ready = readiness else { throw AdminExecError.refused("notReady") }
    if message.query {
      return try files.read("reply.json", as: Reply.self).flatMap { $0.id == message.id ? $0 : nil } ?? Reply(id: message.id, code: "pending", processID: getpid())
    }
    guard !busy else { return Reply(id: message.id, code: "requestBusy", processID: getpid()) }
    let request = Request(id: message.id, rollback: message.rollback)
    try files.write("request.json", request, exclusive: true)
    submit.yield(request)
    return Reply(id: message.id, code: "accepted", processID: getpid())
  }

  private func trigger(probation: Request? = nil, alreadyWritten: Bool = false) async {
    guard !busy else {
      if let probation {
        Logger(label: "wuhu.admin-exec").error("rollbackBlocked", metadata: ["reason": "adminExecBusy"])
        try? files.write("reply.json", Reply(id: probation.id, code: "rollbackBlocked", processID: getpid(), reason: "adminExecBusy"))
        try? files.write("intent.json", Intent(lastGood: files.path + "/last-good-" + digest, digest: digest, phase: "rollbackBlocked"))
      }
      return
    }
    busy = true
    defer { busy = false }
    var request: Request?
    var ownsRequest = false
    var paused = false
    var prepared = false
    var stage = "request"
    do {
      guard let value = try probation ?? files.read("request.json", as: Request.self) else { return }
      request = value
      if probation != nil, !alreadyWritten { try files.write("request.json", value, exclusive: true) }
      ownsRequest = true
      guard let server, let execution, let space, let publicDescriptors, let validateExecution else { throw AdminExecError.refused("incompleteAssembly") }
      stage = "requestGate"
      try await pauseRequests?()
      paused = true
      try await server.setAcceptingConnections(false)
      stage = "workerCheckpoint"
      let exported = try await execution.prepareExec()
      prepared = true
      stage = "workerInventory"
      try await validateExecution(exported.record)
      let descriptor = publicDescriptors.descriptors[0]
      var state = stat()
      guard fstat(descriptor, &state) == 0 else { throw AdminExecError.refused("publicListenerIdentity") }
      stage = "imageStaging"
      let staged = try files.stageImage(image)
      let lastGood = staged.path
      let frame = AdminExecFrame(version: 1, processID: getpid(), birth: try processBirthIdentity(getpid()), request: value.id, digest: digest, lastGood: lastGood, rollback: value.rollback, image: staged.descriptor, listener: descriptor, listenerDevice: UInt64(truncatingIfNeeded: state.st_dev), listenerInode: UInt64(truncatingIfNeeded: state.st_ino), space: space, execution: exported.record)
      stage = "replacement"
      try writeStatus("previous.json", worker: exported.record.worker, phase: value.rollback ? "rollback-source" : "source")
      try files.write("intent.json", Intent(lastGood: lastGood, digest: digest, phase: "replacing"))
      try await execution.checkExec()
      try withExtendedLifetime(exported) { try Self.replace(frame, files: files) }
    } catch {
      Logger(label: "wuhu.admin-exec").error("Preparation refused", metadata: ["stage": "\(stage)", "failureType": "\(String(reflecting: type(of: error)))", "reason": "\(AdminExecError.reason(error))"])
      do {
        if prepared { try await execution?.rollbackExec() }
        if paused { await resumeRequests?(); try await server?.setAcceptingConnections(true) }
        if let request {
          let code = AdminExecError.reason(error)
          let result = request.rollback ? "rollbackBlocked" : code
          if request.rollback { Logger(label: "wuhu.admin-exec").error("rollbackBlocked", metadata: ["reason": "\(code)"]) }
          try AdminExecTesting.current?.beforeReadyWrite("reply.json")
          try files.write("reply.json", Reply(id: request.id, code: result, processID: getpid(), reason: request.rollback ? code : nil))
          if ownsRequest { try files.remove("request.json") }
          try files.write("intent.json", Intent(lastGood: files.path + "/last-good-" + digest, digest: digest, phase: request.rollback ? "rollbackBlocked" : "refused"))
        }
      } catch { Logger(label: "wuhu.admin-exec").critical("Admin exec rollback refused; no replacement performed") }
    }
  }

  private func writeStatus(_ name: String, worker: ExecWorkerRecord?, phase: String) throws {
    guard let server, let publicDescriptors, let port = server.boundAddress.port else { throw AdminExecError.refused("publicListenerIdentity") }
    var state = stat()
    guard fstat(publicDescriptors.descriptors[0], &state) == 0 else { throw AdminExecError.refused("publicListenerIdentity") }
    try files.write(name, Status(processID: getpid(), birth: processBirthIdentity(getpid()), executable: executable, port: port, listenerDevice: UInt64(truncatingIfNeeded: state.st_dev), listenerInode: UInt64(truncatingIfNeeded: state.st_ino), workerProcessID: worker?.processID, workerBirth: worker?.birth, workerListenerDevice: worker?.listenerIdentity.pathDevice, workerListenerInode: worker?.listenerIdentity.pathInode, phase: phase))
  }

  func probationFailed() async {
    await trigger(probation: Request(id: UUID(), rollback: true))
  }

  func probation() async {
    guard incoming != nil, incoming?.rollback == false else { return }
    @Dependency(\.continuousClock) var clock
    await probation(clock: clock)
  }

  private func probation<C: Clock<Duration>>(clock: C) async {
    let deadline = clock.now.advanced(by: .seconds(15 * 60))
    while clock.now < deadline, !Task.isCancelled {
      do {
        try await clock.sleep(for: .seconds(5))
        try Task.checkCancellation()
        try await execution?.probeExec()
      } catch is CancellationError { return }
      catch { await probationFailed(); return }
    }
    try? files.write("intent.json", Intent(lastGood: files.path + "/last-good-" + digest, digest: digest, phase: "last-good"))
  }

  func shutdown() async throws {
    submit.finish()
    await adminSocket?.shutdown(); adminSocket = nil
    try files.remove("lease.json")
  }

  private static func replace(_ frame: AdminExecFrame, files: AdminExecFiles) throws {
    try frame.validate()
    let duplicate = fcntl(frame.image, F_DUPFD_CLOEXEC, 3)
    guard duplicate >= 0 else { throw AdminExecError.refused("descriptorCapacity") }
    let image = try AdminExecImage(taking: duplicate, path: frame.lastGood, digest: frame.digest, privateImage: true, inherited: true)
    let passing = try AdminExecDescriptors(duplicating: frame.descriptors)
    let metadata = try AdminExecEnvelope(frame: frame.replacingDescriptors(passing.descriptors, rollback: frame.rollback), directory: files.path)
    let envelope = try AdminExecDescriptors(duplicating: [metadata.descriptor])
    do {
      try image.execute(metadata: envelope.descriptors[0], inheritedImage: passing.descriptors[1], inherited: passing.descriptors + envelope.descriptors)
    } catch {
      _ = unsetenv(environmentKey)
      throw error
    }
  }
}
