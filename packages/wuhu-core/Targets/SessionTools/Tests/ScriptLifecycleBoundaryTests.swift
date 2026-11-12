import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import LoopCore
import MainHub
import SessionDomain
import SpaceCore
import Testing

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct ScriptLifecycleBoundaryTests {
  @Test func archiveStopsDetachedScriptsAndDropsTheirLateOutput() async throws {
    try await withRig { rig in
      #expect(try await rig.evaluate("result('started'); try { await sleep(100000) } catch { update('late') }") == .string("started"))
      try await rig.worker.archive(rig.session, force: true)
      try await rig.released()
      #expect(try await rig.space.sessions.record(rig.session).lifecycle != .live)
      let delivered = try await rig.delivered()
      #expect(delivered.isEmpty, "unexpected script output: \(delivered)")
    }
  }

  @Test func restartCarriesAndDoesNotStopAnAlreadyRunningScript() async throws {
    let entered = Gate(), release = Gate()
    try await withRig(fetch: FetchClient { _ in
      entered.open()
      await release.wait()
      return Response.text("continue")
    }) { rig in
      defer { release.open() }
      #expect(try await rig.evaluate("result('started'); await fetch('https://script.test/release'); if (signal.aborted) throw Error('restart stopped the script'); update('survived restart')") == .string("started"))
      await entered.wait()
      let script = try #require(rig.running().first)
      let restart = try await rig.worker.restart(rig.session, executor: nil, note: "fresh generation")
      #expect(restart.generation == 1)
      #expect(rig.running() == [script])
      try await until("restarted") { try await rig.space.sessions.generationState(rig.session).generation == 1 }
      let stored = try #require(try await rig.space.sessions.transcriptLines(rig.session).first { $0.key == LineKey.head })
      guard case let .user(header) = try stored.line().message, case let .text(text)? = header.content.first else { throw Mismatch("restart did not write its head line") }
      #expect(text.text.contains(script))
      release.open()
      try await until("the live script posts after the session restarts") {
        let pending = try await rig.delivered()
        let lines = try await rig.space.sessions.transcriptLines(rig.session)
        return pending.contains("survived restart") || lines.contains { $0.role == .user && $0.message.contains("survived restart") }
      }
      try await rig.released()
      #expect(try await rig.space.sessions.generationState(rig.session).generation == 1)
    }
  }
}
