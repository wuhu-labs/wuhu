#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// Hundreds of live session fixtures otherwise contend with one another and
// their worker children inside the same test executable's short waits.
actor SessionFixtureAdmission {
  private(set) var available: Int
  private var waiting: [(id: UUID, continuation: AsyncStream<Void>.Continuation)] = []
  var waitingCount: Int { waiting.count }

  init(capacity: Int) {
    precondition(capacity > 0)
    available = capacity
  }

  func acquire() async throws {
    try Task.checkCancellation()
    if available > 0 {
      available -= 1
      return
    }
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    waiting.append((id, continuation))
    for await _ in stream {}
    if let index = waiting.firstIndex(where: { $0.id == id }) {
      waiting.remove(at: index)
      throw CancellationError()
    }
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }

  func release() {
    if waiting.isEmpty {
      available += 1
    } else {
      waiting.removeFirst().continuation.finish()
    }
  }
}
