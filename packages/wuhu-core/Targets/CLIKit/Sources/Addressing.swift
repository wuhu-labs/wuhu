import struct SpaceContract.GroupID
import struct SpaceContract.SpaceURL

struct RoutedPath: Equatable {
  var spaceOverride: String?
  var path: String
}

func routePath(_ raw: String) throws -> RoutedPath {
  let lowered = raw.lowercased()
  let group: (group: GroupID, path: String)?
  do {
    group = try GroupID.address(raw)
  } catch {
    throw UsageError(message: "invalid group host in \(raw): a group id is lowercase letters, digits and inner hyphens")
  }
  // wuhu://system/ is the server's built-in files and wuhu://<group>.localspace/
  // a group of the pinned space, not spaces to dial: the server resolves both
  // like any tool path.
  guard lowered != "wuhu://system", !lowered.hasPrefix("wuhu://system/"),
        lowered.hasPrefix("wuhu://") || lowered.hasPrefix("https://"),
        group == nil
  else {
    return RoutedPath(spaceOverride: nil, path: raw)
  }
  guard let url = SpaceURL(raw), case let .path(path) = url.destination,
        url.percentEncodedQuery == nil, url.percentEncodedFragment == nil
  else { throw UsageError(message: "not a space file URL: \(raw)") }
  return RoutedPath(spaceOverride: url.host, path: path)
}
