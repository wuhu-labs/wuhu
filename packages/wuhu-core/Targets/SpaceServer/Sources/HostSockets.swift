#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Serve

actor HostSockets {
  private struct Session: Sendable {
    let socket: WebSocket
    let task: Task<Void, Never>
  }

  private var sessions: [UUID: Session] = [:]
  private var stopped = false

  func run(_ body: @escaping WebSocketSession, socket: WebSocket) async {
    guard !stopped else { socket.abort(); return }
    let id = UUID()
    let task = Task { await body(socket) }
    sessions[id] = Session(socket: socket, task: task)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      socket.abort()
      task.cancel()
    }
    sessions[id] = nil
  }

  func shutdown() async {
    stopped = true
    let current = sessions.values
    for session in current { session.socket.abort(); session.task.cancel() }
    for session in current { await session.task.value }
  }
}
