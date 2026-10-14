#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Serve

actor HostSockets {
  private struct Session: Sendable {
    let abort: @Sendable () -> Void
    let task: Task<Void, Never>
  }

  private var sessions: [UUID: Session] = [:]
  private var stopped = false

  func run(_ body: @escaping WebSocketSession, socket: WebSocket) async {
    await run({ await body(socket) }, abort: socket.abort)
  }

  func run(_ body: @escaping @Sendable () async -> Void, abort: @escaping @Sendable () -> Void) async {
    guard !stopped else { abort(); return }
    let id = UUID()
    let task = Task { await body() }
    sessions[id] = Session(abort: abort, task: task)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
      abort()
    }
    sessions[id] = nil
  }

  func shutdown() async {
    stopped = true
    let current = Array(sessions.values)
    for session in current { session.task.cancel() }
    for session in current { session.abort() }
    for session in current { await session.task.value }
  }
}
