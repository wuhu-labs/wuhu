import Fetch
import Foundation
import JSONValue
import OrderedCollections

// MARK: - ResolvedMedia

public enum ResolvedMedia: Sendable {
  case data(Data, mimeType: String)
  case url(URL, mimeType: String)
  /// Words the model reads where the media would have been, for media the
  /// resolver cannot deliver in a form this request takes.
  case text(String)
}

// MARK: - MediaResolver

public protocol MediaResolver: Sendable {
  /// Resolve a media reference to inlineable bytes or a fetchable URL.
  ///
  /// Returns `nil` when the reference is not one this resolver owns (an unknown
  /// scheme/host); the caller drops the media block in that case rather than
  /// emitting an unresolvable reference. A genuine read failure against an
  /// owned reference throws.
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia?
}

// MARK: - ModelEndpoint

/// A model endpoint runs inference and reports it as a stream of
/// ``InferenceEvent``s.
///
/// The single requirement, ``runInference(context:options:mediaResolver:)``,
/// reports events as `Result` values rather than throwing: the stream carries
/// its own typed failure in-band and terminates with either a
/// ``InferenceEvent/done(_:_:)`` success or a `.failure`. Cancelling the task
/// that drives it ends the underlying work and the stream finishes without a
/// terminal event.
///
/// Consumers should drive an endpoint through ``inference(context:options:mediaResolver:)``,
/// which adapts the raw event stream into an ``Inference`` you can watch
/// (`stream()`) or run to completion (`collect()`).
public protocol ModelEndpoint: Sendable {
  /// Opaque identity string for cross-provider replay gating and tracing.
  var providerID: String { get }

  /// Wire-level model name.
  var model: String { get }

  /// Report inference as a stream of events. The stream is cold: iterating it
  /// performs the request. It yields `.success` events ending in
  /// ``InferenceEvent/done(_:_:)``, or a single `.failure` carrying an
  /// ``InferenceError``; on task cancellation it finishes with no terminal.
  func runInference(
    context: Context,
    options: RequestOptions,
    mediaResolver: (any MediaResolver)?,
  ) -> AsyncStream<Result<InferenceEvent, InferenceError>>

  func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions)

  /// Add provider-specific headers, marking sensitive values at their creation
  /// site. No-op by default.
  func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions)
}

extension ModelEndpoint {
  public func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {}

  public func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {}

  /// Begin an inference and return a handle you can watch or collect.
  ///
  /// The returned ``Inference`` is single-use: consume it once via
  /// ``Inference/stream()`` *or* ``Inference/collect()``.
  public func inference(
    context: Context,
    options: RequestOptions = RequestOptions(),
    mediaResolver: (any MediaResolver)? = nil,
  ) -> Inference {
    Inference(source: runInference(context: context, options: options, mediaResolver: mediaResolver))
  }
}
