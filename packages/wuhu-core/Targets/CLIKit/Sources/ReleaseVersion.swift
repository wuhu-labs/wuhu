enum ReleaseLane: String, CaseIterable, Sendable {
  case dev
  case beta
  case release
}

struct ReleaseVersion: Hashable, Sendable, CustomStringConvertible {
  var major: Int
  var minor: Int
  var patch: Int
  var lane: ReleaseLane
  var iteration: Int

  var description: String {
    let train = "\(self.major).\(self.minor).\(self.patch)"
    switch self.lane {
    case .release:
      return train
    case .dev, .beta:
      return "\(train)-\(self.lane.rawValue).\(self.iteration)"
    }
  }

  var tag: String { "wuhu/v\(self.description)" }

  func isNewer(than other: ReleaseVersion) -> Bool {
    precondition(self.lane == other.lane, "release ordering is defined within a lane only")
    return (self.major, self.minor, self.patch, self.iteration)
      > (other.major, other.minor, other.patch, other.iteration)
  }

  static func newest(in lane: ReleaseLane, of versions: some Sequence<ReleaseVersion>) -> ReleaseVersion? {
    versions.filter { $0.lane == lane }.max { $1.isNewer(than: $0) }
  }

  static func parse(_ text: some StringProtocol) -> ReleaseVersion? {
    let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let train = halves[0].split(separator: ".", omittingEmptySubsequences: false)
    guard train.count == 3,
          let major = strictInt(train[0]), let minor = strictInt(train[1]), let patch = strictInt(train[2])
    else { return nil }
    guard halves.count == 2 else {
      return ReleaseVersion(major: major, minor: minor, patch: patch, lane: .release, iteration: 0)
    }
    let suffix = halves[1].split(separator: ".", omittingEmptySubsequences: false)
    guard suffix.count == 2,
          let lane = ReleaseLane(rawValue: String(suffix[0])), lane != .release,
          let iteration = strictInt(suffix[1])
    else { return nil }
    return ReleaseVersion(major: major, minor: minor, patch: patch, lane: lane, iteration: iteration)
  }

  static func parse(tag: String) -> ReleaseVersion? {
    guard tag.hasPrefix("wuhu/v") else { return nil }
    return self.parse(tag.dropFirst(6))
  }

  static func parseStamped(_ text: String) -> ReleaseVersion? {
    var base = text[...]
    if base.hasSuffix("-dirty") { base = base.dropLast(6) }
    if let version = self.parse(base) { return version }
    let parts = base.split(separator: "-")
    guard parts.count >= 3 else { return nil }
    let commit = parts[parts.count - 1]
    let distance = parts[parts.count - 2]
    guard commit.count > 1, commit.first == "g", commit.dropFirst().allSatisfy(\.isHexDigit),
          strictInt(distance) != nil
    else { return nil }
    base = base.dropLast(commit.count + distance.count + 2)
    return self.parse(base)
  }

  private static func strictInt(_ text: some StringProtocol) -> Int? {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(text)
  }
}
