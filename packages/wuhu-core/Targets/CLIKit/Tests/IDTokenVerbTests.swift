@testable import CLIKit
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import Scratch
import Synchronization
import Testing

private actor Sink {
  var text = ""
  func append(_ text: String) { self.text += text }
}

private let capability = "wit_" + String(repeating: "a", count: 64)

private func idToken(_ arguments: [String], environment: [String: String], reply: Response) async throws -> (code: Int32, stdout: String, stderr: String, requests: [Request]) {
  let scratch = try ScratchFolder("id-token-verb")
  let stdout = Sink(), stderr = Sink()
  let seen = Mutex<[Request]>([])
  let runner = CommandRunner(
    fetch: FetchClient { request in seen.withLock { $0.append(request) }; return reply },
    stdin: { "" },
    stdout: { await stdout.append($0) },
    stderr: { await stderr.append($0) },
    environment: ["HOME": scratch.path].merging(environment) { _, new in new },
    currentDirectory: scratch.path,
  )
  let code = await runner.run(arguments: ["id-token"] + arguments)
  return (code, await stdout.text, await stderr.text, seen.withLock { $0 })
}

@Suite(.deterministicDependencies) struct IDTokenVerbTests {
  static let exec = ["WUHU_ID_TOKEN_URL": "https://space.test/v1/id-token", "WUHU_ID_TOKEN_REQUEST": capability]

  @Test func parsesTheAudienceAndRequiresIt() throws {
    #expect(try Command.parse(["id-token", "--audience", "https://pool.example"]) == .idToken(audience: "https://pool.example", json: false))
    #expect(try Command.parse(["id-token", "--audience", "https://pool.example", "--json"]) == .idToken(audience: "https://pool.example", json: true))
    #expect(throws: UsageError.self) { try Command.parse(["id-token"]) }
  }

  @Test func presentsOnlyTheCapabilityAndPrintsTheToken() async throws {
    let reply = try Response.json(JSONValue.object(["token": "header.claims.signature", "expiresAt": 1_800_000_060]))
    let run = try await idToken(["--audience", "https://pool.example"], environment: Self.exec.merging(["WUHU_TOKEN": "wst_session"]) { _, new in new }, reply: reply)
    #expect(run.code == 0)
    #expect(run.stdout == "header.claims.signature\n")
    let request = try #require(run.requests.first)
    #expect(run.requests.count == 1)
    #expect(request.url.absoluteString == "https://space.test/v1/id-token?audience=https://pool.example")
    #expect(request.headers[.authorization] == "Bearer " + capability)
  }

  @Test func jsonPrintsTheExpiryToo() async throws {
    let reply = try Response.json(JSONValue.object(["token": "t", "expiresAt": 1_800_000_060]))
    let run = try await idToken(["--audience", "https://pool.example", "--json"], environment: Self.exec, reply: reply)
    #expect(run.code == 0)
    #expect(JSONValue.parse(run.stdout) == ["token": "t", "expiresAt": 1_800_000_060])
  }

  @Test func outsideASessionsExecItRefusesWithoutAsking() async throws {
    let run = try await idToken(["--audience", "https://pool.example"], environment: [:], reply: Response(status: .ok))
    #expect(run.code == 1)
    #expect(run.stderr.contains("only a session's exec can mint one"))
    #expect(run.requests.isEmpty)
  }

  @Test func theServersRefusalIsShown() async throws {
    let reply = try Response.json(JSONValue.object(["code": "unauthorized", "message": "this id-token request's exec ex_aaaaaaaa has ended"]), status: .unauthorized)
    let run = try await idToken(["--audience", "https://pool.example"], environment: Self.exec, reply: reply)
    #expect(run.code == 1)
    #expect(run.stderr.contains("id-token: this id-token request's exec ex_aaaaaaaa has ended"))
  }
}
