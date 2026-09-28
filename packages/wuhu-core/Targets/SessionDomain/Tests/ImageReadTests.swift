import Foundation
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
    let transcript = Transcript(items: [.toolResult(imageRead(1 << 20))])
    let estimated = transcript.estimatedContextTokens(images: .claude)
    #expect(estimated >= 4784, "an image of unknown size counts as the largest the model takes")
    #expect(estimated < 5200, "a 1MB image must not be counted as prose")
  }

  @Test func sizedImageCostsWhatItIsSentAs() {
    let small = Transcript(items: [.toolResult(imageRead(1 << 20, pixels: PixelSize(width: 280, height: 280)))])
      .estimatedContextTokens(images: .claude)
    #expect(small >= 100 && small < 400, "280x280 is 10x10 patches of 28px")

    // 6000x4000 is fitted to Claude's 2576px edge and its patch budget.
    let huge = Transcript(items: [.toolResult(imageRead(1 << 20, pixels: PixelSize(width: 6000, height: 4000)))])
    let claude = huge.estimatedContextTokens(images: .claude)
    #expect(claude >= 4500 && claude < 5200)
    // OpenAI keeps it whole: 188x125 patches of 32px at 1.2 tokens each.
    let openAI = huge.estimatedContextTokens(images: .openAI)
    #expect(openAI >= 28200 && openAI < 28700)
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
