#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import class Foundation.Thread
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Logging
import MainHub
import SessionDomain
import Synchronization

/// Main's workers when they run out of process: each one is this binary
/// again, with `WUHU_ROLE=worker`, dialling main's worker socket, its
/// credential on its standard input. Main keeps them as its children,
/// through a reboot too, and puts a new one up when one ends unasked.
final class ProcessWorkers: Sendable {
  /// A worker process as the main taking over adopts it.
  struct Child: Codable, Sendable {
    var id: String
    var pid: Int32
  }

  private struct State {
    var children: [WorkerID: pid_t] = [:]
    // Workers main is letting go: their end is expected.
    var retiring: Set<WorkerID> = []
    var stopping = false
    var exits: [WorkerID: [CheckedContinuation<Void, Never>]] = [:]
  }

  let registry: WorkerRegistry
  private let executable: String
  private let environment: [String: String]
  private let state = Mutex(State())
  private let log = Logger(label: "wuhu.workers")
  private let clock: any Clock<Duration>

  /// `environment` is what each worker starts with, beside its role, socket
  /// and space.
  init(registry: WorkerRegistry, executable: String, socket: String, spaceID: String, environment: [String: String]) {
    self.registry = registry
    self.executable = executable
    @Dependency(\.continuousClock) var clock
    self.clock = clock
    var environment = environment
    for name in WorkerProcess.inheritedOnlyByMain { environment[name] = nil }
    environment[WorkerProcess.roleVariable] = WorkerProcess.role
    environment[WorkerProcess.socketVariable] = socket
    environment[WorkerProcess.spaceVariable] = spaceID
    self.environment = environment
  }

  var children: [Child] {
    state.withLock { state in
      state.children.map { Child(id: $0.key.rawValue, pid: $0.value) }.sorted { $0.id < $1.id }
    }
  }

  /// Takes on the workers the main before this one started: they stay this
  /// process's children across `execve`, and announce again on their own.
  func adopt(_ children: [Child]) {
    for child in children { watch(WorkerID(child.id), pid: child.pid) }
  }

  /// Puts the first worker up, unless one was adopted.
  func start() throws {
    guard state.withLock({ $0.children.isEmpty }) else { return }
    _ = try spawn()
  }

  /// A new worker process with a fresh credential.
  func spawn() throws -> WorkerID {
    let credential = registry.mint()
    let pid = try spawnProcess(credential: credential.token)
    log.notice("worker started", metadata: ["worker": "\(credential.id.rawValue)", "pid": "\(pid)"])
    watch(credential.id, pid: pid)
    return credential.id
  }

