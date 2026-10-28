#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import enum OperationProtocol.OperationPreparation
import struct OperationProtocol.OperationTrace
import Synchronization
import TaskLifetime

/// What one exchange came back with. `answered` says the machine itself answered (its instance header was valid), so the
/// operation's lease was renewed, even when the answer is a typed error.
struct Exchanged<T: Sendable>: Sendable {
  let result: Result<T, OperationError>
  let answered: Bool
}

/// One request to one machine, with a real deadline: the caller is answered when the deadline passes, whatever the fetch is
/// doing, and the fetch is cancelled behind it. Nothing here limits how many exchanges run at once.
struct MachineLink: Sendable {
  let taskScope = TaskScope()
  let origin: URL
  let fetch: FetchClient
  let clock: OperationClock
  let ids: @Sendable () -> UUID
  /// A failing trace sink never fails an exchange: traces are diagnostics, not part of the protocol.
  let trace: @Sendable (OperationTrace) throws -> Void

  func address(_ machine: String, operation: UUID? = nil, suffix: String = "", query: [URLQueryItem] = []) -> URL {
    var url = origin.appendingPathComponent("machine/v2/machines").appendingPathComponent(machine)
    if let operation { url = url.appendingPathComponent("operations").appendingPathComponent(operation.uuidString) }
    if !suffix.isEmpty { url = url.appendingPathComponent(suffix) }
    guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.queryItems = query
    return components.url ?? url
  }

  func send<T: Decodable & Sendable>(
    _ type: T.Type,
    _ url: URL,
    method: Fetch.Method = .get,
    body: Body? = nil,
    correlation: UUID?,
    deadline: Duration,
    limit: Int,
    preparation: (@Sendable (Bool) -> Void)? = nil,
  ) async -> Exchanged<T> {
    let id = ids()
    var request = Request(url: url, method: method, body: body)
    request.headers["X-Wuhu-Request-ID"] = id.uuidString
    request.headers["X-Wuhu-Correlation-ID"] = (correlation ?? id).uuidString
    let began = clock.now()
    let outcome: Exchanged<Data>
    do {
      outcome = try await withUnjoinedDeadline("machine-exchange", within: deadline, clock: ExchangeClock(clock), scope: taskScope) { [request] in
        do {
          record(request, id: id, began: began, .dispatch)
          let response = try await OperationPreparation.$observer.withValue(preparation) { try await fetch(request) }
          record(request, id: id, began: began, .head, status: response.status.code)
          let bytes = try await response.body.data(upTo: limit)
          guard response.headers[.init("X-Wuhu-Correlation-ID")!] == request.headers["X-Wuhu-Correlation-ID"],
                response.headers[.init("X-Wuhu-Request-ID")!] == request.headers["X-Wuhu-Request-ID"],
                response.headers[.init("X-Wuhu-Agent-Instance")!].flatMap(UUID.init(uuidString:)) != nil
          else { return .init(result: .failure(.init(.invalidResponse)), answered: false) }
          if response.status.code >= 400 {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: bytes)
            return .init(result: .failure(envelope?.error ?? .init(.invalidResponse)), answered: envelope != nil)
          } else { return .init(result: .success(bytes), answered: true) }
        } catch {
          return .init(result: .failure(error as? OperationError ?? .init(.transport, message: String(describing: error))), answered: false)
        }
      }
    } catch is DeadlineExceeded {
      outcome = .init(result: .failure(.init(.requestDeadline)), answered: false)
    } catch {
      outcome = .init(result: .failure(.init(.requestCancelled)), answered: false)
    }
    let result: Result<T, OperationError> = outcome.result.flatMap { bytes in
      do { return .success(try JSONDecoder().decode(type, from: bytes)) } catch { return .failure(.init(.invalidResponse)) }
    }
    switch result {
    case .success: record(request, id: id, began: began, .complete)
    case let .failure(error):
      let event: OperationTrace.Event = error.code == .requestCancelled ? .cancelled : error.code == .requestDeadline ? .deadline : .failure
      record(request, id: id, began: began, event, error: error.code)
    }
    return .init(result: result, answered: outcome.answered)
  }

  private func record(_ request: Request, id: UUID, began: Duration, _ event: OperationTrace.Event, status: Int? = nil, error: OperationError.Code? = nil) {
    try? trace(.init(
      request: id,
      correlation: request.headers["X-Wuhu-Correlation-ID"] ?? "",
      path: request.url.path,
      event: event,
      elapsed: clock.now() - began,
      status: status,
      error: error,
    ))
  }
}

final class LocalWorkClock: Sendable {
  private struct State {
    var active = 0
    var began = Duration.zero
    var excluded = Duration.zero
  }

  private let state = Mutex(State())
  private let clock: OperationClock
  init(_ clock: OperationClock) { self.clock = clock }
  func work(_ active: Bool) {
    state.withLock { state in
      let now = clock.now()
      if active {
        if state.active == 0 { state.began = now }
        state.active += 1
      } else {
        state.active -= 1
        if state.active == 0 { state.excluded += now - state.began }
      }
    }
  }

  func now() -> Duration {
    state.withLock { state in
      let now = clock.now()
      return now - state.excluded - (state.active > 0 ? now - state.began : .zero)
    }
  }
}
