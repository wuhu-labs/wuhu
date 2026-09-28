import struct Credentials.CredentialResolver
import Fetch
import Foundation
import JSONValue
@testable import SessionTools
import Testing

// A 1536x1024 PNG header: signature, then the IHDR chunk's length, type and fields.
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
  + Data("IHDR".utf8) + Data([0, 0, 0x06, 0, 0, 0, 0x04, 0, 8, 6, 0, 0, 0])

private let chatGPT = CredentialResolver { _ in .chatGPT(accessToken: "token", accountID: "account") }

private let models = #"""
{"codex": {"dialect": "codex", "baseURL": "https://chatgpt.com/backend-api/codex", "models": {}}}
"""#

private final class ImageProvider: Sendable {
  let started = Box<[String]>([])
  let peak = Box(0)
  let cancelled = Box(0)
  private let inFlight = Box(0)
  private let respond: @Sendable (ImageProvider, String) async throws -> Response

  init(_ respond: @escaping @Sendable (ImageProvider, String) async throws -> Response) {
    self.respond = respond
  }

  var client: FetchClient {
    FetchClient { request in
      let body = try #require(JSONValue.parse(try await request.body?.text() ?? ""))
      guard case let .object(fields) = body, case let .string(prompt)? = fields["prompt"] else {
        throw Mismatch("no prompt in \(body)")
      }
      self.started.withLock { $0.append(prompt) }
      let now = self.inFlight.withLock {
        $0 += 1
        return $0
      }
      self.peak.withLock { $0 = max($0, now) }
      defer { self.inFlight.withLock { $0 -= 1 } }
      do {
        return try await self.respond(self, prompt)
      } catch is CancellationError {
        self.cancelled.withLock { $0 += 1 }
        throw CancellationError()
      }
    }
  }
}

private func image() -> Response {
  Response(status: .ok, body: .string(#"{"data":[{"b64_json":"\#(png.base64EncodedString())"}]}"#))
}

private func hang() async throws -> Response {
  for await _ in AsyncStream<Void>.makeStream().stream {}
  throw CancellationError()
}

@Suite struct ScriptAITests {
  // Each provider call holds until four are in flight, so the batch finishes
  // only if four run at once, and a fifth in flight would raise the peak.
  @Test func generatesInParallelAtMostFourAtATime() async throws {
    let provider = ImageProvider { provider, _ in
      try await until("four requests in flight") { provider.started.value.count >= 4 }
      return image()
    }
    let machineFS = FakeMachineFS()
    try await withRig(fetch: provider.client, machines: machineFS.seam, credentials: chatGPT) { rig in
      try await rig.write("/models.json", models)
      try await rig.run("ai-batch")
      rig.probe("prompts: \(provider.started.value.sorted()), peak in flight: \(provider.peak.value)")
      for name in ["moon", "sun", "comet", "star", "nebula"] {
        #expect(try await rig.space.fs(.shared).read("/art/\(name).png").1 == png)
      }
      #expect(machineFS.files.withLock { $0["/tmp/void.png"]?.content } == [UInt8](png))
      try rig.expect("ai-batch")
    }
  }

  @Test func stopCancelsEveryCallAndWritesNothing() async throws {
    let provider = ImageProvider { _, _ in try await hang() }
    try await withRig(fetch: provider.client, credentials: chatGPT) { rig in
      try await rig.write("/models.json", models)
      try await rig.run("ai-stop")
      try await until("four requests in flight") { provider.started.value.count == 4 }
      try await rig.stop(scriptID)
      try await rig.messages(1)
      try await rig.released()
      rig.probe("started: \(provider.started.value.count), cancelled: \(provider.cancelled.value)")
      rig.probe("written: \((try? await rig.space.fs(.shared).list("/art").1.map(\.name)) ?? [])")
      try rig.expect("ai-stop")
    }
  }

  @Test func eachFailureRejectsOnlyItsOwnCall() async throws {
    let provider = ImageProvider { _, prompt in
      prompt == "forbidden"
        ? Response(status: .badRequest, body: .string(#"{"error":{"message":"rejected by the safety system"}}"#))
        : image()
    }
    try await withRig(fetch: provider.client, credentials: chatGPT) { rig in
      try await rig.write("/models.json", models)
      try await rig.write("/art/kept.png", "kept")
      try await rig.run("ai-failures")
      rig.probe("prompts: \(provider.started.value.sorted())")
      #expect(try await rig.space.fs(.shared).read("/art/kept.png").1 == Data("kept".utf8))
      #expect(try await rig.space.fs(.shared).read("/art/fine.png").1 == png)
      try rig.expect("ai-failures")
    }
  }

  // The batch holds at the provider until three calls are there, so both
  // machine twins would pass the existence check before either wrote.
  @Test func oneRunNeverWritesOneMachinePathTwice() async throws {
    let provider = ImageProvider { provider, prompt in
      if prompt == "forbidden" {
        return Response(status: .badRequest, body: .string(#"{"error":{"message":"rejected by the safety system"}}"#))
      }
      try await until("three requests in flight") { provider.started.value.count >= 3 }
      return image()
    }
    let machineFS = FakeMachineFS()
    try await withRig(fetch: provider.client, machines: machineFS.seam, credentials: chatGPT) { rig in
      try await rig.write("/models.json", models)
      try await rig.run("ai-same-path")
      rig.probe("prompts: \(provider.started.value.sorted())")
      rig.probe("machine files: \(machineFS.files.withLock { $0.keys.sorted() })")
      try rig.expect("ai-same-path")
    }
  }
}
