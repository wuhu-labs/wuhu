import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
private let itemID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let callID = ToolCallID("call_image")
private let anchor = Date(timeIntervalSinceReferenceDate: 0)
private let endpoint = OpenAIGPTEndpoint(model: "gpt-5.6-luna", apiKey: "test-key")

private struct RequestInterrupted: Error {}

private func imageRead(_ image: ImageContent) -> Transcript {
  Transcript(items: [.toolResult(ToolResultItem(
    id: itemID,
    timestamp: anchor,
    provenance: .toolCall(callID),
    payload: .read(.init(
      path: "/shots/login.png",
      revision: .journal(1),
      content: "image image/png, \(pngBytes.count) bytes; delivered as an attached image",
      image: image,
    )),
  ))])
}

private func requestBody(_ transcript: Transcript, resolver: (any MediaResolver)?) async throws -> String {
  let bodies = Mutex<[String]>([])
  var capturing: any ModelEndpoint = endpoint.withFetch(FetchClient { request in
    let body = try await request.body?.text() ?? ""
    bodies.withLock { $0.append(body) }
    throw RequestInterrupted()
  })
  if let resolver { capturing = capturing.withMediaResolver(resolver) }
  let context = await transcript.renderRequest(
    session: SessionID("s-1"),
    systemPrompt: "sys",
    budget: ContextBudget(maxInput: 100_000, maxOutput: 10000),
  )
  _ = try? await capturing.inference(context: context).collect()
  return try #require(bodies.withLock { $0.first })
}

@Suite struct ImageReferenceWireTests {
  // A row written before images moved to the blob store and a row written after
  // it must reach the provider as the same bytes: the reference is a storage
  // decision, and the prompt may not notice it.
  @Test func `a stored reference and a legacy inline image render the same request`() async throws {
    let space = try Space.inMemory()
    let hash = try await space.storeImage(pngBytes)

    let legacy = try await requestBody(imageRead(ImageContent(mimeType: "image/png", data: pngBytes)), resolver: nil)
    let referenced = try await requestBody(
      imageRead(ImageContent(mimeType: "image/png", source: .blob(hash), byteCount: pngBytes.count)),
      resolver: SpaceMediaResolver(space: space, limits: .claude, group: .shared),
    )

    #expect(legacy == referenced)
    #expect(legacy.contains("data:image/png;base64,\(pngBytes.base64EncodedString())"))
  }

  @Test func `a reference we own that cannot be read fails the turn rather than dropping the image`() async throws {
    let space = try Space.inMemory()
    let missing = ImageContent(mimeType: "image/png", source: .blob(String(repeating: "0", count: 64)), byteCount: 11)
    await #expect(throws: (any Error).self) {
      let context = await imageRead(missing).renderRequest(
        session: SessionID("s-1"),
        systemPrompt: "sys",
        budget: ContextBudget(maxInput: 100_000, maxOutput: 10000),
      )
      _ = try await endpoint
        .withMediaResolver(SpaceMediaResolver(space: space, limits: .claude, group: .shared))
        .withFetch(FetchClient { _ in throw RequestInterrupted() })
        .inference(context: context)
        .collect()
    }
  }

  @Test func `a reference nobody owns is left for another resolver`() async throws {
    let space = try Space.inMemory()
    let resolved = try await SpaceMediaResolver(space: space, limits: .claude, group: .shared)
      .resolve(MediaContent(url: URL(string: "https://example.com/a.png")!, mimeType: "image/png"))
    #expect(resolved == nil)
  }
}
