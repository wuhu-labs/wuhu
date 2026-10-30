import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ExecSupervisor
import Fetch
import MachineChannel
import MachineContract
import OperationRuntime
import Scratch
import Serve
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct GroupSecretExecTests {
  @Test func twoMachinesInOneGroupUseOneSecretMasked() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let first = try await rig.addMachine("first")
      let second = try await rig.addMachine("second")
      try await rig.run(machines: [first, second]) {
        for machine in [first, second] {
          let collected = try await rig.exec(on: machine, command: [
            "sh", "-c", #"test "$TOKEN" = hunter2-value && printf 'token=%s\n' "$TOKEN""#,
          ])
          #expect(String(decoding: collected.stdout, as: UTF8.self) == "token=***\n")
          #expect(collected.exit == .exited(code: 0))
        }
      }
    }
  }

  @Test func aMachineOfAnotherGroupFailsBeforeAnythingSpawns() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let team = try await rig.addGroup("team")
      let machine = try await rig.addMachine("teambox")
      _ = try await rig.space.moveMachine(machine.id, to: team)
      let marker = rig.scratch.url.appendingPathComponent("spawned")
      try await rig.run(machines: [machine]) {
        let collected = try await rig.exec(on: machine, command: ["touch", marker.path])
        #expect(String(decoding: collected.stderr, as: UTF8.self) == "invalidInput: Secret API_KEY unavailable in group team\n")
        #expect(collected.exit == .exited(code: 1))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let record = try #require(try await rig.space.execRecord(collected.id))
        #expect(record.terminal == .exited(code: 1))
      }
    }
  }

  @Test func aMovedMachineTakesItsNewGroupsSecrets() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "shared-value")
      let team = try await rig.addGroup("team")
      let machine = try await rig.addMachine("mover")
      let echo = ["sh", "-c", #"printf '%s\n' "$TOKEN" | tr a-z A-Z"#]
      try await rig.run(machines: [machine]) {
        let before = try await rig.exec(on: machine, command: echo)
        #expect(String(decoding: before.stdout, as: UTF8.self) == "SHARED-VALUE\n")

        _ = try await rig.space.moveMachine(machine.id, to: team)
        let missing = try await rig.exec(on: machine, command: echo)
        #expect(String(decoding: missing.stderr, as: UTF8.self) == "invalidInput: Secret API_KEY unavailable in group team\n")
        #expect(missing.exit == .exited(code: 1))

        try await rig.stores.group("team").set("API_KEY", to: "team-value")
        let after = try await rig.exec(on: machine, command: echo)
        #expect(String(decoding: after.stdout, as: UTF8.self) == "TEAM-VALUE\n")
      }
    }
  }

  @Test func aRunningExecKeepsItsSecretsAcrossAMoveAndABlip() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let team = try await rig.addGroup("team")
      let machine = try await rig.addMachine("builder")
      let host = EndpointHost()
      try await rig.run(machines: [machine]) {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await host.run() }
          let exec = try await mintExec(rig.server, machine: machine.id)
          let caller = try await connectCaller(rig.server, exec: exec)
          host.attach(caller)
          let outgoing = await host.endpoint.startExec(rig.start(exec, command: [
            "sh", "-c", #"printf 'ready\n'; read line; printf '%s %s\n' "$line" "$TOKEN""#,
          ]))
          var events = outgoing.events.makeAsyncIterator()
          let ready = try await mixedExecOutput(&events, atLeast: 6)
          #expect(ready == Array("ready\n".utf8))

          _ = try await rig.space.moveMachine(machine.id, to: team)
          caller.close()
          #expect(try await realPollUntil { host.completedRounds >= 1 })
          host.attach(try await connectCaller(rig.server, exec: exec))

          try await outgoing.sendStdin(Array("go\n".utf8))
          await outgoing.closeStdin()
          let (rest, exit) = try await mixedExecExit(&events)
          #expect(String(decoding: rest, as: UTF8.self) == "go ***\n")
          #expect(exit == .exited(code: 0))
          let record = try await rig.space.execRecord(exec)
          #expect(record?.terminal == .exited(code: 0))
          group.cancelAll()
        }
      }
    }
  }
}

struct SecretRig: Sendable {
  let server: TestServer
  let stores: SpaceSecretStores
  let scratch: ScratchFolder