  /// Replaces every worker: a new one comes up and announces, then each old
  /// one hands its sessions to it, at the end of each one's step in flight,
  /// and exits.
  func roll(announceWithin limit: Duration = .seconds(60)) async throws {
    let old = state.withLock { Array($0.children.keys) }
    let next = try spawn()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await self.registry.announcement(of: next) }
      group.addTask {
        try await self.clock.sleep(for: limit)
        throw WorkerDidNotAnnounce(id: next)
      }
      defer { group.cancelAll() }
      try await group.next()
    }
    for id in old {
      state.withLock { _ = $0.retiring.insert(id) }
      let line = try await registry.drain(id)
      await line.shutdown()
      await exit(of: id, within: .seconds(30))
    }
  }

  /// Main is stopping: the registry has already shut the workers down over
  /// their lines; what is still running after `grace` is killed.
  func stop(grace: Duration = .seconds(10)) async {
    let ids = state.withLock { state in
      state.stopping = true
      return Array(state.children.keys)
    }
    for id in ids { await exit(of: id, within: grace) }
  }

  // Waits for the worker's process to end, killing it past `limit`.
  private func exit(of id: WorkerID, within limit: Duration) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          let running = self.state.withLock { state in
            guard state.children[id] != nil else { return false }
            state.exits[id, default: []].append(continuation)
            return true
          }
          if !running { continuation.resume() }
        }
      }
      group.addTask {
        guard (try? await self.clock.sleep(for: limit)) != nil else { return }
        if let pid = self.state.withLock({ $0.children[id] }) {
          self.log.warning("worker did not exit; killing it", metadata: ["worker": "\(id.rawValue)", "pid": "\(pid)"])
          kill(pid, SIGKILL)
        }
      }
      await group.next()
      group.cancelAll()
    }
  }

  // Reaps the process on a thread of its own, and acts on its end.
  private func watch(_ id: WorkerID, pid: pid_t) {
    state.withLock { $0.children[id] = pid }
    let thread = Thread { [self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      ended(id, pid: pid, status: status)
    }
    thread.name = "wuhu-worker-reaper-\(id.rawValue)"
    thread.start()
  }

  private func ended(_ id: WorkerID, pid: pid_t, status: Int32) {
    let (expected, waiters) = state.withLock { state in
      state.children[id] = nil
      let expected = state.stopping || state.retiring.remove(id) != nil
      return (expected, state.exits.removeValue(forKey: id) ?? [])
    }
    for waiter in waiters { waiter.resume() }
    guard !expected else {
      log.notice("worker exited", metadata: ["worker": "\(id.rawValue)", "pid": "\(pid)"])
      return
    }
    log.error("worker exited unasked; starting another", metadata: ["worker": "\(id.rawValue)", "pid": "\(pid)", "status": "\(status)"])
    let orphaned = registry.drop(id)
    Task {
      do {
        let next = try self.spawn()
        await self.registry.announcement(of: next)
        // What the lost worker held picks up from the store on the new one.
        for session in orphaned { try? await self.registry.deliver(session, .wake) }
      } catch {
        self.log.error("could not start a worker", metadata: ["error": "\(error)"])
      }
    }
  }

  private func spawnProcess(credential: String) throws -> pid_t {
    var pipe: [Int32] = [-1, -1]
    guard closeOnExecPipe(&pipe) == 0 else { throw WorkerSpawnFailed(step: "pipe", code: errno) }
    defer { close(pipe[0]) }
    let fileActions = try SpawnFileActions()
    fileActions.dup(pipe[0], to: 0)
    fileActions.close(pipe[1])
    let argv = [CommandLine.arguments.first ?? executable]
    let env = environment.map { "\($0.key)=\($0.value)" }
    let pid = try fileActions.spawn(executable, argv: argv, environment: env)
    let token = Array((credential + "\n").utf8)
    let written = token.withUnsafeBytes { write(pipe[1], $0.baseAddress, $0.count) }
    close(pipe[1])
    guard written == token.count else {
      kill(pid, SIGKILL)
      throw WorkerSpawnFailed(step: "credential", code: errno)
    }
    return pid
  }
}

struct WorkerDidNotAnnounce: Error, CustomStringConvertible {
  let id: WorkerID
  var description: String { "worker \(id.rawValue) did not announce itself to main" }
}

struct WorkerSpawnFailed: Error, CustomStringConvertible {
  let step: String
  let code: Int32
  var description: String { "could not start a worker (\(step)): \(String(cString: strerror(code)))" }
}

// A close-on-exec pipe: neither end leaks into another child.
private func closeOnExecPipe(_ fds: inout [Int32]) -> Int32 {
  guard pipe(&fds) == 0 else { return -1 }
  for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
  return 0
}

private final class SpawnFileActions {
  #if canImport(Darwin)
    var actions: posix_spawn_file_actions_t? = nil
  #else
    var actions = posix_spawn_file_actions_t()
  #endif

  init() throws {
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw WorkerSpawnFailed(step: "file actions", code: errno) }
  }

  deinit { posix_spawn_file_actions_destroy(&actions) }

  func dup(_ fd: Int32, to target: Int32) { posix_spawn_file_actions_adddup2(&actions, fd, target) }
  func close(_ fd: Int32) { posix_spawn_file_actions_addclose(&actions, fd) }

  func spawn(_ path: String, argv: [String], environment: [String]) throws -> pid_t {
    var pid: pid_t = 0
    let cArgv = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup($0) } + [nil]
    defer { (cArgv + cEnv).forEach { free($0) } }
    let code = posix_spawn(&pid, path, &actions, nil, cArgv, cEnv)
    guard code == 0 else { throw WorkerSpawnFailed(step: "spawn", code: code) }
    return pid
  }
}
