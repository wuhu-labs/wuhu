public enum PiAI {
  /// Keep a single HTTP client alive for the lifetime of the process. Some streaming bodies
  /// are backed by the underlying client's connection lifecycle; if the client is deallocated
  /// mid-stream (e.g. when providers are created as temporaries), the request can be cancelled.
  private static let sharedHTTPClient = AsyncHTTPClientTransport()

  /// Stream a response from the model using the provider inferred from `model.provider`.
  public static func streamSimple(
    model: Model,
    context: Context,
    options: RequestOptions = .init(),
  ) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    switch model.provider {
    case .openai:
      try await OpenAIResponsesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
    case .openaiCodex:
      try await OpenAICodexResponsesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
    case .anthropic:
      try await AnthropicMessagesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
    }
  }
}
