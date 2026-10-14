#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationTrace

actor ExchangeLedger {
  struct Entry {
    let worker: Task<Void, Never>
    let timer: Task<Void, Never>
    let request: Request
    let began: Duration
    var waiter: AsyncStream<Result<Data, OperationError>>.Continuation?
  }

  let fetch: FetchClient
  let clock: OperationClock
  let abort: @Sendable (UUID) -> Void
  var entries: [UUID: Entry] = [:]
  let capacity: Int
  let trace: @Sendable (OperationTrace) throws -> Void
  init(fetch: FetchClient, clock: OperationClock, capacity: Int, abort: @escaping @Sendable (UUID) -> Void, trace: @escaping @Sendable (OperationTrace) throws -> Void) {
    self.fetch = fetch; self.clock = clock; self.capacity = capacity; self.abort = abort; self.trace = trace
  }

  func exchange(_ request: Request, id: UUID, timeout: Duration, limit: Int) async throws -> Data {
    guard entries.count < capacity else { throw OperationError(.capacityExceeded) }
    let (stream, waiter) = AsyncStream<Result<Data, OperationError>>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let began = clock.now()
    try record(request, id: id, began: began, event: .dispatch)
    let worker = Task {
      let result: Result<Data, OperationError>
      do {
        let response = try await fetch(request)
        if Task.isCancelled {
          expire(id, code: .requestCancelled); complete(id, result: .failure(.init(.requestCancelled))); return
        }
        guard entries[id]?.waiter != nil else { complete(id, result: .failure(.init(.requestDeadline))); return }
        try record(request, id: id, began: began, event: .head, status: response.status.code)
        let bytes = try await response.body.data(upTo: limit)
        guard response.headers[.init("X-Wuhu-Correlation-ID")!] == request.headers["X-Wuhu-Correlation-ID"],
              response.headers[.init("X-Wuhu-Request-ID")!] == request.headers["X-Wuhu-Request-ID"],
              response.headers[.init("X-Wuhu-Agent-Instance")!].flatMap(UUID.init(uuidString:)) != nil
        else {
          throw OperationError(.invalidResponse)
        }
        if response.status.code >= 400 {
          result = .failure(try JSONDecoder().decode(ErrorEnvelope.self, from: bytes).error)
        } else { result = .success(bytes) }
      } catch { result = .failure(error as? OperationError ?? .init(.transport, message: String(describing: error))) }
      complete(id, result: result)
    }
    let timer = Task {
      do { try await clock.sleep(timeout) } catch { return }
      expire(id)
    }
    entries[id] = .init(worker: worker, timer: timer, request: request, began: began, waiter: waiter)
    return try await withTaskCancellationHandler {
      for await answer in stream { return try answer.get() }
      throw OperationError(.requestCancelled)
    } onCancel: { Task { await self.expire(id, code: .requestCancelled) } }
  }

  func complete(_ id: UUID, result: Result<Data, OperationError>) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.timer.cancel()
    guard entry.waiter != nil else { return }
    do {
      switch result {
      case .success: try record(entry.request, id: id, began: entry.began, event: .complete)
      case let .failure(error): try record(entry.request, id: id, began: entry.began, event: error.code == .requestCancelled ? .cancelled : .failure, error: error.code)
      }
      entry.waiter?.yield(result)
    } catch { entry.waiter?.yield(.failure(.init(.traceUnavailable))) }
    entry.waiter?.finish()
  }

  func expire(_ id: UUID, code: OperationError.Code = .requestDeadline) {
    guard var entry = entries[id], let waiter = entry.waiter else { return }
    entry.waiter = nil; entries[id] = entry
    entry.worker.cancel(); entry.timer.cancel()
    do { try record(entry.request, id: id, began: entry.began, event: code == .requestCancelled ? .cancelled : .deadline, error: code)
      waiter.yield(.failure(.init(code)))
    } catch { waiter.yield(.failure(.init(.traceUnavailable))) }
    waiter.finish()
    abort(id)
  }

  func record(
    _ request: Request,
    id: UUID,
    began: Duration,
    event: OperationTrace.Event,
    status: Int? = nil,
    error: OperationError.Code? = nil,
  ) throws {
    do { try trace(.init(
      request: id,
      correlation: request.headers["X-Wuhu-Correlation-ID"] ?? "",
      path: request.url.path,
      event: event,
      elapsed: clock.now() - began,
      status: status,
      error: error,
    )) } catch { throw OperationError(.traceUnavailable) }
  }

  func shutdown() {
    for id in entries.keys { expire(id, code: .requestCancelled) }
  }
}
