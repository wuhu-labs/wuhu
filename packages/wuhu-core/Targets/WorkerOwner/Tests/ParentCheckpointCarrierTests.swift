#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ExecutionOwner
import JSONValue
import SessionDomain
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

let carrierIdentity = ParentExecCheckpoint.Identity(space: "fixture", generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, incarnation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, processID: 123, birth: "fixture-process-birth")
private let inheritedCarrier: Int32 = 198
private struct FixtureProcessFailure: Error { let executable: String; let status: Int32 }
enum FixtureRejection: CaseIterable { case missingArgument, missingEnvironment, depth, filter }

let carrierFixtureRequested: Bool = {
  let environment = ProcessInfo.processInfo.environment
  let requested = environment["WUHU_CARRIER_TEST_MODE"] != nil || environment["WUHU_CARRIER_TEST_DEPTH"] != nil || environment["WUHU_CARRIER_TEST_FD"] != nil || environment.keys.contains(where: { $0.hasPrefix("WUHU_LISTENER_TEST_") }) || CommandLine.arguments.contains("--wuhu-checkpoint-fixture")
  if requested {
    guard let mode = environment["WUHU_CARRIER_TEST_MODE"], ["absent", "import", "short", "oversize", "listener", "composed"].contains(mode),
          environment["WUHU_CARRIER_TEST_FD"].flatMap(Int32.init).map({ $0 >= 0 }) == true,
          let depth = environment["WUHU_CARRIER_TEST_DEPTH"], let level = Int(depth), (1 ... 2).contains(level),
          level == 1 || mode == "absent",
          CommandLine.arguments.dropFirst() == ["--wuhu-checkpoint-fixture", "v1", depth, mode][...],
          environment["TESTBRIDGE_TEST_ONLY"] == "^ParentCheckpointCarrierExecFixture/run"
    else { _exit(90) }
  }
  if environment["WUHU_CARRIER_TEST_MODE"] == "absent" {
    guard ["DEVICE", "INODE"].allSatisfy({ environment["WUHU_CARRIER_TEST_" + $0].flatMap(UInt64.init) != nil }) else { _exit(90) }
  }
  if ["listener", "composed"].contains(environment["WUHU_CARRIER_TEST_MODE"] ?? "") {
    guard let path = environment["WUHU_LISTENER_TEST_PATH"], path.hasPrefix("/"), path.utf8.count < 104,
          let scenario = environment["WUHU_LISTENER_TEST_SCENARIO"], (environment["WUHU_CARRIER_TEST_MODE"] == "listener" ? ListenerScenario(rawValue: scenario) != nil : ComposedScenario(rawValue: scenario) != nil),
          ["FD_DEVICE", "FD_INODE", "PATH_DEVICE", "PATH_INODE"].allSatisfy({ environment["WUHU_LISTENER_TEST_" + $0].flatMap(UInt64.init) != nil })
    else { _exit(90) }
  }
  if environment["WUHU_CARRIER_TEST_MODE"] == "composed" {
    guard environment["WUHU_LISTENER_TEST_FD"] == "199", environment["WUHU_CARRIER_TEST_FD"] == "198" else { _exit(90) }
  }
  return requested
}()

