import protocol MainHub.Main
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceCore.ImageFitting
import struct WuhuAI.MediaContent
import protocol WuhuAI.MediaResolver
import enum WuhuAI.ResolvedMedia

public struct OwnerMediaResolver: MediaResolver {
  private let owner: any Main
  private let limits: ImageLimits
  private let group: GroupID

  public init(owner: any Main, limits: ImageLimits, group: GroupID) {
    self.owner = owner
    self.limits = limits
    self.group = group
  }

  public func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    guard let reference = MediaReference(media.url) else { return nil }
    let data = try await owner.mediaBytes(reference, group: group)
    return switch ImageFitting.fit(data, mimeType: media.mimeType, limits: limits) {
    case let .image(fitted, mimeType): .data(fitted, mimeType: mimeType)
    case let .note(note): .text(note)
    }
  }
}
