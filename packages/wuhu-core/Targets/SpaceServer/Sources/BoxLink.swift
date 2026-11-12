import Dependencies
import Fetch
import OperationClient
import OperationProtocol
import SpaceCore
import TaskLifetime
import Tracing
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct BoxLink: Sendable {
  private enum Event: Sendable {
    case request(BoxSocket.Outgoing)
    case finished(BoxTag, UUID)
  }

  private let machine: String
  private let peer: Peer<BoxSocket>
  private let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let buffers: MachineBuffers
  private let authorizeStart: @Sendable () async throws -> Void
  private let prepare: @Sendable (MachineExec) async throws -> StartRequest

  init?(worker: Worker, machine: String, pubkey: String, connection: UUID, streams: Int, buffers: MachineBuffers, authorizeStart: @escaping @Sendable () async throws -> Void = {}, prepare: @escaping @Sendable (MachineExec) async throws -> StartRequest) {
    let (events, continuation) = AsyncStream<Event>.makeStream()
    guard let peer = worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: connection, pubkey: pubkey, streams: streams), output: {
      switch $0 {
      case let .frame(frame): continuation.yield(.request(frame))
      case .closed: continuation.finish()
      }
    }) else { return nil }
    self.machine = machine; self.peer = peer; self.events = events; self.continuation = continuation; self.buffers = buffers; self.authorizeStart = authorizeStart; self.prepare = prepare
  }

  func close() { peer.close(); continuation.finish() }

  func run(client: FetchClient) async {
    let scope = TaskScope()
    var flights: [BoxTag: (UUID, Task<Void, Never>)] = [:]
    @Dependency(\.tracer) var tracer
    let link = MachineLink(origin: URL(string: "https://machine-v2.internal")!, fetch: client, clock: .continuous, ids: { UUID() }, tracer: tracer)
    await withTaskCancellationHandler {
      for await event in events {
        switch event {
        case let .request(request):
          flights[request.tag]?.1.cancel()
          let ticket = UUID()
          let task = try! scope.run("box-exchange") {
            let answer = await exchange(request.exchange, link: link)
            if !Task.isCancelled { peer.send(.init(tag: request.tag, answer: answer)) }
            else if case let .snapshot(snapshot) = answer, let pointer = snapshot.output { buffers.release(pointer) }
            continuation.yield(.finished(request.tag, ticket))
          }
          flights[request.tag] = (ticket, task)
        case let .finished(tag, ticket):
          if flights[tag]?.0 == ticket { flights[tag] = nil }
        }
      }
    } onCancel: { close() }
    await scope.close()
  }

  func exchange(_ exchange: BoxExchange, link: MachineLink) async -> BoxAnswer {
    let correlation: UUID?
    let request: MachineExchange
    let body: Body?
    var hold = 0
    do {
      switch exchange {
      case .start, .startFile: try await authorizeStart()
      case .describe, .poll, .stop, .input, .fileInput: break
      }
      switch exchange {
      case .describe: correlation = nil; request = .describe; body = nil
      case let .start(exec):
        correlation = exec.operation; request = .start(exec.operation)
        body = try .json(try await prepare(exec))
      case let .startFile(op, start):
        correlation = op; request = .start(op); body = try .json(start)
      case let .poll(op, channel, after, holdMs, terminal, limit):
        correlation = op; hold = holdMs
        var query = [URLQueryItem(name: "holdMs", value: String(holdMs)), URLQueryItem(name: "limit", value: String(limit))]
        if let channel { query += [.init(name: "channel", value: channel), .init(name: "after", value: String(after))] }
        if let terminal { query.append(.init(name: "terminalAck", value: terminal.uuidString)) }
        request = .poll(op, query: query); body = nil
      case let .stop(op, reason): correlation = op; request = .stop(op); body = try .json(StopRequest(reason: reason))
      case let .input(op, pointer, end):
        correlation = op; request = .input(op, channel: "stdin")
        guard let bytes = buffers.read(pointer) else { return .transport(.init(.requestCancelled, message: "Stdin buffer belonged to a previous worker")) }
        body = try .json(WriteRequest(offset: .init(rawValue: pointer.from), payload: .init(data: bytes), end: end))
      case let .fileInput(op, pointer, end):
        correlation = op; request = .input(op, channel: pointer.channel)
        guard let payload = buffers.payload(pointer) else { return .transport(.init(.requestCancelled, message: "File input buffer belonged to a previous worker")) }
        body = try .json(WriteRequest(offset: .init(rawValue: pointer.from), payload: payload, end: end))
      }
    } catch { return .preparation(error as? OperationError ?? .init(.invalidInput, message: String(describing: error))) }
    let deadline = Duration.milliseconds(hold + 5000)
    switch exchange {
    case .describe:
      let answer = await link.send(MachineDescription.self, machine, request, correlation: correlation, deadline: deadline, limit: OperationLimits.responseBytes)
      switch answer.result {
      case let .success(description): return .description(description)
      case let .failure(error): return answer.answered ? .box(error) : .transport(error)
      }
    case .input, .fileInput:
      let answer = await link.send(WriteReceipt.self, machine, request, body: body, correlation: correlation, deadline: deadline, limit: OperationLimits.responseBytes)
      switch answer.result {
      case let .success(receipt): return .input(receipt)
      case let .failure(error): return answer.answered ? .box(error) : .transport(error)
      }
    case .start, .startFile, .poll, .stop:
      let answer = await link.send(OperationSnapshot.self, machine, request, body: body, correlation: correlation, deadline: deadline, limit: OperationLimits.responseBytes)
      switch answer.result {
      case let .failure(error): return answer.answered ? .box(error) : .transport(error)
      case let .success(snapshot):
        let stripped = OperationSnapshot(operation: snapshot.operation, verdict: snapshot.verdict, terminalToken: snapshot.terminalToken, finalOffsets: snapshot.finalOffsets, outputConsumed: snapshot.outputConsumed, channel: snapshot.channel, from: snapshot.from, through: snapshot.through, channelEnd: snapshot.channelEnd, bufferReservationBytes: snapshot.bufferReservationBytes)
        guard let channel = snapshot.channel else { return .snapshot(.init(snapshot: stripped)) }
        guard let payload = snapshot.payload, (payload.data != nil) != (payload.records != nil), let from = snapshot.from, let through = snapshot.through,
              through >= from, through.rawValue - from.rawValue == UInt64(payload.count), payload.byteCount <= 64 * 1024
        else { return .box(.init(.invalidResponse)) }
        let pointer = payload.count == 0 ? nil : buffers.put(payload: payload, operation: snapshot.operation, channel: channel, from: from.rawValue)
        if payload.count != 0 && pointer == nil { return .transport(.init(.capacityExceeded, message: "Worker output window is full")) }
        let tail = ["stdout", "stderr"].contains(channel) ? Data((payload.data ?? Data()).suffix(51200)) : Data()
        return .snapshot(.init(snapshot: stripped, output: pointer, tail: tail))
      }
    }
  }
}
