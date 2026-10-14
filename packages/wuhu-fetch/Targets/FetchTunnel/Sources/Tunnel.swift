#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch

public struct Tunnel: Sendable {
  private let state: TunnelState

  public init(over transport: TunnelTransport, limits: TunnelLimits = .init()) throws {
    try limits.validate(maxMessageBytes: transport.maxMessageBytes)
    state = TunnelState(transport: transport, limits: limits, handler: nil)
  }

  public var client: FetchClient { FetchClient { try await state.fetch($0) } }
  public func run() async throws { try await state.run() }
  public func abort() async { await state.close(.cancelled) }

  public static func serve(
    over transport: TunnelTransport,
    limits: TunnelLimits = .init(),
    handler: @escaping @Sendable (Request) async throws -> Response,
  ) async throws {
    try limits.validate(maxMessageBytes: transport.maxMessageBytes)
    try await TunnelState(transport: transport, limits: limits, handler: handler).run()
  }
}

actor TunnelState {
  struct Exchange {
    var head: Head?
    var body = Bytes()
    var reply: AsyncThrowingStream<Response, any Error>.Continuation?
    var cancellation: AsyncStream<Void>.Continuation?
    var receiving = true
  }

  let transport: TunnelTransport
  let limits: TunnelLimits
  let handler: (@Sendable (Request) async throws -> Response)?
  var exchanges: [UInt64: Exchange] = [:]
  var outbox = FairOutbox()
  var nextID: UInt64 = 1
  var highestPeerID: UInt64 = 0
  var jobs: Set<UInt64> = []
  var preparing = 0
  let work: AsyncStream<Work>
  let workSignal: AsyncStream<Work>.Continuation
  var running = false
  var failure: TunnelError?
  let wake: AsyncStream<Void>
  let signal: AsyncStream<Void>.Continuation

  init(transport: TunnelTransport, limits: TunnelLimits, handler: (@Sendable (Request) async throws -> Response)?) {
    self.transport = transport
    self.limits = limits
    self.handler = handler
    (wake, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (work, workSignal) = AsyncStream.makeStream()
  }

  func fetch(_ request: Request) async throws -> Response {
    guard handler == nil else { throw TunnelError.protocolViolation }
    if let failure { throw failure }
    guard exchanges.count + preparing < limits.streams else { throw TunnelError.capacityExceeded }
    preparing += 1
    let body: Bytes
    do { body = try await collect(request.body ?? .empty) } catch { preparing -= 1; throw error }
    preparing -= 1
    try Task.checkCancellation()
    if let failure { throw failure }
    guard nextID < UInt64.max else { close(.connectionClosed); throw TunnelError.connectionClosed }
    let id = nextID
    nextID += 1
    let (replies, reply) = AsyncThrowingStream<Response, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    exchanges[id] = Exchange(reply: reply)
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        guard exchanges[id] != nil else { throw failure ?? .cancelled }
        enqueue(try frames(id: id, kind: .request, head: Head(request, count: body.count), body: body, limits: limits), id: id)
        var iterator = replies.makeAsyncIterator()
        guard let response = try await iterator.next() else { throw TunnelError.connectionClosed }
        return response
      } catch {
        let error = Task.isCancelled ? TunnelError.cancelled : map(error)
        if exchanges[id] != nil { abortStream(id, error: error, notify: true) }
        throw error
      }
    } onCancel: {
      Task { await self.cancelCall(id) }
    }
  }

  func run() async throws {
    guard !running else { throw TunnelError.alreadyRunning }
    if let failure { throw failure }
    running = true
    defer { close(failure ?? .connectionClosed) }
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.sendLoop() }
        group.addTask { try await self.receiveLoop() }
        group.addTask { try await self.workLoop() }
        do {
          _ = try await group.next()
          close(.connectionClosed)
          group.cancelAll()
          try await group.waitForAll()
        } catch {
          close(map(error))
          group.cancelAll()
          throw error
        }
      }
    } onCancel: { transport.abort() }
    throw failure ?? .connectionClosed
  }

  func close(_ error: TunnelError) {
    guard failure == nil else { return }
    failure = error
    for exchange in exchanges.values {
      exchange.reply?.finish(throwing: error)
      exchange.cancellation?.yield(())
      exchange.cancellation?.finish()
    }
    exchanges.removeAll()
    outbox = FairOutbox()
    signal.finish()
    workSignal.finish()
    transport.abort()
  }

  private func collect(_ body: Body) async throws -> Bytes {
    if let length = body.contentLength, length < 0 || length > limits.bodyBytes { throw TunnelError.bodyTooLarge }
    do { return try await body.bytes(upTo: limits.bodyBytes) }
    catch FetchError.bodyLimitExceeded { throw TunnelError.bodyTooLarge }
  }

  private func enqueue(_ frames: [Frame], id: UInt64) {
    guard failure == nil else { return }
    outbox.enqueue(frames, id: id)
    signal.yield(())
  }

  private func sendLoop() async throws {
    do {
      for await _ in wake {
        while let frame = outbox.next() {
          try Task.checkCancellation()
          try await transport.send(frame.encoded())
          sent(frame)
        }
      }
    } catch {
      close(map(error))
      throw error
    }
  }

  private func sent(_ frame: Frame) {
    if handler != nil && frame.kind == .end { exchanges[frame.id] = nil }
  }

  struct Work: Sendable { var request: Request; var id: UInt64; var cancellation: AsyncStream<Void> }

  private func receiveLoop() async throws {
    while let bytes = try await transport.receive() {
      do {
        let frame = try Frame.decode(bytes, limits: limits)
        if let work = try receive(frame) { workSignal.yield(work) }
      } catch let fault as StreamFault {
        if handler != nil && fault.openingRequest { highestPeerID = max(highestPeerID, fault.id) }
        abortStream(fault.id, error: fault.error, notify: true)
      }
    }
  }

  private func workLoop() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      var pending = 0
      for await work in self.work {
        group.addTask { await self.perform(work.request, id: work.id, cancellation: work.cancellation) }
        pending += 1
        if pending == limits.streams { _ = try await group.next(); pending -= 1 }
      }
      group.cancelAll()
      try await group.waitForAll()
    }
  }

  func receive(_ frame: Frame) throws -> Work? {
    if frame.kind == .request {
      guard handler != nil, frame.id > highestPeerID else { throw StreamFault(id: frame.id, error: .protocolViolation) }
      highestPeerID = frame.id
      guard Set(exchanges.keys).union(jobs).count < limits.streams else { throw StreamFault(id: frame.id, error: .capacityExceeded) }
      exchanges[frame.id] = Exchange()
    }
    if frame.kind == .chunk {
      guard exchanges[frame.id]?.receiving == true, let head = exchanges[frame.id]?.head, let length = head.length,
            !frame.payload.isEmpty, frame.payload.count <= length - exchanges[frame.id]!.body.count,
            head.bodyPresent else { throw StreamFault(id: frame.id, error: .protocolViolation) }
      exchanges[frame.id]!.body.append(frame.payload)
      return nil
    }
    guard var exchange = exchanges[frame.id] else {
      if frame.kind == .abort { return nil }
      throw StreamFault(id: frame.id, error: .protocolViolation)
    }
    do {
      switch frame.kind {
      case .request, .response:
        guard exchange.head == nil, exchange.receiving, (frame.kind == .request) == (handler != nil) else { throw TunnelError.protocolViolation }
        let head = try JSONDecoder().decode(Head.self, from: frame.payload)
        guard let length = head.length, length >= 0, length <= limits.bodyBytes else { throw TunnelError.bodyTooLarge }
        _ = try head.fields()
        if handler != nil { _ = try head.request(body: .init()) } else { _ = try head.response(body: .init()) }
        exchange.head = head
        exchange.body.reserveCapacity(length)
      case .chunk:
        preconditionFailure("chunks are accumulated in place before copying exchange state")
      case .end:
        guard exchange.receiving, let head = exchange.head, head.length == exchange.body.count else { throw TunnelError.protocolViolation }
        exchange.receiving = false
        if handler == nil {
          let response = try head.response(body: exchange.body)
          exchanges[frame.id] = nil
          outbox.remove(frame.id)
          exchange.reply?.yield(response)
          exchange.reply?.finish()
          return nil
        }
        let (cancellation, cancel) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        exchange.cancellation = cancel
        jobs.insert(frame.id)
        exchanges[frame.id] = exchange
        return Work(request: try head.request(body: exchange.body), id: frame.id, cancellation: cancellation)
      case .abort:
        let error = TunnelError(rawValue: String(decoding: frame.payload, as: UTF8.self)) ?? .protocolViolation
        abortStream(frame.id, error: error, notify: false)
        return nil
      }
      exchanges[frame.id] = exchange
      return nil
    } catch {
      throw StreamFault(id: frame.id, error: error as? TunnelError ?? .protocolViolation)
    }
  }

  private func perform(_ request: Request, id: UInt64, cancellation: AsyncStream<Void>) async {
    defer { jobs.remove(id) }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          let response = try await self.handler!(request)
          let body = try await self.collect(response.body)
          try await self.respond(response, body: body, id: id)
        }
        group.addTask {
          for await _ in cancellation { throw TunnelError.cancelled }
        }
        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      if exchanges[id] != nil {
        abortStream(id, error: error is TunnelError || error is CancellationError ? map(error) : .handlerFailed, notify: true)
      }
    }
  }

  private func respond(_ response: Response, body: Bytes, id: UInt64) throws {
    guard exchanges[id] != nil else { return }
    enqueue(try frames(id: id, kind: .response, head: Head(response, count: body.count), body: body, limits: limits), id: id)
  }

  private func cancelCall(_ id: UInt64) {
    guard exchanges[id] != nil else { return }
    abortStream(id, error: .cancelled, notify: true)
  }

  private func abortStream(_ id: UInt64, error: TunnelError, notify: Bool) {
    let exchange = exchanges.removeValue(forKey: id)
    exchange?.reply?.finish(throwing: error)
    exchange?.cancellation?.yield(())
    exchange?.cancellation?.finish()
    if outbox.isAborting(id) { return }
    outbox.remove(id)
    guard notify, failure == nil else { return }
    // One bounded control slot per stream; hostile unknown ids cannot fill a queue.
    guard outbox.abortCount < limits.streams else { close(.capacityExceeded); return }
    enqueue([Frame(kind: .abort, id: id, payload: Bytes(error.rawValue.utf8))], id: id)
  }

  private func map(_ error: any Error) -> TunnelError {
    if let error = error as? TunnelError { return error }
    if error is CancellationError { return .cancelled }
    return .transportFailure
  }
}
