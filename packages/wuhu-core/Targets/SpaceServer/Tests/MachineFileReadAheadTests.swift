import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import MachineContract
import OperationProtocol
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineFileReadAheadTests {
  @Test func cancellingWhileWaitingForAChunkCannotReturnSourceSuccess() async throws {
    let requested = AsyncStream<Void>.makeStream()
    let consumed = Mutex(0)
    _ = try await withFileBox(kinds: [ComputerKindSchemas.read], respond: { request, peer, _ in
      switch request.exchange {
      case let .startFile(id, _):
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
      case let .poll(_, channel, _, _, _, _) where channel != nil:
        requested.continuation.yield(())
      case .stop:
        peer.send(.init(tag: request.tag, answer: .box(.init(.unknownOperation))))
      default: break
      }
    }, operation: { client in
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await readAhead(client, start: .init(kind: "read.v1", input: ["path": "/source"])) { _ in
            consumed.withLock { $0 += 1 }
          }
        }
        var iterator = requested.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        group.cancelAll()
        await #expect(throws: CancellationError.self) { try await group.next() }
        #expect(consumed.withLock { $0 } == 0)
        return true
      }
    })
  }

  @Test(arguments: ["sourceLast", "sourceFirst", "sourceFailure", "cancel", "cancelIdle", "targetFailure"])
  func oneChunkOverlapsAcceptanceAndCommitWaitsForBothEnds(ending: String) async throws {
    let frameBytes = 65536
    let total = frameBytes * 3
    let sourceStarted = AsyncStream<UUID>.makeStream()
    let sourceControl = AsyncStream<(BoxSocket.Outgoing, Peer<BoxSocket>)>.makeStream()
    let inputs = AsyncStream<(BoxSocket.Outgoing, Peer<BoxSocket>)>.makeStream()
    let commits = Mutex(0)
    let ends = Mutex(0)
    let sourceRequested = AsyncStream<Void>.makeStream()
    var kinds: [UUID: String] = [:]
    var targetReady = false
    var targetControl: (BoxSocket.Outgoing, Peer<BoxSocket>)?
    _ = try await withFileBox(kinds: [ComputerKindSchemas.stat, ComputerKindSchemas.read, ComputerKindSchemas.stagedWrite], respond: { request, peer, space in
      switch request.exchange {
      case let .startFile(id, start):
        kinds[id] = start.kind
        if start.kind == "stat.v1" {
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["name": "source", "kind": "file", "size": 196_608, "token": "pinned", "mtime": 0])))))
        } else {
          if start.kind == "stagedWrite.v1" { targetReady = true }
          if start.kind == "read.v1" {
            #expect(targetReady)
            #expect(start.input.object?["ifMatch"] == "pinned")
            sourceStarted.continuation.yield(id)
          }
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        }
      case let .poll(id, channel, after, _, terminal, _):
        if terminal != nil { break }
        if kinds[id] == "read.v1" {
          guard let channel else { sourceControl.continuation.yield((request, peer)); break }
          if ending == "cancelIdle" { sourceRequested.continuation.yield(()); break }
          let from = Int(after)
          let through = min(total, from + frameBytes)
          let pointer = try #require(space.machineBuffers.put(Data(repeating: UInt8(from / frameBytes), count: through - from), operation: id, channel: channel, from: after))
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, channel: channel, from: after, through: UInt64(through), final: UInt64(total)), output: pointer))))
        } else if kinds[id] == "stagedWrite.v1" { targetControl = (request, peer) }
      case let .fileInput(id, pointer, end):
        if pointer.channel == "data", pointer.through > pointer.from {
          inputs.continuation.yield((request, peer))
        } else if pointer.channel == "commit" {
          commits.withLock { $0 += 1 }
          peer.send(.init(tag: request.tag, answer: .box(.init(.operationEnded))))
          let control = try #require(targetControl)
          control.1.send(.init(tag: control.0.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["version": "landed"])))))
        } else {
          ends.withLock { $0 += 1 }
          peer.send(.init(tag: request.tag, answer: .input(.init(acceptedThrough: .init(rawValue: pointer.through), end: end, blocked: false))))
        }
      case .stop:
        peer.send(.init(tag: request.tag, answer: .box(.init(.unknownOperation))))
      default: break
      }
    }, operation: { client in
      try await withThrowingTaskGroup(of: CopyReceipt.self) { group in
        group.addTask {
          try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .machine(client.machine, path: "/source"), to: .machine(client.machine, path: "/target", replace: false))
        }
        var starts = sourceStarted.stream.makeAsyncIterator()
        let source = try #require(await starts.next())
        if ending == "cancelIdle" {
          var requests = sourceRequested.stream.makeAsyncIterator()
          _ = try #require(await requests.next())
          group.cancelAll()
          await #expect(throws: CancellationError.self) { try await group.next() }
          #expect(ends.withLock { $0 } == 0)
          #expect(commits.withLock { $0 } == 0)
          return Optional<CopyReceipt>.none
        }
        var controls = sourceControl.stream.makeAsyncIterator()
        func finishSource() async throws {
          let (request, peer) = try #require(await controls.next())
          let verdict = ending == "sourceFailure" ? Verdict(.failed, error: .init(.fileChanged)) : Verdict(.completed, result: ["version": "pinned"])
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: .init(operation: source, verdict: verdict, terminalToken: UUID(), finalOffsets: ["data": .init(rawValue: UInt64(total))], outputConsumed: false)))))
        }
        if ending == "sourceFirst" { try await finishSource() }
        var pending = inputs.stream.makeAsyncIterator()
        for index in 1 ... 3 {
          let (request, peer) = try #require(await pending.next())
          guard case let .fileInput(_, pointer, end) = request.exchange else { preconditionFailure() }
          #expect(pointer.from == UInt64((index - 1) * frameBytes))
          if index < 3 {
            try await waitForCopyOffer(source, through: (index + 1) * frameBytes, space: client.space)
            let writer = await client.space.writer
            let consumed = try await writer.read { db in
              try Int.fetchOne(db, sql: "SELECT json_extract(offsets, '$.data') FROM machine_file_operations WHERE id = ?", arguments: [source.uuidString.lowercased()])
            }
            #expect(consumed == index * frameBytes)
            #expect(commits.withLock { $0 } == 0)
          }
          if ending == "targetFailure" {
            peer.send(.init(tag: request.tag, answer: .box(.init(.invalidInput))))
            await #expect(throws: OperationError(.invalidInput)) { try await group.next() }
            #expect(ends.withLock { $0 } == 0)
            #expect(commits.withLock { $0 } == 0)
            return Optional<CopyReceipt>.none
          }
          if ending == "cancel" {
            group.cancelAll()
            await #expect(throws: CancellationError.self) { try await group.next() }
            #expect(client.space.machineBuffers.retained(source, channel: "data") == 0)
            #expect(client.space.machineBuffers.retained(pointer.operation, channel: "data") == 0)
            #expect(commits.withLock { $0 } == 0)
            return Optional<CopyReceipt>.none
          }
          if index == 3, ending == "sourceFirst" {
            try await waitForCopyOffer(source, through: total, consumed: true, space: client.space)
            #expect(commits.withLock { $0 } == 0)
          }
          peer.send(.init(tag: request.tag, answer: .input(.init(acceptedThrough: .init(rawValue: pointer.through), end: end, blocked: false))))
        }
        if ending != "sourceFirst" { try await waitForCopyOffer(source, through: total, consumed: true, space: client.space)
          #expect(commits.withLock { $0 } == 0)
          try await finishSource()
        }
        if ending == "sourceFailure" {
          await #expect(throws: CopyRefusal.sourceChanged) { try await group.next() }
          #expect(commits.withLock { $0 } == 0)
          return Optional<CopyReceipt>.none
        }
        let result = try #require(try await group.next())
        #expect(result.bytes == total)
        #expect(commits.withLock { $0 } == 1)
        return Optional(result)
      }
    })
  }
}

private func waitForCopyOffer(_ operation: UUID, through: Int, consumed: Bool = false, space: Space) async throws {
  let writer = await space.writer
  let column = consumed ? "offsets" : "offered"
  let values = ValueObservation.tracking { db in
    try Int.fetchOne(db, sql: "SELECT json_extract(\(column), '$.data') FROM machine_file_operations WHERE id = ?", arguments: [operation.uuidString.lowercased()])
  }.values(in: writer, bufferingPolicy: .bufferingNewest(1))
  for try await value in values {
    let offset = try #require(value)
    #expect(offset <= through)
    if offset == through { return }
  }
  Issue.record("Copy source observation ended before its expected offset")
}
