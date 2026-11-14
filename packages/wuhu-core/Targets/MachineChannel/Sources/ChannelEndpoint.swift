import MachineContract

public actor ChannelEndpoint {
  private var execs: [ExecID: ExecState] = [:]
  private var execsByStream: [Int: ExecState] = [:]
  private var nextStreamID: Int = 1
  private var outbound: AsyncStream<Frame>.Continuation?
  private var bindingGeneration: Int = 0
  private var terminalWaiters: [ExecID: [AsyncStream<Void>.Continuation]] = [:]
  private var acceptanceWaiters: [ExecID: [AsyncStream<Void>.Continuation]] = [:]

  public init() {}

  public func run(_ transport: some FrameTransport) async {
    let (frames, continuation) = AsyncStream<Frame>.makeStream()
    let generation = bind(continuation)
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await frame in frames {
          do {
            try await transport.send(FrameCodec.encode(frame))
            await self.didSend(frame)
          } catch {
            break
          }
        }
      }
      group.addTask {
        for await bytes in transport.inbound {
          await self.route(bytes)
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
    transport.close()
    unbind(generation)
  }

  // Manual acknowledgement lets the consumer defer the ack until the bytes are durable, so "last ack" never runs ahead of
  // what a crash-retry can actually resume from.
  public func startExec(_ start: ExecStart, autoAcknowledge: Bool = true) -> OutgoingExec {
    precondition(execs[start.id] == nil, "duplicate exec id \(start.id.rawValue)")
    let streamID = nextStreamID
    nextStreamID += 1
    let exec = ExecState(streamID: streamID, start: start)
    execs[start.id] = exec
    execsByStream[streamID] = exec
    outbound?.yield(Frame(streamID: streamID, opcode: .execStart, payload: start))
    return OutgoingExec(
      id: start.id,
      events: ExecEvents(endpoint: self, id: start.id, frames: exec.frames, autoAcknowledge: autoAcknowledge),
      endpoint: self,
    )
  }

  // MARK: Exec plumbing for the handles

  func sendData(exec id: ExecID, bytes: [UInt8]) async throws {
    var index = 0
    while index < bytes.count {
      guard let exec = execs[id] else { return }
      precondition(exec.sender.eofCursor == nil, "stdin after closeStdin")
      if exec.exitReceived { return }
      let room = exec.sender.room
      guard room > 0 else {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        exec.sender.addWaiter(continuation)
        for await _ in signal {}
        try Task.checkCancellation()
        continue
      }
      let take = min(room, bytes.count - index)
      let chunk = exec.sender.append(bytes: Array(bytes[index ..< index + take]))
      index += take
      outbound?.yield(Frame(streamID: exec.streamID, opcode: .stdin, payload: StdinChunk(id: id, cursor: chunk.cursor, data: Base64Data(chunk.bytes))))
    }
  }

  func closeStdin(exec id: ExecID) {
    guard let exec = execs[id], exec.sender.eofCursor == nil else { return }
    exec.sender.eofCursor = exec.sender.nextCursor
    guard !exec.exitReceived else { return }
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .stdinEof, payload: StdinEOF(id: id, cursor: exec.sender.nextCursor)))
  }

  func requestKill(exec id: ExecID) {
    guard let exec = execs[id], !exec.killRequested else { return }
    exec.killRequested = true
    guard !exec.exitReceived else { return }
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .kill, payload: Kill(id: id)))
  }

  func acknowledgeConsumption(exec id: ExecID, through cursor: Int) {
    guard let exec = execs[id] else { return }
    exec.acknowledgedInbound = max(exec.acknowledgedInbound, cursor)
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: id, cursor: cursor)))
  }

  private func retire(_ id: ExecID) {
    guard let exec = execs.removeValue(forKey: id) else { return }
    execsByStream[exec.streamID] = nil
    exec.sender.resumeWaiters()
    exec.framesContinuation.finish()
    for waiter in terminalWaiters.removeValue(forKey: id) ?? [] { waiter.finish() }
    for waiter in acceptanceWaiters.removeValue(forKey: id) ?? [] { waiter.finish() }
  }

  /// Returns once the peer acknowledged the exec's start, or the exec is gone; early when the waiting task is cancelled.
  func accepted(exec id: ExecID) async {
    guard let exec = execs[id], !exec.accepted else { return }
    let (accepted, continuation) = AsyncStream<Void>.makeStream()
    acceptanceWaiters[id, default: []].append(continuation)
    for await _ in accepted {}
  }

  func acknowledgeExit(exec id: ExecID) async {
    guard let exec = execs[id], let cursor = exec.exitCursor else { return }
    exec.acknowledgedInbound = cursor
    exec.terminalAckPending = true
    guard let outbound else { return }
    let (sent, continuation) = AsyncStream<Void>.makeStream()
    terminalWaiters[id, default: []].append(continuation)
    outbound.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: id, cursor: cursor, terminal: true)))
    for await _ in sent {}
  }

  private func didSend(_ frame: Frame) {
    guard frame.opcode == .ack, let ack = try? frame.payload(Ack.self), ack.terminal == true else { return }
    retire(ack.id)
  }

  // MARK: Binding

  // Rebind protocol: hello FIRST, then per-exec resume — exec-start retransmit,
  // self-replay of everything un-acked (the dead transport may have swallowed
  // it), and our consumption cursor as a plain ack so the peer trims. The hello
  // precedes the announcement acks so the peer queues its replay before an ack
  // can wake its window-blocked sender: the rebinding side then receives
  // replay-before-fresh and heals without dropping a single frame. The peer
  // replays from its pre-announcement cursor; the over-replay is bounded by
  // the window and deduped by the receiver watermark.
  private func bind(_ continuation: AsyncStream<Frame>.Continuation) -> Int {
    outbound?.finish()
    outbound = continuation
    bindingGeneration += 1
    continuation.yield(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1, execs: execs.values.filter { !$0.exitReceived }.map { $0.start.id })))
    for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
      yieldResume(for: exec, into: continuation)
      if exec.exitReceived { continue }
      continuation.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: exec.start.id, cursor: exec.acknowledgedInbound)))
    }
    return bindingGeneration
  }

  private func yieldResume(for exec: ExecState, into continuation: AsyncStream<Frame>.Continuation) {
    if exec.exitReceived {
      if exec.terminalAckPending, let cursor = exec.exitCursor {
        continuation.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: exec.start.id, cursor: cursor, terminal: true)))
      }
      return
    }
    continuation.yield(Frame(streamID: exec.streamID, opcode: .execStart, payload: exec.start))
    for chunk in exec.sender.replay(above: exec.sender.ackedThrough) {
      continuation.yield(Frame(streamID: exec.streamID, opcode: .stdin, payload: StdinChunk(id: exec.start.id, cursor: chunk.cursor, data: Base64Data(chunk.bytes))))
    }
    if let eof = exec.sender.eofCursor {
      continuation.yield(Frame(streamID: exec.streamID, opcode: .stdinEof, payload: StdinEOF(id: exec.start.id, cursor: eof)))
    }
    if exec.killRequested {
      continuation.yield(Frame(streamID: exec.streamID, opcode: .kill, payload: Kill(id: exec.start.id)))
    }
  }

  private func unbind(_ generation: Int) {
    guard generation == bindingGeneration else { return }
    outbound?.finish()
    outbound = nil
    for waiters in terminalWaiters.values { for waiter in waiters { waiter.finish() } }
    terminalWaiters.removeAll()
  }

  // MARK: Inbound routing

  // The pump is synchronous: it routes by opcode and stream id, leaves output
  // bodies undecoded, and never waits on a per-stream consumer.
  private func route(_ bytes: [UInt8]) {
    let frame: Frame
    do {
      frame = try FrameCodec.decode(bytes)
    } catch {
      yieldControl(.error(error: MachineError(code: .protocolViolation, message: "undecodable frame")))
      return
    }
    switch frame.opcode {
    case .control:
      routeControl(frame)
    case .ack:
      routeAck(frame)
    case .output:
      execsByStream[frame.streamID]?.framesContinuation.yield(frame)
    case .execExit:
      guard let exec = execsByStream[frame.streamID] else { return }
      exec.exitReceived = true
      exec.exitCursor = (try? frame.payload(ExecExit.self))?.cursor
      exec.sender.resumeWaiters()
      exec.framesContinuation.yield(frame)
    case .execStart, .stdin, .stdinEof, .kill:
      break
    }
  }

  private func routeControl(_ frame: Frame) {
    guard let message = try? frame.payload(ControlMessage.self) else { return }
    switch message {
    case .hello:
      // Replay synchronously before later announcement acks can wake a blocked sender.
      guard let outbound else { return }
      for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
        yieldResume(for: exec, into: outbound)
      }
    case .ping, .error:
      break
    }
  }

  private func routeAck(_ frame: Frame) {
    guard let exec = execsByStream[frame.streamID], let ack = try? frame.payload(Ack.self) else { return }
    guard ack.id == exec.start.id else { return }
    exec.sender.acknowledge(through: ack.cursor)
    if !exec.accepted {
      exec.accepted = true
      for waiter in acceptanceWaiters.removeValue(forKey: ack.id) ?? [] { waiter.finish() }
    }
  }

  private func yieldControl(_ message: ControlMessage) {
    outbound?.yield(Frame(streamID: 0, opcode: .control, payload: message))
  }
}

private final class ExecState {
  let streamID: Int
  let start: ExecStart
  var sender: SendState
  let frames: AsyncStream<Frame>
  let framesContinuation: AsyncStream<Frame>.Continuation
  var acknowledgedInbound: Int = 0
  var exitReceived: Bool = false
  /// The peer acknowledged this outgoing exec's start.
  var accepted: Bool = false
  var exitCursor: Int?
  var terminalAckPending: Bool = false
  var killRequested: Bool = false

  init(streamID: Int, start: ExecStart, cursor: Int = 0) {
    self.streamID = streamID
    self.start = start
    sender = SendState(window: start.window ?? ExecDefaults.window, cursor: cursor)
    (frames, framesContinuation) = AsyncStream.makeStream()
  }
}
