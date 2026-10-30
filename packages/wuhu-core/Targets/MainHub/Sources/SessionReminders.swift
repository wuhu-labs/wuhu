import Clocks
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import protocol MainHub.Worker
import struct SessionDomain.SessionID
import struct SpaceCore.SessionStore

actor SessionReminders {
  private let sessions: SessionStore
  private let execution: any Worker
  private var pending: [SessionID: UUID] = [:]
  private var dues: [SessionID: Date] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var stopped = false
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date) private var date

  init(sessions: SessionStore, execution: any Worker) {
    self.sessions = sessions
    self.execution = execution
  }

  deinit { for task in tasks.values { task.cancel() } }

  func schedule(_ id: SessionID, at due: Date?) {
    if let token = pending.removeValue(forKey: id) { tasks[token]?.cancel() }
    dues[id] = nil
    guard !stopped, let due else { return }
    dues[id] = due
    let token = UUID()
    let sleep = deadlineSleep(after: .seconds(max(0, due.timeIntervalSince(date()))), clock: clock)
    let task = Task { @Sendable [weak self] in
      do {
        try await sleep()
        try Task.checkCancellation()
        await self?.fire(id, token: token)
      } catch {}
      await self?.finished(token)
    }
    pending[id] = token
    tasks[token] = task
  }

  private func finished(_ token: UUID) { tasks[token] = nil }

  private func fire(_ id: SessionID, token: UUID) async {
    guard !stopped, pending[id] == token else { return }
    var attempt = 0
    while true {
      do {
        try Task.checkCancellation()
        try await execution.deliver(id, .wake)
        break
      } catch is CancellationError { break }
      catch {
        guard !Task.isCancelled else { break }
        if isWorkerUnreachable(error) {
          do { try await clock.sleep(for: .seconds(1)) } catch { break }
          continue
        }
        guard attempt < 3 else {
          let log = Logger(label: "wuhu.session-reminders")
          log.error("Reminder wake failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
          do { try await sessions.markErrored(id, message: "parent reminder wake failed: \(error)") }
          catch { log.error("Reminder failure could not be persisted", metadata: ["session": "\(id.rawValue)", "error": "\(error)"]) }
          break
        }
        do { try await clock.sleep(for: .seconds(1 << attempt)) }
        catch { break }
        attempt += 1
      }
    }
    if pending[id] == token {
      pending[id] = nil
      dues[id] = nil
    }
  }

  /// The wakes still to come, by when each is due.
  func scheduled() -> [SessionID: Date] { dues }

  func shutdown() async {
    stopped = true
    let running = Array(tasks.values)
    pending.removeAll()
    dues.removeAll()
    for task in running { task.cancel() }
    for task in running { await task.value }
    tasks.removeAll()
  }
}

public func deadlineSleep(after delay: Duration, clock: any NonsendingClock<Duration>) -> @Sendable () async throws -> Void {
  let clock = AnyClock(clock)
  let deadline = clock.now.advanced(by: delay)
  return { try await clock.sleep(until: deadline, tolerance: nil) }
}
