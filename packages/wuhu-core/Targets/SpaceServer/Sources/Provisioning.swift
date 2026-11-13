#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceCore
import struct SpaceFS.SpacePath
import Wuwei

/// Shared's Everything sidebar is a real file. Startup writes it when it is
/// missing, so deleting it brings it back on the next start and editing it is
/// how Everything changes.
func provisionEverythingSidebar(_ space: Space) async throws {
  guard let file = EmbeddedProvisioned.files.first(where: { $0.path == ["everything.sidebar.jsx"] }) else {
    preconditionFailure("the provisioned files have no everything.sidebar.jsx")
  }
  let path = try SpacePath(validating: "/.sidebars/everything.sidebar.jsx")
  // A read takes no lease: another process serving this space has provisioned
  // the file, and there is nothing to write.
  do {
    _ = try await space.fs(.shared).stat(path.rawValue)
    return
  } catch SpaceError.notFound {}
  do {
    _ = try await space.writeFile(
      path, data: Data(EmbeddedProvisioned.bytes(for: file)),
      in: .shared, acting: .shared, ifMatch: nil, createOnly: true,
    )
  } catch SpaceError.alreadyExists {
  } catch is Evicted {
    // The space is held by another serving process and its own start made this
    // write: this process has nothing left to provision.
  }
}