@Suite(.enabled(if: !carrierFixtureRequested), .serialized, .timeLimit(.minutes(2))) struct ParentCheckpointCarrierTests {
  @Test func invalidFixtureInvocationFailsBeforeRunningTests() throws {
    let unrelated = try ParentCheckpointCarrier.empty()
    let file = try DescriptorFile(of: unrelated.descriptor)
    for rejection in FixtureRejection.allCases {
      #expect(try spawnCarrierTest(mode: "absent", descriptor: inheritedCarrier, file: file, rejection: rejection) == 0)
    }
  }

  @Test func carrierExportRequiresPreparedState() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    await #expect(throws: WorkerProtocolError.self) { try await source.execCarrier(identity: carrierIdentity) }
    try await source.prepare()
    let carrier = try await source.execCarrier(identity: carrierIdentity)
    #expect(try ParentCheckpointCarrier.take(duplicate(carrier.descriptor), expecting: carrierIdentity).execution.receipts.clients.isEmpty)
    try await source.resume()
    await #expect(throws: WorkerProtocolError.self) { try await source.execCarrier(identity: carrierIdentity) }
    await source.shutdown()
  }

  @Test func execImportsOnlyIntoIntendedChild() async throws {
    try await Task.detached {
      let original = try carrierFixture()
      let carrier = try ParentCheckpointCarrier.export(original)
      #expect(fcntl(carrier.descriptor, F_GETFD) & FD_CLOEXEC != 0)
      var info = stat()
      #expect(fstat(carrier.descriptor, &info) == 0)
      #expect(info.st_nlink == 0)
      #expect(try spawnCarrierTest(mode: "absent", descriptor: carrier.descriptor, file: DescriptorFile(of: carrier.descriptor)) == 0)
      #expect(try spawnCarrierTest(mode: "import", descriptor: carrier.descriptor, mapping: true) == 0)
      #expect(fcntl(carrier.descriptor, F_GETFD) & FD_CLOEXEC != 0)
      let restored = try ParentCheckpointCarrier.take(duplicate(carrier.descriptor), expecting: carrierIdentity)
      #expect(restored.execution.receipts.clients[0].entries[0].reply == original.execution.receipts.clients[0].entries[0].reply)
    }.value
  }

  @Test func malformedCarriersCloseBeforeThrowing() throws {
    let carrier = try ParentCheckpointCarrier.export(carrierFixture())
    for count in [0, 8, 15, 20] {
      let malformed = try ParentCheckpointCarrier.empty()
      var bytes = Data(count: count)
      _ = bytes.withUnsafeMutableBytes { pread(carrier.descriptor, $0.baseAddress, count, 0) }
      _ = bytes.withUnsafeBytes { pwrite(malformed.descriptor, $0.baseAddress, count, 0) }
      let fd = try duplicate(malformed.descriptor), file = try DescriptorFile(of: fd)
      #expect(throws: ParentCheckpointCarrierError(code: .shortRead)) { try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity) }
      #expect(released(fd, from: file))
      #expect(try spawnCarrierTest(mode: "short", descriptor: malformed.descriptor, mapping: true) == 0)
    }
    let damaged = try ParentCheckpointCarrier.export(carrierFixture())
    var info = stat()
    try #require(fstat(damaged.descriptor, &info) == 0)
    for offset in [info.st_size, 0] {
      var bad: UInt8 = 0
      try #require(pwrite(damaged.descriptor, &bad, 1, offset) == 1)
      let fd = try duplicate(damaged.descriptor), file = try DescriptorFile(of: fd)
      #expect(throws: ParentCheckpointCarrierError(code: .invalidFrame)) { try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity) }
      #expect(released(fd, from: file))
    }
    let oversized = try ParentCheckpointCarrier.empty()
    var prefix = Data("WUHUCP01".utf8)
    var length = UInt64(ParentExecCheckpoint.maximumBytes + 1).bigEndian
    withUnsafeBytes(of: &length) { prefix.append(contentsOf: $0) }
    _ = prefix.withUnsafeBytes { pwrite(oversized.descriptor, $0.baseAddress, prefix.count, 0) }
    #expect(try spawnCarrierTest(mode: "oversize", descriptor: oversized.descriptor, mapping: true) == 0)
    let fd = try duplicate(oversized.descriptor), file = try DescriptorFile(of: fd)
    #expect(throws: ParentCheckpointCarrierError(code: .oversized)) { try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity) }
    #expect(released(fd, from: file))
    let foreign = ParentExecCheckpoint.Identity(space: "other", generation: carrierIdentity.generation, incarnation: carrierIdentity.incarnation, processID: carrierIdentity.processID, birth: carrierIdentity.birth)
    let other = try duplicate(carrier.descriptor), otherFile = try DescriptorFile(of: other)
    #expect(throws: WorkerProtocolError.self) { try ParentCheckpointCarrier.take(other, expecting: foreign) }
    #expect(released(other, from: otherFile))
  }

  @Test func closeFailureRefusesImport() throws {
    let carrier = try ParentCheckpointCarrier.export(carrierFixture())
    let fd = try duplicate(carrier.descriptor), file = try DescriptorFile(of: fd)
    defer { _ = close(fd) }
    #expect(throws: ParentCheckpointCarrierError(code: .closeFailed)) {
      try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity, closeDescriptor: { open in
        #expect(fcntl(open, F_GETFD) & FD_CLOEXEC != 0)
        #expect((try? spawnCarrierTest(mode: "absent", descriptor: open, file: file)) == 0)
        errno = EIO
        return -1
      })
    }
    #expect(fcntl(fd, F_GETFD) >= 0)
  }

  @Test func interruptedCloseStillImports() throws {
    let carrier = try ParentCheckpointCarrier.export(carrierFixture())
    let fd = try duplicate(carrier.descriptor)
    let restored = try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity, closeDescriptor: { open in
      _ = close(open)
      errno = EINTR
      return -1
    })
    #expect(restored.execution.receipts.clients.count == 1)
  }

  @Test func numberReusedRightAfterCloseStillImports() throws {
    let carrier = try ParentCheckpointCarrier.export(carrierFixture())
    let fd = try duplicate(carrier.descriptor)
    let reuse = Mutex<Int32>(-1)
    defer { if reuse.withLock({ $0 }) >= 0 { _ = close(reuse.withLock { $0 }) } }
    let restored = try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity, closeDescriptor: { open in
      let result = close(open)
      // The lowest free number at or above the closed one: almost always the closed number, naming the same file again.
      reuse.withLock { $0 = fcntl(carrier.descriptor, F_DUPFD_CLOEXEC, open) }
      return result
    })
    #expect(reuse.withLock { $0 } >= fd)
    #expect(restored.execution.receipts.clients.count == 1)
  }

  @Test func credentialAndOpaqueRepliesAreNeverWrittenOrFiltered() throws {
    let safe = try carrierFixture()
    let entry = safe.execution.receipts.clients[0].entries[0]
    let credential = "credential-sentinel-never-written"
    for operation in ["inference.provider-credential", "inference.provider-credential-binding", "inference.inference-token", "inference.inference-binding-identity", "script.secret-value", "script.set-secret", "custom.callback"] {
      let call = WorkerCall(id: entry.call.id, operation: operation, payload: .string(credential), traceContext: nil, receipt: entry.call.receipt)
      #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) {
        try ParentCheckpointCarrier.export(carrierFixture(entry: .init(call: call, reply: .init(id: call.id, result: .string(credential)))))
      }
    }
    for reply in [WorkerReply(id: entry.call.id, result: .object(["value": .string(credential)])), .init(id: entry.call.id, error: .init(.unavailable, message: credential))] {
      #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) {
        try ParentCheckpointCarrier.export(carrierFixture(entry: .init(call: entry.call, reply: reply)))
      }
    }
    let badRequest = WorkerCall(id: entry.call.id, operation: entry.call.operation, payload: try ownerEncode(WarmingRequest(session: .init(credential), intervalSeconds: 7)), traceContext: nil, receipt: entry.call.receipt)
    #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) {
      try ParentCheckpointCarrier.export(carrierFixture(entry: .init(call: badRequest, reply: entry.reply)))
    }
    let reader = ScriptStreamCheckpoint(definition: entry.call, reader: .init(cursor: .init(marker: .string(credential), revision: nil, acknowledgedInRevision: []), stagedID: nil, stagedValue: nil, ended: false, overflowed: false))
    #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) {
      try ParentCheckpointCarrier.export(.init(identity: carrierIdentity, execution: .init(receipts: safe.execution.receipts, readers: [reader])))
    }
    #expect(safe.execution.receipts.clients[0].entries.count == 1)
    _ = try ParentCheckpointCarrier.export(safe)
  }
}

