import Synchronization

// The kernel's mailbox. Consumer cancellation returns nil and leaves the
// inbox intact; dropping the inbox drops buffered elements, resolving their
// callbacks to UnfulfilledError.
final class Inbox<Element: Sendable>: Sendable {
  private struct Storage {
    var buffer: [Element] = []
    var waiter: CheckedContinuation<Element?, Never>?
  }

  private let coalescing: Bool
  private let storage = Mutex(Storage())

  init(coalescing: Bool = false) {
    self.coalescing = coalescing
  }

  func post(_ element: Element) {
    let waiter = storage.withLock { storage -> CheckedContinuation<Element?, Never>? in
      if let waiter = storage.waiter {
        storage.waiter = nil
        return waiter
      }
      if !coalescing || storage.buffer.isEmpty {
        storage.buffer.append(element)
      }
      return nil
    }
    waiter?.resume(returning: element)
  }

  private enum Verdict {
    case deliver(Element?)
    case parked
  }

  func next() async -> Element? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let verdict = storage.withLock { storage -> Verdict in
          guard !Task.isCancelled else { return .deliver(nil) }
          if !storage.buffer.isEmpty {
            return .deliver(storage.buffer.removeFirst())
          }
          precondition(storage.waiter == nil, "Inbox has a single consumer")
          storage.waiter = continuation
          return .parked
        }
        if case let .deliver(element) = verdict {
          continuation.resume(returning: element)
        }
      }
    } onCancel: {
      let waiter = storage.withLock { storage -> CheckedContinuation<Element?, Never>? in
        let waiter = storage.waiter
        storage.waiter = nil
        return waiter
      }
      waiter?.resume(returning: nil)
    }
  }
}
