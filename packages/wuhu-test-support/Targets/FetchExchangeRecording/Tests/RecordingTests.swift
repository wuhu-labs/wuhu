#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchExchangeRecording
import Testing

@Suite struct RecordingTests {
  @Test(arguments: [false, true]) func oversizedEffectsAreRejected(live: Bool) async throws {
    let effect = RecordedEffect("oversized", input: ["value": String(repeating: "x", count: 129)])
    let recorder = live ? FetchExchangeRecorder(live: FetchClient { _ in .text("safe") }, bodyLimit: 128) : FetchExchangeRecorder(replay: ExchangeRecording(exchanges: [], effects: [effect]), bodyLimit: 128)
    await #expect(throws: RecordingError.capacityExceeded) { try await recorder.effect(effect) }
    #expect(await recorder.recording().effects.isEmpty)
  }

  @Test(arguments: [false, true]) func oversizedRequestHeadsAreRejected(live: Bool) async throws {
    var request = Request(url: URL(string: "http://test")!)
    request.headers["X-Oversized"] = String(repeating: "x", count: 16 * 1024)
    let recorder = live ? FetchExchangeRecorder(live: FetchClient { _ in Issue.record("oversized request dispatched"); return .text("safe") }) : FetchExchangeRecorder(replay: ExchangeRecording(exchanges: [.init(request: .init(method: "GET", url: request.url.absoluteString, headers: ["x-oversized": String(repeating: "x", count: 16 * 1024)]), response: .init(status: 200, body: Data("safe".utf8)))]))
    await #expect(throws: RecordingError.capacityExceeded) { try await recorder.client(request) }
  }

  @Test(arguments: [false, true]) func oversizedResponseHeadsAreRejected(live: Bool) async throws {
    let request = Request(url: URL(string: "http://test")!)
    let header = String(repeating: "x", count: 16 * 1024)
    let recorder: FetchExchangeRecorder
    if live {
      recorder = FetchExchangeRecorder(live: FetchClient { _ in var response = Response.text("safe"); response.headers[.init("X-Oversized")!] = header; return response })
    } else {
      recorder = FetchExchangeRecorder(replay: ExchangeRecording(exchanges: [.init(request: .init(method: "GET", url: request.url.absoluteString), response: .init(status: 200, headers: ["x-oversized": header], body: Data("safe".utf8)))]))
    }
    await #expect(throws: RecordingError.capacityExceeded) { try await recorder.client(request) }
  }

  @Test(arguments: ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-wuhu-supervisor-nonce"], [false, true])
  func credentialResponsesAreRejected(header: String, live: Bool) async throws {
    let request = Request(url: URL(string: "http://test")!)
    let recorder: FetchExchangeRecorder
    if live {
      recorder = FetchExchangeRecorder(live: FetchClient { _ in var response = Response.text("safe"); response.headers[.init(header)!] = "synthetic"; return response })
    } else {
      recorder = FetchExchangeRecorder(replay: ExchangeRecording(exchanges: [.init(request: .init(method: "GET", url: request.url.absoluteString), response: .init(status: 200, headers: [header: "synthetic"], body: Data("safe".utf8)))]))
    }
    await #expect(throws: RecordingError.unsafeHeaders) { try await recorder.client(request) }
  }

  @Test func effectsHaveAnIndependentReplayCap() async throws {
    let recording = ExchangeRecording(exchanges: [], effects: [.init("crash"), .init("restart")])
    let replay = FetchExchangeRecorder(replay: recording)
    try await replay.effect(.init("crash"))
    try await replay.effect(.init("restart"))
    try await replay.assertComplete()
  }

  @Test func sensitiveHeadersAreRefusedBeforeLiveDispatch() async throws {
    let recorder = FetchExchangeRecorder(live: FetchClient { _ in Issue.record("unsafe request dispatched"); return .text("wrong") })
    var request = Request(url: URL(string: "http://test")!)
    request.headers["Authorization"] = "Bearer synthetic"
    await #expect(throws: RecordingError.unsafeHeaders) { try await recorder.client(request) }
  }

  @Test func recordsFailuresStatusHeadersBodyAndEffects() async throws {
    let recorder = FetchExchangeRecorder(live: FetchClient { _ in .text("conflict", status: .conflict) })
    let request = Request(url: URL(string: "http://test/start")!, method: .post, body: .bytes(Data("once".utf8)))
    let response = try await recorder.client(request)
    #expect(response.status.code == 409)
    #expect(try await response.body.text() == "conflict")
    try await recorder.effect(.init("spawn", input: ["argv": "test"], output: ["exit": "3"]))
    let replay = FetchExchangeRecorder(replay: await recorder.recording())
    let result = try await replay.client(Request(url: request.url, method: .post, body: .bytes(Data("once".utf8))))
    #expect(result.status.code == 409)
    #expect(try await result.body.text() == "conflict")
    try await replay.effect(.init("spawn", input: ["argv": "test"], output: ["exit": "3"]))
    try await replay.assertComplete()
  }
}
