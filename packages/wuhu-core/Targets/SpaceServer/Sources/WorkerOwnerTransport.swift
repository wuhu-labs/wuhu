#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import struct Fetch.Request
import struct Fetch.Response
import typealias Serve.Handler
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

  func detach() async { await listener?.shutdown() }

  func stop() async {
    stopped = true
    await listener?.shutdown()
    listener = nil
  }
}
