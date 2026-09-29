import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import Scratch
import Serve
import SpaceCore
import SpaceServer
import Testing

@Suite struct MachineExecTests {
  @Test func execEchoEndToEndByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      host.attach(try await connectCaller(server, exec: exec))

      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
      let payload = Array("machine domain m4\n".utf8)
      try await outgoing.sendStdin(payload)
      await outgoing.closeStdin()
      let collected = try await collectExec(outgoing)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))

      let record = try #require(try await space.execRecord(exec))
      #expect(record.terminal == .exited(code: 0))
      #expect(record.command == "cat")
    }
  }

  @Test func callerBlipResumesByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)

      let first = try await connectCaller(server, exec: exec)
      host.attach(first)
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
      let head = Array("first half|".utf8)
      try await outgoing.sendStdin(head)

      first.close()
      host.attach(try await connectCaller(server, exec: exec))

      let tail = Array("second half".utf8)
      try await outgoing.sendStdin(tail)
      await outgoing.closeStdin()

      let collected = try await collectExec(outgoing)
      #expect(collected.stdout == head + tail)
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func machineBlipResumesByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      host.attach(try await connectCaller(server, exec: exec))

      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
      let head = Array("before blip|".utf8)
      try await outgoing.sendStdin(head)

      machineSocket.close()
      dialer.offer(try await connectMachine(server, key: key))

      let tail = Array("after blip".utf8)
      try await outgoing.sendStdin(tail)
      await outgoing.closeStdin()

      let collected = try await collectExec(outgoing)
      #expect(collected.stdout == head + tail)
      #expect(collected.exit == .exited(code: 0))
    }
  }

  // Window-pressure shape: fill the flow-control window until the machine's
  // sender blocks, sever only the caller leg, and consume part of the buffered
  // output while unbound so those acks are lost with the leg. The rebind's
  // announce-ack then wakes the blocked sender, whose fresh chunk races the
  // hello-triggered replay; the stream must still assemble byte-exact.
  @Test(.timeLimit(.minutes(2)))
  func callerBlipUnderWindowPressureResumesByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      let counter = OutputByteCounter()
      let first = try await connectCaller(server, exec: exec)
      host.attach(CountingTransport(WebSocketTransport(first), counter: counter) as any FrameTransport)

      let window = 65536
      let payload = patternBytes(3 * window)
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"], window: window))

      try await withThrowingTaskGroup(of: Void.self) { feed in
        feed.addTask {
          try await outgoing.sendStdin(payload)
          await outgoing.closeStdin()
        }

        #expect(try await realPollUntil { counter.value >= window })
        first.close()
        #expect(try await realPollUntil { host.completedRounds >= 1 })

        // One event may carry the whole window when the agent's pipe reads are
        // large (Linux), so partial consumption is best-effort — the shape
        // only needs some lost acks, which any consumption here guarantees.
        var iterator = outgoing.events.makeAsyncIterator()
        var stdout = try await consumeOutput(&iterator, atLeast: window / 4)
        #expect(!stdout.isEmpty)

        host.attach(try await connectCaller(server, exec: exec))
        let (rest, exit) = try await drainToExit(&iterator)
        stdout += rest
        #expect(stdout == payload)
        #expect(exit == .exited(code: 0))
        try await feed.waitForAll()
      }
      let record = try #require(try await space.execRecord(exec))
      #expect(record.terminal == .exited(code: 0))
    }
  }

  // The report's Bug 1 shape: both legs severed at once under window pressure,
  // caller reconnects first (the natural ordering — the CLI backoff is tighter
  // than the agent's). The hub must keep the caller mapped so the machine's
  // bind-time replay reaches it; otherwise the exec ack-starves as a registry
  // zombie.
  @Test(.timeLimit(.minutes(2)))
  func doubleSeverCallerFirstReconnectResumesByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      let counter = OutputByteCounter()
      let first = try await connectCaller(server, exec: exec)
      host.attach(CountingTransport(WebSocketTransport(first), counter: counter) as any FrameTransport)

      let window = 65536
      let payload = patternBytes(3 * window)
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"], window: window))

      try await withThrowingTaskGroup(of: Void.self) { feed in
        feed.addTask {
          try await outgoing.sendStdin(payload)
          await outgoing.closeStdin()
        }

        #expect(try await realPollUntil { counter.value >= window })
        machineSocket.close()
        first.close()
        #expect(try await realPollUntil { host.completedRounds >= 1 })

        // Drain everything already delivered while unbound: the acks are lost
        // with the leg, so after the reconnects only the machine's bind-time
        // replay (and its dedup acks) can free the blocked sender.
        var iterator = outgoing.events.makeAsyncIterator()
        var stdout = try await consumeOutput(&iterator, atLeast: window)
        #expect(stdout.count == window)

        host.attach(try await connectCaller(server, exec: exec))
        // Let the caller's rebind handshake drain into the hub while the
        // machine leg is still absent; the assertions hold in either ordering.
        for _ in 0 ..< 200 {
          await Task.yield()
        }
        dialer.offer(try await connectMachine(server, key: key))

        let (rest, exit) = try await drainToExit(&iterator)
        stdout += rest
        #expect(stdout == payload)
        #expect(exit == .exited(code: 0))
        try await feed.waitForAll()
      }
      let record = try #require(try await space.execRecord(exec))
      #expect(record.terminal == .exited(code: 0))
    }
  }

  // The double-sever heal must not depend on reconnect order: here the machine
  // rebinds first, its bind-time replay lands with no caller bound, and the
  // caller's later hello re-triggers the replay.
  @Test(.timeLimit(.minutes(2)))
  func doubleSeverMachineFirstReconnectResumesByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      let counter = OutputByteCounter()
      let first = try await connectCaller(server, exec: exec)
      host.attach(CountingTransport(WebSocketTransport(first), counter: counter) as any FrameTransport)

      let window = 65536
      let payload = patternBytes(3 * window)
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"], window: window))

      try await withThrowingTaskGroup(of: Void.self) { feed in
        feed.addTask {
          try await outgoing.sendStdin(payload)
          await outgoing.closeStdin()
        }

        #expect(try await realPollUntil { counter.value >= window })
        machineSocket.close()
        first.close()
        #expect(try await realPollUntil { host.completedRounds >= 1 })

        var iterator = outgoing.events.makeAsyncIterator()
        var stdout = try await consumeOutput(&iterator, atLeast: window)
        #expect(stdout.count == window)

        dialer.offer(try await connectMachine(server, key: key))
        #expect(try await realPollUntil { await server.hub.attachedMachines().contains(machine) })
        host.attach(try await connectCaller(server, exec: exec))

        let (rest, exit) = try await drainToExit(&iterator)
        stdout += rest
        #expect(stdout == payload)
        #expect(exit == .exited(code: 0))
        try await feed.waitForAll()
      }
      let record = try #require(try await space.execRecord(exec))
      #expect(record.terminal == .exited(code: 0))
    }
  }

  // Ruling 10's zombie shape: kill lands while both legs are down and the
  // machine sender sits window-blocked. The registry records cancelled at
  // once, the kill delivers on the machine's next connect, and the real exit
  // still settles the row through the healed relay.
  @Test(.timeLimit(.minutes(2)))
  func killDuringDoubleSeverWedgeSettlesTheRegistry() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      let machineSocket = try await connectMachine(server, key: key)
      dialer.offer(machineSocket)
      let exec = try await mintExec(server, machine: machine)
      let counter = OutputByteCounter()
      let first = try await connectCaller(server, exec: exec)
      host.attach(CountingTransport(WebSocketTransport(first), counter: counter) as any FrameTransport)

      let window = 65536
      let payload = patternBytes(3 * window)
      // No closeStdin: cat stays alive so only the kill can end it.
      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"], window: window))

      try await withThrowingTaskGroup(of: Void.self) { feed in
        feed.addTask {
          try? await outgoing.sendStdin(payload)
        }

        #expect(try await realPollUntil { counter.value >= window })
        machineSocket.close()
        first.close()
        #expect(try await realPollUntil { host.completedRounds >= 1 })
        #expect(try await realPollUntil { await !server.hub.attachedMachines().contains(machine) })

        #expect(try await server.http(.post, "/v1/exec/\(exec.rawValue)/kill").status == .ok)
        #expect(try await space.execRecord(exec)?.terminal == .cancelled)
        #expect(try await server.http(.get, "/v1/exec").json([ExecStatus].self).isEmpty)

        host.attach(try await connectCaller(server, exec: exec))
        dialer.offer(try await connectMachine(server, key: key))

        var iterator = outgoing.events.makeAsyncIterator()
        let (stdout, exit) = try await drainToExit(&iterator)
        guard case .signaled = exit else {
          Issue.record("kill must surface as a signal exit, got \(String(describing: exit))")
          feed.cancelAll()
          return
        }
        #expect(payload.starts(with: stdout))
        feed.cancelAll()
      }
      let settled = try await realPollUntil {
        if case .signaled = try await space.execRecord(exec)?.terminal { return true }
        return false
      }
      #expect(settled)
      #expect(try await server.http(.get, "/v1/exec").json([ExecStatus].self).isEmpty)
    }
  }

  @Test func serverRestartResumesFromTheSameRegistry() async throws {
    let scratch = try ScratchFolder("m4-restart")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    let space = try makeMachineSpace(file: file)
    let state = try ScratchFolder("m4-agent")
    defer { state.remove() }
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()
    let host = EndpointHost()

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run(dial: dialer.dial) }
      group.addTask { await host.run() }
      group.addTask {
        let first = TestServer(space: space, clock: ContinuousClock())
        let firstRun = Task { await first.run() }
        let (machine, key) = try await addMachine(first)
        let firstMachineSocket = try await connectMachine(first, key: key)
        dialer.offer(firstMachineSocket)
        let exec = try await mintExec(first, machine: machine)
        let firstCallerSocket = try await connectCaller(first, exec: exec)
        host.attach(firstCallerSocket)

        let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
        let head = Array("pre-restart|".utf8)
        try await outgoing.sendStdin(head)

        // The restart: the old incarnation dies with every leg it held; the
        // fresh one knows only what the registry rows carry.
        firstMachineSocket.close()
        firstCallerSocket.close()
        firstRun.cancel()

        let second = TestServer(space: space, clock: ContinuousClock())
        let secondRun = Task { await second.run() }
        dialer.offer(try await connectMachine(second, key: key))
        host.attach(try await connectCaller(second, exec: exec))

        let tail = Array("post-restart".utf8)
        try await outgoing.sendStdin(tail)
        await outgoing.closeStdin()

        let collected = try await collectExec(outgoing)
        #expect(collected.stdout == head + tail)
        #expect(collected.exit == .exited(code: 0))
        secondRun.cancel()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func terminalExecStillDrainsTheRetainedTailByteExact() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      let first = try await connectCaller(server, exec: exec)
      host.attach(first)

      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
      let payload = Array("finishes while the caller is away".utf8)
      try await outgoing.sendStdin(payload)
      await outgoing.closeStdin()

      // The exit settles the registry as it relays, independent of the caller
      // consuming its events; the blip then lands between exit and drain.
      let finished = try await realPollUntil {
        try await space.execRecord(exec)?.terminal == .exited(code: 0)
      }
      #expect(finished)
      first.close()

      host.attach(try await connectCaller(server, exec: exec))
      let collected = try await collectExec(outgoing)
      #expect(collected.stdout == payload)
      #expect(collected.exit == .exited(code: 0))
    }
  }

  @Test func psListsLiveExecAndKillKillsIt() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await runScenario(server: server) { dialer, host in
      dialer.offer(try await connectMachine(server, key: key))
      let exec = try await mintExec(server, machine: machine)
      host.attach(try await connectCaller(server, exec: exec))

      let outgoing = await host.endpoint.startExec(makeExecStart(exec, command: ["cat"]))
      _ = try await realPollUntil {
        let listed = try await server.http(.get, "/v1/exec").json([ExecStatus].self)
        return listed.contains { $0.id == exec && $0.command == "cat" }
      }
      let listed = try await server.http(.get, "/v1/exec").json([ExecStatus].self)
      #expect(listed.map(\.id) == [exec])
      #expect(listed.first?.machine == machine)

      #expect(try await server.http(.post, "/v1/exec/\(exec.rawValue)/kill").status == .ok)
      let collected = try await collectExec(outgoing)
      guard case .signaled = collected.exit else {
        Issue.record("kill must surface as a signal exit, got \(String(describing: collected.exit))")
        return
      }
      _ = try await realPollUntil {
        try await server.http(.get, "/v1/exec").json([ExecStatus].self).isEmpty
      }
      #expect(try await server.http(.get, "/v1/exec").json([ExecStatus].self).isEmpty)
      let status = try await server.http(.get, "/v1/exec/\(exec.rawValue)").json(ExecStatus.self)
      guard case .signaled = status.state else {
        Issue.record("per-id status must expose the terminal state, got \(status.state)")
        return
      }
      #expect(try await server.http(.get, "/v1/exec/ex_zzzzzzzz").status == .notFound)
      #expect(try await server.http(.post, "/v1/exec/ex_zzzzzzzz/kill").status == .notFound)
    }
  }
}

func makeExecStart(_ id: ExecID, command: [String], window: Int? = nil) -> ExecStart {
  ExecStart(id: id, cwd: "/", command: command, env: nil, secrets: nil, window: window, maxOutput: nil, timeout: nil)
}

func runScenario(
  server: TestServer,
  killGrace: Duration = .milliseconds(300),
  _ body: @escaping @Sendable (AgentDialer, EndpointHost) async throws -> Void,
) async throws {
  let state = try ScratchFolder("m4-agent")
  defer { state.remove() }
  let agent = makeAgent(state: state, killGrace: killGrace)
  let dialer = AgentDialer()
  let host = EndpointHost()
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await server.run() }
    group.addTask { await agent.run(dial: dialer.dial) }
    group.addTask { await host.run() }
    group.addTask { try await body(dialer, host) }
    _ = try await group.next()
    group.cancelAll()
  }
}
