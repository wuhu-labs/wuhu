import Dependencies
import DeterministicDependencies
import ExecutionOwner
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import LoopCore
import class MainHub.Hub
import struct MainHub.SessionEffects
import SessionDomain
import SessionTools
import struct SpaceContract.GroupID
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
private let itemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let callID = ToolCallID("call_image")
private let anchor = Date(timeIntervalSinceReferenceDate: 0)
private let endpoint = OpenAIGPTEndpoint(model: "gpt-5.6-luna", apiKey: "test-key")

private struct RequestInterrupted: Error {}

private func imageRead(_ image: ImageContent) -> [TranscriptLine] {
  TranscriptItem.toolResult(ToolResultItem(
    id: itemID,
    timestamp: anchor,
    provenance: .toolCall(callID),
    payload: .read(.init(
      path: "/shots/login.png",
      revision: .journal(1),
      content: "image image/png, \(pngBytes.count) bytes; delivered as an attached image",
      image: image,
    )),
  )).lines(session: SessionID("s-1"))
}

private func requestBody(_ lines: [TranscriptLine], resolver: (any MediaResolver)?) async throws -> String {
  let bodies = Mutex<[String]>([])
  var capturing: any ModelEndpoint = endpoint.withFetch(FetchClient { request in
    let body = try await request.body?.text() ?? ""
    bodies.withLock { $0.append(body) }
    throw RequestInterrupted()
  })
  if let resolver { capturing = capturing.withMediaResolver(resolver) }
  let context = Context(systemPrompt: "sys", messages: lines.map(\.message))
  _ = try? await capturing.inference(context: context).collect()
  return try #require(bodies.withLock { $0.first })
}

@Suite(.deterministicDependencies) struct ImageReferenceWireTests {
  // A row written before images moved to the blob store and a row written after
  // it must reach the provider as the same bytes: the reference is a storage
  // decision, and the prompt may not notice it.
  @Test func `a stored reference and a legacy inline image render the same request`() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let fixture = try await SessionToolFixture(space: space)
      let session = try await fixtureSession(space)
      let hash = try await space.storeImage(pngBytes)

      let legacy = try await requestBody(imageRead(ImageContent(mimeType: "image/png", data: pngBytes)), resolver: nil)
      let referenced = try await requestBody(
        imageRead(ImageContent(mimeType: "image/png", source: .blob(hash), byteCount: pngBytes.count)),
        resolver: try await mediaResolver(space, fixture: fixture, session: session),
      )

      #expect(legacy == referenced)
      #expect(legacy.contains("data:image/png;base64,\(pngBytes.base64EncodedString())"))
    }
  }

  @Test(arguments: [false, true]) func storedMediaRunsTheNextTurnWithoutOwnershipOrCurrentReadAccess(attachment: Bool) async throws {
    try await withSessionDeps {
      let bodies = Mutex<[String]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.text() ?? ""
          bodies.withLock { $0.append(body) }
          let event = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
          return Response(status: .ok, body: .bytes(Data(event.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models)
        let session = try await harness.createSession()
        if attachment {
          let group = GroupID(rawValue: "attachments")
          try await harness.space.writer.write { db in
            try db.execute(sql: "INSERT INTO groups (id, created_at, visibility) VALUES (?, '2026-01-01T00:00:00Z', 'open')", arguments: [group.rawValue])
          }
          _ = try await harness.space.fs(group).write("/image.png", pngBytes, ifMatch: nil)
          #expect(try await harness.space.reads(.shared).contains(group))
          let message = TranscriptItem.message(.init(
            id: UUID(), messageID: MessageID("image-attachment"), conversationID: ConversationID(session.rawValue), sender: .init(id: "sender", timeZone: .gmt), timestamp: anchor,
            content: .init(text: "see image", attachments: [.image(path: "wuhu://\(group.rawValue).localspace/image.png", mimeType: "image/png", size: pngBytes.count)]),
          ))
          try await harness.store.appendTestLines(session, message.lines(session: session))
          try await harness.space.setVisibility(.private, of: group, by: (try await harness.space.ensureDevPerson()).actor, acting: group)
          #expect(try await !harness.space.reads(.shared).contains(group))
        } else {
          let hash = try await harness.space.storeImage(pngBytes)
          let read = imageRead(ImageContent(mimeType: "image/png", source: .blob(hash), byteCount: pngBytes.count))
          try await harness.store.appendTestLines(session, read)
        }
        try await harness.running {
          try await harness.deliver("next turn", to: session)
          try await until("media inference committed") {
            guard !bodies.withLock({ $0.isEmpty }) else { return false }
            return try await harness.store.settledWork(session)
          }
        }
        #expect(bodies.withLock { $0.contains { $0.contains("data:image/png;base64,\(pngBytes.base64EncodedString())") } })
      }
    }
  }

  @Test func `a reference we own that cannot be read fails the turn rather than dropping the image`() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let fixture = try await SessionToolFixture(space: space)
      let session = try await fixtureSession(space)
      let missing = ImageContent(mimeType: "image/png", source: .blob(String(repeating: "0", count: 64)), byteCount: 11)
      await #expect(throws: (any Error).self) {
        let context = Context(systemPrompt: "sys", messages: imageRead(missing).map(\.message))
        _ = try await endpoint
          .withMediaResolver(try await mediaResolver(space, fixture: fixture, session: session))
          .withFetch(FetchClient { _ in throw RequestInterrupted() })
          .inference(context: context)
          .collect()
      }
    }
  }

  @Test func `a reference nobody owns is left for another resolver`() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let fixture = try await SessionToolFixture(space: space)
      let resolver = try await mediaResolver(space, fixture: fixture, session: try await fixtureSession(space))
      let resolved = try await resolver.resolve(MediaContent(url: URL(string: "https://example.com/a.png")!, mimeType: "image/png"))
      #expect(resolved == nil)
    }
  }
}

private func fixtureSession(_ space: Space) async throws -> SessionID {
  try await space.sessions.createSession(
    group: .shared, title: "media", kind: .agent, createdBy: "fixture", model: .init(provider: "test", model: "test", effort: "high"),
  )
}

private func mediaResolver(_ space: Space, fixture: SessionToolFixture, session: SessionID) async throws -> any MediaResolver {
  let owner = withDependencies {
    $0[SessionEffects.self] = fixture.execution.sessionEffects
  } operation: { Hub(space: space) }
  SessionRuntime.bindMain(owner: owner, execution: fixture.execution, tokens: fixture.tokens, connection: fixture.connection)
  return fixture.execution.tools.mediaResolver(session)
}
