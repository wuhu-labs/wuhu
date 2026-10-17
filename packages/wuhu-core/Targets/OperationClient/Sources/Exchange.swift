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
import Synchronization

/// What one exchange came back with. `answered` says the machine itself answered (its instance header was valid), so the
/// operation's lease was renewed, even when the answer is a typed error.
struct Exchanged<T: Sendable>: Sendable {
  let result: Result<T, OperationError>
  let answered: Bool
}

/// One request to one machine, with a real deadline: the caller is answered when the deadline passes, whatever the fetch is
/// doing, and the fetch is cancelled behind it. Nothing here limits how many exchanges run at once.
struct MachineLink: Sendable {
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
  ) async -> Exchanged<T> {
    let id = ids()
    var request = Request(url: url, method: method, body: body)
    request.headers["X-Wuhu-Request-ID"] = id.uuidString
    request.headers["X-Wuhu-Correlation-ID"] = (correlation ?? id).uuidString
    let began = clock.now()
    record(request, id: id, began: began, .dispatch)
    let gate = Gate<Exchanged<Data>>()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Exchanged<Data>, Never>) in
        gate.arm(continuation)
        let worker = Task { [request] in
          do {
            let response = try await fetch(request)
            record(request, id: id, began: began, .head, status: response.status.code)
            let bytes = try await response.body.data(upTo: limit)
            guard response.headers[.init("X-Wuhu-Correlation-ID")!] == request.headers["X-Wuhu-Correlation-ID"],
                  response.headers[.init("X-Wuhu-Request-ID")!] == request.headers["X-Wuhu-Request-ID"],
                  response.headers[.init("X-Wuhu-Agent-Instance")!].flatMap(UUID.init(uuidString:)) != nil
            else { gate.fire(.init(result: .failure(.init(.invalidResponse)), answered: false)); return }
            if response.status.code >= 400 {
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: bytes)
              gate.fire(.init(result: .failure(envelope?.error ?? .init(.invalidResponse)), answered: envelope != nil))
            } else { gate.fire(.init(result: .success(bytes), answered: true)) }
          } catch {
            gate.fire(.init(result: .failure(error as? OperationError ?? .init(.transport, message: String(describing: error))), answered: false))
          }
        }
        let timer = Task {
          do { try await clock.sleep(max(.zero, deadline)) } catch { return }
          gate.fire(.init(result: .failure(.init(.requestDeadline)), answered: false))
        }
        gate.onFire { worker.cancel(); timer.cancel() }
      }
    } onCancel: {
      gate.fire(.init(result: .failure(.init(.requestCancelled)), answered: false))
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

/// A continuation resumed once by whichever of worker, timer or cancellation fires first.
private final class Gate<T: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<T, Never>?
    var value: T?
    var cleanup: (@Sendable () -> Void)?
    var fired = false
  }

  private let state = Mutex(State())

  func arm(_ continuation: CheckedContinuation<T, Never>) {
    let value: T? = state.withLock { state in
      if let value = state.value { return value }
      state.continuation = continuation; return nil
    }
    if let value { continuation.resume(returning: value) }
  }

  func onFire(_ cleanup: @escaping @Sendable () -> Void) {
    let fired = state.withLock { state in
      if state.fired { return true }
      state.cleanup = cleanup; return false
    }
    if fired { cleanup() }
  }

  func fire(_ value: T) {
    let (continuation, cleanup): (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?) = state.withLock { state in
      guard !state.fired else { return (nil, nil) }
      state.fired = true; state.value = value
      defer { state.continuation = nil; state.cleanup = nil }
      return (state.continuation, state.cleanup)
    }
    continuation?.resume(returning: value)
    cleanup?()
  }
}
