import protocol Clocks.NonsendingClock
import Dependencies
import MachineContract

/// Where an incoming exec picks up when its relay already holds part of it durably: output starts at `output`, stdin is taken
/// from `stdin`, and stdin is acknowledged only by `IncomingExec.acknowledgeStdin`, once the relay made it durable.
public struct IncomingResume: Sendable {
  public let output: Int
  public let stdin: Int
  public init(output: Int, stdin: Int) { self.output = output; self.stdin = stdin }
}

public actor ChannelEndpoint {
  public nonisolated let incomingExecs: AsyncStream<IncomingExec>

  private nonisolated let incomingExecsContinuation: AsyncStream<IncomingExec>.Continuation

  private var execs: [ExecID: ExecState] = [:]
  private var execsByStream: [Int: ExecState] = [:]
  var retainedExecCount: Int {
    precondition(execs.count == execsByStream.count)
    return execs.count
  }

  private var nextStreamID: Int = 1
  private var outbound: AsyncStream<Frame>.Continuation?
  private var bindingGeneration: Int = 0

  private let clock: any NonsendingClock<Duration>
  private let expirations: AsyncStream<(ExecID, @Sendable () async throws -> Void, AsyncStream<Void>)>
  private let expirationContinuation: AsyncStream<(ExecID, @Sendable () async throws -> Void, AsyncStream<Void>)>.Continuation
  private var terminalWaiters: [ExecID: [AsyncStream<Void>.Continuation]] = [:]

  private let incomingResume: IncomingResume?

  public init(incomingResume: IncomingResume? = nil) {
    self.incomingResume = incomingResume
    @Dependency(\.continuousClock) var clock
    self.clock = clock
    (expirations, expirationContinuation) = AsyncStream.makeStream()
    (incomingExecs, incomingExecsContinuation) = AsyncStream.makeStream()
  }

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

  // A rejoin after a caller crash starts a fresh endpoint at the retry's
  // durable cursor: the ack announced at bind trims the peer through it, the
  // peer's hello-triggered replay redelivers everything above it, and the
  // consumer skips the over-replay below. Manual acknowledgement lets the
  // consumer defer the ack until the bytes are durable, so "last ack" never
  // runs ahead of what a crash-retry can actually resume from.
  public func startExec(
    _ start: ExecStart,
    resumingFrom cursor: Int = 0,
    autoAcknowledge: Bool = true,
  ) -> OutgoingExec {
    precondition(execs[start.id] == nil, "duplicate exec id \(start.id.rawValue)")
    let streamID = nextStreamID
    nextStreamID += 1
    let exec = ExecState(role: .outgoing, streamID: streamID, start: start)
    exec.acknowledgedInbound = cursor
    execs[start.id] = exec
    execsByStream[streamID] = exec
    outbound?.yield(Frame(streamID: streamID, opcode: .execStart, payload: start))
    if cursor > 0 {
      outbound?.yield(Frame(streamID: streamID, opcode: .ack, payload: Ack(id: start.id, cursor: cursor)))
    }
    return OutgoingExec(
      id: start.id,
      events: ExecEvents(
        endpoint: self,
        id: start.id,
        frames: exec.frames,
        initialConsumed: cursor,
        autoAcknowledge: autoAcknowledge,
      ),
      endpoint: self,
    )
  }

  // MARK: Exec plumbing for the handles

  func sendData(exec id: ExecID, stream: ExecOutputStream?, bytes: [UInt8], waitForCapacity: Bool = true) async throws {
    var index = 0
    while index < bytes.count {
      guard let exec = execs[id] else { return }
      switch exec.role {
      case .outgoing:
        precondition(exec.sender.eofCursor == nil, "stdin after closeStdin")
        if exec.exitReceived { return }
      case .incoming:
        // A send that waited for capacity while the exit was sent ends with it.
        if exec.sender.exit != nil { return }
        if exec.outputStopped {
          exec.outputCut = true
          return
        }
      }
      let room = exec.sender.room
      guard room > 0 else {
        if !waitForCapacity || exec.outputDraining {
          exec.outputCut = true
          // A draining exec's first shortfall ends its output, so nothing sent later leaves a gap in what the caller reads.
          if exec.outputDraining { exec.outputStopped = true }
          return
        }
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        exec.sender.addWaiter(continuation)
        for await _ in signal {}
        try Task.checkCancellation()
        continue
      }
      let take = min(room, bytes.count - index)
      let chunk = exec.sender.append(stream: stream, bytes: Array(bytes[index ..< index + take]))
      index += take
      outbound?.yield(dataFrame(for: exec, chunk: chunk))
    }
  }

  func closeStdin(exec id: ExecID) {
    guard let exec = execs[id], exec.role == .outgoing, exec.sender.eofCursor == nil else { return }
    exec.sender.eofCursor = exec.sender.nextCursor
    guard !exec.exitReceived else { return }
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .stdinEof, payload: StdinEOF(id: id, cursor: exec.sender.nextCursor)))
  }

  func requestKill(exec id: ExecID) {
    guard let exec = execs[id], exec.role == .outgoing, !exec.killRequested else { return }
    exec.killRequested = true
    guard !exec.exitReceived else { return }
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .kill, payload: Kill(id: id)))
  }

  func finish(exec id: ExecID, status: ExitStatus, timedOut: ExecTimeout?) {
    guard let exec = execs[id], exec.role == .incoming, exec.sender.exit == nil else { return }
    exec.sender.exit = status
    exec.timedOut = timedOut
    let (cancelled, cancellation) = AsyncStream<Void>.makeStream()
    exec.retentionCancellation = cancellation
    expirationContinuation.yield((id, expiryWait(clock), cancelled))
    outbound?.yield(exitFrame(for: exec))
  }

  func acknowledgeConsumption(exec id: ExecID, through cursor: Int) {
    guard let exec = execs[id] else { return }
    exec.acknowledgedInbound = max(exec.acknowledgedInbound, cursor)
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: id, cursor: cursor)))
  }

  public func runRetention() async {
    await withDiscardingTaskGroup { group in
      for await (id, wait, cancelled) in expirations {
        group.addTask {
          let expired = await withTaskGroup(of: Bool.self) { race in
            race.addTask {
              do { try await wait(); return true } catch { return false }
            }
            race.addTask {
              for await _ in cancelled {}
              return false
            }
            let expired = await race.next() ?? false
            race.cancelAll()
            return expired
          }
          if expired { await self.retire(id) }
        }
      }
    }
  }

  private func expiryWait<C: NonsendingClock>(_ clock: C) -> @Sendable () async throws -> Void where C.Duration == Duration {
    let deadline = clock.now.advanced(by: .seconds(600))
    return { try await clock.sleep(until: deadline, tolerance: nil, isolation: self) }
  }

  private func retire(_ id: ExecID) {
    guard let exec = execs.removeValue(forKey: id) else { return }
    execsByStream[exec.streamID] = nil
    exec.retentionCancellation?.finish()
    exec.sender.resumeWaiters()
    exec.framesContinuation.finish()
    exec.killsContinuation.finish()
    exec.acksContinuation.finish()
    for waiter in terminalWaiters.removeValue(forKey: id) ?? [] { waiter.finish() }
  }

  @discardableResult
  func stopOutput(exec id: ExecID) -> Int? {
    guard let exec = execs[id], exec.role == .incoming else { return nil }
    exec.outputStopped = true
    exec.outputCut = true
    exec.sender.resumeWaiters()
    return exec.sender.nextCursor
  }

  func drainOutput(exec id: ExecID) {
    guard let exec = execs[id], exec.role == .incoming else { return }
    exec.outputDraining = true
    exec.sender.resumeWaiters()
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

  private func exitFrame(for exec: ExecState) -> Frame {
    Frame(streamID: exec.streamID, opcode: .execExit, payload: ExecExit(
      id: exec.start.id, cursor: exec.sender.nextCursor, status: exec.sender.exit!, outputCut: exec.outputCut ? true : nil,
      timedOut: exec.timedOut,
    ))
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
    continuation.yield(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1, execs: execs.values.filter { $0.role == .outgoing && !$0.exitReceived }.map { $0.start.id })))
    for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
      yieldResume(for: exec, into: continuation)
      if exec.role == .outgoing, exec.exitReceived { continue }
      continuation.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: exec.start.id, cursor: exec.acknowledgedInbound)))
    }
    return bindingGeneration
  }

  private func yieldResume(for exec: ExecState, into continuation: AsyncStream<Frame>.Continuation) {
    if exec.role == .outgoing {
      if exec.exitReceived {
        if exec.terminalAckPending, let cursor = exec.exitCursor {
          continuation.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: exec.start.id, cursor: cursor, terminal: true)))
        }
        return
      }
      continuation.yield(Frame(streamID: exec.streamID, opcode: .execStart, payload: exec.start))
    }
    yieldReplay(for: exec, above: exec.sender.ackedThrough, into: continuation)
  }

  private func unbind(_ generation: Int) {
    guard generation == bindingGeneration else { return }
    outbound?.finish()
    outbound = nil
    for waiters in terminalWaiters.values { for waiter in waiters { waiter.finish() } }
    terminalWaiters.removeAll()
  }

  private func yieldReplay(for exec: ExecState, above cursor: Int, into continuation: AsyncStream<Frame>.Continuation) {
    for chunk in exec.sender.replay(above: cursor) {
      continuation.yield(dataFrame(for: exec, chunk: chunk))
    }
    switch exec.role {
    case .outgoing:
      if let eof = exec.sender.eofCursor {
        continuation.yield(Frame(streamID: exec.streamID, opcode: .stdinEof, payload: StdinEOF(id: exec.start.id, cursor: eof)))
      }
      if exec.killRequested {
        continuation.yield(Frame(streamID: exec.streamID, opcode: .kill, payload: Kill(id: exec.start.id)))
      }
    case .incoming:
      if exec.sender.exit != nil { continuation.yield(exitFrame(for: exec)) }
    }
  }

  private func dataFrame(for exec: ExecState, chunk: SendState.Chunk) -> Frame {
    switch exec.role {
    case .outgoing:
      Frame(
        streamID: exec.streamID,
        opcode: .stdin,
        payload: StdinChunk(id: exec.start.id, cursor: chunk.cursor, data: Base64Data(chunk.bytes)),
      )
    case .incoming:
      Frame(
        streamID: exec.streamID,
        opcode: .output,
        payload: OutputChunk(id: exec.start.id, stream: chunk.stream!, cursor: chunk.cursor, data: Base64Data(chunk.bytes)),
      )
    }
  }

  // MARK: Inbound routing

  // The pump is synchronous: it routes by opcode and stream id, leaves stdin and
  // output bodies undecoded, and never waits on a per-stream consumer.
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
    case .execStart:
      routeExecStart(frame)
    case .ack:
      routeAck(frame)
    case .stdin, .output, .stdinEof:
      execsByStream[frame.streamID]?.framesContinuation.yield(frame)
    case .execExit:
      guard let exec = execsByStream[frame.streamID] else { return }
      exec.exitReceived = true
      exec.exitCursor = (try? frame.payload(ExecExit.self))?.cursor
      exec.sender.resumeWaiters()
      exec.framesContinuation.yield(frame)
    case .kill:
      guard let exec = execsByStream[frame.streamID], exec.role == .incoming, !exec.killDelivered else { return }
      exec.killDelivered = true
      exec.killsContinuation.yield(())
      exec.killsContinuation.finish()
    }
  }

  private func routeControl(_ frame: Frame) {
    guard let message = try? frame.payload(ControlMessage.self) else { return }
    switch message {
    case let .hello(_, scope):
      // Replay synchronously before later announcement acks can wake a blocked sender.
      guard let outbound else { return }
      for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
        if exec.role == .incoming, let scope, !scope.contains(exec.start.id) { continue }
        yieldResume(for: exec, into: outbound)
      }
    case .ping, .error:
      break
    }
  }

  private func routeExecStart(_ frame: Frame) {
    guard let start = try? frame.payload(ExecStart.self) else {
      yieldControl(.error(error: MachineError(code: .protocolViolation, message: "malformed exec-start")))
      return
    }
    // Idempotent by exec id: a retransmitted start after a blip is dropped here,
    // so the consumer sees at most one IncomingExec per id.
    guard execs[start.id] == nil else { return }
    guard execsByStream[frame.streamID] == nil else {
      yieldControl(.error(error: MachineError(code: .protocolViolation, message: "stream id \(frame.streamID) in use")))
      return
    }
    let exec = ExecState(role: .incoming, streamID: frame.streamID, start: start, cursor: incomingResume?.output ?? 0)
    exec.acknowledgedInbound = incomingResume?.stdin ?? 0
    execs[start.id] = exec
    execsByStream[frame.streamID] = exec
    nextStreamID = max(nextStreamID, frame.streamID + 1)
    if exec.acknowledgedInbound > 0 {
      outbound?.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: start.id, cursor: exec.acknowledgedInbound)))
    }
    incomingExecsContinuation.yield(IncomingExec(
      start: start,
      stdin: StdinStream(endpoint: self, id: start.id, frames: exec.frames, initialConsumed: exec.acknowledgedInbound, autoAcknowledge: incomingResume == nil),
      kills: exec.kills,
      acknowledgements: exec.acks,
      endpoint: self,
    ))
  }

  private func routeAck(_ frame: Frame) {
    guard let exec = execsByStream[frame.streamID], let ack = try? frame.payload(Ack.self) else { return }
    guard ack.id == exec.start.id else { return }
    exec.sender.acknowledge(through: ack.cursor)
    if exec.role == .incoming { exec.acksContinuation.yield(exec.sender.ackedThrough) }
    if exec.role == .incoming, exec.sender.exit != nil, ack.terminal == true, ack.cursor == exec.sender.nextCursor {
      retire(ack.id)
    }
  }

  private func yieldControl(_ message: ControlMessage) {
    outbound?.yield(Frame(streamID: 0, opcode: .control, payload: message))
  }
}

