import Foundation
import Testing
import WuhuAI
import WuhuRecordReplay

// MARK: - Image Recognition

/// Test image recognition with a panda photo.
/// DeepSeek excluded (no image support).

private let imageModels: [ModelEntry] = [
  ModelEntry(providerID: "anthropic", model: "claude-sonnet-4-6", recordingName: "claude-sonnet-4-6-image-recognition"),
  ModelEntry(providerID: "anthropic", model: "claude-opus-4-7", recordingName: "claude-opus-4-7-image-recognition"),
  ModelEntry(providerID: "openai", model: "gpt-5.4", recordingName: "gpt-5.4-image-recognition"),
  ModelEntry(providerID: "gemini", model: "gemini-2.5-flash", recordingName: "gemini-2.5-flash-image-recognition"),
  ModelEntry(providerID: "kimi", model: "kimi-k2.6", recordingName: "kimi-k2.6-image-recognition"),
]

/// Load the test panda image as a base64 data URI.
private func pandaDataURI() -> String {
  let sourceFile = URL(fileURLWithPath: #filePath)
  let imageFile = sourceFile.deletingLastPathComponent().appendingPathComponent("panda.jpg")
  let data = try! Data(contentsOf: imageFile)
  return "data:image/jpeg;base64,\(data.base64EncodedString())"
}

@Suite struct ImageRecognitionTests {
  @Test(arguments: imageModels)
  func identifiesPanda(entry: ModelEntry) async throws {
    try await withRecording(entry.recordingName) {
      let endpoint = makeEndpoint(entry)

      let imageURL = URL(string: pandaDataURI())!
      let context = Context(messages: [
        .user(UserMessage(content: [
          .text(TextContent(text: "What animal do you see in this image? Answer in one word.")),
          .media(MediaContent(url: imageURL, mimeType: "image/jpeg")),
        ])),
      ])

      let msgInference = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(),
      )
      let msg = msgInference.message
      let metadata = msgInference.metadata
      #expect(metadata.stopReason == .stop)
      #expect(!msg.content.isEmpty)

      let allText = msg.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text.lowercased() }
        return nil
      }.joined()

      #expect(
        allText.contains("panda") || allText.contains("bear"),
        "Expected response to identify a panda/bear, got: \(allText)",
      )
    }
  }
}
