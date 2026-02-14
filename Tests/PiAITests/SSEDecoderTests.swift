import Foundation
import PiAI
import Testing

struct SSEDecoderTests {
  @Test func decodeDropsTrailingPartialFrame() async throws {
    let partial = Data(#"data: {"type":"assistant_text_delta","delta":"Hi""#.utf8)
    let stream = SSEDecoder.decode(partial)

    var messages: [SSEMessage] = []
    for try await message in stream {
      messages.append(message)
    }

    #expect(messages.isEmpty)
  }

  @Test func decodeYieldsCompleteFrame() async throws {
    let frame = Data("data: {\"type\":\"done\"}\n\n".utf8)
    let stream = SSEDecoder.decode(frame)

    var messages: [SSEMessage] = []
    for try await message in stream {
      messages.append(message)
    }

    #expect(messages == [SSEMessage(event: nil, data: #"{"type":"done"}"#)])
  }

  @Test func decodeSkipsDONEFrames() async throws {
    let data = Data("data: [DONE]\n\n".utf8)
    let stream = SSEDecoder.decode(data)

    var messages: [SSEMessage] = []
    for try await message in stream {
      messages.append(message)
    }

    #expect(messages.isEmpty)
  }
}
