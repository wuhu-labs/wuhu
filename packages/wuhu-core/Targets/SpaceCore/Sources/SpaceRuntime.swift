#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Synchronization
import Wuwei

/// The space's wuwei runtime: one worker on the shared backend over the space's own database, hosting the kinds of every module of the space, on the date and clock injected where it is first asked for.
final class SpaceRuntime: Sendable {
  var machineBuffers: MachineBuffers {
    _ = worker()
    return running.withLock { $0!.buffers }
  }

  private let database: WuweiDatabase
  private let fileReads: @Sendable (Worker) -> FileWatchReads
  private let observations: ObservationSources
  private let documents: Documents
  /// Held while a worker is made, which writes — and only there: the writer's commit hooks run inside a write, so no lock they take may be held across one.
  private let hosting = Mutex(())
  /// The worker this space hosts and its scheduler; a commit hook poking a cell takes it for the length of a lock.
  private let running = Mutex<(worker: Worker, scheduler: DependencyScheduler, buffers: MachineBuffers)?>(nil)
  /// Whether the space is closing, read and set for the length of a lock only: closing under the same lock a worker is handed out under keeps the two atomic without holding it across the work of making one.
  private let closing = Mutex(false)

  init(database: WuweiDatabase, observations: ObservationSources, documents: Documents, fileReads: @escaping @Sendable (Worker) -> FileWatchReads) {
    self.database = database
    self.fileReads = fileReads
    self.observations = observations
    self.documents = documents
  }

  func worker() -> Worker {
    guard let worker = hosted() else { preconditionFailure("the space is closing: it makes no worker") }
    return worker
  }

  /// The space's worker for an observation: made if the space has none yet, nil once the space is closing.
  func observing() -> Worker? {
    hosted()
  }

  /// The worker, made on first use; nil once the space is closing. `hosting` alone serializes the making, never a lock a commit hook takes: the making waits for the writer.
  private func hosted() -> Worker? {
    hosting.withLock { _ in
      if let running = running.withLock({ $0 }) { return running.worker }
      guard !closing.withLock({ $0 }) else { return nil }
      let scheduler = DependencyScheduler()
      // A worker retakes a lease held under its own id at once, so two processes on one database never share an id.
      let worker = Worker(id: "space-\(UUID().uuidString.lowercased())", storage: .shared(database), scheduler: scheduler, registrations: [.cell(MachineCell.self), .cell(GroupCell.self), .cell(SpaceCell.self), .cell(PersonCell.self), .cell(ConversationCell.self), .cell(DocumentCell.self), .cell(FilesCell.self), .job(ObservationJob.self)])
      let buffers = MachineBuffers(worker: worker.id)
      worker.provide(buffers)
      worker.provide(observations)
      worker.provide(fileReads(worker))
      worker.provide(documents)
      do { try worker.create(ObservationJob.address, params: ObservationJob.Params()) } catch { preconditionFailure("the observation job was not created: \(error)") }
      running.withLock { $0 = (worker, scheduler, buffers) }
      return worker
    }
  }

  /// Has the session's cell look at its mail, after the write that posted it commits. Without a worker, or lost, a worker's scan finds the mail.
  func poke(_ session: SessionID) {
    running.withLock { $0?.worker }?.poke(Recipient<SessionMail>(kind: SessionMail.kind, key: session.rawValue))
  }

  func poke<Message>(_ recipient: Recipient<Message>) {
    running.withLock { $0?.worker }?.poke(recipient)
  }

  /// The same for a person's cell.
  func poke(person: String) {
    running.withLock { $0?.worker }?.poke(PersonCell.ID(person).recipient)
  }

  func quiesce() async {
    guard let running = running.withLock({ $0 }) else { return }
    await running.worker.quiesce()
  }

  /// The first act of closing. Waiting on `hosting` lets a making already under way settle, so the worker it installs is this space's to stop; then closing is set under the lock a worker is handed out under, and none is made after it.
  func beginClosing() {
    hosting.withLock { _ in closing.withLock { $0 = true } }
  }

  func stop() async {
    let stopped = running.withLock { $0 }
    guard let stopped else { return }
    await stopped.worker.quiesce()
    stopped.worker.release()
    stopped.scheduler.stop()
    running.withLock { running in
      if running?.worker === stopped.worker { running = nil }
    }
  }

  func close() {
    database.closeReaders()
  }
}

extension Space {
  public nonisolated var machineBuffers: MachineBuffers { runtime.machineBuffers }

  /// The space's one worker, which a module gives its kinds and clients before `start`. After `stopWorker` the next one is new, as after a restart of the process.
  public nonisolated var worker: Worker {
    runtime.worker()
  }

  public nonisolated func quiesceWorker() async {
    await runtime.quiesce()
  }

  /// Quiesces the worker, ends its timers and releases its leases.
  public nonisolated func stopWorker() async {
    await runtime.stop()
  }
}
