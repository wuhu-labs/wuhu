#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
import SessionTools
import Testing

@Suite struct ScriptMachineV2ClientContractTests {
  @Test func semanticFacetRecordsTypedEffectsWithoutConcreteClient() async throws {
    let id = UUID()
    let effects = Box<[String]>([])
    let snapshot = OperationSnapshot(operation: id, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)
    let payload = ChannelPayload(data: Data([1, 2, 3]))
    let facet = ScriptMachineV2Client(
      describe: { machine in
        effects.withLock { $0.append("describe:\(machine)") }
        return MachineDescription(instance: id, acceptingStarts: true, limits: .init(), kinds: [])
      },
      start: { machine, request, owner, timeout, claimed in
        #expect(machine == "disk" && request.kind == "exec.v1" && owner.scope == "script" && owner.key == "one")
        #expect(timeout == .seconds(10))
        effects.withLock { $0.append("start") }
        claimed(id)
        effects.withLock { $0.append("after-claim") }
        return id
      },
      reconcile: { operation, hold in
        #expect(operation == id && hold == 20000)
        effects.withLock { $0.append("reconcile") }
        return snapshot
      },
      poll: { operation, channel, hold, ack in
        #expect(operation == id && channel == "stdout" && hold == 20000 && ack)
        effects.withLock { $0.append("poll") }
        return snapshot
      },
      takeOutput: { operation, channel in
        #expect(operation == id && channel == "stdout")
        effects.withLock { $0.append("take") }
        return [payload]
      },
      write: { operation, channel, bytes, end in
        #expect(operation == id && channel == "stdin" && bytes == payload && end)
        effects.withLock { $0.append("write") }
        return .init(acceptedThrough: .init(rawValue: 3), end: true, blocked: false)
      },
      stop: { operation, reason in
        #expect(operation == id && reason == "scriptEnded")
        effects.withLock { $0.append("stop") }
        return snapshot
      },
    )
    #expect(try await facet.describe("disk").instance == id)
    let started = try await facet.start("disk", request: .init(kind: "exec.v1", input: [:]), owner: .init(scope: "script", key: "one"), timeout: .seconds(10), onClaim: { claimed in
      #expect(claimed == id)
      effects.withLock { $0.append("claimed") }
    })
    #expect(started == id)
    #expect(try await facet.reconcile(id, holdMs: 20000).operation == id)
    #expect(try await facet.poll(id, channel: "stdout", holdMs: 20000, terminalAck: true).operation == id)
    #expect(try await facet.takeOutput(id, channel: "stdout") == [payload])
    #expect(try await facet.write(id, channel: "stdin", payload: payload, end: true).acceptedThrough == .init(rawValue: 3))
    #expect(try await facet.stop(id, reason: "scriptEnded").operation == id)
    #expect(effects.value == ["describe:disk", "start", "claimed", "after-claim", "reconcile", "poll", "take", "write", "stop"])
  }
}
