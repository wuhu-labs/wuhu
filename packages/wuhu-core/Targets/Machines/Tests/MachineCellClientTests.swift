import Clocks
import Dependencies
import DeterministicDependencies
@testable import Machines
import MachinesContract
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import MachinesTesting
import OperationProtocol
import Scratch
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineCellClientTests {
  @Test func reservationReadsKeepTheMachineCallerAndScriptIdentity() async throws {
    let space = try makeMachineSpace()
    let machine = try await space.machineFamily.addMachineV2(name: "box").machine.id
    let tool = try await space.machineFamily.reserveExec(machine: machine, caller: "caller", group: .shared, toolCall: .init("call"))
    #expect(tool.machine == machine)
    #expect(tool.caller == "caller")
    #expect(tool.toolCallID == .init("call"))
    #expect(try await space.machineFamily.execRecord(caller: "caller", toolCallID: .init("call")) == tool)
    #expect(try await space.machineFamily.liveToolExecs(caller: "caller") == [tool])
    let script = try await space.machineFamily.reserveExec(machine: machine, caller: "caller", group: .shared, script: "script")
    _ = try await space.machineFamily.reserveExec(machine: machine, caller: "other", group: .shared, script: "script")
    #expect(try await space.machineFamily.liveScriptExecs(script: "script", caller: "caller") == [script.id])
    try await space.worker.call(MachineCell.ID(machine.rawValue)) { try $0.stop(script.id.rawValue) }
    #expect(try await space.machineFamily.execRecord(script.id)?.terminal == .cancelled)
    #expect(try await space.machineFamily.liveScriptExecs(script: "script", caller: "caller").isEmpty)
    try await space.close()
  }

  @Test func presenceComesFromTheBoxAndRetainsItsLastAnswerAfterLossAndReopen() async throws {
    let now = Mutex(fixedDate)
    try await withDependencies {
      $0.date = .init { now.withLock { $0 } }
      $0.continuousClock = ContinuousClock()
    } operation: {
      let folder = try ScratchFolder("machine-presence")
      let url = folder.url.appending(path: "space.sqlite")
      let space = try Space.open(file: url).registeringMachines()
      let machine = try await space.machineFamily.addMachineV2(name: "box").machine.id
      let id = MachineCell.ID(machine.rawValue)
      let initial = try #require(try await space.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared))
      #expect(initial.state == .lost)
      #expect(initial.reason == "neverAttached")
      #expect(initial.observedAt == fixedDate)
      let pubkey = try await space.addMachineTestKey(machine.rawValue)
      let (frames, continuation) = AsyncStream<BoxSocket.Outgoing>.makeStream()
      let peer = try #require(await space.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
        if case let .frame(frame) = $0 { continuation.yield(frame) }
      })
      var framesIterator = frames.makeAsyncIterator()
      let first = try #require(await framesIterator.next())
      #expect(first.tag == .describe)
      let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
      peer.send(.init(tag: .describe, answer: .description(description)))
      for _ in 0 ..< 1000 {
        if try await space.worker.call(id, { $0.presence.state }) == "attached" { break }
        await Task.yield()
      }
      let attached = try #require(try await space.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared))
      #expect(attached.state == .attached)
      #expect(attached.observedAt == fixedDate)
      #expect(attached.reason == nil)
      #expect(try await space.machineFamily.machineDescription(machine)?.instance == description.instance)
      #expect(try await space.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .init(rawValue: "other")) == nil)
      #expect(try await space.machineFamily.machineV2PresenceEvidence("missing", group: .shared) == nil)
      now.withLock { $0 += 60 }
      try await space.worker.call(id) { try $0.wake() }
      let lost = try #require(try await space.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared))
      #expect(lost.state == .lost)
      #expect(lost.observedAt == attached.observedAt)
      #expect(lost.reason == "leaseSilence")
      #expect(try await space.machineFamily.machineDescription(machine) == nil)
      now.withLock { $0 += 20 }
      try await space.worker.call(id) { try $0.wake() }
      #expect(try await space.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared)?.observedAt == attached.observedAt)
      peer.close()
      try await space.close()
      let reopened = try Space.open(file: url).registeringMachines()
      #expect(try await reopened.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared)?.state == .lost)
      #expect(try await reopened.machineFamily.machineV2PresenceEvidence(machine.rawValue, group: .shared)?.observedAt == attached.observedAt)
      try await reopened.close()
    }
  }
}
