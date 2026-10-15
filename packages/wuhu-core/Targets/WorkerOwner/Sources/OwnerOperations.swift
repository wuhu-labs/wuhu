#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

actor OwnerOperations {
  private var tasks: [UUID: Task<JSONValue, any Error>] = [:]
  private var cancelled: Set<UUID> = []
  private var order: [UUID] = []
  private var stopped = false

  func run(_ call: WorkerCall, invoke: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
    guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Execution owner incarnation is closed") }
    guard tasks[call.id] == nil else { throw WorkerProtocolError(.invalidMessage, message: "Duplicate owner operation") }
    if cancelled.remove(call.id) != nil { throw CancellationError() }
    guard tasks.count < 1024 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many active owner operations") }
    let task = Task {
      let value = try await invoke()
      try Task.checkCancellation()
      return value
    }
    tasks[call.id] = task
    defer { tasks[call.id] = nil }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }

  func cancel(_ id: UUID) {
    if let task = tasks[id] { task.cancel(); return }
    if cancelled.insert(id).inserted { order.append(id) }
    while order.count > 4096 { cancelled.remove(order.removeFirst()) }
  }

  func stop() async {
    stopped = true
    let active = Array(tasks.values)
    for task in active { task.cancel() }
    for task in active { _ = try? await task.value }
    tasks.removeAll(); cancelled.removeAll(); order.removeAll()
  }
}
