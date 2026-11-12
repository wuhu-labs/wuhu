#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.PixelSize
import Testing
import WuhuAI

private func imageRead(_ bytes: Int = 100, pixels: PixelSize? = nil) -> ToolResultItem {
  ToolResultItem(
    id: UUID(),
    timestamp: Date(timeIntervalSinceReferenceDate: 0),
    provenance: .toolCall(.init("tc-1")),
    payload: .read(.init(
      path: "/shot.png",
      revision: .journal(1),
      content: "image image/png, \(bytes) bytes; delivered as an attached image",
      image: .init(mimeType: "image/png", source: .inline(Data(repeating: 0x89, count: bytes)), byteCount: bytes, pixels: pixels),
    )),
  )
}

@Suite struct ImageReadEstimateTests {
  @Test func unsizedImageCostsTheModelMaximumNotItsBytes() {
    let lines = TranscriptItem.toolResult(imageRead(1 << 20)).lines(session: Fix.session)
    let estimated = lines.estimatedContextTokens(images: .claude)
    #expect(estimated >= 4784)
    #expect(estimated < 5200, "image bytes are not prose")
    #expect(lines.map(\.key) == ["call:tc-1", "call:tc-1:image"])
    #expect(lines.map(\.role) == [.toolResult, .user])
  }

  @Test func renderedMediaUsesTheModelImageMaximum() {
    let small = TranscriptItem.toolResult(imageRead(100, pixels: PixelSize(width: 280, height: 280))).lines(session: Fix.session)
    let huge = TranscriptItem.toolResult(imageRead(100, pixels: PixelSize(width: 6000, height: 4000))).lines(session: Fix.session)
    #expect(small.estimatedContextTokens(images: .claude) == huge.estimatedContextTokens(images: .claude))
    #expect(huge.estimatedContextTokens(images: .openAI) > huge.estimatedContextTokens(images: .claude))
  }
}

@Suite struct ImageReadRenderTests {
  @Test func imageReadRendersToolResultPlusUserMedia() {
    let messages = imageRead().render(for: .toolResult(.init("tc-1")))
    #expect(messages.count == 2)
    guard case let .toolResult(result) = messages[0] else {
      Issue.record("first message must be the tool result")
      return
    }
    #expect(result.toolCallId == "tc-1")
    guard case let .user(user) = messages[1],
          case let .text(caption) = user.content[0],
          case let .media(media) = user.content[1]
    else {
      Issue.record("second message must be a user media message")
      return
    }
    #expect(caption.text.contains("/shot.png"))
    #expect(media.mimeType == "image/png")
    #expect(media.url.absoluteString.hasPrefix("data:image/png;base64,"))
  }

  @Test func textReadStaysASingleMessage() {
    let item = ToolResultItem(
      id: UUID(),
      timestamp: Date(timeIntervalSinceReferenceDate: 0),
      provenance: .toolCall(.init("tc-1")),
      payload: .read(.init(path: "/a.txt", revision: .journal(1), content: "hello")),
    )
    #expect(item.render(for: .toolResult(.init("tc-1"))).count == 1)
  }

  @Test func imageSurvivesJSONRoundTrip() throws {
    let payload = imageRead().payload
    let decoded = try JSONDecoder().decode(
      ToolResultPayload.self,
      from: try JSONEncoder().encode(payload),
    )
    #expect(decoded == payload)
  }

  @Test func backstopDropsOversizedImages() {
    let item = imageRead((4 << 20) + 1)
    guard case let .read(result) = item.payload.clamped() else {
      Issue.record("payload changed case")
      return
    }
    #expect(result.image == nil)
    #expect(result.content.contains("[kernel backstop: attached image was"))

    guard case let .read(kept) = imageRead(100).payload.clamped() else {
      Issue.record("payload changed case")
      return
    }
    #expect(kept.image != nil)
  }
}
