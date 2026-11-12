import struct Credentials.SpaceSecretStores
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ExecSupervisor
import Fetch
import GRDB
import MachineChannel
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
import Serve
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct GroupSecretExecTests {
  @Test func preparedSecretsAndCredentialsNeverEnterCellRowsOrMail() async throws {
    let scratch = try ScratchFolder("exec-cell-secrecy")
    defer { scratch.remove() }
    let stores = SpaceSecretStores(configDirectory: scratch.url.appendingPathComponent("config", isDirectory: true), spaceID: "spc_test")
    let secret = "cell-secret-value-not-an-argument"
    try await stores.group("shared").set("API_KEY", to: secret)
    let space = try makeMachineSpace()
    let tokens = try await testTokens(space: space, spaceURL: "https://space.test")
    let server = TestServer(space: space, clock: ContinuousClock(), tokens: tokens, secrets: stores)
    let (machine, _) = try await addMachine(server)
    let session = try await space.sessions.createSession(group: .shared, title: "secrecy", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
    let prepared = Mutex<StartRequest?>(nil)
    let started = Gate(), release = Gate()
    let client = FetchClient { request in
      var request = request
      if request.method == .post, request.url.path.contains("/operations/") {
        let start = try await request.json(StartRequest.self)
        prepared.withLock { $0 = start }
        started.open()
        await release.wait()
        request.body = try .json(start)
      }
      return try await agent.handler(request)
    }
    let exec = try await space.reserveExec(machine: machine, caller: session.rawValue)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: exec.id, cwd: "/", command: ["sh", "-c", "printf '%s|%s' \"$TOKEN\" \"$WUHU_TOKEN\""], secrets: ["TOKEN": "API_KEY"]))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { release.open(); tasks.cancelAll() }
      try await withMachineBox(space: space, hub: server.hub, machine: machine, client: client) {
        let transport = try await connectExecCaller(exec.id, space: space, hub: server.hub)
        let caller = Task { await endpoint.run(transport) }
        defer { caller.cancel() }
        await started.wait()
        let input = try #require(prepared.withLock { $0?.input.object })
        #expect(input["secretValues"]?.object?["TOKEN"] == .string(secret))
        let credential = try #require(input["sessionCredential"]?.object?["token"]?.stringValue)
        #expect(credential.hasPrefix(ExecTokens.prefix))
        #expect(input["secretValues"]?.object?["WUHU_ID_TOKEN_REQUEST"] == nil)
        #expect(input["env"]?.object?["WUHU_ID_TOKEN_URL"] == nil)
        let payloads = try await space.writer.read { db in
          try Row.fetchAll(db, sql: "SELECT * FROM machine_operations").flatMap { row in
            row.compactMap { _, value -> Data? in
              switch value.storage {
              case let .string(text): Data(text.utf8)
              case let .blob(data): data
              case .null, .int64, .double: nil
              }
            }
          } + Data.fetchAll(db, sql: "SELECT payload FROM wuwei_mail")
        }
        for value in [secret, credential] {
          #expect(!value.isEmpty)
          #expect(payloads.allSatisfy { $0.range(of: Data(value.utf8)) == nil })
        }
        release.open()
        let collected = try await collectExec(outgoing)
        #expect(String(decoding: collected.stdout, as: UTF8.self) == "***|***")
        #expect(collected.exit == .exited(code: 0))
      }
      await agent.shutdown()
    }
  }

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
        #expect(record.terminal == .machineLost)
        let operation = try #require(rig.space.worker.cell(MachineCell.ID(machine.id.rawValue)).operation(collected.id.rawValue))
        #expect(operation.diagnostic?.code == .invalidInput)
        #expect(operation.snapshot?.verdict?.result == nil)
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

  @Test func aRunningExecKeepsItsSecretsAcrossAMove() async throws {
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
    try await withMixedExecAgents(server, machines: machines.map(\.id)) { try await body() }
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
  _ body: @escaping @Sendable () async throws -> Void,
) async throws {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
  } operation: {
    let agents = try Dictionary(uniqueKeysWithValues: machines.map { machine in
      (machine.rawValue, try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in }))
    })
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await server.run() }
      var links: [BoxLink] = []
      for (id, agent) in agents {
        tasks.addTask { await agent.run() }
        let pubkey = try await seedBoxKey(space: server.space, machine: id)
        let link = try #require(BoxLink(worker: server.space.worker, machine: id, pubkey: pubkey, connection: UUID(), streams: 1024, buffers: server.space.machineBuffers) {
          try await server.hub.prepare($0, machine: id)
        })
        links.append(link)
        tasks.addTask { await link.run(client: FetchClient { try await agent.handler($0) }) }
      }
      defer { for link in links { link.close() } }
      for machine in machines { try #require(try await realPollUntil { try await server.space.machineDescription(machine) != nil }) }
      defer { tasks.cancelAll() }
      do {
        try await body()
      } catch {
        for agent in agents.values { await agent.shutdown() }
        throw error
      }
      for agent in agents.values { await agent.shutdown() }
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
