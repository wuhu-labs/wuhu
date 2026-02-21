import PiAI

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>
