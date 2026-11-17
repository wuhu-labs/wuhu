import Crypto
import DeterministicDependencies
@testable import Machines
import MachinesContract
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
import MachinesTesting
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineKeyAttachTests {
  @Test(arguments: ["revoked", "otherMachine", "missingMachine"])
  func refusedFirstAttachmentClosesWithoutDescribingOrPublishingPresence(reason: String) async throws {
    let space = try await MachineCellTestSpace.inMemory().registeringMachines()
    let machine = try await space.machineFamily.addMachineV2(name: "refused").machine.id.rawValue
    let pubkey = try await space.addMachineTestKey(machine)
    let target: String
    switch reason {
    case "revoked":
      _ = try await space.machineFamily.revokeMachine(MachineID(rawValue: machine))
      target = machine
    case "otherMachine": target = try await space.machineFamily.addMachineV2(name: "other").machine.id.rawValue
    case "missingMachine": target = "missing-machine"
    default: preconditionFailure()
    }
    let events = Mutex((frames: 0, closes: 0))
    let peer = try #require(await space.worker.attach(BoxSocket.self, to: MachineCell.ID(target), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      switch $0 {
      case .frame: events.withLock { $0.frames += 1 }
      case .closed: events.withLock { $0.closes += 1 }
      }
    })
    await space.drain()
    #expect(events.withLock { $0.frames } == 0)
    #expect(events.withLock { $0.closes } == 1)
    #expect(space.worker.cell(MachineCell.ID(target)).presence.state == "lost")
    #expect(space.worker.cell(MachineCell.ID(target)).presence.describeAt == nil)
    peer.close()
    await space.drain()
    try await space.close()
  }

  @Test func refusingAnUnboundKeyDoesNotReplaceTheAcceptedBox() async throws {
    let space = try await MachineCellTestSpace.inMemory().registeringMachines()
    let machine = try await space.machineFamily.addMachineV2(name: "accepted").machine.id.rawValue
    let other = try await space.machineFamily.addMachineV2(name: "other").machine.id.rawValue
    let pubkey = try await space.addMachineTestKey(machine)
    let otherKey = try await space.addMachineTestKey(other)
    let acceptedEvents = Mutex((frames: 0, closes: 0))
    let accepted = try #require(await space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      switch $0 {
      case .frame: acceptedEvents.withLock { $0.frames += 1 }
      case .closed: acceptedEvents.withLock { $0.closes += 1 }
      }
    })
    await space.drain()
    let before = space.worker.cell(MachineCell.ID(machine)).presence
    let refusedEvents = Mutex((frames: 0, closes: 0))
    let refused = try #require(await space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: otherKey, streams: 32)) {
      switch $0 {
      case .frame: refusedEvents.withLock { $0.frames += 1 }
      case .closed: refusedEvents.withLock { $0.closes += 1 }
      }
    })
    await space.drain()
    #expect(acceptedEvents.withLock { $0.frames } == 1)
    #expect(acceptedEvents.withLock { $0.closes } == 0)
    #expect(refusedEvents.withLock { $0.frames } == 0)
    #expect(refusedEvents.withLock { $0.closes } == 1)
    #expect(space.worker.cell(MachineCell.ID(machine)).presence == before)
    let remainingKey = try await space.worker.call(MachineCell.ID(machine)) { $0.box?.opening.pubkey }
    #expect(remainingKey == pubkey)
    accepted.close(); refused.close()
    await space.drain()
    try await space.close()
  }

  @Test func aReplacementKeyDoesNotAuthorizeTheCapturedRevokedKey() async throws {
    let space = try await MachineCellTestSpace.inMemory().registeringMachines()
    let machine = try await space.machineFamily.addMachineV2(name: "rotated").machine.id.rawValue
    let oldKey = try await space.addMachineTestKey(machine)
    _ = try await space.machineFamily.revokeMachine(MachineID(rawValue: machine))
    let newKey = try await space.addMachineTestKey(machine)
    let oldEvents = Mutex((frames: 0, closes: 0))
    let old = try #require(await space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: oldKey, streams: 32)) {
      switch $0 {
      case .frame: oldEvents.withLock { $0.frames += 1 }
      case .closed: oldEvents.withLock { $0.closes += 1 }
      }
    })
    await space.drain()
    #expect(oldEvents.withLock { $0.frames } == 0)
    #expect(oldEvents.withLock { $0.closes } == 1)
    let newEvents = Mutex((frames: 0, closes: 0))
    let new = try #require(await space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: newKey, streams: 32)) {
      switch $0 {
      case .frame: newEvents.withLock { $0.frames += 1 }
      case .closed: newEvents.withLock { $0.closes += 1 }
      }
    })
    await space.drain()
    #expect(newEvents.withLock { $0.frames } == 1)
    #expect(newEvents.withLock { $0.closes } == 0)
    old.close(); new.close()
    await space.drain()
    try await space.close()
  }
}
