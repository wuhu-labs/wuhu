import JSONValue
import MachineContract

public actor ChannelEndpoint {
  public nonisolated let incomingExecs: AsyncStream<IncomingExec>
  public nonisolated let inboundRequests: AsyncStream<InboundRequest>

  private nonisolated let incomingExecsContinuation: AsyncStream<IncomingExec>.Continuation
  private nonisolated let inboundRequestsContinuation: AsyncStream<InboundRequest>.Continuation

  private var execs: [ExecID: ExecState] = [:]
  private var execsByStream: [Int: ExecState] = [:]
  private var nextStreamID: Int = 1
  var nextRequestID: Int = 1
  var pendingRequests: [Int: AsyncThrowingStream<Frame, any Error>.Continuation] = [:]
  var outbound: AsyncStream<Frame>.Continuation?
  private var bindingGeneration: Int = 0

  public init() {
    (incomingExecs, incomingExecsContinuation) = AsyncStream.makeStream()
    (inboundRequests, inboundRequestsContinuation) = AsyncStream.makeStream()
  }

  public func run(_ transport: some FrameTransport) async {
    let (frames, continuation) = AsyncStream<Frame>.makeStream()
    let generation = bind(continuation)
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await frame in frames {
          do {
            try await transport.send(FrameCodec.encode(frame))
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

  func sendData(exec id: ExecID, stream: ExecOutputStream?, bytes: [UInt8]) async throws {
    var index = 0
    while index < bytes.count {
      guard let exec = execs[id] else { return }
      switch exec.role {
      case .outgoing:
        precondition(exec.sender.eofCursor == nil, "stdin after closeStdin")
        if exec.exitReceived { return }
      case .incoming:
        precondition(exec.sender.exit == nil, "output after exit")
      }
      let room = exec.sender.room
      guard room > 0 else {
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

  func finish(exec id: ExecID, status: ExitStatus) {
    guard let exec = execs[id], exec.role == .incoming, exec.sender.exit == nil else { return }
    exec.sender.exit = status
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .execExit, payload: ExecExit(id: id, cursor: exec.sender.nextCursor, status: status)))
  }

  func acknowledgeConsumption(exec id: ExecID, through cursor: Int) {
    guard let exec = execs[id] else { return }
    exec.acknowledgedInbound = max(exec.acknowledgedInbound, cursor)
    outbound?.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: id, cursor: cursor)))
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
    continuation.yield(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1)))
    for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
      if exec.role == .outgoing, exec.exitReceived { continue }
      yieldResume(for: exec, into: continuation)
      continuation.yield(Frame(streamID: exec.streamID, opcode: .ack, payload: Ack(id: exec.start.id, cursor: exec.acknowledgedInbound)))
    }
    return bindingGeneration
  }

  private func yieldResume(for exec: ExecState, into continuation: AsyncStream<Frame>.Continuation) {
    if exec.role == .outgoing {
      continuation.yield(Frame(streamID: exec.streamID, opcode: .execStart, payload: exec.start))
    }
    yieldReplay(for: exec, above: exec.sender.ackedThrough, into: continuation)
  }

  private func unbind(_ generation: Int) {
    guard generation == bindingGeneration else { return }
    outbound?.finish()
    outbound = nil
    failPendingRequests(with: ChannelError.severed)
  }

  func failPendingRequests(with error: any Error) {
    for continuation in pendingRequests.values {
      continuation.finish(throwing: error)
    }
    pendingRequests.removeAll()
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
      if let exit = exec.sender.exit {
        continuation.yield(Frame(streamID: exec.streamID, opcode: .execExit, payload: ExecExit(id: exec.start.id, cursor: exec.sender.nextCursor, status: exit)))
      }
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
      exec.sender.resumeWaiters()
      exec.framesContinuation.yield(frame)
    case .kill:
      guard let exec = execsByStream[frame.streamID], exec.role == .incoming, !exec.killDelivered else { return }
      exec.killDelivered = true
      exec.killsContinuation.yield(())
      exec.killsContinuation.finish()
    case .vfsResponse, .searchResponse:
      routeResponse(frame)
    case .vfsRequest, .searchRequest:
      routeRequest(frame)
    }
  }

  private func routeControl(_ frame: Frame) {
    guard let message = try? frame.payload(ControlMessage.self) else { return }
    switch message {
    case .hello:
      // The peer (re)connected. Any in-flight response may have died with the
      // peer's old binding, so pending round trips fail instead of hanging.
      // Live execs resume exactly as at bind — including the exec-start
      // retransmit, or a start dropped during the peer's outage would never
      // spawn. The resume must stay synchronous within this actor turn: the
      // peer's announcement acks arrive after its hello, and an ack that wakes
      // a window-blocked sendData does so only in a later turn, so a fresh
      // chunk always follows the replay queued here.
      failPendingRequests(with: ChannelError.severed)
      guard let outbound else { return }
      for exec in execs.values.sorted(by: { $0.streamID < $1.streamID }) {
        if exec.role == .outgoing, exec.exitReceived { continue }
        yieldResume(for: exec, into: outbound)
      }
    case .ping:
      break
    case let .error(error):
      failPendingRequests(with: ChannelError.remote(error))
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
    let exec = ExecState(role: .incoming, streamID: frame.streamID, start: start)
    execs[start.id] = exec
    execsByStream[frame.streamID] = exec
    nextStreamID = max(nextStreamID, frame.streamID + 1)
    incomingExecsContinuation.yield(IncomingExec(
      start: start,
      stdin: StdinStream(endpoint: self, id: start.id, frames: exec.frames),
      kills: exec.kills,
      endpoint: self,
    ))
  }

  private func routeAck(_ frame: Frame) {
    guard let exec = execsByStream[frame.streamID], let ack = try? frame.payload(Ack.self) else { return }
    exec.sender.acknowledge(through: ack.cursor)
  }

  private func routeResponse(_ frame: Frame) {
    guard let id = frame.requestID, let continuation = pendingRequests.removeValue(forKey: id) else { return }
    continuation.yield(frame)
    continuation.finish()
  }

  private func routeRequest(_ frame: Frame) {
    let request: InboundRequest? = switch frame.opcode {
    case .vfsRequest: (try? frame.payload(VFSRequest.self)).map(InboundRequest.vfs)
    case .searchRequest: (try? frame.payload(SearchRequest.self)).map(InboundRequest.search)
    default: nil
    }
    guard let request else {
      yieldControl(.error(error: MachineError(code: .protocolViolation, message: "malformed \(frame.opcode.rawValue)")))
      return
    }
    inboundRequestsContinuation.yield(request)
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
  var acknowledgedInbound: Int = 0
  var exitReceived: Bool = false
  var killRequested: Bool = false
  var killDelivered: Bool = false

  init(role: Role, streamID: Int, start: ExecStart) {
    self.role = role
    self.streamID = streamID
    self.start = start
    sender = SendState(window: start.window ?? ExecDefaults.window)
    (frames, framesContinuation) = AsyncStream.makeStream()
    (kills, killsContinuation) = AsyncStream.makeStream()
  }
}
