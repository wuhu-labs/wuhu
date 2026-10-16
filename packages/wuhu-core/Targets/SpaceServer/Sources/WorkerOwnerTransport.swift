#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import AsyncHTTPClient
import Dependencies
import struct Fetch.Request
import struct Fetch.Response
import FetchAsyncHTTPClient
import class NIOPosix.MultiThreadedEventLoopGroup
import typealias Serve.Handler
import WorkerProtocol
import class WorkerProtocol.WorkerListener
import struct WorkerProtocol.WorkerProtocolError

actor WorkerOwnerTransport {
  private let socket: String
  private var handler: Handler
  private var revision = UUID()
  private var requiresHello = false
  private var listener: WorkerListener?
  private var stopped = false

  private init(socket: String, handler: @escaping Handler) {
    self.socket = socket; self.handler = handler
  }

  static func bind(socket: String, handler: @escaping Handler) async throws -> WorkerOwnerTransport {
    let transport = WorkerOwnerTransport(socket: socket, handler: handler)
    try await transport.bindListener()
    return transport
  }

  func run() async {
    @Dependency(\.continuousClock) var clock
    while !stopped, !Task.isCancelled {
      if let listener {
        await listener.run()
        self.listener = nil
      }
      guard !stopped, !Task.isCancelled else { break }
      do { try await bindListener() }
      catch {
        do { try await clock.sleep(for: .milliseconds(100)) }
        catch { break }
      }
    }
    await stop()
  }

  func replace(handler: @escaping Handler) throws {
    guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Owner transport is stopped") }
    self.handler = handler
    revision = UUID()
    requiresHello = true
  }

  private func handle(_ request: Request) async throws -> Response {
    guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Owner transport is stopped") }
    let hello = request.url.path == "/worker/hello"
    guard !requiresHello || hello else {
      var response = try Response.json(WorkerProtocolError(.unavailable, message: "Replacement owner requires rehello"), status: .badRequest)
      response.headers[.init("Connection")!] = "close"
      return response
    }
    let revision = revision
    let response = try await handler(request)
    if hello, response.status == .ok, revision == self.revision { requiresHello = false }
    return response
  }

  private func bindListener() async throws {
    let bound = try await WorkerListener.bind(socket: socket, handler: { try await self.handle($0) })
    guard !stopped, !Task.isCancelled else {
      await bound.shutdown()
      throw CancellationError()
    }
    listener = bound
  }

  func exportExec() async throws -> WorkerListener.ListenerExport {
    guard !stopped, let listener else { throw AdminExecError.refused("workerListener") }
    try await listener.pauseAccepting()
    do { return try await listener.exportListener() }
    catch { try await listener.resumeAccepting(); throw error }
  }

  func resumeExec() async throws { try await listener?.resumeAccepting() }

  func probeExec(credentials: WorkerCredentials, hello: WorkerHello) async throws {
    guard !stopped else { throw AdminExecError.refused("ownerStopped") }
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    let http = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let client = try WorkerClient(socket: socket, credentials: credentials, control: .asyncHTTPClient(http, timeout: .seconds(10)), bytes: .asyncHTTPClient(http, timeout: .seconds(10)))
    let outcome: Result<Void, any Error>
    do {
      _ = try await client.negotiate(hello)
      let lease = try await client.stream(.init(operation: "worker.lease"))
      let consumer = Task { try await lease.discard() }
      consumer.cancel()
      _ = await consumer.result
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await client.close()
    try await http.shutdown()
    try outcome.get()
  }

  static func adoptExec(_ record: ExecWorkerRecord, socket: String, handler: @escaping Handler) async throws -> WorkerOwnerTransport {
    let transport = WorkerOwnerTransport(socket: socket, handler: handler)
    let listener = try await WorkerListener.adopt(record.listener, socket: socket, expecting: record.listenerIdentity.value, initiallyAccepting: false, handler: { try await transport.handle($0) })
    await transport.installExec(listener)
    return transport
  }

  private func installExec(_ listener: WorkerListener) { self.listener = listener; requiresHello = true }

  func commitExec(socket: String, identity: WorkerListener.InheritedIdentity) async throws {
    guard let listener, !stopped else { throw AdminExecError.refused("workerListener") }
    try await listener.commitHandoff(.init(socket: socket, identity: identity))
    try await listener.resumeAccepting()
  }

  func detach() async { await listener?.shutdown() }

  func stop() async {
    stopped = true
    await listener?.shutdown()
    listener = nil
  }
}
