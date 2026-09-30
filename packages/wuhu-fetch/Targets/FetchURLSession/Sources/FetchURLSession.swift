import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

import Fetch
import HTTPTypes

#if canImport(Security)
  import Security
#endif

extension FetchClient {
  public static func urlSession(_ session: URLSession = .shared) -> Self {
    let transport = URLSessionFetchTransport(configuration: session.configuration, delegate: StreamingURLSessionDelegate())

    return Self { request in
      try await transport.fetch(request)
    }
  }

  #if canImport(Security)
    /// A client whose server-trust challenges `serverTrust` decides in place of the system.
    ///
    /// It receives the challenged host and the trust the server presented; `true` accepts that trust as is, without system evaluation, and `false` cancels the connection.
    public static func urlSession(
      _ session: URLSession = .shared,
      serverTrust: @escaping @Sendable (_ host: String, _ trust: SecTrust) -> Bool,
    ) -> Self {
      let transport = URLSessionFetchTransport(
        configuration: session.configuration,
        delegate: StreamingURLSessionDelegate(serverTrust: serverTrust),
      )

      return Self { request in
        try await transport.fetch(request)
      }
    }
  #endif
}

private final class URLSessionFetchTransport: @unchecked Sendable {
  private let delegate: StreamingURLSessionDelegate
  private let session: URLSession

  init(configuration: URLSessionConfiguration, delegate: StreamingURLSessionDelegate) {
    self.delegate = delegate
    self.session = URLSession(
      configuration: configuration,
      delegate: self.delegate,
      delegateQueue: nil,
    )
  }

  deinit {
    self.session.invalidateAndCancel()
  }

  func fetch(_ request: Request) async throws -> Response {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method.rawValue

    for field in request.headers.fields {
      urlRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
    }
    for (name, value) in request.headers.sensitiveValues {
      urlRequest.addValue(value, forHTTPHeaderField: name)
    }

    if let body = request.body {
      if let contentType = body.contentType, urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
      }
      if let contentLength = body.contentLength, urlRequest.value(forHTTPHeaderField: "Content-Length") == nil {
        urlRequest.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
      }
      urlRequest.httpBody = try await body.data()
    }

    let state = StreamingTaskState()
    let task = self.session.dataTask(with: urlRequest)
    state.attach(task: task) { [delegate = self.delegate] taskIdentifier in
      delegate.unregisterTask(withIdentifier: taskIdentifier)
    }
    self.delegate.register(state, for: task)
    task.resume()

    do {
      let urlResponse = try await withTaskCancellationHandler {
        try await state.waitForResponse()
      } onCancel: {
        state.cancel()
      }

      return makeResponse(
        from: urlResponse,
        body: .stream(
          length: urlResponse.expectedContentLength >= 0 ? urlResponse.expectedContentLength : nil,
          contentType: headerValue(named: "Content-Type", in: urlResponse),
          TransportBoundSequence(transport: self, base: state.body),
        ),
      )
    } catch {
      state.cancel()
      throw error
    }
  }
}

private func makeResponse(from urlResponse: URLResponse, body: Body) -> Response {
  guard let response = urlResponse as? HTTPURLResponse else {
    return Response(status: Status(code: 599), body: body)
  }

  let headers = Headers(response)

  return Response(
    status: Status(code: response.statusCode),
    headers: headers,
    body: body,
  )
}

private extension Headers {
  init(_ response: HTTPURLResponse) {
    self.init()

    for (name, value) in response.allHeaderFields {
      guard let name = String(describing: name).split(separator: "\n").first,
            let fieldName = HTTPField.Name(String(name))
      else {
        continue
      }

      self[fieldName] = String(describing: value)
    }
  }
}

private func headerValue(named field: String, in response: URLResponse) -> String? {
  (response as? HTTPURLResponse)?.value(forHTTPHeaderField: field)
}

