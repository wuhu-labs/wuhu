import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import Scratch
import SessionDomain
@testable import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies) struct Migration035Tests {
  @Test func existingSQLSlotsRewatchThroughTheirOwnersOnFirstStart() async throws {
    try await withToolDeps { time in
      let folder = try ScratchFolder("migration-035")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let session = try await makeSession(old)
      let child = try await old.sessions.createSession(
        group: .shared, title: "child to recover", kind: .task, parent: session, createdBy: "morgan",
        executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )
      let plain = try SpacePath(validating: "/plain.table")
      let handled = try SpacePath(validating: "/handled.table")
      let grouped = try SpacePath(validating: "/grouped.table")
      let output = try SpacePath(validating: "/output.table")
      for path in [plain, handled, grouped, output] {
        _ = try await old.createTable(path, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      }
      _ = try await old.fs(.shared).write("/recover.js", Data("export default ({wake}) => { wake('handler recovered'); };".utf8), ifMatch: nil)
      _ = try await old.fs(.shared).write("/group-recover.js", Data("""
      import {mutateRows} from 'wuhu:space';
      export default async () => { await mutateRows('/output.table', [{insert: {n: 1}}]); };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(old) { worker, _ in
        try await worker.interrupt(session)
        try await until("the owner is held") { try await old.sessions.record(session).hold == .interrupted }
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("observe", .object(["sql": "SELECT n FROM \"/plain.table\"", "throttle_seconds": 1]))
        _ = try await world.run("observe", .object(["sql": "SELECT n FROM \"/handled.table\"", "throttle_seconds": 1, "handler": "/recover.js"]))
        let statement = "SELECT n FROM \"/grouped.table\""
        _ = try await old.sessions.armObserver(
          .shared, ObserverTerms(name: "recover"),
          slot: SubscriptionSlot(id: SubscriptionID("group-recover"), kind: .observe(sql: statement, throttleSeconds: 1), handler: "/group-recover.js"),
          marker: rowsMarker(try await old.query(statement, as: .shared(.anonymous))),
        )
        try await until("all old registrations have their baseline") {
          try await old.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM observation_slots WHERE marker IS NOT NULL") == 4 }
        }
        #expect(try await handlerNotifications(old, session).isEmpty)
        try await until("the old worker has no remaining mail") {
          try await old.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM wuwei_mail") == 0 }
        }
      }
      let before = try await old.sessions.armedSubscriptions()
      try await old.close()

      var configuration = Configuration()
      configuration.busyMode = .timeout(5)
      let fixture = try DatabaseQueue(path: file.path, configuration: configuration)
      try await fixture.write { db in
        try db.execute(sql: """
        DELETE FROM observation_slots;
        DELETE FROM observer_watched;
        DELETE FROM grdb_migrations WHERE identifier = '035';
        """)
      }
      try fixture.close()

      let upgraded = try Space.open(file: file)
      #expect(try await upgraded.sessions.armedSubscriptions() == before)
      let recipients = try await upgraded.writer.read { try String.fetchAll($0, sql: "SELECT recipient FROM wuwei_mail ORDER BY recipient") }
      #expect(recipients == [
        "ObserverCell/group:shared:group-recover",
        "ObserverCell/session:\(session.rawValue):\(before.first { $0.slot.handler == "/recover.js" }!.slot.id.rawValue)",
        "SessionCell/\(session.rawValue)",
      ])
      let reopened = try Space.open(file: file)
      #expect(try await reopened.writer.read { try String.fetchAll($0, sql: "SELECT recipient FROM wuwei_mail ORDER BY recipient") } == recipients)
      try await reopened.close()

      try await withHandlerFiring(upgraded) { _, _ in
        try await until("the first scan delivers migration mail and owners watch") {
          try await upgraded.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM observation_slots WHERE marker IS NOT NULL") == 4 }
        }
        #expect(try await handlerNotifications(upgraded, session).isEmpty)
        _ = try await upgraded.mutateRows(plain, [.insert([.integer(1)])], in: .shared, acting: .shared)
        _ = try await upgraded.mutateRows(handled, [.insert([.integer(1)])], in: .shared, acting: .shared)
        _ = try await upgraded.mutateRows(grouped, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await upgraded.sessions.markErrored(child, message: "recover this child")
        try await untilAdvancing("each recovered owner hears once", time) {
          let notices = try await handlerNotifications(upgraded, session)
          let output = try await upgraded.query("SELECT n FROM \"/output.table\"", as: .shared(.anonymous))
          return notices.count == 3 && output.rows.count == 1
        }
        let notices = try await handlerNotifications(upgraded, session).map(\.content.text)
        #expect(notices.count { $0.contains("observed change for SELECT n FROM \"/plain.table\"") } == 1)
        #expect(notices.count { $0.contains("Your children errored:") && $0.contains("child to recover") } == 1)
        #expect(notices.count { $0 == "handler recovered" } == 1)
        try await holds("the recovered watches deliver exactly once") {
          let notices = try await handlerNotifications(upgraded, session)
          let output = try await upgraded.query("SELECT n FROM \"/output.table\"", as: .shared(.anonymous))
          return notices.count == 3 && output.rows == [[.integer(1)]]
        }
      }
      try await upgraded.close()
    }
  }
}
