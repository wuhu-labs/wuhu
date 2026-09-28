import Dependencies
import Foundation
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite struct AppendAssistantTests {
  private func controlled<R>(_ operation: () throws -> R) rethrows -> R {
    try withDependencies {
      $0.uuid = .incrementing
      $0.date = .constant(Fix.instant)
    } operation: {
      try operation()
    }
  }

  @Test func `provider tool call ids are remapped to kernel-minted ids on the entry`() {
    var transcript = Transcript()
    let entry = controlled {
      transcript.appendAssistant(
        .init(content: [
          .text("working"),
          .toolCall(.init(id: "call_0", name: "read", arguments: .object(["path": .string("a")]))),
          .toolCall(.init(id: "call_1", name: "grep", arguments: .object(["pattern": .string("x")]))),
        ]),
        id: UUID(),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2)),
      )
    }

    #expect(entry.toolCallIDs.count == 2)
    let kernelIDs = entry.toolCalls.map(\.id)
    #expect(Set(kernelIDs).count == 2)
    #expect(!kernelIDs.contains("call_0"))
    #expect(!kernelIDs.contains("call_1"))
    #expect(entry.toolCallIDs["call_0"]?.rawValue == kernelIDs[0])
    #expect(entry.toolCallIDs["call_1"]?.rawValue == kernelIDs[1])
    #expect(transcript.items == [.assistant(entry)])
  }

  @Test func `usage is stored on the committed entry`() {
    var transcript = Transcript()
    let entry = controlled {
      transcript.appendAssistant(
        .init(content: [.text("done")]),
        id: UUID(),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 5, totalTokens: 15)),
      )
    }
    #expect(entry.usage.totalTokens == 15)
    #expect(transcript.estimatedContextTokens(images: .claude) == 15)
  }

  @Test func `appending an assistant message without usage traps`() async {
    await #expect(processExitsWith: .failure) {
      var transcript = Transcript()
      withDependencies {
        $0.uuid = .incrementing
        $0.date = .constant(Fix.instant)
      } operation: {
        _ = transcript.appendAssistant(
          .init(content: [.text("done")]),
          id: UUID(),
          metadata: .init(stopReason: .stop, usage: nil),
        )
      }
    }
  }
}
