#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID
import enum SessionDomain.ToolResultPayload
import struct WorkerProtocol.WorkerProtocolError

actor WorkerScriptDirectory {
  typealias Control = @Sendable (String, SessionID) async throws -> ToolResultPayload
  private struct Entry { let session: SessionID; let generation: UUID }
  private var scripts: [String: Entry] = [:]
  private var controls: [UUID: Control] = [:]
  private var controlling: [UUID: Int] = [:]
  nonisolated let changes: AsyncStream<Void>
  private let changed: AsyncStream<Void>.Continuation
  private var dirty: Set<UUID> = []

  init() { (changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }

  func takeChanges() -> Set<UUID> {
    defer { dirty.removeAll() }
    return dirty
  }

  func bind(_ generation: UUID, control: @escaping Control) { controls[generation] = control }

  func started(_ script: String, session: SessionID, generation: UUID) throws {
    guard scripts[script] == nil, scripts.count < 4096 else { throw WorkerProtocolError(.capacityExceeded, message: "Worker script directory is full or script is already registered") }
    scripts[script] = Entry(session: session, generation: generation)
  }

  func ended(_ script: String, session: SessionID, generation: UUID) {
    guard scripts[script]?.session == session, scripts[script]?.generation == generation else { return }
    scripts[script] = nil
    dirty.insert(generation)
    changed.yield(())
  }

  func scripts(for session: SessionID) -> [String] { scripts.compactMap { $0.value.session == session ? $0.key : nil } }

  func contains(_ generation: UUID) -> Bool {
    controlling[generation, default: 0] > 0 || scripts.values.contains { $0.generation == generation }
  }

  func stop(_ script: String, session: SessionID) async throws -> ToolResultPayload {
    guard let entry = scripts[script], entry.session == session, let control = controls[entry.generation] else {
      return .failure(.init(message: "stop_script: you have no running script \(script)"))
    }
    controlling[entry.generation, default: 0] += 1
    defer {
      controlling[entry.generation, default: 0] -= 1
      dirty.insert(entry.generation)
      changed.yield(())
    }
    return try await control(script, session)
  }

  func stopAll(_ session: SessionID) async throws {
    for (script, entry) in scripts where entry.session == session { _ = try await stop(script, session: session) }
  }

  func lost(_ generation: UUID) {
    scripts = scripts.filter { $0.value.generation != generation }
    dirty.insert(generation)
    changed.yield(())
  }

  func remove(_ generation: UUID) {
    scripts = scripts.filter { $0.value.generation != generation }
    controls[generation] = nil
    controlling[generation] = nil
  }

  func shutdown() { controls.removeAll(); scripts.removeAll(); controlling.removeAll(); changed.finish() }
}
