import SessionDomain
import enum SpaceCore.ImageFitting
import struct WuhuAI.MediaContent
import protocol WuhuAI.MediaResolver
import enum WuhuAI.ResolvedMedia

/// Transcript media fetched through the worker-only route when a request is built.
public struct ClientMediaResolver: MediaResolver {
  let tools: ToolExecutor
  let session: SessionID
  let limits: ImageLimits

  public func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    guard MediaReference(media.url) != nil else { return nil }
    let client = try await tools.client(session)
    let data = try await client.media(media.url)
    return switch ImageFitting.fit(data, mimeType: media.mimeType, limits: limits) {
    case let .image(fitted, mimeType): .data(fitted, mimeType: mimeType)
    case let .note(note): .text(note)
    }
  }
}
