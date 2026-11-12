import ControlledTime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import OperationProtocol
import Scratch
@testable import SpaceCore
import Testing
import Wuwei

extension MachineCellTests {
  enum CrashWake: CaseIterable, Sendable {
    case describeAt, describeDeadline, waitingPoll, retryPoll, stopAt, answerAt, stopAndAnswerAt, unopenedReservation, expiredLease

    var restartAfter: Double {
      switch self {
      case .answerAt: 45
      case .stopAndAnswerAt: 55
      case .unopenedReservation, .expiredLease: 65
      default: 30
      }
    }

    var timeout: Double? {
      switch self {
      case .stopAt, .stopAndAnswerAt: 20
      case .answerAt: 1
      default: nil
      }
    }

    var endsBeforeRedial: Bool { self == .answerAt || self == .stopAndAnswerAt || self == .expiredLease }
  }

  @Test(arguments: CrashWake.allCases)
  func `a copied attached machine advances expired wakes without a socket and redials once`(_ deadline: CrashWake) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("machine-before-crash")
      let file = folder.url.appending(path: "space.sqlite")
      let crashed = try ScratchFolder("machine-after-crash")
      let copy = crashed.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let buffers = setup(old)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(old, requests)
      try await described(peer, old)
      let exec = MachineExec(id: "crash-live", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"], timeout: deadline.timeout)
      try await starting(old, peer, exec)
      let before = Data("before".utf8)
      let pointer = try #require(buffers.put(before, operation: exec.operation, channel: "stdout", from: 0))
      peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 0, through: 6), output: pointer, tail: before))))
      try await until("the live process is polling its committed offset before the crash copy") {
        old.worker.cell(cell).operation(exec.id)?.stdout == 6
          && requests.value.contains { if case let .poll(operation, channel, after, _, _, _) = $0.exchange { operation == exec.operation && channel == "stdout" && after == 6 } else { false } }
      }
      let epoch = old.worker.scheduler.now.milliseconds
      let reserved = MachineExec(id: "crash-unopened", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      if deadline == .unopenedReservation {
        _ = try await old.worker.call(cell) { try $0.reserve(reserved) }
      }
      try await old.worker.call(cell) { machine in
        var presence = machine.presence
        presence.describeAt = nil
        presence.describeDeadline = nil
        if deadline == .describeAt { presence.describeAt = epoch + 20000 }
        if deadline == .describeDeadline { presence.describeDeadline = epoch + 20000 }
        if deadline == .unopenedReservation { presence.lease = epoch + 120_000 }
        try machine.save(presence)
        var row = machine.operation(exec.id)!
        row.flights = [
          .control: ExecFlight(due: epoch + 20000, waiting: deadline != .retryPoll),
          .output("stdout"): ExecFlight(due: epoch + 20000, waiting: deadline != .retryPoll),
          .output("stderr"): ExecFlight(due: epoch + 20000, waiting: deadline != .retryPoll),
        ]
        if deadline == .answerAt {
          row.stop = "timeout"
          row.state = "stopping"
          row.stopAt = nil
          row.answerAt = epoch + 31000
        }
        try machine.save(row)
      }
      #expect(old.worker.cell(cell).presence.state == "attached")
      #expect(old.worker.cell(cell).operation(exec.id)?.terminal == false)
      let flights = try #require(old.worker.cell(cell).operation(exec.id)).flights
      var expectedFlights: Set<BoxPurpose> = [.control, .output("stdout"), .output("stderr")]
      if deadline == .answerAt { expectedFlights.insert(.stop) }
      #expect(Set(flights.keys) == expectedFlights)
      do {
        let source = try DatabaseQueue(path: file.path)
        try source.backup(to: DatabaseQueue(path: copy.path))
      }
      peer.close()
      try await old.close()
      await time.advance(to: anchor.addingTimeInterval(deadline.restartAfter))

      let new = try Space.open(file: copy)
      new.worker.start()
      try await crashWakeSettles(new)
      try expectNoExpiredMachineWake(new)
      #expect(new.worker.cell(cell).presence.describeAt == nil)
      #expect(new.worker.cell(cell).presence.describeDeadline == nil)
      if deadline == .expiredLease {
        #expect(new.worker.cell(cell).presence.state == "lost")
        #expect(new.worker.cell(cell).presence.lease == nil)
        #expect(new.worker.cell(cell).operation(exec.id)?.diagnostic?.code == .unknownOperation)
      } else {
        #expect(new.worker.cell(cell).presence.state == "attached")
        let lease = try #require(new.worker.cell(cell).presence.lease)
        #expect(lease > new.worker.scheduler.now.milliseconds)
      }
      if deadline == .stopAt {
        #expect(new.worker.cell(cell).operation(exec.id)?.stop == "timeout")
        #expect(new.worker.cell(cell).operation(exec.id)?.stopAt == nil)
        #expect(new.worker.cell(cell).operation(exec.id)?.answerAt == epoch + 50000)
      }
      if deadline == .answerAt || deadline == .stopAndAnswerAt {
        #expect(new.worker.cell(cell).operation(exec.id)?.diagnostic?.code == .requestDeadline)
      }
      if deadline == .unopenedReservation {
        #expect(new.worker.cell(cell).operation(reserved.id)?.terminal == true)
        #expect(new.worker.cell(cell).operation(reserved.id)?.diagnostic?.code == .operationEnded)
      }
      #expect(new.worker.cell(cell).operation(exec.id)?.terminal == deadline.endsBeforeRedial)
      await time.advance(by: 0.25)
      try await crashWakeSettles(new)
      try expectNoExpiredMachineWake(new)

      let redialRequests = Box<[BoxSocket.Outgoing]>([])
      let redial = try await attach(new, redialRequests)
      try await described(redial, new)
      #expect(!redialRequests.value.contains { if case .start = $0.exchange { true } else { false } })
      if !deadline.endsBeforeRedial {
        try await until("redial resumes the original operation at its committed offset") {
          redialRequests.value.contains { if case let .poll(operation, channel, after, _, _, _) = $0.exchange { operation == exec.operation && channel == "stdout" && after == 6 } else { false } }
        }
        let after = Data("after".utf8)
        let pointer = try #require(new.machineBuffers.put(after, operation: exec.operation, channel: "stdout", from: 6))
        redial.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot(exec, channel: "stdout", from: 6, through: 11, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), finals: ["stdout": .init(rawValue: 11)]), output: pointer, tail: after))))
        try await until("the resumed exec finishes once") { new.worker.cell(cell).operation(exec.id)?.delivered == true }
        #expect(new.worker.cell(cell).tail(exec.id) == Data("beforeafter".utf8))
      }
      let mails = try await new.writer.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM wuwei_mail WHERE recipient = 'test-recipient/exec'") }
      #expect(mails.count == 1)
      let result = try JSONDecoder().decode(MachineExecReply.self, from: #require(mails.first))
      guard case let .finished(end) = result else {
        Issue.record("the restarted cell must finish its original waiter")
        throw UnexpectedCall("crash finish")
      }
      #expect(end.id == exec.id)
      if !deadline.endsBeforeRedial {
        #expect(end.status == .exited(code: 0))
        #expect(end.tail == Data("beforeafter".utf8))
      }
      redial.close()
      try await new.close()
    }
  }

  private func crashWakeSettles(_ space: Space) async throws {
    try await until("the copied worker moves its due wake strictly into the future") {
      try await space.writer.read { db in
        try Bool.fetchOne(db, sql: "SELECT holder = ? AND (wake_at IS NULL OR wake_at > ?) FROM wuwei_addressable WHERE address = ?", arguments: [space.worker.id, space.worker.scheduler.now.milliseconds, cell.description]) == true
      }
    }
  }

  private func expectNoExpiredMachineWake(_ space: Space) throws {
    let machine = space.worker.cell(cell)
    let now = space.worker.scheduler.now.milliseconds
    if let next = machine.nextWake() { #expect(next.milliseconds > now) }
    for due in [machine.presence.lease, machine.presence.describeAt, machine.presence.describeDeadline].compactMap({ $0 }) {
      #expect(due > now)
    }
    for row in machine.db.rows(MachineOperation.live) {
      if !row.opened { #expect(row.created + 60000 > now) }
      for due in [row.stopAt, row.answerAt].compactMap({ $0 }) { #expect(due > now) }
      for flight in row.flights.values where flight.waiting { #expect(flight.due > now) }
    }
  }
}