@Suite struct ParentCheckpointCarrierExecFixture {
  @Test func run() async throws {
    guard carrierFixtureRequested else { return }
    let environment = ProcessInfo.processInfo.environment
    guard let mode = environment["WUHU_CARRIER_TEST_MODE"], let fd = environment["WUHU_CARRIER_TEST_FD"].flatMap(Int32.init) else { return }
    if mode == "absent" {
      func number(_ key: String) throws -> UInt64 { try #require(environment["WUHU_CARRIER_TEST_" + key].flatMap(UInt64.init)) }
      try #require(released(fd, from: DescriptorFile(device: number("DEVICE"), inode: number("INODE"))))
      _exit(42)
    }
    try #require(fd == inheritedCarrier)
    try #require(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0)
    let inherited = try DescriptorFile(of: fd)
    if mode == "composed" {
      try await runComposedExecFixture(carrier: fd, descriptor: 199)
      _exit(42)
    }
    if mode == "listener" {
      try await runListenerAdoptionFixture(descriptor: fd)
      _exit(42)
    }
    if mode == "short" || mode == "oversize" {
      try #require(throws: ParentCheckpointCarrierError(code: mode == "short" ? .shortRead : .oversized)) { try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity) }
      try #require(released(fd, from: inherited))
      try #require(try spawnCarrierTest(mode: "absent", descriptor: fd, file: inherited) == 0)
      _exit(42)
    }
    try #require(fcntl(fd, F_GETFD) >= 0)
    let restored = try ParentCheckpointCarrier.take(fd, expecting: carrierIdentity)
    let journal = try OwnerReceiptJournal(restoring: restored.execution.receipts)
    let entry = restored.execution.receipts.clients[0].entries[0]
    try #require(try await journal.run(entry.call) { Issue.record("Imported effect replayed"); return .null } == entry.reply)
    await journal.stop()
    try #require(restored.execution.receipts.clients.count == 1)
    try #require(restored.execution.receipts.clients[0].entries[0].call.operation == "runtime.schedule-warming")
    try #require(released(fd, from: inherited))
    try #require(try spawnCarrierTest(mode: "absent", descriptor: fd, file: inherited) == 0)
    _exit(42)
  }
}

private func carrierFixture(entry: OwnerReceiptCheckpoint.Entry? = nil) throws -> ParentExecCheckpoint {
  let journal = entry?.call.receipt?.endpoint ?? UUID(), client = entry?.call.receipt?.client ?? UUID()
  let call = try WorkerCall(operation: "runtime.schedule-warming", payload: ownerEncode(WarmingRequest(session: .init(UUID().uuidString), intervalSeconds: 7)), traceContext: nil, receipt: .init(endpoint: journal, client: client, sequence: 1))
  let retained = try entry ?? .init(call: call, reply: .init(id: call.id, result: ownerEncode(OwnerEnvelope(value: .bool(true), fault: nil))))
  return ParentExecCheckpoint(identity: carrierIdentity, execution: .init(receipts: .init(identity: journal, clients: [.init(id: client, consumed: 0, acknowledged: [], entries: [retained])]), readers: []))
}

private func duplicate(_ fd: Int32) throws -> Int32 {
  let result = fcntl(fd, F_DUPFD_CLOEXEC, 200)
  guard result >= 0 else { throw ParentCheckpointCarrierError(code: .io) }
  return result
}

/// The open file behind a descriptor. A closed number can be reused by any later open in the process (NIO selectors, descriptors inherited from the parent), so closure and absence are proven by the file, never by the number.
struct DescriptorFile: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64