  var space: Space {
    server.space
  }

  struct Machine: Sendable {
    let id: MachineID
  }

  func addMachine(_ name: String) async throws -> Machine {
    let (machine, _) = try await space.addMachineV2(name: name, group: .shared, scope: .reachable)
    return Machine(id: machine.id)
  }

  func addGroup(_ name: String) async throws -> GroupID {
    let group = GroupID(rawValue: name)
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2030-01-01T00:00:00.000Z')", arguments: [name])
    }
    try await space.setGrant(.group, GroupID.shared.rawValue, role: .write, in: group, by: .anonymous, acting: group)
    return group
  }

  func start(_ id: ExecID, command: [String]) -> ExecStart {
    ExecStart(id: id, cwd: "/", command: command, env: nil, secrets: ["TOKEN": "API_KEY"], window: nil, maxOutput: nil, timeout: nil)
  }

  func exec(on machine: Machine, command: [String]) async throws -> (id: ExecID, stdout: [UInt8], stderr: [UInt8], exit: MachineContract.ExitStatus?) {
    let id = try await mintExec(server, machine: machine.id)
    let host = EndpointHost()
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await host.run() }
      host.attach(try await connectCaller(server, exec: id))
      let outgoing = await host.endpoint.startExec(start(id, command: command))
      await outgoing.closeStdin()
      let collected = try await collectExec(outgoing)
      group.cancelAll()
      return (id, collected.stdout, collected.stderr, collected.exit)
    }
  }

  func run(machines: [Machine], _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withMixedExecAgents(server, machines: machines.map(\.id)) { _ in try await body() }
  }
}

func withSecretServer(_ body: (SecretRig) async throws -> Void) async throws {
  let scratch = try ScratchFolder("group-secrets")
  defer { scratch.remove() }
  let stores = SpaceSecretStores(configDirectory: scratch.url.appendingPathComponent("config", isDirectory: true), spaceID: "spc_test")
  let space = try makeMachineSpace()
  let server = TestServer(space: space, clock: ContinuousClock(), secrets: stores)
  try await body(SecretRig(server: server, stores: stores, scratch: scratch))
}

func withMixedExecAgents(
  _ server: TestServer, machines: [MachineID],
  _ body: @escaping @Sendable (MachineV2Service) async throws -> Void,
) async throws {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
  } operation: {
    let agents = try Dictionary(uniqueKeysWithValues: machines.map { machine in
      (machine.rawValue, try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in }))
    })
    let service = MachineV2Service(space: server.space, hub: MachineV2Hub(space: server.space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      let parts = request.url.pathComponents
      let index = try #require(parts.firstIndex(of: "machines"))
      let agent = try #require(agents[parts[index + 1]])
      return try await agent.handler(request)
    } })
    await server.hub.configureV2(service)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await server.run() }
      tasks.addTask { try await service.run() }
      for agent in agents.values { tasks.addTask { await agent.run() } }
      defer { tasks.cancelAll() }
      do {
        try await body(service)
      } catch {
        for agent in agents.values { await agent.shutdown() }
        await service.shutdown()
        throw error
      }
      for agent in agents.values { await agent.shutdown() }
      await service.shutdown()
    }
  }
}

private enum ExecStreamFailure: Error {
  case machine(MachineError)
}

func mixedExecOutput(_ events: inout ExecEvents.Iterator, atLeast count: Int) async throws -> [UInt8] {
  var output: [UInt8] = []
  while output.count < count, let event = try await events.next() {
    switch event {
    case let .output(.stdout, _, bytes): output += bytes.bytes
    case let .failed(error): throw ExecStreamFailure.machine(error)
    case .exit: Issue.record("exec exited before its expected output"); return output
    default: break
    }
  }
  #expect(output.count >= count)
  return output
}

func mixedExecExit(_ events: inout ExecEvents.Iterator) async throws -> ([UInt8], MachineContract.ExitStatus?) {
  var output: [UInt8] = []
  while let event = try await events.next() {
    switch event {
    case let .output(.stdout, _, bytes): output += bytes.bytes
    case let .exit(status): return (output, status)
    case let .failed(error): throw ExecStreamFailure.machine(error)
    default: break
    }
  }
  return (output, nil)
}
