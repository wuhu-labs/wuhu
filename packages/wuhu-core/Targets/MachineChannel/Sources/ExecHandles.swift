import MachineContract

public struct OutgoingExec: Sendable {
  public let id: ExecID
  public let events: ExecEvents
  let endpoint: ChannelEndpoint

  public func sendStdin(_ bytes: [UInt8]) async throws {
    try await endpoint.sendData(exec: id, bytes: bytes)
  }

  public func closeStdin() async {
    await endpoint.closeStdin(exec: id)
  }

  public func kill() async {
    await endpoint.requestKill(exec: id)
  }

  /// Returns once the peer holds the exec's start: from then on the exec no longer depends on this side staying connected.
  public func accepted() async {
    await endpoint.accepted(exec: id)
  }

  public func acknowledgeExit() async {
    await endpoint.acknowledgeExit(exec: id)
  }

  public func acknowledge(through cursor: Int) async {
    await endpoint.acknowledgeConsumption(exec: id, through: cursor)
  }
}

public struct ExecEvents: AsyncSequence, Sendable {
  public typealias Element = ExecEvent

  let endpoint: ChannelEndpoint
  let id: ExecID
  let frames: AsyncStream<Frame>
  let initialConsumed: Int
  let autoAcknowledge: Bool

  init(
    endpoint: ChannelEndpoint,
    id: ExecID,
    frames: AsyncStream<Frame>,
    initialConsumed: Int = 0,
    autoAcknowledge: Bool = true,
  ) {
    self.endpoint = endpoint
    self.id = id
    self.frames = frames
    self.initialConsumed = initialConsumed
    self.autoAcknowledge = autoAcknowledge
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(
      endpoint: endpoint,
      id: id,
      frames: frames.makeAsyncIterator(),
      consumed: initialConsumed,
      autoAcknowledge: autoAcknowledge,
    )
  }

  public struct Iterator: AsyncIteratorProtocol {
    let endpoint: ChannelEndpoint
    let id: ExecID
    var frames: AsyncStream<Frame>.AsyncIterator
    var consumed: Int
    let autoAcknowledge: Bool
    /// Events an exit frame announces ahead of its exit, then the exit itself.
    var pending: [ExecEvent] = []
    var finished: Bool = false

    public mutating func next() async throws -> ExecEvent? {
      guard !finished else { return nil }
      if !pending.isEmpty {
        let event = pending.removeFirst()
        if case .exit = event {
          finished = true
          if autoAcknowledge { await endpoint.acknowledgeExit(exec: id) }
        }
        return event
      }
      while let frame = await frames.next() {
        switch frame.opcode {
        case .output:
          let chunk: OutputChunk
          do {
            chunk = try frame.payload(OutputChunk.self)
          } catch {
            finished = true
            throw error
          }
          // Above-consumed means frames were lost to a leg blip the sender has
          // not yet heard about (or raced its hello-triggered replay). The
          // sender retains everything un-acked and replays it on every hello,
          // so the dropped chunk is redelivered in order; unacked drops are
          // never data loss.
          guard chunk.cursor <= consumed else { continue }
          let end = chunk.cursor + chunk.data.count
          guard end > consumed else {
            if autoAcknowledge {
              await endpoint.acknowledgeConsumption(exec: id, through: consumed)
            }
            continue
          }
          let skip = consumed - chunk.cursor
          let bytes = skip == 0 ? chunk.data.bytes : Array(chunk.data.bytes[skip...])
          let cursor = consumed
          consumed = end
          if autoAcknowledge {
            await endpoint.acknowledgeConsumption(exec: id, through: end)
          }
          return .output(stream: chunk.stream, cursor: cursor, data: Base64Data(bytes))
        case .execExit:
          let exit: ExecExit
          do {
            exit = try frame.payload(ExecExit.self)
          } catch {
            finished = true
            throw error
          }
          // An exit ahead of consumption is dropped like an early chunk: the
          // replay redelivers it after the missing output.
          if exit.cursor > consumed { continue }
          finished = true
          guard exit.cursor == consumed else {
            throw ChannelError.protocolViolation("exit at \(exit.cursor) with output consumed through \(consumed)")
          }
          if exit.outputCut == true { pending.append(.truncated(limit: consumed)) }
          if let outcome = exit.timedOut { pending.append(.timedOut(outcome: outcome)) }
          if !pending.isEmpty {
            finished = false
            pending.append(.exit(status: exit.status))
            return pending.removeFirst()
          }
          if autoAcknowledge { await endpoint.acknowledgeExit(exec: id) }
          return .exit(status: exit.status)
        default:
          continue
        }
      }
      return nil
    }
  }
}
