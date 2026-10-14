struct FairOutbox {
  private struct Queue {
    var frames: [Frame]
    var index = 0
    var next: Frame { frames[index] }
  }

  private var queues: [UInt64: Queue] = [:]
  private var order: [UInt64] = []
  var abortCount: Int { queues.values.filter { $0.next.kind == .abort }.count }

  func isAborting(_ id: UInt64) -> Bool { queues[id]?.next.kind == .abort }

  mutating func enqueue(_ batch: [Frame], id: UInt64) {
    guard !batch.isEmpty else { return }
    if queues[id] == nil {
      order.append(id)
      queues[id] = Queue(frames: batch)
    } else {
      queues[id]!.frames.append(contentsOf: batch)
    }
  }

  mutating func remove(_ id: UInt64) {
    queues[id] = nil
    order.removeAll { $0 == id }
  }

  mutating func next() -> Frame? {
    guard !order.isEmpty else { return nil }
    let id = order.removeFirst()
    let frame = queues[id]!.next
    queues[id]!.index += 1
    if queues[id]!.index == queues[id]!.frames.count { queues[id] = nil } else { order.append(id) }
    return frame
  }
}
