import Fetch
import Foundation
import Synchronization

public struct AttemptLogConfig: Sendable {
  public var directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  func fileURL(attemptID: UUID) -> URL {
    directory.appendingPathComponent("\(attemptID.uuidString.lowercased()).log")
  }
}

final class TrafficSizes: Sendable {
  private let sizes = Mutex<(request: Int, response: Int)>((0, 0))

  var request: Int { sizes.withLock(\.request) }
  var response: Int { sizes.withLock(\.response) }

  func addRequest(_ count: Int) { sizes.withLock { $0.request += count } }
  func addResponse(_ count: Int) { sizes.withLock { $0.response += count } }
}

// Appends the raw request body, then raw SSE bytes as they stream, so partial
// evidence survives a kill mid-attempt.
private actor AttemptLogFile {
  private let handle: FileHandle

  init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
  }

  func append(_ data: Data) {
    try? handle.write(contentsOf: data)
  }
}

func attemptLoggingFetch(
  base: FetchClient,
  file: URL,
  sizes: TrafficSizes,
) -> FetchClient {
  FetchClient { request in
    let log = try AttemptLogFile(url: file)

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
