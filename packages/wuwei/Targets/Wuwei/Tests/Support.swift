#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Synchronization
import Wuwei

/// Simulated processes sharing one database file, plus a client worker that hosts nothing and only sends.
struct World {
  let simulation: Simulation
  let shared: Bool
  let path = FileManager.default.temporaryDirectory.appending(path: "wuwei-\(UUID().uuidString).sqlite").path(percentEncoded: false)

  init(seed: UInt64 = 1, shared: Bool = false) {
    simulation = Simulation(seed: seed)
    self.shared = shared
  }

  func node(_ id: String, _ registrations: [Registration], dependencies: Dependencies = Dependencies()) throws -> Node {
    var options = Worker.Options()
    options.cellIdle = .seconds(5)
    let process = simulation.spawn()
    let file = try FileDatabase(path: path, synchronous: false)
    let worker = Worker(id: id, storage: shared ? .shared(file) : .layered(file), scheduler: process, dependencies: dependencies, options: options)
    for registration in registrations {
      worker.register(registration)
    }
    worker.start()
    return Node(worker: worker, process: process)
  }

  func client() throws -> Worker {
    try node("client", []).worker
  }

  func run(for duration: Duration) {
    simulation.run(for: duration)
  }
}

struct Node {
  let worker: Worker
  let process: SimulatedProcess
}

/// A test-controlled external effect: `pass` parks until the test opens the label.
final class Valve: Sendable {
  private let waiting = Mutex<[String: [CheckedContinuation<Void, Never>]]>([:])
  private let passed = Mutex<[String]>([])
  private let cancellable = Mutex<[String: (label: String, continuation: CheckedContinuation<Void, any Error>)]>([:])

  func pass(_ label: String) async {
    await withCheckedContinuation { continuation in
      waiting.withLock { $0[label, default: []].append(continuation) }
    }
    passed.withLock { $0.append(label) }
  }

  /// As `pass`, but cancelling the waiting task ends the wait with `CancellationError`.
  func wait(_ label: String) async throws {
    let id = UUID().uuidString
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled { return continuation.resume(throwing: CancellationError()) }
        cancellable.withLock { $0[id] = (label, continuation) }
      }
    } onCancel: {
      cancellable.withLock { $0.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
    passed.withLock { $0.append(label) }
  }

  func open(_ label: String) {
    for id in cancellable.withLock({ $0.filter { $0.value.label == label }.map(\.key) }) {
      cancellable.withLock { $0.removeValue(forKey: id) }?.continuation.resume()
    }
    for continuation in waiting.withLock({ $0.removeValue(forKey: label) ?? [] }) {
      continuation.resume()
    }
  }

  var waitingLabels: [String] {
    let plain = waiting.withLock { $0.flatMap { label, continuations in Array(repeating: label, count: continuations.count) } }
    return (plain + cancellable.withLock { $0.values.map(\.label) }).sorted()
  }

  var passedLabels: [String] {
    passed.withLock { $0 }
  }
}
