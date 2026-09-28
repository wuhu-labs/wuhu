import MachineChannel
import MachineContract
import Testing

@Suite(.timeLimit(.minutes(2)))
struct IsolationTests {
  @Test func stuckConsumerAndSpewingStreamLeaveControlAndOtherStreamsResponsive() async throws {
    let caller = ChannelEndpoint()
    let machine = ChannelEndpoint()
    let (callerSide, machineSide) = InMemoryTransport.pair()
    let tap = TapTransport(machineSide)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await caller.run(callerSide) }
      group.addTask { await machine.run(tap) }
      group.addTask {
        await withTaskGroup(of: Void.self) { inner in
          for await exec in machine.incomingExecs {
            inner.addTask {
              if exec.start.command == ["spew"] {
                // Spews far past the window into a consumer that never reads.
                try? await exec.send(.stdout, Array(repeating: 0xAB, count: 4096))
                await exec.exit(.exited(code: 0))
              } else {
                var collected: [UInt8] = []
                do {
                  for try await chunk in exec.stdin {
                    collected += chunk
                  }
                  try await exec.send(.stdout, collected)
                  await exec.exit(.exited(code: 0))
                } catch {}
              }
            }
          }
        }
      }
      group.addTask { await serveRequestsOK(machine) }

      let spew = await caller.startExec(makeStart(execID(1), command: ["spew"], window: 32))
      // Never consume spew.events; wait until the spewing producer is stalled
      // at exactly its window.
      while tap.outputBytes() < 32 {
        await Task.yield()
      }
      #expect(tap.outputBytes() == 32)

      let echo = await caller.startExec(makeStart(execID(2)))
      try await echo.sendStdin([9, 8, 7])
      await echo.closeStdin()
      let collected = try await collect(echo)
      #expect(collected.stdout == [9, 8, 7])
      #expect(collected.exit == .exited(code: 0))

      let result = try await caller.vfs(.stat(path: "/"))
      #expect(result == .ok)
      _ = spew
      group.cancelAll()
    }
  }
}