private struct TransportBoundSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
  where Base.Element == Bytes
{
  typealias Element = Bytes

  let transport: URLSessionFetchTransport
  let base: Base

  func makeAsyncIterator() -> Iterator {
    Iterator(transport: self.transport, base: self.base.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    let transport: URLSessionFetchTransport
    var base: Base.AsyncIterator

    mutating func next() async throws -> Bytes? {
      _ = self.transport
      return try await self.base.next()
    }
  }
}

private final class StreamingURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private var tasks: [Int: StreamingTaskState] = [:]
  private let lock = NSLock()

  #if canImport(Security)
    private let serverTrust: (@Sendable (String, SecTrust) -> Bool)?

    init(serverTrust: (@Sendable (String, SecTrust) -> Bool)? = nil) {
      self.serverTrust = serverTrust
    }

    func urlSession(
      _ session: URLSession,
      didReceive challenge: URLAuthenticationChallenge,
      completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
      guard let serverTrust,
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
      else {
        completionHandler(.performDefaultHandling, nil)
        return
      }
      guard serverTrust(challenge.protectionSpace.host, trust) else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  #endif

  func register(_ state: StreamingTaskState, for task: URLSessionTask) {
    self.withLock {
      $0.tasks[task.taskIdentifier] = state
    }
  }

  func unregisterTask(withIdentifier taskIdentifier: Int) {
    self.withLock {
      $0.tasks[taskIdentifier] = nil
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
  ) {
    self.state(for: dataTask)?.receive(response: response)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.state(for: dataTask)?.receive(data: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    self.state(for: task)?.complete(error: error)
  }

  private func state(for task: URLSessionTask) -> StreamingTaskState? {
    self.withLock {
      $0.tasks[task.taskIdentifier]
    }
  }

  private func withLock<R>(_ operation: (StreamingURLSessionDelegate) -> R) -> R {
    self.lock.lock()
    defer { self.lock.unlock() }
    return operation(self)
  }
}

private final class StreamingTaskState: @unchecked Sendable {
  let body: AsyncThrowingStream<Bytes, Error>

  private var task: URLSessionTask?
  private var taskIdentifier: Int?
  private var unregisterTask: (@Sendable (Int) -> Void)?
  private var response: URLResponse?
  private var terminalError: Error?
  private var responseContinuation: CheckedContinuation<URLResponse, Error>?
  private var bodyContinuation: AsyncThrowingStream<Bytes, Error>.Continuation?
  private var isFinished = false
  private let lock = NSLock()

  init() {
    var continuation: AsyncThrowingStream<Bytes, Error>.Continuation!
    self.body = AsyncThrowingStream { continuation = $0 }
    self.bodyContinuation = continuation
    continuation.onTermination = { [weak self] _ in
      self?.cancel()
    }
  }

  func attach(
    task: URLSessionTask,
    unregisterTask: @escaping @Sendable (Int) -> Void,
  ) {
    self.withLock {
      $0.task = task
      $0.taskIdentifier = task.taskIdentifier
      $0.unregisterTask = unregisterTask
    }
  }

  func waitForResponse() async throws -> URLResponse {
    try await withCheckedThrowingContinuation { continuation in
      self.withLock {
        if let response = $0.response {
          continuation.resume(returning: response)
          return
        }

        if $0.isFinished {
          continuation.resume(throwing: $0.terminalError ?? URLError(.badServerResponse))
          return
        }

        $0.responseContinuation = continuation
      }
    }
  }

  func receive(response: URLResponse) {
    let responseContinuation = self.withLock { state in
      guard !state.isFinished else {
        return nil as CheckedContinuation<URLResponse, Error>?
      }

      state.response = response
      defer { state.responseContinuation = nil }
      return state.responseContinuation
    }

    responseContinuation?.resume(returning: response)
  }

  func receive(data: Data) {
    let bodyContinuation = self.withLock { state in
      state.isFinished ? nil : state.bodyContinuation
    }

    bodyContinuation?.yield(data)
  }

  func complete(error: Error?) {
    let continuations = self.finish(error: error)

    if let responseContinuation = continuations.response {
      responseContinuation.resume(throwing: error ?? URLError(.badServerResponse))
    }

    if let bodyContinuation = continuations.body {
      if let error {
        bodyContinuation.finish(throwing: error)
      } else {
        bodyContinuation.finish()
      }
    }

    continuations.unregisterTask?()
  }

  func cancel() {
    let taskAndContinuations = self.finish(error: CancellationError())
    taskAndContinuations.task?.cancel()

    if let responseContinuation = taskAndContinuations.response {
      responseContinuation.resume(throwing: CancellationError())
    }

    taskAndContinuations.body?.finish(throwing: CancellationError())
    taskAndContinuations.unregisterTask?()
  }

  private func finish(
    error: Error?,
  ) -> (
    task: URLSessionTask?,
    response: CheckedContinuation<URLResponse, Error>?,
    body: AsyncThrowingStream<Bytes, Error>.Continuation?,
    unregisterTask: (() -> Void)?,
  ) {
    self.withLock { state in
      guard !state.isFinished else {
        return (nil, nil, nil, nil)
      }

      state.isFinished = true
      state.terminalError = error

      let responseContinuation = state.responseContinuation
      let bodyContinuation = state.bodyContinuation
      let task = state.task
      let taskIdentifier = state.taskIdentifier
      let unregisterTask = state.unregisterTask

      state.responseContinuation = nil
      state.bodyContinuation = nil
      state.task = nil
      state.taskIdentifier = nil
      state.unregisterTask = nil

      return (
        task,
        responseContinuation,
        bodyContinuation,
        taskIdentifier.map { taskIdentifier in
          { unregisterTask?(taskIdentifier) }
        },
      )
    }
  }

  private func withLock<R>(_ operation: (StreamingTaskState) -> R) -> R {
    self.lock.lock()
    defer { self.lock.unlock() }
    return operation(self)
  }
}
