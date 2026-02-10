import Foundation
import PiAI

public enum DefaultStream {
  public static func stream(model: Model, context: SimpleContext, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    switch model.provider {
    case .openai:
      let provider = OpenAIResponsesProvider()
      let inner = try await provider.stream(model: model, context: context, options: options)
      return AsyncThrowingStream { continuation in
        let task = Task {
          _ = provider
          do {
            for try await event in inner {
              continuation.yield(event)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    case .anthropic:
      let provider = AnthropicMessagesProvider()
      let inner = try await provider.stream(model: model, context: context, options: options)
      return AsyncThrowingStream { continuation in
        let task = Task {
          _ = provider
          do {
            for try await event in inner {
              continuation.yield(event)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    case .openaiCodex:
      throw PiAIError.unsupported("PiAgent DefaultStream does not support openai-codex yet")
    }
  }
}
