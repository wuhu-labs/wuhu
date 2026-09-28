import Foundation

// Each wire protocol is a refinement of `ModelEndpoint` that supplies a default
// `runInference` over the shared SSE transport. A conforming endpoint provides
// its `baseURL` and, via the `modifyBody`/`modifyHeaders` hooks on
// `ModelEndpoint`, any provider-specific request tweaks.

// MARK: - ChatCompletions

public protocol ChatCompletionsEndpoint: ModelEndpoint {
  var baseURL: URL { get }
}

extension ChatCompletionsEndpoint {
  public func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    let (providerID, model, baseURL) = (providerID, model, baseURL)
    return runSSEInference(
      buildRequest: { try await buildChatCompletionsRequest(model: model, baseURL: baseURL, context: normalizedRequestContext(context, targetProviderID: providerID), options: options, mediaResolver: mediaResolver) },
      modifyBody: { self.modifyBody(&$0, options: $1) },
      modifyHeaders: { self.modifyHeaders(&$0, options: $1) },
      options: options,
      parse: { parseChatCompletionsStream($0, providerID: providerID, model: model) },
    )
  }
}

// MARK: - Responses

public protocol ResponsesEndpoint: ModelEndpoint {
  var baseURL: URL { get }
  var isCodex: Bool { get }
}

protocol ResponsesHeaderReceiving {
  var receiveResponseHeaders: @Sendable ([String: String]) async -> Void { get }
}

extension ResponsesEndpoint {
  public var isCodex: Bool { false }

  public func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    let (providerID, model, baseURL, isCodex) = (providerID, model, baseURL, isCodex)
    let receiveResponseHeaders: @Sendable ([String: String]) async -> Void
    if let receiver = self as? any ResponsesHeaderReceiving {
      receiveResponseHeaders = receiver.receiveResponseHeaders
    } else {
      receiveResponseHeaders = { _ in }
    }
    return runSSEInference(
      buildRequest: { try await buildResponsesRequest(model: model, baseURL: baseURL, context: normalizedRequestContext(context, targetProviderID: providerID), options: options, isCodex: isCodex, mediaResolver: mediaResolver) },
      modifyBody: { self.modifyBody(&$0, options: $1) },
      modifyHeaders: { self.modifyHeaders(&$0, options: $1) },
      receiveResponseHeaders: receiveResponseHeaders,
      options: options,
      parse: { parseResponsesStream($0, providerID: providerID, model: model) },
    )
  }
}

// MARK: - Anthropic

public protocol AnthropicMessagesEndpoint: ModelEndpoint {
  var baseURL: URL { get }
  var acceptsUnsignedThinking: Bool { get }
}

extension AnthropicMessagesEndpoint {
  public var acceptsUnsignedThinking: Bool { true }

  public func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    let (providerID, model, baseURL, acceptsUnsignedThinking) = (providerID, model, baseURL, acceptsUnsignedThinking)
    return runSSEInference(
      buildRequest: { try await buildAnthropicRequest(model: model, baseURL: baseURL, context: normalizedRequestContext(context, targetProviderID: providerID), options: options, acceptsUnsignedThinking: acceptsUnsignedThinking, mediaResolver: mediaResolver) },
      modifyBody: { self.modifyBody(&$0, options: $1) },
      modifyHeaders: { self.modifyHeaders(&$0, options: $1) },
      options: options,
      parse: { parseAnthropicStream($0, providerID: providerID, model: model) },
    )
  }
}

// MARK: - Gemini

public protocol GeminiContentEndpoint: ModelEndpoint {
  var baseURL: URL { get }
}

extension GeminiContentEndpoint {
  public func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    let (providerID, model, baseURL) = (providerID, model, baseURL)
    return runSSEInference(
      buildRequest: { try await buildGeminiRequest(model: model, baseURL: baseURL, context: normalizedRequestContext(context, targetProviderID: providerID), options: options, mediaResolver: mediaResolver) },
      modifyBody: { self.modifyBody(&$0, options: $1) },
      modifyHeaders: { self.modifyHeaders(&$0, options: $1) },
      options: options,
      parse: { parseGeminiStream($0, providerID: providerID, model: model) },
    )
  }
}
