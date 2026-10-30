public enum Handle {
  public static func normalized(_ raw: String) -> String? {
    normalizedLabel(raw, allowing: ["_"], length: 2 ... 32)
  }
}

public func normalizedLabel(_ raw: String, allowing extras: Set<Character>, length: ClosedRange<Int>) -> String? {
  let lowered = raw.lowercased()
  guard length.contains(lowered.count), let first = lowered.first, isASCIIAlphanumeric(first) else { return nil }
  guard lowered.dropFirst().allSatisfy({ isASCIIAlphanumeric($0) || extras.contains($0) }) else { return nil }
  return lowered
}

private func isASCIIAlphanumeric(_ character: Character) -> Bool {
  character.isASCII && (("a" ... "z").contains(character) || ("0" ... "9").contains(character))
}
