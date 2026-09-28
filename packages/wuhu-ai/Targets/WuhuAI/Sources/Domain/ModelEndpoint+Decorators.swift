import Dependencies
import Fetch
import Foundation

extension ModelEndpoint {
  /// Wrap with a custom fetch client.
  ///
  /// Use this when an endpoint should execute through a concrete transport
  /// instead of the ambient `DependencyValues.fetch` binding.
  public func withFetch(_ fetch: FetchClient) -> some ModelEndpoint {
    FetchWrappedEndpoint(endpoint: self, fetch: fetch)
  }

  /// Wrap with a default media resolver, applied when a call supplies none.
  public func withMediaResolver(_ resolver: any MediaResolver) -> some ModelEndpoint {
    MediaResolverWrappedEndpoint(endpoint: self, resolver: resolver)
  }
}

private struct FetchWrappedEndpoint<Base: ModelEndpoint>: ModelEndpoint {
  let endpoint: Base
  let fetch: FetchClient

  var providerID: String { endpoint.providerID }
  var model: String { endpoint.model }

  func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    withDependencies {
      $0.fetch = fetch
    } operation: {
      endpoint.runInference(context: context, options: options, mediaResolver: mediaResolver)
    }
  }
}

private struct MediaResolverWrappedEndpoint<Base: ModelEndpoint>: ModelEndpoint {
  let endpoint: Base
  let resolver: any MediaResolver

  var providerID: String { endpoint.providerID }
  var model: String { endpoint.model }

  func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>> {
    endpoint.runInference(context: context, options: options, mediaResolver: mediaResolver ?? resolver)
  }
}
