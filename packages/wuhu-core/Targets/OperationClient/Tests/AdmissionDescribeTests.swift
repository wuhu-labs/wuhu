#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import OperationClient
import OperationProtocol
import Synchronization
import Testing

/// Opens once, for every waiter, now and later.
private final class Gate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream() }
  func open() { continuation.finish() }
  /// Returns once the gate opens or the waiting task is cancelled.
  func wait() async { for await _ in stream {} }
}

private func isDescribe(_ request: Request) -> Bool {
  request.method == .get && request.url.deletingLastPathComponent().lastPathComponent == "machines"
}

/// Holds every describe of the wire's machines until `released` opens, counting them; each answers with `failure` while one is
/// set, else through the wire. `arrived` opens with the first.
private final class HeldDescribes: Sendable {
  let wire: Wire
  let describes = Mutex(0)
  let failure = Mutex<OperationError?>(nil)
  let arrived = Gate(), released = Gate()

  init(_ wire: Wire) { self.wire = wire }

  var fetch: FetchClient {
    FetchClient { request in
      guard isDescribe(request) else { return try await self.wire.fetch(request) }
      self.describes.withLock { $0 += 1 }
      self.arrived.open()
      await self.released.wait()
      if let failure = self.failure.withLock({ $0 }) { throw failure }
      return try await self.wire.fetch(request)
    }
  }
}

/// A store whose lookups wait until their caller is cancelled and then answer anyway, as a database call that ignores
/// cancellation does. `looking` opens once a lookup waits.
private struct LookupsOutlivingCancellation: OperationStore {
  let base = MemoryOperationStore()
  let looking = Gate(), never = Gate()

  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? {
    looking.open()
    await never.wait()
    return try await base.lookup(owner)
  }

  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws { try await base.save(record, appending: chunk) }
  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws { try await base.trim(record, removing: sequences) }
}

@Suite(.timeLimit(.minutes(1)))
struct AdmissionDescribeTests {
  /// A failed describe answers every start waiting on it the same way and is not kept: the next start describes afresh.
  @Test func aFailedDescribeAnswersEveryWaitingStartAndTheNextDescribesAfresh() async throws {
    let wire = try Wire()
    let held = HeldDescribes(wire)
    let refusal = OperationError(.machineNotAuthorized, message: "Machine left the group")
    held.failure.withLock { $0 = refusal }
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: held.fetch, store: MemoryOperationStore())
    let starts = (0 ..< 8).map { index in
      Task { () -> Result<UUID, OperationError> in
        do { return try await .success(operations.open(.init(scope: "test", key: "start-\(index)"), machine: "disk", start: emit()).id) }
        catch { return .failure(error as? OperationError ?? OperationError(.transport, message: "\(error)")) }
      }
    }
    await held.arrived.wait()
    held.released.open()
    for start in starts { #expect(await start.value == .failure(refusal)) }
    let failed = held.describes.withLock { $0 }
    held.failure.withLock { $0 = nil }
    _ = try await operations.open(.init(scope: "test", key: "after"), machine: "disk", start: emit())
    #expect(held.describes.withLock { $0 } == failed + 1)
    await operations.shutdown(); await wire.close()
  }

  /// A claim held in its store lookup across a shutdown reaches admission after shutdown cancelled the describes: it is refused
  /// without describing, and shutdown does not wait on a describe it never saw. No exchange deadline passes on its own here.
  @Test func aClaimThatOutlivesShutdownInTheStoreDoesNotDescribe() async throws {
    let describes = Mutex(0)
    let unanswered = Gate(), stopped = Gate()
    let store = LookupsOutlivingCancellation()
    let operations = try MachineOperations(
      origin: URL(string: "https://memory.invalid")!,
      fetch: FetchClient { request in
        if isDescribe(request) { describes.withLock { $0 += 1 } }
        await unanswered.wait()
        throw CancellationError()
      },
      store: store,
      clock: OperationClock(now: { .zero }, sleep: { _ in
        await stopped.wait()
        throw CancellationError()
      }),
    )
    let start = Task { try await operations.open(.init(scope: "test", key: "late"), machine: "disk", start: emit()) }
    await store.looking.wait()
    await operations.shutdown()
    let refusal = await #expect(throws: OperationError.self) { _ = try await start.value }
    #expect(refusal?.code == .requestCancelled)
    #expect(describes.withLock { $0 } == 0)
  }
}

/// A describe the machine never answers fails `requestDeadline` naming the machine and the deadline.
@Test(.timeLimit(.minutes(1))) func anUnansweredDescribeSaysWhatTimedOut() async throws {
  let unanswered = Gate()
  let operations = try MachineOperations(
    origin: URL(string: "https://memory.invalid")!,
    fetch: FetchClient { _ in
      await unanswered.wait()
      throw CancellationError()
    },
    store: MemoryOperationStore(), clock: OperationClock(now: { .zero }, sleep: { _ in }),
  )
  let error = await #expect(throws: OperationError.self) { try await operations.describe("disk") }
  #expect(error?.code == .requestDeadline)
  #expect(error?.message == "Machine disk did not describe itself within 5 s")
  await operations.shutdown()
  unanswered.open()
}
