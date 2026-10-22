#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceCore
import struct SpaceFS.SpacePath

/// Shared's Everything sidebar is a real file. Startup writes it when it is
/// missing, so deleting it brings it back on the next start and editing it is
/// how Everything changes.
func provisionEverythingSidebar(_ space: Space) async throws {
  guard let file = EmbeddedProvisioned.files.first(where: { $0.path == ["everything.sidebar.jsx"] }) else {
    preconditionFailure("the provisioned files have no everything.sidebar.jsx")
  }
  do {
    _ = try await space.writeFile(
      try SpacePath(validating: "/.sidebars/everything.sidebar.jsx"), data: Data(EmbeddedProvisioned.bytes(for: file)),
      in: .shared, acting: .shared, ifMatch: nil, createOnly: true,
    )
  } catch SpaceError.alreadyExists {}
}
