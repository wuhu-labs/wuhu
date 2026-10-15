#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol ExecutionOwner.ExecutionOwnerClient
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerCredentials
import class WorkerProtocol.WorkerEndpoint
import struct WorkerProtocol.WorkerHello
import struct WorkerProtocol.WorkerProtocolError

public actor ParentExecutionHandoff {
  private enum State {
    case active, preparing, transferring, retired
    case paused(UUID, ParentExecutionCheckpoint)
  }

  private let parent: ParentExecutionEndpoint
  let bytes: OwnerByteEndpoint
  private var state: State

  public init(owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil, control: (@Sendable (WorkerCall) async throws -> JSONValue)? = nil) {
    let parent = ParentExecutionEndpoint(owner: owner, runtime: runtime, spawn: spawn, control: control)
    self.parent = parent
    bytes = OwnerByteEndpoint(parent: parent, journal: OwnerReceiptJournal(), paused: false)
    state = .active
  }

  private init(parent: ParentExecutionEndpoint, journal: OwnerReceiptJournal, token: UUID, checkpoint: ParentExecutionCheckpoint) {
    self.parent = parent
    bytes = OwnerByteEndpoint(parent: parent, journal: journal, paused: true)
    state = .paused(token, checkpoint)
  }

  public func endpoint(credentials: WorkerCredentials, hello: WorkerHello) throws -> WorkerEndpoint {
    guard case .active = state else { throw unavailable() }
    return bytes.endpoint(credentials: credentials, hello: hello)
  }

  public func prepare() async throws {
    guard case .active = state else { throw unavailable() }
    state = .preparing
    var token: UUID?
    var frozen = false
    do {
      try await bytes.admission.freeze()
      frozen = true
      let paused = try await bytes.journal.pauseAdmission()
      token = paused
      guard await bytes.journal.inventory().allSatisfy({ $0.terminal || $0.operation == "script.stream-next" }) else {
        throw WorkerProtocolError(.unavailable, message: "Parent has unfinished owner effects")
      }
      try await parent.suspendResources()
      _ = try await bytes.journal.quiesce(paused)
      await bytes.admission.drain()
      try Task.checkCancellation()
      let receipts = try await bytes.journal.checkpoint(paused)
      try await bytes.requireTransferableReplies()
      let retained = Set(receipts.clients.flatMap { $0.entries.map { $0.call.id } })
      let readers = try await parent.checkpointReaders(retaining: retained)
      let checkpoint = ParentExecutionCheckpoint(receipts: receipts, readers: readers)
      try checkpoint.validate()
      try Task.checkCancellation()
      try requirePreparing()
      state = .paused(paused, checkpoint)
    } catch {
      if case .preparing = state {
        await parent.resumeResources()
        if let token { try? await bytes.journal.resumeAdmission(token) }
        if frozen { try? await bytes.admission.resume() }
        if case .preparing = state { state = .active }
      }
      throw error
    }
  }

  public func resume() async throws {
    guard case let .paused(token, _) = state else { throw unavailable() }
    state = .preparing
    await parent.resumeResources()
    try await bytes.journal.resumeAdmission(token)
    try requirePreparing()
    try await bytes.admission.resume()
    try requirePreparing()
    state = .active
  }

  public func transfer(to owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil, control: (@Sendable (WorkerCall) async throws -> JSONValue)? = nil) async throws -> ParentExecutionHandoff {
    guard case let .paused(token, checkpoint) = state else { throw unavailable() }
    state = .transferring
    let replacement = ParentExecutionEndpoint(owner: owner, runtime: runtime, spawn: spawn, control: control)
    do {
      try checkpoint.validate()
      let journal = try OwnerReceiptJournal(restoring: checkpoint.receipts)
      try await replacement.restoreReaders(checkpoint.readers)
      let restoredToken = try await journal.pauseAdmission()
      try Task.checkCancellation()
      let restored = ParentExecutionHandoff(parent: replacement, journal: journal, token: restoredToken, checkpoint: checkpoint)
      guard case .transferring = state else { await restored.shutdown(); throw unavailable() }
      await bytes.admission.close()
      await bytes.shutdown()
      await parent.shutdown()
      guard case .transferring = state else { await restored.shutdown(); throw unavailable() }
      state = .retired
      return restored
    } catch {
      await replacement.shutdown()
      if case .transferring = state { state = .paused(token, checkpoint) }
      throw error
    }
  }

  public func shutdown() async {
    if case .retired = state { return }
    state = .retired
    await bytes.admission.close()
    await parent.shutdown()
    await bytes.shutdown()
  }

  private func requirePreparing() throws {
    guard case .preparing = state else { throw unavailable() }
  }

  private func unavailable() -> WorkerProtocolError {
    .init(.unavailable, message: "Parent handoff state does not allow this operation")
  }
}

struct ParentExecutionCheckpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  let receipts: OwnerReceiptCheckpoint
  let readers: [ScriptStreamCheckpoint]
  var description: String { "ParentExecutionCheckpoint(<redacted>)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }

  func validate() throws {
    _ = try receipts.restore()
    guard readers.count <= 256, Set(readers.map { $0.definition.id }).count == readers.count,
          try JSONEncoder().encode(receipts).count + JSONEncoder().encode(readers).count <= 128 << 20
    else { throw invalid() }
    let entries = receipts.clients.flatMap(\.entries)
    guard Set(entries.map { $0.call.id }).count == entries.count else { throw invalid() }
    for reader in readers {
      try reader.validate()
      guard reader.definition.abi == 1, let receipt = reader.definition.receipt, receipt.sequence > 0, receipt.endpoint == receipts.identity,
            reader.definition.operation == "script.observe-open" || reader.definition.operation == "script.watch-open"
      else { throw invalid() }
      if let staged = reader.reader.stagedID {
        guard let entry = entries.first(where: { $0.call.id == staged }),
              entry.call.operation == "script.stream-next",
              try ownerDecode(StreamRequest.self, entry.call.payload).id == reader.definition.id,
              let result = entry.reply.result,
              case let recordValue = try ownerDecode(OwnerEnvelope.self, result).value,
              try ownerDecode(OwnerRecord.self, recordValue).value == reader.reader.stagedValue
        else { throw invalid() }
      }
    }
  }

  private func invalid() -> WorkerProtocolError { .init(.invalidConfiguration, message: "Invalid combined parent checkpoint") }
}
