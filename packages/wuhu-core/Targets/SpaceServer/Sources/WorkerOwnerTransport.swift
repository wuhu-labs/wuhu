import Dependencies
import typealias Serve.Handler
import class WorkerProtocol.WorkerListener

actor WorkerOwnerTransport {
  private let socket: String
  private let handler: Handler
  private var listener: WorkerListener?
  private var stopped = false

  private init(socket: String, handler: @escaping Handler, listener: WorkerListener) {
    self.socket = socket; self.handler = handler; self.listener = listener
  }

  static func bind(socket: String, handler: @escaping Handler) async throws -> WorkerOwnerTransport {
    try await WorkerOwnerTransport(socket: socket, handler: handler, listener: WorkerListener.bind(socket: socket, handler: handler))
  }

  func run() async {
    @Dependency(\.continuousClock) var clock
    while !stopped, !Task.isCancelled {
      if let listener {
        await listener.run()
        self.listener = nil
      }
      guard !stopped, !Task.isCancelled else { break }
      do { listener = try await WorkerListener.bind(socket: socket, handler: handler) }
      catch {
        do { try await clock.sleep(for: .milliseconds(100)) }
        catch { break }
      }
    }
    await stop()
  }

  func detach() async { await listener?.shutdown() }

  func stop() async {
    stopped = true
    await listener?.shutdown()
    listener = nil
  }
}
