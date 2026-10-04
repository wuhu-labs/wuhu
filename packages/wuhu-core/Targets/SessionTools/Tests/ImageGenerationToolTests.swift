import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Synchronization
import Testing

private let generatedPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==")!

private struct ImageRequestSnapshot: Sendable {
  var url: String
  var method: String
  var headers: [String: String]
  var sensitiveHeaders: [String: String]
  var body: JSONValue
}

private final class ImageRequestRecorder: Sendable {
  let snapshots = Mutex<[ImageRequestSnapshot]>([])

  var client: FetchClient {
    FetchClient { request in
      let body = try #require(JSONValue.parse(try await request.body?.text() ?? ""))
      self.snapshots.withLock {
        $0.append(ImageRequestSnapshot(
          url: request.url.absoluteString,
          method: request.method.rawValue,
          headers: request.headers.values,
          sensitiveHeaders: request.headers.sensitiveValues,
          body: body,
        ))
      }
      let encoded = generatedPNG.base64EncodedString()
      return Response(
        status: .ok,
        body: .string(#"{"created":1758,"data":[{"b64_json":"\#(encoded)","generation_id":"gen_1"}],"output_format":"png"}"#),
      )
    }
  }
}

private func installModels(_ space: Space) async throws {
  _ = try await space.fs(.shared).write(ModelsPath, Data(#"""
  {
    "codex": {
      "dialect": "codex",
      "baseURL": "https://chatgpt.com/backend-api/codex",
      "originator": "wuhu-test",
      "models": {
        "gpt-5.6-sol": {"maxInput": 100000, "maxOutput": 10000, "efforts": ["high"], "defaultEffort": "high"}
      }
    },
    "deepseek": {
      "dialect": "anthropic",
      "baseURL": "https://api.deepseek.test",
      "models": {
        "deepseek-v4-pro": {"maxInput": 100000, "maxOutput": 10000, "efforts": ["high"], "defaultEffort": "high"}
      }
    }
  }
  """#.utf8), ifMatch: nil)
}

private func installModelsWithoutCodex(_ space: Space) async throws {
  _ = try await space.fs(.shared).write(ModelsPath, Data(#"""
  {
    "deepseek": {
      "dialect": "anthropic",
      "baseURL": "https://api.deepseek.test",
      "models": {
        "deepseek-v4-pro": {"maxInput": 100000, "maxOutput": 10000, "efforts": ["high"], "defaultEffort": "high"}
      }
    }
  }
  """#.utf8), ifMatch: nil)
}

private let ModelsPath = "/models.json"

@Suite struct ImageGenerationToolTests {
  @Test func codexRequestWritesAReadablePNGWithoutReturningItsBase64() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModels(space)
      let session = try await space.sessions.createSession(
        group: .shared,
        title: "image",
        kind: .agent,
        createdBy: "morgan",
        executor: .kernel(ModelSpecifier(provider: "codex", model: "gpt-5.6-luna", effort: "high")),
      )
      let recorder = ImageRequestRecorder()
      var world = ToolWorld(
        executor: ToolExecutor(
          space: space,
          credentials: CredentialResolver { _ in .chatGPT(accessToken: "token", accountID: "account") },
        ),
        session: session,
      )

      let generated = try await withDependencies {
        $0.fetch = recorder.client
      } operation: {
        try await world.run(
          "generate_image",
          .object(["prompt": "a tiny moon", "destination": "/art/moon.png"]),
          id: "image-call",
        )
      }
      guard case let .write(result) = generated else {
        throw Mismatch("generate_image did not return a written path")
      }
      #expect(result.path == "/art/moon.png")
      #expect(generated.renderedText == "wrote /art/moon.png")
      #expect(!generated.renderedText.contains(generatedPNG.base64EncodedString()))
      #expect(try await space.fs(.shared).read(result.path).1 == generatedPNG)

      guard case let .read(read) = try await world.run("read", .object(["path": .string(result.path)])) else {
        throw Mismatch("generated image was not readable")
      }
      #expect(read.path == result.path)
      #expect(read.image?.mimeType == "image/png")
      #expect(try await space.imageBytes(try #require(read.image)) == generatedPNG)

      let request = try #require(recorder.snapshots.withLock { $0.first })
      #expect(recorder.snapshots.withLock(\.count) == 1)
      #expect(request.url == "https://chatgpt.com/backend-api/codex/images/generations")
      #expect(request.method == "POST")
      #expect(request.headers["originator"] == "wuhu-test")
      #expect(request.sensitiveHeaders["authorization"] == "Bearer token")
      #expect(request.sensitiveHeaders["chatgpt-account-id"] == "account")
      #expect(request.body == .object([
        "model": "gpt-image-2",
        "n": 1,
        "prompt": "a tiny moon",
        "size": "1024x1024",
      ]))

      let replayed = try await withDependencies {
        $0.fetch = recorder.client
      } operation: {
        try await world.retry(
          "generate_image",
          .object(["prompt": "different", "destination": "/art/moon.png"]),
          id: "image-call",
        )
      }
      #expect(replayed == generated)
      #expect(recorder.snapshots.withLock(\.count) == 1)
    }
  }

  @Test func aMachineDestinationReceivesThePNG() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModels(space)
      let machineFS = FakeMachineFS()
      let recorder = ImageRequestRecorder()
      var world = ToolWorld(
        executor: ToolExecutor(
          space: space,
          machines: machineFS.seam,
          credentials: CredentialResolver { _ in .chatGPT(accessToken: "token", accountID: "account") },
        ),
        session: try await makeSession(space),
      )

      let destination = "machines://\(machineA.rawValue)/tmp/moon.png"
      let generated = try await withDependencies {
        $0.fetch = recorder.client
      } operation: {
        try await world.run("generate_image", .object(["prompt": "a tiny moon", "destination": .string(destination)]))
      }
      guard case let .write(result) = generated else {
        throw Mismatch("generate_image did not return a written path")
      }
      #expect(result.path == destination)
      guard case .mtime = result.revision else { throw Mismatch("a machine write carries an mtime revision") }
      #expect(machineFS.files.withLock { $0["/tmp/moon.png"]?.content } == [UInt8](generatedPNG))
    }
  }

  @Test func aMachineDestinationDeliversTheMachineNotes() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModels(space)
      _ = try await space.addMachine(name: "studio")
      _ = try await space.fs(.shared).write("/_/machines/studio/AGENTS.md", Data("studio manual".utf8), ifMatch: nil)
      var world = ToolWorld(
        executor: ToolExecutor(
          space: space,
          machines: FakeMachineFS().seam,
          credentials: CredentialResolver { _ in .chatGPT(accessToken: "token", accountID: "account") },
        ),
        session: try await makeSession(space),
      )

      let generated = try await withDependencies {
        $0.fetch = ImageRequestRecorder().client
      } operation: {
        try await world.run("generate_image", .object(["prompt": "a tiny moon", "destination": "machines://studio/tmp/moon.png"]))
      }
      guard case .write = generated else { throw Mismatch("generate_image did not return a written path") }
      #expect(world.delivered?.text.contains("studio manual") == true)
    }
  }

  @Test func anExistingDestinationIsRefusedBeforeAnyRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModels(space)
      _ = try await space.fs(.shared).write("/art/moon.png", Data("kept".utf8), ifMatch: nil)
      let machineFS = FakeMachineFS()
      machineFS.put("/tmp/moon.png", "kept", mtime: 100)
      let recorder = ImageRequestRecorder()
      var world = ToolWorld(
        executor: ToolExecutor(
          space: space,
          machines: machineFS.seam,
          credentials: CredentialResolver { _ in .chatGPT(accessToken: "token", accountID: "account") },
        ),
        session: try await makeSession(space),
      )

      for destination in ["/art/moon.png", "machines://\(machineA.rawValue)/tmp/moon.png"] {
        let refused = try await withDependencies {
          $0.fetch = recorder.client
        } operation: {
          try await world.run("generate_image", .object(["prompt": "a tiny moon", "destination": .string(destination)]))
        }
        #expect(try failureMessage(refused) == "\(destination) already exists; generate_image never overwrites")
      }
      #expect(recorder.snapshots.withLock(\.count) == 0)
      #expect(try await space.fs(.shared).read("/art/moon.png").1 == Data("kept".utf8))
      #expect(machineFS.files.withLock { $0["/tmp/moon.png"]?.content } == Array("kept".utf8))
    }
  }

  @Test func aMissingChatGPTLoginReturnsAFailureWithoutARequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModels(space)
      let recorder = ImageRequestRecorder()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let result = try await withDependencies {
        $0.fetch = recorder.client
      } operation: {
        try await world.run("generate_image", .object(["prompt": "unused", "destination": "/unused.png"]))
      }
      #expect(try failureMessage(result).contains("provider_not_configured"))
      #expect(recorder.snapshots.withLock(\.count) == 0)
    }
  }

  @Test func aSpaceWithoutCodexReturnsTheConfiguredFailureWithoutARequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      try await installModelsWithoutCodex(space)
      let recorder = ImageRequestRecorder()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      let result = try await withDependencies {
        $0.fetch = recorder.client
      } operation: {
        try await world.run("generate_image", .object(["prompt": "unused", "destination": "/unused.png"]))
      }
      #expect(try failureMessage(result).contains("provider_not_configured"))
      #expect(recorder.snapshots.withLock(\.count) == 0)
    }
  }
}
