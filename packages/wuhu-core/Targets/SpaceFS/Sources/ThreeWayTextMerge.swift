/// A line-based three-way merge: the two sides' changes to `base` combine unless they touch the
/// same lines differently.
public enum ThreeWayTextMerge {
  struct Patch: Equatable {
    var range: Range<Int>
    var replacement: [String]
  }

  public enum Result: Equatable, Sendable {
    case merged(String)
    case conflict
  }

  public static func merge(base: String, local: String, remote: String) -> Result {
    if local == remote { return .merged(local) }
    if local == base { return .merged(remote) }
    if remote == base { return .merged(local) }

    let baseLines = lines(base)
    let localPatches = patches(from: baseLines, to: lines(local))
    let remotePatches = patches(from: baseLines, to: lines(remote))
    var combined = localPatches
    for remotePatch in remotePatches {
      var duplicate = false
      for localPatch in localPatches where overlaps(localPatch.range, remotePatch.range) {
        guard localPatch == remotePatch else { return .conflict }
        duplicate = true
      }
      if !duplicate { combined.append(remotePatch) }
    }

    combined.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound > $1.range.lowerBound
      }
      return !$0.range.isEmpty && $1.range.isEmpty
    }
    var result = baseLines
    for patch in combined {
      result.replaceSubrange(patch.range, with: patch.replacement)
    }
    return .merged(result.joined(separator: "\n"))
  }

  private static func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func patches(from base: [String], to target: [String]) -> [Patch] {
    let difference = target.difference(from: base)
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }

    var patches: [Patch] = []
    var baseIndex = 0
    var targetIndex = 0
    while baseIndex < base.count || targetIndex < target.count {
      let baseChanged = baseIndex < base.count && removed.contains(baseIndex)
      let targetChanged = targetIndex < target.count && inserted.contains(targetIndex)
      if !baseChanged, !targetChanged {
        precondition(baseIndex < base.count && targetIndex < target.count && base[baseIndex] == target[targetIndex])
        baseIndex += 1
        targetIndex += 1
        continue
      }

      let start = baseIndex
      var replacement: [String] = []
      while targetIndex < target.count, inserted.contains(targetIndex) {
        replacement.append(target[targetIndex])
        targetIndex += 1
      }
      while baseIndex < base.count, removed.contains(baseIndex) {
        baseIndex += 1
      }
      patches.append(Patch(range: start ..< baseIndex, replacement: replacement))
    }
    return patches
  }

  private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    switch (lhs.isEmpty, rhs.isEmpty) {
    case (true, true):
      lhs.lowerBound == rhs.lowerBound
    case (true, false):
      rhs.lowerBound < lhs.lowerBound && lhs.lowerBound < rhs.upperBound
    case (false, true):
      lhs.lowerBound < rhs.lowerBound && rhs.lowerBound < lhs.upperBound
    case (false, false):
      max(lhs.lowerBound, rhs.lowerBound) < min(lhs.upperBound, rhs.upperBound)
    }
  }
}
