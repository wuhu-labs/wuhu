#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import struct Fetch.FetchClient
import class OperationClient.OperationClient
import struct OperationClient.OperationOwner
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct SpaceContract.GroupID
import class SpaceCore.Space

actor MachineV2Coordinator {
  private let space: Space
  private let key: SymmetricKey
  private let problemsGroup: GroupID
  private let origin: URL
  private let clock: OperationClock
  private let fetch: @Sendable (GroupID) -> FetchClient
  private let abort: @Sendable (GroupID, UUID) -> Void
  private var clients: [GroupID: OperationClient] = [:]
  private var recovery: [GroupID: Set<UUID>] = [:]
  private var presence: [String: Duration] = [:]
  private var leases: [String: Duration] = [:]
  private var detached: Set<String> = []
  private var leaveFailed: Set<String> = []
  private var probes: [String: Duration] = [:]
  private var prepared = false
  private var running = false
  private var closed = false

  init(
    space: Space,
    key: SymmetricKey,
    problemsGroup: GroupID,
    origin: URL,
    clock: OperationClock = .continuous,
    fetch: @escaping @Sendable (GroupID) -> FetchClient,
    abort: @escaping @Sendable (GroupID, UUID) -> Void,
  ) {
    self.space = space; self.key = key; self.problemsGroup = problemsGroup; self.origin = origin
    self.clock = clock; self.fetch = fetch; self.abort = abort
  }

  func credentialIssued(group: GroupID, owner: OperationOwner) async throws -> Bool {
    guard !closed else { throw OperationError(.requestCancelled) }
    let store = try await space.machineV2Store(group: group, key: key, problemsGroup: problemsGroup)
    return try await store.lookup(owner)?.start.input.object?["sessionCredential"] != nil
  }

  func credentialActive(group: GroupID, owner: OperationOwner) async throws -> Bool {
    guard !closed else { return false }
    let store = try await space.machineV2Store(group: group, key: key, problemsGroup: problemsGroup)
    guard let record = try await store.lookup(owner) else { return false }
    return record.start.kind == "exec.v1" && record.snapshot?.verdict == nil && record.unknown == nil && record.stopReason == nil
  }

  func client(group: GroupID) async throws -> OperationClient {
    guard !closed else { throw OperationError(.requestCancelled) }
    if let client = clients[group] { return client }
    let store = try await space.machineV2Store(group: group, key: key, problemsGroup: problemsGroup)
    let trace = try await space.machineV2TraceSink(group: group, problemsGroup: problemsGroup)
    if let client = clients[group] { return client }
    guard !closed else { throw OperationError(.requestCancelled) }
    let client = try OperationClient(
      origin: origin,
      fetch: fetch(group),
      clock: clock,
      store: store,
      abort: { [abort] id in abort(group, id) },
      trace: trace,
    )
    clients[group] = client
    return client
  }

  func prepare() async throws {
    guard !prepared, !closed else { throw OperationError(.invalidConfiguration) }
    try await space.validateMachineV2Key(key)
    for group in try await space.groups() { detached.formUnion(try await space.machineV2DetachedMembers(group: group.id)) }
    for group in try await space.machineV2RecoveryGroups() {
      let store = try await space.machineV2Store(group: group, key: key, problemsGroup: problemsGroup)
      let records = try await space.machineV2Recovery(group: group, key: key)
      for operation in records {
        _ = try await store.transaction(operation.record.id) {
          $0.stopReason = $0.stopReason ?? "serverRestart"
          $0.callerRemainingMs = 0
          $0.pendingInputs = [:]
          $0.output = [:]
        }
        recovery[group, default: []].insert(operation.record.id)
      }
      _ = try await client(group: group)
    }
    prepared = true
  }

  func run() async throws {
    guard prepared, !running, !closed else { throw OperationError(.invalidConfiguration) }
    running = true
    defer { running = false }
    do {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        for (group, operations) in recovery {
          for id in operations {
            tasks.addTask {
              while await self.needsRecovery(id, group: group) {
                try Task.checkCancellation()
                try await self.recover(id, group: group)
                try await self.clock.sleep(.seconds(1))
              }
            }
          }
        }
        tasks.addTask {
          while await !self.closed {
            try Task.checkCancellation()
            try await self.probeMembers()
            try await self.clock.sleep(.seconds(1))
          }
        }
        while try await tasks.next() != nil {}
      }
    } catch {
      await shutdown()
      throw error
    }
  }

  func shutdown() async {
    closed = true
    await withTaskGroup(of: Void.self) { tasks in
      for client in clients.values { tasks.addTask { await client.shutdown() } }
    }
  }

  func tick() async throws {
    guard prepared, !closed else { throw OperationError(.invalidConfiguration) }
    var work: [@Sendable () async throws -> Void] = []
    for (group, operations) in recovery {
      for id in operations { work.append { try await self.recover(id, group: group) } }
    }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      for job in work { tasks.addTask { try await job() } }
      tasks.addTask { try await self.probeMembers() }
      while try await tasks.next() != nil {}
    }
  }

  private func needsRecovery(_ id: UUID, group: GroupID) -> Bool {
    !closed && recovery[group]?.contains(id) == true
  }

  private func probeMembers() async throws {
    var members: [(GroupID, String)] = []
    for group in try await space.groups() where group.removedAt == nil {
      for machine in try await space.machineV2Members(group: group.id) {
        if let last = probes[machine], clock.now() - last < .seconds(20) { continue }
        probes[machine] = clock.now()
        members.append((group.id, machine))
      }
    }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      for (group, machine) in members { tasks.addTask { try await self.probe(machine, group: group) } }
      while try await tasks.next() != nil {}
    }
  }

  private func recover(_ id: UUID, group: GroupID) async throws {
    let client = try await client(group: group)
    let store = try await space.machineV2Store(group: group, key: key, problemsGroup: problemsGroup)
    do {
      let current = try await store.read(id)
      if current.snapshot?.verdict == nil { _ = try await client.reconcileAbandoned(id) }
      let record = try await store.read(id)
      guard let snapshot = record.snapshot, snapshot.verdict != nil else { return }
      let channels = record.description.kinds.first { $0.name == record.start.kind }?.outputChannels ?? []
      for channel in channels {
        _ = try await client.takeOutput(id, channel: channel.name)
        _ = try await client.poll(id, channel: channel.name)
        _ = try await client.takeOutput(id, channel: channel.name)
      }
      let drained = try await store.read(id)
      guard let terminal = drained.snapshot, channels.allSatisfy({ channel in
        guard let final = terminal.finalOffsets[channel.name] else { return false }
        return (drained.committed[channel.name] ?? .zero) == final
      }) else { return }
      let acknowledged = try await client.poll(id, terminalAck: true)
      if acknowledged.outputConsumed { recovery[group]?.remove(id) }
    } catch let error as OperationError {
      if error.code == .unknownOperation {
        do {
          let current = try await store.read(id)
          if current.unknown?.details?.object?["reason"]?.stringValue != "leaseSilence" { recovery[group]?.remove(id) }
        } catch let local as OperationError where local.code == .unknownOperation {
          recovery[group]?.remove(id)
        }
      } else if Self.fatal(error) { throw error }
    }
  }

  private func probe(_ machine: String, group: GroupID) async throws {
    let client = try await client(group: group)
    let now = clock.now()
    if presence[machine] == nil { presence[machine] = now; leases[machine] = .seconds(60) }
    do {
      let description = try await client.describe(machine)
      if detached.contains(machine), !description.acceptingStarts { return }
      if leaveFailed.contains(machine), !description.acceptingStarts {
        try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaveHandshakeFailed")
        return
      }
      leaveFailed.remove(machine)
      detached.remove(machine)
      presence[machine] = clock.now(); leases[machine] = .milliseconds(description.limits.leaseMs)
      try await space.recordMachineV2Presence(machine, group: group, state: .attached, description: description)
    } catch let error as OperationError {
      if error.code == .leaving {
        do {
          try await client.acknowledgeLeave(machine)
        } catch let acknowledgement as OperationError {
          leaveFailed.insert(machine)
          try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaveHandshakeFailed")
          if Self.fatal(acknowledgement) { throw acknowledgement }
          return
        }
        leaveFailed.remove(machine)
        detached.insert(machine)
        try await space.recordMachineV2Presence(machine, group: group, state: .detached, reason: "leaving")
      } else if Self.retryable(error) {
        if !detached.contains(machine), clock.now() - (presence[machine] ?? now) >= (leases[machine] ?? .seconds(60)) {
          try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaseSilence")
        }
      } else if Self.fatal(error) { throw error }
      else {
        try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: error.code.rawValue)
      }
    }
  }

  private static func fatal(_ error: OperationError) -> Bool {
    [.storeUnavailable, .traceUnavailable, .invalidConfiguration].contains(error.code)
  }

  private static func retryable(_ error: OperationError) -> Bool {
    [.transport, .requestDeadline, .requestCancelled, .capacityExceeded, .machineUnavailable, .supervisorUnavailable].contains(error.code)
  }
}
