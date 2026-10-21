import SessionDomain
import enum SpaceCore.ImageFitting
import struct WuhuAI.MediaContent
import protocol WuhuAI.MediaResolver
import enum WuhuAI.ResolvedMedia

/// Media a transcript names, read as the session from main: a space file
/// through `/v1/f` (hostless means the session's group), a stored image
/// through `/v1/blob/:hash`. Nothing is fetched until a request is built.
public struct ClientMediaResolver: MediaResolver {
  let tools: ToolExecutor
  let session: SessionID
  let limits: ImageLimits

  public func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    guard let reference = MediaReference(media.url) else { return nil }
    let client = try await tools.client(session)
    let data = switch reference {
    case let .blob(hash): try await client.blob(hash)
    case let .spaceFile(path): try await client.file(path).data
    }
    return switch ImageFitting.fit(data, mimeType: media.mimeType, limits: limits) {
    case let .image(fitted, mimeType): .data(fitted, mimeType: mimeType)
    case let .note(note): .text(note)
    }
  }
}
