import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import Dependencies
import struct Fetch.FetchClient
import enum JSONValue.JSONValue
import MachineChannel
import struct MachineContract.ExecID
import OperationClient
import struct OperationClient.Operation
import struct OperationClient.OperationOwner
import protocol OperationClient.OperationStore
import struct OperationProtocol.OperationError
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import struct SpaceCore.ExecRecord
import class SpaceCore.Space

/// Machine v2 on the server: one `MachineOperations` per group, all sharing the machines' tunnel lanes, the members' presence,
/// and the exec relay. Boot resumes a group's live operations before a caller can reach one of them.
actor MachineV2Service {
  private let presenceScope = TaskScope()
  struct ExecEndpoint {
    let endpoint: ChannelEndpoint
    let starter: ExecStarter
    var callers: [UUID: ExecLeg] = [:]
    var disconnected: Date?
    var completed: Date?
    /// The machine operation the exec runs as, once it has one.
    var operation: OperationClient.Operation?

    init(endpoint: ChannelEndpoint, starter: ExecStarter = ExecStarter()) {
      self.endpoint = endpoint; self.starter = starter
    }
  }

  var execEndpoints: [String: ExecEndpoint] = [:]
  /// Execs a kill reached before or while they started.
  var killedExecs: Set<String> = []
  enum ExecJob: Sendable {
    case caller(MachineV2ExecRelay)
    case minted(ExecRecord, Space)
  }

  let relays = AsyncStream<ExecJob>.makeStream()
  static let origin = URL(string: "https://machine-v2.internal")!
  static let problemsGroup = GroupID.shared
  /// Why boot ends an operation a server from before this release started.
  static let serverUpgraded = "serverUpgraded"
  let space: Space
  private let hub: MachineV2Hub
  private let key: SymmetricKey?
  private let failure: OperationError?
  /// How a group's operations reach machines: through the hub, unless a test hands its own fetch.
  private let fetch: (@Sendable (GroupID) -> FetchClient)?
  /// Where a group's operations are kept: the space's store, unless a test hands its own.
  private let stores: (@Sendable (GroupID) async throws -> any OperationStore)?
  private let tunnel: TunnelLanes
  private var groups: [GroupID: MachineOperations] = [:]
  /// Groups whose live operations are not resumed yet, nil while that is not known: their operations are refused until then.
  private var unrecovered: Set<GroupID>? = []
  /// One presence loop per member machine, under the group it is a member of.
  private var presence: [String: (group: GroupID, task: Task<Void, Never>)] = [:]
  private var closed = false
  var closing: Bool { closed }

  init(
    space: Space, hub: MachineV2Hub, key: SymmetricKey?, failure: OperationError?,
    fetch: (@Sendable (GroupID) -> FetchClient)? = nil,
    stores: (@Sendable (GroupID) async throws -> any OperationStore)? = nil,
  ) {
    self.space = space; self.hub = hub; self.key = key; self.failure = failure; self.fetch = fetch; self.stores = stores
    tunnel = TunnelLanes { machine in await hub.streams(machine) }
  }

  /// Loads the durable key and resumes every live operation: an exec still live on
  /// its record waits for its caller again from where the store holds it; anything else is abandoned, nobody is left to read it.
  static func open(space: Space, hub: MachineV2Hub, directory: URL) async -> MachineV2Service {
    let key: SymmetricKey
    do { key = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: space) } catch {
      let failure = unavailable(error)
      await hub.fail(failure)
      return .init(space: space, hub: hub, key: nil, failure: failure)
    }
    return await open(space: space, hub: hub, key: key)
  }

  /// `open` with a given key; `fetch` replaces the hub as the way to machines, `stores` the space as the operations' store. Only
  /// a key that fails fails the service; a group whose operations cannot be resumed yet is retried while the service runs.
  static func open(
    space: Space, hub: MachineV2Hub, key: SymmetricKey,
    fetch: (@Sendable (GroupID) -> FetchClient)? = nil,
    stores: (@Sendable (GroupID) async throws -> any OperationStore)? = nil,
  ) async -> MachineV2Service {
    do { try await space.validateMachineV2Key(key) } catch {
      let failure = unavailable(error)
      await hub.fail(failure)
      return .init(space: space, hub: hub, key: nil, failure: failure)
    }
    let service = MachineV2Service(space: space, hub: hub, key: key, failure: nil, fetch: fetch, stores: stores)
    await service.boot()
    return service
  }

  private func boot() async {
    unrecovered = nil
    await recover()
  }

  /// Resumes the live operations of every group not resumed yet. A group that fails stays unresumed for the next attempt; the
  /// others go on.
  private func recover() async {
    let pending: Set<GroupID>
    if let unrecovered { pending = unrecovered } else {
      do { pending = try await space.machineV2RecoveryGroups() } catch { return }
    }
    var left = pending
    for group in pending {
      do { try await resume(group); left.remove(group) } catch {}
    }
    unrecovered = left
  }

  private func keepRecovering() async {
    @Dependency(\.continuousClock) var clock
    var delay = Duration.seconds(1)
    while unrecovered != [], !closed {
      do { try await clock.sleep(for: delay) } catch { return }
      await recover()
      delay = min(delay * 2, .seconds(30))
    }
  }

  /// Resumes the group's live operations: an exec still live on its record waits for its holder again from where the store
  /// holds it; anything else is abandoned, nobody is left to read it. Repeating it after a failure resumes each once. The
  /// store being unavailable fails the group, to be retried; any other failure is one record's: that record is set aside, and
  /// its exec ends with an unknown outcome.
  private func resume(_ group: GroupID) async throws {
    let operations = try await operations(group: group, recovering: true)
    for resumed in try await operations.resume() {
      switch resumed {
      case let .setAside(owner, _):
        try await conclude(owner)
      case let .live(operation):
        do { try await resume(operation) } catch let error as OperationError where error.code != .storeUnavailable {
          try await operations.setAside(operation)
          try await conclude(operation.owner)
        }
      }
    }
  }

  /// Ends the exec a set-aside operation ran, if it is still live: its outcome is unknown.
  private func conclude(_ owner: OperationOwner) async throws {
    guard let exec = Self.execID(owner), try await space.execRecord(exec)?.terminal == nil else { return }
    try await space.finishExec(exec, .machineLost)
  }

  private func resume(_ operation: OperationClient.Operation) async throws {
    @Dependency(\.date) var date
    let space = space
    guard let exec = Self.execID(operation.owner), let record = try await space.execRecord(exec), record.terminal == nil else {
      try await operation.abandon("callerGone")
      return
    }
    guard execEndpoints[exec.rawValue] == nil else { return }
    let current = await operation.record
    guard let stored = current.consumer else {
      // Started by a server from before execs kept their relay state: there is no compatible way to resume it. It ends, and
      // its record says its outcome is unknown, which is what its caller is told when it comes back.
      try await operation.abandon(Self.serverUpgraded)
      try await space.finishExec(exec, .machineLost)
      return
    }
    guard let state = try? ExecRelayState(stored) else { throw OperationError(.invalidInput, message: "Exec relay state does not decode", operation: operation.id) }
    let output = ["stdout", "stderr"].reduce(0) { $0 + Int(current.consumed[$1]?.rawValue ?? 0) }
    let stdin = Int(current.accepted["stdin"]?.rawValue ?? 0) + (current.pendingInputs["stdin"]?.payload.count ?? 0)
    var entry = ExecEndpoint(endpoint: ChannelEndpoint(incomingResume: .init(output: output, stdin: stdin)), starter: ExecStarter(owner: state.holder))
    entry.operation = operation
    entry.disconnected = date.now
    execEndpoints[exec.rawValue] = entry
    let relay = MachineV2ExecRelay(
      record: record, endpoint: entry.endpoint, starter: entry.starter, space: space, tokens: nil, secrets: nil,
      resumed: .init(operation: operation, state: state),
    )
    relays.continuation.yield(.caller(relay))
  }

  /// Whether the group's live operations are resumed, so a caller may reach them.
  func recovered(_ group: GroupID) -> Bool {
    unrecovered.map { !$0.contains(group) } ?? false
  }

  static func execID(_ owner: OperationOwner) -> ExecID? {
    owner.scope == "exec/" + owner.key ? ExecID(rawValue: owner.key) : nil
  }

  /// The group's operations, created on first use; refused while the group's live operations are not resumed.
  func operations(group: GroupID) async throws -> MachineOperations {
    try await operations(group: group, recovering: false)
  }

  private func operations(group: GroupID, recovering: Bool) async throws -> MachineOperations {
    if let failure { throw failure }
    guard let key, !closed else { throw OperationError(.requestCancelled) }
    guard recovering || recovered(group) else { throw OperationError(.storeUnavailable, message: "Machine v2 is still resuming the group's operations") }
    if let operations = groups[group] { return operations }
    let store: any OperationStore
    if let stores { store = try await stores(group) } else { store = try await space.machineV2Store(group: group, key: key, problemsGroup: Self.problemsGroup) }
    let trace = try await space.machineV2TraceSink(group: group, problemsGroup: Self.problemsGroup)
    if let operations = groups[group] { return operations }
    let hub = hub
    let operations = try MachineOperations(
      origin: Self.origin,
      fetch: fetch?(group) ?? FetchClient { request in try await hub.fetch(request, usableFrom: group) },
      store: store,
      trace: trace,
      tunnel: tunnel,
    )
    groups[group] = operations
    return operations
  }

  func credential(tokens: ExecTokens, session: SessionID, group: GroupID, owner: OperationOwner, timeout: Duration) async throws -> JSONValue {
    let operations = try await operations(group: group)
    let previouslyIssued = try await operations.lookup(owner)?.start.input.object?["sessionCredential"] != nil
    @Dependency(\.date) var date
    return try tokens.credential(session: session, group: group, scope: owner.scope, key: owner.key, timeout: timeout, now: date.now, previouslyIssued: previouslyIssued, reserveAttempt: true, active: {
      try await Self.runs(owner, in: operations)
    })
  }

  /// Whether the exec a v2 credential was issued for still runs: what a
  /// credential restored from the main before this one checks.
  nonisolated func credentialActive(group: GroupID, owner: OperationOwner) -> @Sendable () async throws -> Bool {
    { try await Self.runs(owner, in: self.operations(group: group)) }
  }

  private static func runs(_ owner: OperationOwner, in operations: MachineOperations) async throws -> Bool {
    guard let record = try await operations.lookup(owner) else { return false }
    return record.start.kind == "exec.v1" && record.live && record.snapshot?.verdict == nil && record.stopReason == nil
  }

  func run() async throws {
    guard key != nil else { return }
    // Recovery ends once every group is resumed; the service ends when either of the others does.
    await withTaskGroup(of: Bool.self) { tasks in
      tasks.addTask { await self.keepRecovering(); return false }
      tasks.addTask { await self.watchMembers(); return true }
      tasks.addTask {
        await withDiscardingTaskGroup { relays in
          for await job in self.relays.stream {
            relays.addTask {
              switch job {
              case let .caller(relay): await self.serveExec(relay)
              case let .minted(record, space): await self.expireUnconnected(record, space: space)
              }
            }
          }
          relays.cancelAll()
        }
        return true
      }
      while let ended = await tasks.next(), !ended {}
      tasks.cancelAll()
    }
  }

  func shutdown() async {
    closed = true
    relays.continuation.finish()
    for watched in presence.values { watched.task.cancel() }
    presence = [:]
    let current = Array(groups.values)
    for operations in current { await operations.shutdown() }
    await presenceScope.close()
  }

  private static func unavailable(_ error: any Error) -> OperationError {
    if let error = error as? OperationError { return error }
    return OperationError(.storeUnavailable, message: "Machine v2 durable state is unavailable")
  }

  // MARK: Presence

  /// Keeps one presence loop per member machine; a machine that left a group's membership loses that group's loop and cached
  /// description, and one that moved is watched under its new group.
  private func watchMembers() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled, !closed {
      do {
        var members: [String: GroupID] = [:]
        for group in try await space.groups() where group.removedAt == nil {
          for machine in try await space.machineV2Members(group: group.id) { members[machine] = group.id }
        }
        for (machine, watched) in presence where members[machine] != watched.group {
          watched.task.cancel()
          presence[machine] = nil
          await groups[watched.group]?.forget(machine)
        }
        for (machine, group) in members where presence[machine] == nil {
          let detached = try await space.machineV2DetachedMembers(group: group).contains(machine)
          if let task = try? presenceScope.run("machine-presence", operation: { await self.watch(machine, group: group, detached: detached) }) {
            presence[machine] = (group, task)
          }
        }
      } catch {}
      try? await clock.sleep(for: .seconds(1))
    }
    for watched in presence.values { watched.task.cancel() }
  }

  /// Describes the machine every third of its lease and records what that says about its presence. Every failure is this
  /// machine's alone: the loop retries, and only the presence evidence changes.
  private func watch(_ machine: String, group: GroupID, detached: Bool) async {
    @Dependency(\.continuousClock) var clock
    await watch(machine, group: group, detached: detached, clock: clock)
  }

  private func watch(_ machine: String, group: GroupID, detached initiallyDetached: Bool, clock: some Clock<Duration>) async {
    var detached = initiallyDetached
    var leaveFailed = false
    var lastAnswer = clock.now
    var lease = Duration.seconds(60)
    while !Task.isCancelled {
      do {
        let operations = try await operations(group: group)
        do {
          let description = try await operations.describe(machine)
          lastAnswer = clock.now
          lease = .milliseconds(description.limits.leaseMs)
          if detached, !description.acceptingStarts {
          } else if leaveFailed, !description.acceptingStarts {
            try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaveHandshakeFailed")
          } else {
            leaveFailed = false; detached = false
            try await space.recordMachineV2Presence(machine, group: group, state: .attached, description: description)
          }
        } catch let error as OperationError where error.code == .leaving {
          do {
            try await operations.acknowledgeLeave(machine)
            leaveFailed = false; detached = true
            try await space.recordMachineV2Presence(machine, group: group, state: .detached, reason: "leaving")
          } catch let failure as OperationError where failure.code != .storeUnavailable {
            leaveFailed = true
            try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaveHandshakeFailed")
          }
        } catch let error as OperationError where Self.transient(error) {
          if !detached, lastAnswer.duration(to: clock.now) >= lease {
            try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: "leaseSilence")
          }
        } catch let error as OperationError {
          try await space.recordMachineV2Presence(machine, group: group, state: .lost, reason: error.code.rawValue)
        }
      } catch is CancellationError { return }
      catch {}
      try? await clock.sleep(for: lease / 3)
    }
  }

  private static func transient(_ error: OperationError) -> Bool {
    [.transport, .requestDeadline, .requestCancelled, .capacityExceeded, .machineUnavailable, .supervisorUnavailable].contains(error.code)
  }
}
