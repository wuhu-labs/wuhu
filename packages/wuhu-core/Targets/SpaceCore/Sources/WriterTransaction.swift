import Dispatch
import GRDB
import Synchronization
import Wuwei

final class WriterTransaction: SharedTransaction, Sendable {
  private enum Command: Sendable {
    case access(@Sendable (GRDB.Database) -> Void)
    case commit
    case rollback
  }

  private struct State {
    var started = false
    var command: Command?
    var result: Result<Void, any Error>?
  }

  private struct Rollback: Error {}
  private let state = Mutex(State())
  private let opened = DispatchSemaphore(value: 0)
  private let commands = DispatchSemaphore(value: 0)
  private let answered = DispatchSemaphore(value: 0)
  private let finished = DispatchSemaphore(value: 0)

  func waitUntilOpen() throws {
    opened.wait()
    try state.withLock { try $0.result?.get() }
  }

  func serve(_ db: GRDB.Database) throws {
    state.withLock { $0.started = true }
    opened.signal()
    while true {
      commands.wait()
      switch try perform(db) {
      case true: return
      case false: answered.signal()
      }
    }
  }

  private func perform(_ db: GRDB.Database) throws -> Bool {
    let command = state.withLock { state in
      let command = state.command!
      state.command = nil
      return command
    }
    switch command {
    case let .access(body): body(db); return false
    case .commit: return true
    case .rollback: throw Rollback()
    }
  }

  func completed(_ result: Result<Void, any Error>) {
    let started = state.withLock { state in
      state.result = result.flatMapError { $0 is Rollback ? .success(()) : .failure($0) }
      return state.started
    }
    if !started { opened.signal() }
    finished.signal()
  }

  private func submit(_ command: Command) {
    state.withLock { state in
      precondition(state.command == nil && state.result == nil)
      state.command = command
    }
    commands.signal()
  }

  func access<T: Sendable>(_ body: @Sendable (OpaquePointer) throws -> T) throws -> T {
    try withoutActuallyEscaping(body) { body in
      let result = Mutex<Result<T, any Error>?>(nil)
      submit(.access { db in
        let value = Result { try body(db.sqliteConnection!) }
        result.withLock { $0 = value }
      })
      answered.wait()
      return try result.withLock { try $0!.get() }
    }
  }

  func commit() throws {
    submit(.commit)
    finished.wait()
    try state.withLock { try $0.result!.get() }
  }

  func rollback() {
    submit(.rollback)
    finished.wait()
  }

  deinit { precondition(state.withLock { $0.result != nil }, "the writer server must finish") }
}
