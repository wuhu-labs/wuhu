import Dependencies
import Fetch
import Foundation
import JSONValue
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

extension SessionGateTests {
  @Test func capabilityRoutesAcceptLiveSessionTokensOnlyInTheirOwnGroup() async throws {
    try await withSessionDeps {
      let t = try await tree(dev: false, credentials: .init { _ in .apiKey("synthetic") })
      _ = try await t.harness.space.fs(.shared).write("/capabilities.json", Data(#"{"web_search":{"active":"brave","providers":{"brave":{"dialect":"brave","baseURL":"https://provider.test"}}},"image":{"active":"openai","providers":{"openai":{"dialect":"openai-images","baseURL":"https://provider.test"}}},"transcription":{"active":"openai","providers":{"openai":{"dialect":"openai-audio","baseURL":"https://provider.test"}}}}"#.utf8), ifMatch: nil)
      let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="
      let calls = LockIsolated(0)
      let provider = FetchClient { request in
        calls.withValue { $0 += 1 }
        let reply = request.url.path.contains("images") ? #"{"data":[{"b64_json":"\#(png)"}]}"# : request.url.path.contains("audio") ? #"{"text":"hello"}"# : #"{"web":{"results":[]}}"#
        return Response(status: .ok, body: .string(reply))
      }
      let audio = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!
      let routes: [(Fetch.Method, String, Body?)] = [
        (.get, "/v1/transcribe", nil),
        (.post, "/v1/transcribe", .bytes(audio, contentType: "audio/wav")),
        (.post, "/v1/web-search", try .json(["query": "moon"])),
        (.post, "/v1/image", try .json(["prompt": "moon"])),
      ]
      for (method, path, body) in routes {
        var request = Request(url: URL(string: "http://space" + path)!, method: method, body: body)
        request.headers[.authorization] = "Bearer " + t.token
        request.headers[GroupHeader.name] = GroupID.shared.rawValue
        if path == "/v1/transcribe", method == .post { request.headers[.contentType] = "audio/wav" }
        let accepted = try await withDependencies { $0.fetch = provider } operation: { try await t.harness.api(request) }
        #expect(accepted.status == .ok, "\(path)")
        if method == .get { #expect(try await accepted.text().contains("\"available\":true")) }
        request.headers[GroupHeader.name] = "another-group"
        let refused = try await t.harness.api(request)
        #expect(refused.status == .forbidden, "\(path)")
        #expect(try await refused.text().contains("groupMismatch"))
        request.headers[.authorization] = "Bearer " + ExecTokens.prefix + "invalid"
        request.headers[GroupHeader.name] = GroupID.shared.rawValue
        #expect(try await t.harness.api(request).status == .unauthorized, "\(path)")
      }
      #expect(calls.value == 3)
      try await t.harness.space.finishExec(t.exec, .exited(code: 0))
      for (method, path, body) in routes {
        var request = Request(url: URL(string: "http://space" + path)!, method: method, body: body)
        request.headers[.authorization] = "Bearer " + t.token
        #expect(try await t.harness.api(request).status == .unauthorized, "\(path)")
      }
      #expect(calls.value == 3)
    }
  }
}
