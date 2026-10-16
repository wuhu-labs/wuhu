// Umbrella Foundation, unlike the rest of SpaceContract: on Linux, NFC
// (`precomposedStringWithCanonicalMapping`) is in neither FoundationEssentials nor
// FoundationInternationalization. The server rule this mirrors, SpaceFS `SpacePath`, imports it
// for the same call.
import Foundation

extension GroupID {
  /// The longest `viewing` a message may carry, in UTF-8 bytes.
  public static let viewingMaxBytes = 1024

  /// The `viewing` a send names for `path` in this group: `wuhu://<group>.localspace<path>` in
  /// Unicode NFC, or nil when the server would refuse it or it names no doc or page (the root, a
  /// listing).
  ///
  /// The server's rules are `Viewing` in SpaceCore and `SpacePath` in SpaceFS. This, web
  /// `lib/viewing.ts` and the server's own test all hold to `Tests/contract/viewing-vectors.json`.
  /// A send that names nothing still goes, so a path left out never fails the message.
  public func viewing(_ path: String) -> String? {
    guard Self.isValid(rawValue), path.hasPrefix("/") else { return nil }
    let normalized = path.precomposedStringWithCanonicalMapping
    guard normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy(Self.isViewingComponent)
    else { return nil }
    let spelling = address(normalized)
    guard spelling.utf8.count <= Self.viewingMaxBytes, !spelling.unicodeScalars.contains(where: Self.viewingRefuses) else {
      return nil
    }
    return spelling
  }

  private static func viewingRefuses(_ scalar: Unicode.Scalar) -> Bool {
    "<>&\"'".unicodeScalars.contains(scalar) || scalar.properties.isWhitespace
      || scalar.properties.generalCategory == .control
  }

  // Controls and whitespace are refused across the whole spelling, so a component only has its
  // own rules left.
  private static func isViewingComponent(_ component: Substring) -> Bool {
    if component.isEmpty || component == "." || component == ".." { return false }
    return !component.unicodeScalars.contains {
      "@%#?".unicodeScalars.contains($0) || $0.properties.generalCategory == .format
    }
  }
}
