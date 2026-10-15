#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct OwnerCancellationTests {
  @Test func cancellationBeforeRegistrationDoesNotInvokeEffect() async throws {
    let operations = OwnerOperations()
    let call = WorkerCall(operation: "fixture.effect")
    let invoked = Mutex(false)
    await operations.cancel(call.id)
    await #expect(throws: CancellationError.self) {
      _ = try await operations.run(call) { invoked.withLock { $0 = true }; return .null }
    }
    #expect(!invoked.withLock { $0 })
    await operations.stop()
  }

  @Test func cancellationAfterRegistrationStopsAwaitedEffect() async throws {
    let operations = OwnerOperations()
    let call = WorkerCall(operation: "fixture.effect")
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let blocked = AsyncStream<Void> { _ in }
    let task = Task {
      try await operations.run(call) {
        signal.yield(())
        signal.finish()
        for await _ in blocked {}
        return .null
      }
    }
    for await _ in entered {}
    await operations.cancel(call.id)
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    await operations.stop()
  }

  @Test func recordBytesArePulledOnlyWhenConsumerAdvances() async throws {
    let emitted = Mutex(0)
    let source = AsyncThrowingStream<Int, any Error>(unfolding: {
      emitted.withLock { count in
        count += 1
        return count <= 2 ? count : nil
      }
    })
    let body = Body.stream(OwnerRecordSequence(source: source))
    let reader = OwnerRecordReader<Int>(body)
    #expect(emitted.withLock { $0 } == 0)
    #expect(try await reader.next() == 1)
    #expect(emitted.withLock { $0 } == 1)
    #expect(try await reader.next() == 2)
    #expect(emitted.withLock { $0 } == 2)
    #expect(try await reader.next() == nil)
  }

  @Test func consumedResourcesReleaseOnceAndDownloadedStreamsStillCountTowardsCapacity() async throws {
    let ended = Mutex(0)
    var iterator = OwnerResourceBytes(body: .string("one"), finished: { ended.withLock { $0 += 1 } }).makeAsyncIterator()
    #expect(try await iterator.next() == Data("one".utf8))
    #expect(ended.withLock { $0 } == 0)
    #expect(try await iterator.next() == nil)
    #expect(try await iterator.next() == nil)
    #expect(ended.withLock { $0 } == 1)
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "streams", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let owner = InProcessToolOwnerClient(space: space)
    let streams = ParentScriptStreams()
    for _ in 0 ..< 256 {
      let call = WorkerCall(operation: "script.observe-open", payload: try ownerEncode(ObserveRequest(sql: "SELECT 1", parameters: [], session: id)))
      let token = try await streams.open(call, owner: owner)
      _ = try await streams.take(token)
    }
    await #expect(throws: (any Error).self) {
      _ = try await streams.open(WorkerCall(operation: "script.observe-open", payload: ownerEncode(ObserveRequest(sql: "SELECT 1", parameters: [], session: id))), owner: owner)
    }
    await streams.stop()
  }
}
