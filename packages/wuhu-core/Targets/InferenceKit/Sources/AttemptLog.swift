import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Synchronization
import WuhuAI

public struct AttemptTraceSink: Sendable {
  public var append: @Sendable (Data) async -> Void

  public init(append: @escaping @Sendable (Data) async -> Void) {
    self.append = append
  }
}

public struct AttemptTraceClient: Sendable {
  public var open: @Sendable (UUID) async throws -> AttemptTraceSink

  public init(open: @escaping @Sendable (UUID) async throws -> AttemptTraceSink) {
    self.open = open
  }
}

final class TrafficSizes: Sendable {
  private let sizes = Mutex<(request: Int, response: Int)>((0, 0))

  var request: Int { sizes.withLock(\.request) }
  var response: Int { sizes.withLock(\.response) }

  func addRequest(_ count: Int) { sizes.withLock { $0.request += count } }
  func addResponse(_ count: Int) { sizes.withLock { $0.response += count } }
}

func attemptLoggingFetch(
  base: FetchClient,
  trace: AttemptTraceClient,
  attemptID: UUID,
  sizes: TrafficSizes,
) -> FetchClient {
  FetchClient { request in
    let log = try await trace.open(attemptID)

    let bodyData: Data = if let body = request.body { try await body.data() } else { Data() }
    sizes.addRequest(bodyData.count)
    await log.append(bodyData)
    await log.append(Data("\n\n".utf8))

    let outbound = Request(
      url: request.url,
      method: request.method,
      headers: request.headers,
      body: bodyData.isEmpty ? nil : .bytes(bodyData, contentType: request.body?.contentType),
    )
    let response = try await base.fetch(outbound)

    let source = response.body.asyncBytes()
    let teed = AsyncThrowingStream<Data, any Error> { continuation in
      let task = Task {
        do {
          for try await chunk in source {
            sizes.addResponse(chunk.count)
            await log.append(chunk)
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return Response(
      status: response.status,
      headers: response.headers,
      body: .stream(contentType: response.body.contentType, teed),
    )
  }
}

func socketAttemptObserver(trace: AttemptTraceSink?, sizes: TrafficSizes) -> ResponsesWebSocketObserver {
  let log = trace
  return ResponsesWebSocketObserver(request: { subattempt, _, body in
    let bytes = Data(body.jsonString().utf8)
    sizes.addRequest(bytes.count)
    await log?.append(Data("\n[websocket request \(subattempt)]\n".utf8))
    await log?.append(bytes)
    await log?.append(Data("\n".utf8))
  }, received: { subattempt, message in
    let bytes: Data
    switch message {
    case .text(let text): bytes = Data(text.utf8)
    case .binary(let payload): bytes = Data(payload)
    }
    sizes.addResponse(bytes.count)
    await log?.append(Data("[websocket event \(subattempt)] ".utf8))
    await log?.append(bytes)
    await log?.append(Data("\n".utf8))
  })
}
