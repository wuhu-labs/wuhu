import struct Credentials.SpaceSecretStores
import Crypto
import Foundation
import MachineChannel
import MachineContract
import Scratch
import Serve
import SpaceContract
@testable import SpaceCore
import SpaceServer
import Testing

// An exec's secrets resolve in the group of the machine it runs on, at the
// moment it starts; the caller's group plays no part.
@Suite struct GroupSecretExecTests {
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

  // The caller's group holds the name and reads the machine's group; the
  // machine's group does not hold it, so nothing spawns.
  @Test func aMachineOfAnotherGroupFailsBeforeAnythingSpawns() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let team = try await rig.addGroup("team")
      let machine = try await rig.addMachine("teambox")
      _ = try await rig.space.moveMachine(machine.id, to: team)
      let marker = rig.scratch.url.appendingPathComponent("spawned")
      try await rig.run(machines: [machine]) {
        let collected = try await rig.exec(on: machine, command: ["touch", marker.path])
        #expect(String(decoding: collected.stderr, as: UTF8.self) == "wuhu: no secret API_KEY in group team\n")
        #expect(collected.exit == .exited(code: 127))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let record = try #require(try await rig.space.execRecord(collected.id))
        #expect(record.terminal == .exited(code: 127))
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
        #expect(String(decoding: missing.stderr, as: UTF8.self) == "wuhu: no secret API_KEY in group team\n")
        #expect(missing.exit == .exited(code: 127))

        try await rig.stores.group("team").set("API_KEY", to: "team-value")
        let after = try await rig.exec(on: machine, command: echo)
        #expect(String(decoding: after.stdout, as: UTF8.self) == "TEAM-VALUE\n")
      }
    }
  }

  // A running exec keeps the values its first start carried: after its machine
  // moves and loses the secret, a blip of both legs makes the caller replay the
  // start, and the replay neither refuses nor re-resolves it.
  @Test func aRunningExecKeepsItsSecretsAcrossAMoveAndABlip() async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let team = try await rig.addGroup("team")
      let machine = try await rig.addMachine("builder")
      let state = try ScratchFolder("group-secret-blip")
      defer { state.remove() }
      let dialer = AgentDialer()
      let host = EndpointHost()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await rig.server.run() }
        group.addTask { await makeAgent(state: state).run(dial: dialer.dial) }
        group.addTask { await host.run() }
        let machineSocket = try await connectMachine(rig.server, key: machine.key)
        dialer.offer(machineSocket)
        try await awaitAttached(rig.server, machine.id)
        let exec = try await mintExec(rig.server, machine: machine.id)
        let caller = try await connectCaller(rig.server, exec: exec)
        host.attach(caller)
        let outgoing = await host.endpoint.startExec(rig.start(exec, command: [
          "sh", "-c", #"printf 'ready\n'; read line; printf '%s %s\n' "$line" "$TOKEN""#,
        ]))
        var events = outgoing.events.makeAsyncIterator()
        let ready = try await consumeOutput(&events, atLeast: 6)
        #expect(ready == Array("ready\n".utf8))

        _ = try await rig.space.moveMachine(machine.id, to: team)
        machineSocket.close()
        dialer.offer(try await connectMachine(rig.server, key: machine.key))
        caller.close()
        #expect(try await realPollUntil { host.completedRounds >= 1 })
        host.attach(try await connectCaller(rig.server, exec: exec))

        try await outgoing.sendStdin(Array("go\n".utf8))
        await outgoing.closeStdin()
        let (rest, exit) = try await drainToExit(&events)
        #expect(String(decoding: rest, as: UTF8.self) == "go ***\n")
        #expect(exit == .exited(code: 0))
        let record = try await rig.space.execRecord(exec)
        #expect(record?.terminal == .exited(code: 0))
        group.cancelAll()
      }
    }
  }

  // An agent that announced group-secrets gets values and no names; one from
  // before the header gets the names it resolves in its own vault, unchanged.
  @Test(arguments: [true, false])
  func theExecStartCarriesValuesOnlyToAnAgentThatAnnouncedGroupSecrets(announced: Bool) async throws {
    try await withSecretServer { rig in
      try await rig.stores.group("shared").set("API_KEY", to: "hunter2-value")
      let machine = try await rig.addMachine("raw")
      let host = EndpointHost()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await rig.server.run() }
        group.addTask { await host.run() }
        let socket = try await connectMachine(rig.server, key: machine.key, groupSecrets: announced)
        try await socket.send(.binary(FrameCodec.encode(
          Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1)),
        )))
        try await awaitAttached(rig.server, machine.id)
        let exec = try await mintExec(rig.server, machine: machine.id)
        host.attach(try await connectCaller(rig.server, exec: exec))
        _ = await host.endpoint.startExec(rig.start(exec, command: ["true"]))
        var relayed: ExecStart?
        for await message in socket.inbound {
          guard case let .binary(bytes) = message, let frame = try? FrameCodec.decode(bytes),
                frame.opcode == .execStart
          else { continue }
          relayed = try frame.payload(ExecStart.self)
          break
        }
        let start = try #require(relayed)
        if announced {
          #expect(start.secrets == nil)
          #expect(start.secretValues == ["TOKEN": "hunter2-value"])
        } else {
          #expect(start.secrets == ["TOKEN": "API_KEY"])
          #expect(start.secretValues == nil)
        }
        socket.close()
        group.cancelAll()
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
    let key: Curve25519.Signing.PrivateKey
  }

  func addMachine(_ name: String) async throws -> Machine {
    let response = try await server.http(.post, "/v1/machine", json: .object(["name": .string(name)]))
    #expect(response.status == .ok)
    let output = try await response.json(MachineAddOutput.self)
    return Machine(id: output.id, key: try await enrollMachineKey(server, token: output.token))
  }

  func addGroup(_ name: String) async throws -> GroupID {
    let group = GroupID(rawValue: name)
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2030-01-01T00:00:00.000Z')", arguments: [name])
    }
    try await space.addEdge(src: .shared, dst: group, kind: .read, by: nil)
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

  // Every machine runs a real agent of its own while `body` runs.
  func run(machines: [Machine], _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      for (index, machine) in machines.enumerated() {
        let state = try ScratchFolder("group-secret-agent-\(index)")
        let dialer = AgentDialer()
        group.addTask {
          defer { state.remove() }
          await makeAgent(state: state).run(dial: dialer.dial)
        }
        dialer.offer(try await connectMachine(server, key: machine.key))
        try await awaitAttached(server, machine.id)
      }
      group.addTask { try await body() }
      _ = try await group.next()
      group.cancelAll()
    }
  }
}

func withSecretServer(clock: any Clock<Duration> = ContinuousClock(), _ body: (SecretRig) async throws -> Void) async throws {
  let scratch = try ScratchFolder("group-secrets")
  defer { scratch.remove() }
  let stores = SpaceSecretStores(configDirectory: scratch.url.appendingPathComponent("config", isDirectory: true), spaceID: "spc_test")
  let space = try makeMachineSpace()
  let server = TestServer(space: space, clock: clock, secrets: stores)
  try await body(SecretRig(server: server, stores: stores, scratch: scratch))
}
