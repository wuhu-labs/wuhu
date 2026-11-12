import LiveDocument
import Synchronization
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One Loro replica per live document for the life of the process, handed to the cell: a step uses an
/// entry only while it reflects the document's row, and rebuilds otherwise. A step that rolls back
/// leaves its replica ahead of its rows, so its entry goes rather than lingering as a wrong answer.
final class DocumentReplicas: Sendable {
  /// Documents kept at once; the least recently used one is rebuilt on its next step.
  static let capacity = 32

  private struct Entry {
    let replica: LiveReplica
    var frontier: Data?
  }

  private struct State {
    var entries: [String: Entry] = [:]
    var order: [String] = []
  }

  /// One step's access to the entry of its document.
  struct Slot {
    fileprivate var replica: LiveReplica?
    fileprivate var frontier: Data?

    /// The replica at `frontier`, built by `build` when the entry reflects anything else.
    mutating func take(_ frontier: Data?, _ build: () throws -> LiveReplica) rethrows -> LiveReplica {
      if let replica, self.frontier == frontier { return replica }
      let built = try build()
      replica = built
      self.frontier = frontier
      return built
    }

    /// The replica a step made itself, at the frontier its rows will hold.
    mutating func put(_ replica: LiveReplica, _ frontier: Data?) {
      self.replica = replica
      self.frontier = frontier
    }

    /// What the rows hold now: a later step uses the entry only at this frontier.
    mutating func keep(_ frontier: Data?) {
      self.frontier = frontier
    }
  }

  private let state = Mutex(State())

  func with<T>(_ key: String, _ body: (inout Slot) throws -> T) throws -> T {
    try state.withLock { state in
      var slot = Slot(replica: state.entries[key]?.replica, frontier: state.entries[key]?.frontier)
      touch(key, in: &state)
      do {
        let value = try body(&slot)
        if let replica = slot.replica {
          state.entries[key] = Entry(replica: replica, frontier: slot.frontier)
        }
        return value
      } catch {
        forget(key, in: &state)
        throw error
      }
    }
  }

  func drop(_ key: String) {
    state.withLock { state in forget(key, in: &state) }
  }

  private func touch(_ key: String, in state: inout State) {
    state.order.removeAll { $0 == key }
    state.order.append(key)
    while state.order.count > Self.capacity {
      state.entries[state.order.removeFirst()] = nil
    }
  }

  private func forget(_ key: String, in state: inout State) {
    state.entries[key] = nil
    state.order.removeAll { $0 == key }
  }
}
