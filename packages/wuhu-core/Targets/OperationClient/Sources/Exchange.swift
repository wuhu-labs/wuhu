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
import Synchronization
import TaskLifetime
import Tracing

/// What one exchange came back with. `answered` says the machine itself answered (its instance header was valid), so the
/// operation's lease was renewed, even when the answer is a typed error.
struct Exchanged<T: Sendable>: Sendable {
  let result: Result<T, OperationError>
  let answered: Bool
}

/// What one exchange asks of a machine; it decides the request's path, method and the span's `machine.exchange.kind`.
enum MachineExchange: Sendable {
  case describe
  case start(UUID)
  case poll(UUID, query: [URLQueryItem])
  case stop(UUID)
  case input(UUID, channel: String)

  var kind: String {
    switch self {
    case .describe: "describe"
    case .start: "start"
    case .poll: "poll"
    case .stop: "stop"
    case .input: "input"
    }
  }

  var method: Fetch.Method {
    switch self {
    case .describe, .poll: .get
    case .start: .post
    case .stop, .input: .put
    }
  }

  var operation: UUID? {
    switch self {
    case .describe: nil
    case let .start(id), let .poll(id, _), let .stop(id), let .input(id, _): id
    }
  }
}

/// One request to one machine, with a real deadline: the caller is answered when the deadline passes, whatever the fetch is
/// doing, and the fetch is cancelled behind it. Nothing here limits how many exchanges run at once. Each exchange is one
/// content-free `machine.exchange` client span under the current one.
struct MachineLink: Sendable {
  let taskScope = TaskScope()
  let origin: URL
  let fetch: FetchClient
  let clock: OperationClock
  let ids: @Sendable () -> UUID
  let tracer: any Tracer

  func url(_ machine: String, _ exchange: MachineExchange) -> URL {
    var url = origin.appendingPathComponent("machine/v2/machines").appendingPathComponent(machine)
    if let operation = exchange.operation { url = url.appendingPathComponent("operations").appendingPathComponent(operation.uuidString) }
    switch exchange {
    case .describe, .start: return url
    case .stop: return url.appendingPathComponent("stop")
    case let .input(_, channel): return url.appendingPathComponent("inputs/\(channel)")
    case let .poll(_, query):
      guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
      components.queryItems = query
      return components.url ?? url
    }
  }

  func send<T: Decodable & Sendable>(
    _ type: T.Type,
    _ machine: String,
    _ exchange: MachineExchange,
    body: Body? = nil,
    correlation: UUID?,
    deadline: Duration,
    limit: Int,
    preparation: (@Sendable (Bool) -> Void)? = nil,
  ) async -> Exchanged<T> {
    let span = tracer.startSpan("machine.exchange", ofKind: .client)
    defer { span.end() }
    let id = ids()
    var request = Request(url: url(machine, exchange), method: exchange.method, body: body)
    request.headers["X-Wuhu-Request-ID"] = id.uuidString
    request.headers["X-Wuhu-Correlation-ID"] = (correlation ?? id).uuidString
    let began = clock.now()
    let outcome: Exchanged<Data>
    do {
      outcome = try await withUnjoinedDeadline("machine-exchange", within: deadline, clock: ExchangeClock(clock), scope: taskScope) { [request, clock] in
        do {
          let response = try await OperationPreparation.$observer.withValue(preparation) { try await fetch(request) }
          span.updateAttributes { attributes in
            attributes["http.response.status_code"] = response.status.code
            attributes["machine.exchange.head_ms"] = (clock.now() - began).milliseconds
          }
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
    span.updateAttributes { attributes in
      attributes["machine.id"] = machine
      attributes["machine.exchange.kind"] = exchange.kind
      attributes["operation.id"] = exchange.operation?.uuidString
      attributes["machine.exchange.elapsed_ms"] = (clock.now() - began).milliseconds
      if case let .failure(error) = result { attributes["error.type"] = error.code.rawValue }
    }
    if case .failure = result { span.setStatus(.init(code: .error)) }
    return .init(result: result, answered: outcome.answered)
  }
}

private extension Duration {
  var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
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