private final class ExecState {
  enum Role {
    case outgoing
    case incoming
  }

  let role: Role
  let streamID: Int
  let start: ExecStart
  var sender: SendState
  let frames: AsyncStream<Frame>
  let framesContinuation: AsyncStream<Frame>.Continuation
  let kills: AsyncStream<Void>
  let killsContinuation: AsyncStream<Void>.Continuation
  let acks: AsyncStream<Int>
  let acksContinuation: AsyncStream<Int>.Continuation
  var acknowledgedInbound: Int = 0
  var exitReceived: Bool = false
  var exitCursor: Int?
  var terminalAckPending: Bool = false
  var retentionCancellation: AsyncStream<Void>.Continuation?
  var outputStopped: Bool = false
  var outputDraining: Bool = false
  var outputCut: Bool = false
  var timedOut: ExecTimeout?
  var killRequested: Bool = false
  var killDelivered: Bool = false

  init(role: Role, streamID: Int, start: ExecStart, cursor: Int = 0) {
    self.role = role
    self.streamID = streamID
    self.start = start
    sender = SendState(window: start.window ?? ExecDefaults.window, cursor: cursor)
    (frames, framesContinuation) = AsyncStream.makeStream()
    (kills, killsContinuation) = AsyncStream.makeStream()
    (acks, acksContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }
}
