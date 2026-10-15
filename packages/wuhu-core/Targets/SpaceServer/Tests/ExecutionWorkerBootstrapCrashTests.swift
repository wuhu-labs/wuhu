#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
@testable import SpaceServer
import Subprocess
import Synchronization
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerBootstrapCrashTests {
  @Test(arguments: [false, true])
  func killedRealParentClosesEmptyOrPartialBootstrapAndChildExits(partial: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
    let fifo = fixture.base + "/bootstrap.pipe", pidFile = fixture.base + "/child.pid", opened = fixture.base + "/reader-open"
    #expect(mkfifo(fifo, 0o600) == 0)
    let calls = Mutex(0)
    let owner = try await WorkerListener.bind(socket: fixture.base + "/owner.sock", handler: { _ in
      calls.withLock { $0 += 1 }
      return .text("No bootstrap effect is permitted")
    })
    let listening = Task { await owner.run() }
    let prefix = "{\"parentSocket\":\"" + fixture.base + "/owner.sock\",\"workerSocket\":"
    let write = partial ? "printf '%s' '\(prefix)' >&3;" : ""
    let script = "umask 077; exec 3<> '\(fifo)'; (exec 0< '\(fifo)'; exec 3>&-; printf ready > '\(opened)'; exec '\(binary)' _execution-worker) & c=$!; \(write) printf '%s' \"$c\" > '\(pidFile)'; wait \"$c\""
    let outcome: Result<Void, any Error>
    do {
      let result = try await Subprocess.run(.path("/bin/sh"), arguments: ["-c", script], environment: .custom([:]), input: .none, output: .discarded, error: .discarded) { parent in
        try await until("fixture parent publishes child PID") {
          guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return false }
          return Int32(text) != nil && FileManager.default.fileExists(atPath: opened)
        }
        let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8)))
        let birth = try processBirthIdentity(pid)
        defer {
          if (try? processBirthIdentity(pid)) == birth { _ = kill(pid, SIGKILL) }
        }
        #expect(kill(parent.processIdentifier.value, SIGKILL) == 0)
        try await until("actual worker PID exits after parent SIGKILL", timeout: .seconds(10)) {
          if (try? processBirthIdentity(pid)) != birth { return true }
          #if os(Linux)
            if let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let end = text.lastIndex(of: ")") {
              return text[text.index(after: end)...].split(separator: " ").first == "Z"
            }
          #endif
          return false
        }
      }
      #expect(result.terminationStatus == .signaled(SIGKILL))
      #expect(calls.withLock { $0 } == 0)
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await owner.shutdown()
    await listening.value
    try outcome.get()
  }
}
