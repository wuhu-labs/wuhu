import Crypto
import DeterministicDependencies
import Fetch
import Foundation
import ServerTelemetry
import Synchronization
import Testing

private let shebang = "#!/usr/bin/env -S wuhu script\n"

private func hex(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite(.deterministicDependencies) struct ScriptCLITests {
  private func script(_ h: IdentityHarness, _ source: String) throws -> String {
    let file = h.cwd.appendingPathComponent("run.js")
    try Data(source.utf8).write(to: file)
    return file.lastPathComponent
  }

  @Test func aShebangFilePrintsItsResultThenItsUpdatesAndItsSpanRecordsTheSourceHash() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let source = shebang + """
      result("args " + import.meta.args.length)
      update("one " + import.meta.args[0])
      update("two")
      """
      let file = try script(h, source)
      let spans = Mutex<[FinishedSpan]>([])
      let run = await ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
        await h.asSession(["script", file, "a", "--b"])
      }
      #expect(run.code == 0, "\(run.stderr)")
      #expect(run.stdout == "args 2\none a\ntwo\n")
      let scripts = spans.withLock { $0.filter { $0.name == .script } }
      #expect(scripts.map(\.attributes[.kind]) == ["wuhu_script"])
      #expect(scripts.map(\.attributes[.sourceSHA256]) == [hex(source)])
      #expect(scripts.map(\.attributes[.outcome]) == ["ok"])
    }
  }

  @Test func aScriptThatFailsOrNeverAnswersExitsNonzeroWithTheReason() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let threw = await h.asSession(["script", try script(h, "console.log(\"before\")\nthrow new Error(\"boom\")\n")])
      #expect(threw.code == 1)
      #expect(threw.stdout.isEmpty)
      #expect(threw.stderr.contains("threw before calling result(): Error: boom"), "\(threw.stderr)")

      let silent = await h.asSession(["script", try script(h, "console.log(\"quiet\")\n")])
      #expect(silent.code == 1)
      #expect(silent.stderr.contains("finished without calling result()"), "\(silent.stderr)")
      #expect(silent.stderr.contains("quiet"), "the console tail comes with the reason")

      let after = await h.asSession(["script", try script(h, "result(\"ok\")\nupdate(\"then\")\nthrow new Error(\"late\")\n")])
      #expect(after.code == 1)
      #expect(after.stdout == "ok\nthen\n")
      #expect(after.stderr.contains("failed after its result: Error: late"), "\(after.stderr)")
    }
  }

  @Test func aStreamThatStopsBeforeTheRunEndsExitsNonzero() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let file = try script(h, "result(\"half\")\n")
      let cut = FetchClient { request in
        guard request.url.path == "/v1/scripts" else { return try await h.fetch(request) }
        return Response(status: .ok, body: .chunk(Data(#"data: {"kind":"result","text":"half"}\#n\#n"#.utf8), contentType: "text/event-stream"))
      }
      let run = await h.run(["script", file], environment: h.sessionEnvironment, fetch: cut)
      #expect(run.code == 1)
      #expect(run.stdout == "half\n")
      #expect(run.stderr.contains("script: the server closed the stream before the run ended"), "\(run.stderr)")
    }
  }

  @Test func aTerminalCallerIsRefusedBeforeReachingAServer() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let file = try script(h, "result(1)\n")
      let refused = await h.run(["script", file], environment: ["HOME": h.home.path])
      #expect(refused.code == 64)
      #expect(refused.stderr.contains("script: only a session runs scripts, from its own exec (WUHU_EXEC=1)"), "\(refused.stderr)")
      #expect(refused.hosts.isEmpty)
    }
  }
}
