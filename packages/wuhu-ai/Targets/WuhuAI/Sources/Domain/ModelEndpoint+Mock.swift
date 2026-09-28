import Foundation

extension ModelEndpoint where Self == MockEndpoint {
  /// A mock endpoint that reports caller-provided events. No dialect, no
  /// transport — it just yields whatever the `run` closure produces.
  public static func mock(
    providerID: String = "mock",
    model: String = "mock",
    run: @escaping @Sendable (Context, RequestOptions, (any MediaResolver)?) -> AsyncStream<Result<InferenceEvent, InferenceError>>,
  ) -> Self {
    Self(providerID: providerID, model: model, run: run)
  }

  /// A mock endpoint that replays a fixed sequence of events and then ends
  /// successfully. Convenience for the common "script the events" case.
  public static func mock(
    providerID: String = "mock",
    model: String = "mock",
    events: [InferenceEvent],
  ) -> Self {
    Self(providerID: providerID, model: model) { _, _, _ in
      AsyncStream { continuation in
        for event in events { continuation.yield(.success(event)) }
        continuation.finish()
      }
    }
  }
}

public struct MockEndpoint: ModelEndpoint {
  public var providerID: String
  public var model: String
  let run: @Sendable (Context, RequestOptions, (any MediaResolver)?) -> AsyncStream<Result<InferenceEvent, InferenceError>>

  public init(
    providerID: String,
    model: String,
    run: @escaping @Sendable (Context, RequestOptions, (any MediaResolver)?) -> AsyncStream<Result<InferenceEvent, InferenceError>>,
  ) {
    self.providerID = providerID
    self.model = model
    self.run = run
  }

  public func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    run(context, options, mediaResolver)
  }
}
