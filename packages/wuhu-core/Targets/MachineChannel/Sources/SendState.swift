import enum MachineContract.ExecOutputStream
import enum MachineContract.ExitStatus

struct SendState {
  struct Chunk {
    let cursor: Int
    let stream: ExecOutputStream?
    let bytes: [UInt8]
    var end: Int { cursor + bytes.count }
  }

  let window: Int
  private(set) var chunks: [Chunk] = []
  private(set) var nextCursor: Int = 0
  private(set) var ackedThrough: Int = 0
  var eofCursor: Int?
  var exit: ExitStatus?
  private var waiters: [AsyncStream<Void>.Continuation] = []

  init(window: Int) {
    self.window = window
  }

  var room: Int { window - (nextCursor - ackedThrough) }

  mutating func append(stream: ExecOutputStream?, bytes: [UInt8]) -> Chunk {
    let chunk = Chunk(cursor: nextCursor, stream: stream, bytes: bytes)
    chunks.append(chunk)
    nextCursor = chunk.end
    return chunk
  }

  mutating func acknowledge(through cursor: Int) {
    let cursor = min(cursor, nextCursor)
    guard cursor > ackedThrough else { return }
    ackedThrough = cursor
    while let first = chunks.first, first.end <= cursor {
      chunks.removeFirst()
    }
    if let first = chunks.first, first.cursor < cursor {
      chunks[0] = Chunk(cursor: cursor, stream: first.stream, bytes: Array(first.bytes[(cursor - first.cursor)...]))
    }
    resumeWaiters()
  }

  func replay(above cursor: Int) -> [Chunk] {
    chunks.filter { $0.end > cursor }
  }

  mutating func addWaiter(_ continuation: AsyncStream<Void>.Continuation) {
    waiters.append(continuation)
  }

  mutating func resumeWaiters() {
    for waiter in waiters { waiter.finish() }
    waiters = []
  }
}