  init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }

  init(of descriptor: Int32) throws {
    var state = stat()
    try #require(fstat(descriptor, &state) == 0)
    self.init(device: UInt64(truncatingIfNeeded: state.st_dev), inode: UInt64(truncatingIfNeeded: state.st_ino))
  }
}

/// Whether the descriptor number no longer refers to `file`: it is closed, or a later open reused the number.
func released(_ descriptor: Int32, from file: DescriptorFile) -> Bool {
  var state = stat()
  guard fstat(descriptor, &state) == 0 else { return errno == EBADF }
  return DescriptorFile(device: UInt64(truncatingIfNeeded: state.st_dev), inode: UInt64(truncatingIfNeeded: state.st_ino)) != file
}

/// `file` is required for, and only for, `absent`: the file the child's descriptor must not refer to.
func spawnCarrierTest(mode: String, descriptor: Int32, file: DescriptorFile? = nil, mapping: Bool = false, rejection: FixtureRejection? = nil, listenerEnvironment: [String: String] = [:], listenerDescriptor: Int32? = nil) throws -> Int32 {
  #if os(Linux)
    var linuxActions = posix_spawn_file_actions_t()
    guard posix_spawn_file_actions_init(&linuxActions) == 0 else { throw ParentCheckpointCarrierError(code: .io) }
    defer { posix_spawn_file_actions_destroy(&linuxActions) }
  #else
    var actions: posix_spawn_file_actions_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw ParentCheckpointCarrierError(code: .io) }
    defer { posix_spawn_file_actions_destroy(&actions) }
  #endif
  let executable = CommandLine.arguments[0]
  let parentEnvironment = ProcessInfo.processInfo.environment
  let depth = (parentEnvironment["WUHU_CARRIER_TEST_DEPTH"].flatMap(Int.init) ?? 0) + 1
  guard depth <= 2, depth == 1 || (carrierFixtureRequested && mode == "absent") else { _exit(91) }
  var arguments = [executable, "--wuhu-checkpoint-fixture", "v1", String(depth), mode]
  var environment = [
    "PATH": "/usr/bin:/bin",
    "TESTBRIDGE_TEST_ONLY": "^ParentCheckpointCarrierExecFixture/run",
    "WUHU_CARRIER_TEST_MODE": mode,
    "WUHU_CARRIER_TEST_DEPTH": String(depth),
    "WUHU_CARRIER_TEST_FD": String(mapping ? inheritedCarrier : descriptor),
  ]
  let listenerKeys: Set<String> = ["PATH", "SCENARIO", "FD_DEVICE", "FD_INODE", "PATH_DEVICE", "PATH_INODE"]
  guard listenerEnvironment.keys.allSatisfy({ listenerKeys.contains($0) }), listenerEnvironment.isEmpty || mode == "listener" || mode == "composed" else { _exit(91) }
  guard (mode == "composed") == (listenerDescriptor != nil), mode != "composed" || (mapping && descriptor != listenerDescriptor && descriptor != 199 && listenerDescriptor != 198) else { _exit(91) }
  guard (mode == "absent") == (file != nil) else { _exit(91) }
  if let file {
    environment["WUHU_CARRIER_TEST_DEVICE"] = String(file.device)
    environment["WUHU_CARRIER_TEST_INODE"] = String(file.inode)
  }
  if listenerDescriptor != nil { environment["WUHU_LISTENER_TEST_FD"] = "199" }
  for (key, value) in listenerEnvironment { environment["WUHU_LISTENER_TEST_" + key] = value }
  for key in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "SDKROOT"] {
    environment[key] = parentEnvironment[key]
  }
  switch rejection {
  case .missingArgument: arguments.removeLast()
  case .missingEnvironment: environment.removeValue(forKey: "WUHU_CARRIER_TEST_MODE")
  case .depth: environment["WUHU_CARRIER_TEST_DEPTH"] = "3"; arguments[3] = "3"
  case .filter: environment["TESTBRIDGE_TEST_ONLY"] = ".*"
  case nil: break
  }
  let argv = arguments.map { strdup($0)! } + [nil]
  let envp = environment.map { strdup("\($0.key)=\($0.value)")! } + [nil]
  defer { for pointer in argv + envp { free(pointer) } }
  var pid: pid_t = 0
  let result = argv.withUnsafeBufferPointer { argv in
    envp.withUnsafeBufferPointer { envp in
      #if os(Linux)
        if mapping { guard posix_spawn_file_actions_adddup2(&linuxActions, descriptor, inheritedCarrier) == 0 else { return Int32(EINVAL) } }
        if let listenerDescriptor { guard posix_spawn_file_actions_adddup2(&linuxActions, listenerDescriptor, 199) == 0 else { return Int32(EINVAL) } }
        return posix_spawn(&pid, executable, &linuxActions, nil, argv.baseAddress!, envp.baseAddress!)
      #else
        if mapping { guard posix_spawn_file_actions_adddup2(&actions, descriptor, inheritedCarrier) == 0 else { return Int32(EINVAL) } }
        if let listenerDescriptor { guard posix_spawn_file_actions_adddup2(&actions, listenerDescriptor, 199) == 0 else { return Int32(EINVAL) } }
        return posix_spawn(&pid, executable, &actions, nil, argv.baseAddress!, envp.baseAddress!)
      #endif
    }
  }
  guard result == 0 else { throw ParentCheckpointCarrierError(code: .io) }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 { if errno != EINTR { throw ParentCheckpointCarrierError(code: .io) } }
  guard status == (rejection == nil ? 42 : 90) << 8 else { throw FixtureProcessFailure(executable: URL(fileURLWithPath: executable).lastPathComponent, status: status) }
  return 0
}
