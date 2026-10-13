#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import Serve

actor HostRequests {
  private var requests: [UUID: Task<UpgradeResult, Error>] = [:]
  private var stopped = false
  private var bodies: [UUID: Task<Void, Never>] = [:]

  func run(_ body: @escaping UpgradingHandler, request: Request) async throws -> UpgradeResult {
    guard !stopped else { return .response(Response(status: .serviceUnavailable)) }
    let id = UUID()
    let task = Task { try await body(request) }
    requests[id] = task
    defer { requests[id] = nil }
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel() }
    switch result {
    case var .response(response):
      guard !stopped else { return .response(Response(status: .serviceUnavailable)) }
      if request.method != .head, response.body.contentLength != 0 { response.body = own(response.body) }
      return .response(response)
    case .webSocket: return result
    }
  }

  private func own(_ body: Body) -> Body {
    let id = UUID()
    let (chunks, output) = AsyncThrowingStream<Bytes, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let (demand, input) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let task = Task {
      defer { output.finish(); input.finish(); bodies[id] = nil }
      var iterator = body.asyncBytes().makeAsyncIterator()
      do {
        for await _ in demand {
          try Task.checkCancellation()
          guard let chunk = try await iterator.next() else { break }
          output.yield(chunk)
        }
      } catch { output.finish(throwing: error) }
    }
    bodies[id] = task
    output.onTermination = { _ in task.cancel() }
    return .stream(length: body.contentLength, contentType: body.contentType, HostBodyChunks(chunks: chunks, demand: input))
  }

  func shutdown(sockets: HostSockets) async {
    stopped = true
    let current = Array(requests.values)
    for task in current { task.cancel() }
    let streams = Array(bodies.values)
    for task in streams { task.cancel() }
    await sockets.shutdown()
    for task in current { _ = await task.result }
    for task in streams { await task.value }
  }
}

private struct HostBodyChunks: AsyncSequence, Sendable {
  typealias Element = Bytes
  let chunks: AsyncThrowingStream<Bytes, any Error>
  let demand: AsyncStream<Void>.Continuation

  struct AsyncIterator: AsyncIteratorProtocol {
    var chunks: AsyncThrowingStream<Bytes, any Error>.Iterator
    let demand: AsyncStream<Void>.Continuation
    mutating func next() async throws -> Bytes? {
      demand.yield(())
      return try await chunks.next()
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(chunks: chunks.makeAsyncIterator(), demand: demand)
  }
}
