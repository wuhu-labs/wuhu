#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import MachineChannel
import MachineContract
import Serve
import SpaceCore
import Synchronization
import Wuwei

struct ExecSocketLink: Sendable {
  let space: Space
  let record: ExecRecord
  let leg: ExecLeg

  func run(_ socket: WebSocket) async {
    @Dependency(\.uuid) var uuid
    let nonce = uuid()
    let transport = WebSocketTransport(socket)
    defer { transport.close() }
    do {
      try await transport.send(FrameCodec.encode(Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1))))
      var iterator = transport.inbound.makeAsyncIterator()
      while let bytes = await iterator.next() {
        let frame = try FrameCodec.decode(bytes)
        guard frame.opcode == .execStart else { continue }
        let start = try frame.payload(ExecStart.self)
        guard start.id == record.id, start.secretValues == nil, start.session == nil,
              var request = try await space.execRequest(record.id) else { return }
        request.argv = start.command; request.cwd = start.cwd; request.stdin = true
        request.env = start.env?.entries ?? [:]; request.secrets = start.secrets?.entries ?? [:]
        request.window = start.window ?? ExecDefaults.window; request.maxOutput = start.maxOutput; request.timeout = start.timeout
        request.session = leg.session?.rawValue == record.caller ? leg.session : nil
        request.attribution = await space.startCaller(leg.session)
        let buffers = space.machineBuffers
        let (events, continuation) = AsyncStream<ExecStream.Outgoing>.makeStream()
        guard let peer = space.worker.attach(ExecStream.self, to: MachineCell.ID(record.machine.rawValue), opening: .init(exec: request, nonce: nonce), output: {
          switch $0 {
          case let .frame(frame): continuation.yield(frame)
          case .closed: continuation.finish()
          }
        }) else { return }
        let admitted = Mutex(false)
        defer {
          peer.close()
          if admitted.withLock({ $0 }) { buffers.discard(request.operation) }
        }
        let streamID = frame.streamID
        let operation = request.operation
        let (terminal, acknowledged) = AsyncStream<Void>.makeStream()
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            do {
              var ended = false
              for await event in events {
                let frame: Frame
                switch event {
                case let .accepted(offset):
                  admitted.withLock { $0 = true }
                  frame = Frame(streamID: streamID, opcode: .ack, payload: Ack(id: record.id, cursor: Int(offset)))
                case let .output(pointer, cursor):
                  guard let bytes = buffers.read(pointer) else { continue }
                  frame = Frame(streamID: streamID, opcode: .output, payload: OutputChunk(id: record.id, stream: pointer.channel == "stderr" ? .stderr : .stdout, cursor: cursor - bytes.count, data: Base64Data(Array(bytes))))
                case let .exit(end):
                  ended = true
                  var cursor = end.cursor
                  if let error = end.error {
                    let diagnostic = Array("\(error.code.rawValue): \(error.message)\n".utf8)
                    try await transport.send(FrameCodec.encode(Frame(streamID: streamID, opcode: .output, payload: OutputChunk(id: record.id, stream: .stderr, cursor: cursor, data: Base64Data(diagnostic)))))
                    cursor += diagnostic.count
                  }
                  frame = Frame(streamID: streamID, opcode: .execExit, payload: ExecExit(id: record.id, cursor: cursor, status: end.status ?? .exited(code: 1), outputCut: end.cut ? true : nil, timedOut: end.timedOut))
                }
                try await transport.send(FrameCodec.encode(frame))
              }
              if ended { for await _ in terminal {} }
            } catch {}
          }
          group.addTask {
            for await bytes in transport.inbound {
              do {
                let frame = try FrameCodec.decode(bytes)
                guard frame.streamID == streamID else { continue }
                switch frame.opcode {
                case .stdin:
                  let chunk = try frame.payload(StdinChunk.self)
                  guard chunk.id == record.id, chunk.cursor >= 0, chunk.data.bytes.count <= 65536 else { return }
                  guard let pointer = buffers.put(Data(chunk.data.bytes), operation: operation, channel: "stdin", from: UInt64(chunk.cursor)) else { return }
                  peer.send(.stdin(pointer))
                case .stdinEof:
                  let eof = try frame.payload(StdinEOF.self)
                  guard eof.id == record.id, eof.cursor >= 0 else { return }
                  peer.send(.eof(UInt64(eof.cursor)))
                case .ack:
                  let ack = try frame.payload(Ack.self)
                  guard ack.id == record.id else { return }
                  if ack.terminal == true { acknowledged.finish(); return }
                  peer.send(.consumed(ack.cursor))
                case .kill: peer.send(.kill)
                case .control, .execStart, .output, .execExit: break
                }
              } catch { return }
            }
          }
          _ = await group.next()
          group.cancelAll()
          transport.close()
        }
        return
      }
    } catch {}
  }
}
