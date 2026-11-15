import Synchronization
import Testing
import Wuwei

/// Two workers on one store while a release rolls: the outgoing one, and the one that takes over before it serves.
@Suite struct HandoverTests {
  private let room = Room.ID("r")
  private let kept = Counter.ID("kept")
  private let reached = Counter.ID("reached")
  private let fresh = Counter.ID("fresh")

  private func node(_ id: String, in world: World, starts: Bool = true) throws -> Node {
    var dependencies = Dependencies()
    dependencies.register(Tripwire())
    return try world.node(id, [.cell(Room.self), .cell(Counter.self)], dependencies: dependencies, starts: starts)
  }

  private func ask(_ node: Node, _ counter: Counter.ID, adding amount: Int64) -> Asked {
    let answer = Asked()
    Task(executorPreference: node.process) {
      let result: Result<Int64, any Error>
      do { result = .success(try await node.worker.call(counter) { try $0.addThenRead(amount) }) }
      catch { result = .failure(error) }
      answer.heard.withLock { $0 = (result, node.worker.cell(counter).value()) }
    }
    return answer
  }

  private func takeOver(_ node: Node) -> TookOver {
    let tookOver = TookOver()
    Task(executorPreference: node.process) {
      await node.worker.takeOver()
      tookOver.done.withLock { $0 = true }
    }
    return tookOver
  }

  private func drain(_ node: Node, in world: World) {
    Task(executorPreference: node.process) { await node.worker.quiesce() }
    world.run(for: .zero)
  }

  @Test(arguments: [false, true], 1 ... 8 as ClosedRange<UInt64>)
  func anAttachWaitsOutADrainingHolderThenHearsTheCell(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try node("a", in: world)
    a.worker.send(room).announce("before")
    world.run(for: .zero)
    drain(a, in: world)
    let b = try node("b", in: world)
    let client = Client<Chat>()
    let attached = Mutex<Bool?>(nil)
    Task(executorPreference: b.process) { [room] in
      let peer = try? await b.worker.attach(Chat.self, to: room) { client.hear($0, durable: []) }
      attached.withLock { $0 = peer != nil }
    }
    world.run(for: .seconds(5))
    #expect(attached.withLock { $0 } == nil)
    a.worker.release()
    world.run(for: .seconds(1))
    #expect(attached.withLock { $0 } == true)
    #expect(client.heard == [.frame(.history(["before"]))])
  }

  @Test(arguments: [false, true], 1 ... 8 as ClosedRange<UInt64>)
  func cancellingAHeldAttachThrowsCancellationAndAttachesNothing(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try node("a", in: world)
    a.worker.send(room).announce("before")
    world.run(for: .zero)
    drain(a, in: world)
    let b = try node("b", in: world)
    let client = Client<Chat>()
    let outcome = Mutex<String?>(nil)
    let waiting = Task(executorPreference: b.process) { [room] in
      do {
        _ = try await b.worker.attach(Chat.self, to: room) { client.hear($0, durable: []) }
        outcome.withLock { $0 = "attached" }
      } catch {
        outcome.withLock { $0 = "cancelled" }
      }
    }
    world.run(for: .seconds(1))
    waiting.cancel()
    world.run(for: .zero)
    #expect(outcome.withLock { $0 } == "cancelled")
    a.worker.release()
    world.run(for: .seconds(2))
    #expect(client.heard.isEmpty)
  }

  @Test(arguments: [false, true], 1 ... 8 as ClosedRange<UInt64>)
  func endingTheHoldsRefusesEveryWaitingCallAndAttachAndEveryLaterOneWhileTheWorkerServesOn(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try node("a", in: world)
    a.worker.send(room).announce("before")
    a.worker.send(kept).add(1)
    world.run(for: .zero)
    drain(a, in: world)
    let b = try node("b", in: world)
    let attaches = Mutex<[Bool]>([])
    let attach = { [room] in
      _ = Task(executorPreference: b.process) {
        let peer = try? await b.worker.attach(Chat.self, to: room) { _ in }
        attaches.withLock { $0.append(peer != nil) }
      }
    }
    attach()
    let waiting = ask(b, kept, adding: 10)
    world.run(for: .seconds(1))
    #expect(waiting.answer == nil && attaches.withLock { $0 }.isEmpty)
    b.worker.endHolds()
    world.run(for: .zero)
    #expect(throws: Evicted.self) { try waiting.answer?.get() }
    attach()
    let later = ask(b, kept, adding: 10)
    world.run(for: .zero)
    #expect(throws: Evicted.self) { try later.answer?.get() }
    #expect(attaches.withLock { $0 } == [false, false])
    a.worker.release()
    world.run(for: .seconds(1))
    let served = ask(b, kept, adding: 10)
    world.run(for: .seconds(1))
    #expect(served.answered)
  }

  @Test(arguments: [false, true], 1 ... 8 as ClosedRange<UInt64>)
  func theOutgoingWorkerKeepsServingWhileEveryCallOfItsSuccessorWaits(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try node("a", in: world)
    a.worker.send(kept).add(1)
    world.run(for: .milliseconds(500))
    let b = try node("b", in: world, starts: false)
    let tookOver = takeOver(b)
    world.run(for: .zero)
    #expect(!tookOver.done.withLock { $0 })
    world.run(for: .milliseconds(1100))
    #expect(tookOver.done.withLock { $0 })
    let outgoing = [ask(a, kept, adding: 1), ask(a, reached, adding: 1)]
    world.run(for: .seconds(1))
    #expect(outgoing.allSatisfy { $0.answered })
    let incoming = [ask(b, kept, adding: 10), ask(b, reached, adding: 10), ask(b, fresh, adding: 10)]
    world.run(for: .seconds(3))
    #expect(incoming.allSatisfy { $0.answer == nil })
    drain(a, in: world)
    a.worker.release()
    world.run(for: .seconds(1))
    #expect(incoming.allSatisfy { $0.answered })
  }

  /// The successor's own scanner runs offset from its announcement, and the outgoing worker never answers, as an older build does: the takeover ends at its two-scan bound, the holder's addresses refuse while it serves, and the successor serves them once it quiesces.
  @Test(arguments: [false, true], 1 ... 8 as ClosedRange<UInt64>)
  func takingOverFromAWorkerThatNeverAnswersEndsAtTwoScansThenServesOnceItQuiesces(shared: Bool, seed: UInt64) throws {
    let world = World(seed: seed, shared: shared)
    let a = try node("a", in: world)
    a.worker.send(kept).add(1)
    world.run(for: .milliseconds(500))
    world.simulation.freeze(a.process)
    let b = try node("b", in: world)
    world.run(for: .milliseconds(300))
    let tookOver = takeOver(b)
    world.run(for: .milliseconds(1950))
    #expect(!tookOver.done.withLock { $0 })
    world.run(for: .milliseconds(100))
    #expect(tookOver.done.withLock { $0 })
    let refused = ask(b, kept, adding: 10)
    world.run(for: .zero)
    #expect(throws: Evicted.self) { try refused.answer?.get() }
    world.simulation.thaw(a.process)
    drain(a, in: world)
    a.worker.release()
    world.run(for: .seconds(1))
    let served = ask(b, kept, adding: 10)
    world.run(for: .seconds(1))
    #expect(served.answered)
  }
}

extension Asked {
  /// Answered with a value; on the shared backend every `Counter` reads one table, so the value says nothing of which.
  fileprivate var answered: Bool { (try? answer?.get()) != nil }
}

private final class TookOver: Sendable {
  let done = Mutex(false)
}
