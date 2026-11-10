#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SSHMachine
import Synchronization
import Testing
import WuweiNeo

/// The caller: keeps every reply it gets.
@Cell
struct Session: SSHCaller {
  static let schema = ["CREATE TABLE reply (call TEXT NOT NULL, reply TEXT NOT NULL)"]

  static func message(_ reply: SSHReply, call: String) -> Message {
    .reply(call, reply)
  }

  func replies() throws -> [String: SSHReply] {
    try Dictionary(uniqueKeysWithValues: db.rows("SELECT call, reply FROM reply").map { row in
      try (row["call"].text!, JSONDecoder().decode(SSHReply.self, from: Data(row["reply"].text!.utf8)))
    })
  }

  mutating func reply(_ call: String, _ reply: SSHReply) throws {
    try db.execute("INSERT INTO reply VALUES (?, ?)", .text(call), .text(String(decoding: JSONEncoder().encode(reply), as: UTF8.self)))
  }
}

/// Commands wait until the test answers or cuts them.
final class FakeSSH: Sendable {
  private struct State {
    var waiting: [(command: String, continuation: CheckedContinuation<SSHOutput, any Error>)] = []
    var commands: [String] = []
    var connections = 0
    var closes = 0
  }

  private let state = Mutex(State())

  var client: SSHClient {
    SSHClient { _ in
      self.state.withLock { $0.connections += 1 }
      return SSHConnection(
        run: { command in
          try await withCheckedThrowingContinuation { continuation in
            self.state.withLock { state in
              state.commands.append(command)
              state.waiting.append((command, continuation))
            }
          }
        },
        close: { self.state.withLock { $0.closes += 1 } },
      )
    }
  }

  func answer(_ command: String, _ output: SSHOutput) {
    for continuation in take(command) {
      continuation.resume(returning: output)
    }
  }

  func cut(_ command: String) {
    for continuation in take(command) {
      continuation.resume(throwing: SSHFailure.lost("cut"))
    }
  }

  var commands: [String] {
    state.withLock { $0.commands }
  }

  var waiting: [String] {
    state.withLock { $0.waiting.map(\.command) }
  }

  var connections: Int {
    state.withLock { $0.connections }
  }

  var closes: Int {
    state.withLock { $0.closes }
  }

  private func take(_ command: String) -> [CheckedContinuation<SSHOutput, any Error>] {
    state.withLock { state in
      defer { state.waiting.removeAll { $0.command == command } }
      return state.waiting.filter { $0.command == command }.map(\.continuation)
    }
  }
}

@Suite struct SSHTests {
  let simulation = Simulation(seed: 7)
  let path = FileManager.default.temporaryDirectory.appending(path: "ssh-\(UUID().uuidString).sqlite").path(percentEncoded: false)
  let ssh = FakeSSH()
  let session = Session.ID("s")
  let linux = SSHOutput(status: 0, stdout: "Linux\n")

  func node(_ id: String) throws -> (worker: Worker, process: SimulatedProcess) {
    var dependencies = Dependencies()
    dependencies.register(ssh.client)
    let process = simulation.spawn()
    let worker = try Worker(
      id: id, storage: .layered(FileDatabase(path: path, synchronous: false)), scheduler: process,
      registrations: [.job(SSHHost.self), .job(SSHCall<Session>.self), .cell(Session.self)],
      dependencies: dependencies,
    )
    worker.start()
    return (worker, process)
  }

  func call(_ id: String, _ command: String, retrySafe: Bool = false, on worker: Worker) throws {
    try worker.create(SSHCall<Session>.ID(id), params: .init(host: "box", command: command, retrySafe: retrySafe, timeout: .seconds(30), replyTo: session))
  }

  func replies(_ worker: Worker) throws -> [String: SSHReply] {
    try worker.cell(session).replies()
  }

  @Test func aCommandRunsOnceAndItsOutputReachesTheCaller() throws {
    let a = try node("a")
    try call("1", "uname", on: a.worker)
    simulation.run(for: .seconds(2))
    #expect(ssh.waiting == ["uname"])

    ssh.answer("uname", linux)
    simulation.run(for: .seconds(2))
    #expect(try replies(a.worker) == ["1": .output(linux)])
    #expect(ssh.commands == ["uname"])
  }

  @Test func theHostKeepsItsConnectionUntilItHibernates() throws {
    let a = try node("a")
    for id in ["1", "2"] {
      try call(id, "uname", on: a.worker)
      simulation.run(for: .seconds(2))
      ssh.answer("uname", linux)
      simulation.run(for: .seconds(2))
    }
    #expect(ssh.connections == 1)

    simulation.run(for: .seconds(61))
    #expect(ssh.closes == 1)

    try call("3", "uname", on: a.worker)
    simulation.run(for: .seconds(2))
    ssh.answer("uname", linux)
    simulation.run(for: .seconds(2))
    #expect(ssh.connections == 2)
    #expect(try replies(a.worker).count == 3)
  }

  @Test func aCommandWithNoAnswerIsUnknownAndNeverSentAgain() throws {
    let a = try node("a")
    try call("1", "rm -r build", on: a.worker)
    simulation.run(for: .seconds(31))
    guard case .unknown? = try replies(a.worker)["1"] else { Issue.record("expected an unknown outcome"); return }

    ssh.answer("rm -r build", SSHOutput(status: 0, stdout: ""))
    simulation.run(for: .seconds(5))
    #expect(try replies(a.worker).count == 1)
    #expect(ssh.commands == ["rm -r build"])
  }

  @Test func aCrashWhileACommandRunsNeverRunsItAgain() throws {
    let a = try node("a")
    try call("1", "deploy", on: a.worker)
    simulation.run(for: .seconds(2))
    #expect(ssh.waiting == ["deploy"])

    simulation.kill(a.process)
    let b = try node("b")
    simulation.run(for: .seconds(40))
    guard case .unknown? = try replies(b.worker)["1"] else { Issue.record("expected an unknown outcome"); return }
    #expect(ssh.commands == ["deploy"])
  }

  @Test func aReadIsSentAgainWhenTheConnectionBreaks() throws {
    let a = try node("a")
    try call("1", "cat notes", retrySafe: true, on: a.worker)
    simulation.run(for: .seconds(2))
    ssh.cut("cat notes")
    simulation.run(for: .seconds(2))
    #expect(ssh.waiting == ["cat notes"])

    ssh.answer("cat notes", SSHOutput(status: 0, stdout: "hello\n"))
    simulation.run(for: .seconds(2))
    #expect(try replies(a.worker) == ["1": .output(SSHOutput(status: 0, stdout: "hello\n"))])
    #expect(ssh.connections == 2)
  }

  @Test func aReadSurvivesACrash() throws {
    let a = try node("a")
    try call("1", "cat notes", retrySafe: true, on: a.worker)
    simulation.run(for: .seconds(2))
    simulation.kill(a.process)
    let b = try node("b")
    simulation.run(for: .seconds(15))
    ssh.answer("cat notes", SSHOutput(status: 0, stdout: "hello\n"))
    simulation.run(for: .seconds(2))
    #expect(try replies(b.worker) == ["1": .output(SSHOutput(status: 0, stdout: "hello\n"))])
    #expect(ssh.commands == ["cat notes", "cat notes"])
  }
}
