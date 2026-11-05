import struct Credentials.CredentialResolver
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
@testable import SessionTools
import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize
import Testing

private let scriptPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8) + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
private let scriptGIF = Data(base64Encoded: "R0lGODlhAwACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQADAAAACwAAAAAAwACAAAIBgABCBwYEAAh+QQBDAABACwAAAAAAwACAIEAAP8AAAAAAAAAAAAIBgABCBwYEAA7")!
private let scriptWAV = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!

@Suite(.deterministicDependencies) struct ScriptCapabilityTests {
  @Test func allCapabilitiesAreDeclaredWhenUnconfiguredAndErrorsAreTyped() async throws {
    try await withRig { rig in
      _ = try await rig.space.fs(.shared).write("/audio.wav", scriptWAV, ifMatch: nil)
      try await rig.run("capability-errors")
      try rig.expect("capability-errors")
    }
  }

  @Test func scriptsUseConfiguredProvidersEvenWhenCodexIsLoggedIn() async throws {
    let seen = Box<[String]>([])
    let fetch = FetchClient { request in
      seen.withLock { $0.append(request.url.absoluteString) }
      let path = request.url.path
      let body: String
      switch path {
      case "/web/search": body = #"{"web":{"results":[{"title":"Synthetic title","url":"https://example.test","description":"Synthetic snippet"}]}}"#
      case "/images/generations", "/images/edits": body = #"{"data":[{"b64_json":"\#(scriptPNG.base64EncodedString())"}]}"#
      case "/files" where request.method == .post: body = #"{"data":{"uploaded_files":[{"file_id":"owned"}]}}"#
      case "/files/owned" where request.method == .get: body = #"{"data":{"url":"http://storage/audio?signature=fixture"}}"#
      case "/services/audio/asr/transcription": body = #"{"output":{"task_id":"task","task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://storage/result"}]}}"#
      case "/result":
        #expect(request.headers.sensitiveValues.isEmpty)
        body = #"{"transcripts":[{"text":"hello","sentences":[{"text":"hello","begin_time":100,"end_time":1000,"speaker_id":1,"words":[{"text":"hello","begin_time":100,"end_time":1000}]}]}]}"#
      default: body = "{}"
      }
      _ = try await request.body?.data()
      return Response(status: .ok, body: .string(body))
    }
    let credentials = CredentialResolver { id in id == "codex" ? .chatGPT(accessToken: "private-token", accountID: "account") : .apiKey("private-key") }
    try await withRig(fetch: fetch, credentials: credentials) { rig in
      try await rig.write("/capabilities.json", #"{"web_search":{"active":"brave","providers":{"brave":{"dialect":"brave","baseURL":"https://fake.provider"}}},"image":{"active":"openai","providers":{"openai":{"dialect":"openai-images","baseURL":"https://fake.provider"}}},"transcription":{"active":"qwen","providers":{"qwen":{"dialect":"dashscope","baseURL":"https://fake.provider"}}}}"#)
      _ = try await rig.space.fs(.shared).write("/audio.wav", scriptWAV, ifMatch: nil)
      _ = try await rig.space.fs(.shared).write("/reference.png", scriptPNG, ifMatch: nil)
      try await rig.run("capabilities")
      try rig.expect("capabilities")
      #expect(seen.value.count == 8)
      #expect(seen.value.allSatisfy { !$0.contains("chatgpt") })
      #expect(try await rig.space.fs(.shared).read("/art/edited.png").1 == scriptPNG)
    }
  }

  @Test func aGIFDestinationSendsTheFrameFieldsAndAnswersFromTheBytes() async throws {
    let bodies = Box<[JSONValue]>([])
    let fetch = FetchClient { request in
      let body = JSONValue.parse(try await request.body?.text() ?? "") ?? .null
      bodies.withLock { $0.append(body) }
      return Response(status: .ok, body: .string(#"{"data":[{"b64_json":"\#(scriptGIF.base64EncodedString())"}]}"#))
    }
    try await withRig(fetch: fetch, credentials: CredentialResolver { _ in .apiKey("private-key") }) { rig in
      try await rig.write("/capabilities.json", #"{"image":{"active":"openai","providers":{"openai":{"dialect":"openai-images","baseURL":"https://fake.provider"}}}}"#)
      _ = try await rig.space.fs(.shared).write("/reference.png", scriptPNG, ifMatch: nil)
      try await rig.run("gif-capability")
      try rig.expect("gif-capability")
      #expect(bodies.value == [["prompt": "a fox waving", "model": "gpt-image-2.6-flare", "n": 1, "output_format": "gif", "frame_count": 2, "frame_duration_ms": 120]])
      #expect(try await rig.space.fs(.shared).read("/art/fox.gif").1 == scriptGIF)
    }
  }

  @Test func aGIFIsInspectedAndItsFramesRenderedToAPNGWithoutAProvider() async throws {
    try await withRig { rig in
      for (path, bytes) in [("/lights.gif", lightsGIF), ("/still.png", scriptPNG), ("/notes.txt", Data("red, green, blue".utf8))] {
        _ = try await rig.space.fs(.shared).write(path, bytes, ifMatch: nil)
      }
      try await rig.run("gif-frames")
      try rig.expect("gif-frames")
      for (path, size) in [("/art/lights.png", PixelSize(width: 4, height: 4)), ("/art/picked.png", PixelSize(width: 4, height: 2))] {
        let png = try await rig.space.fs(.shared).read(path).1
        #expect(ImageMedia.mimeType(ofBytes: png) == "image/png" && ImageMedia.pixelSize(ofBytes: png) == size)
      }
    }
  }
}

// Pillow's 2×2 GIF of a red, a green and a blue frame shown 100, 200 and 300 ms.
private let lightsGIF = Data(base64Encoded: "R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBFAABACwAAAAAAgACAIEA/wAAAAAAAAAAAAAIBgABCAQQEAAh+QQBHgABACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7")!
