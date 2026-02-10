import Foundation

public enum ToolPath {
  private static let unicodeSpacesPattern = #"[\u{00A0}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]"#
  private static let narrowNoBreakSpace = "\u{202F}"

  public static func expand(_ raw: String) -> String {
    var s = normalizeAtPrefix(raw)
    s = normalizeUnicodeSpaces(s)
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)

    if s == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
    if s.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(s.dropFirst(2))).path }
    return s
  }

  public static func resolveToCwd(_ path: String, cwd: String) -> String {
    let expanded = expand(path)
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL.path
  }

  public static func resolveReadPath(_ path: String, cwd: String) -> String {
    let resolved = resolveToCwd(path, cwd: cwd)
    if FileManager.default.fileExists(atPath: resolved) { return resolved }

    let amPmVariant = tryMacOSScreenshotPath(resolved)
    if amPmVariant != resolved, FileManager.default.fileExists(atPath: amPmVariant) { return amPmVariant }

    let nfdVariant = resolved.decomposedStringWithCanonicalMapping // macOS often stores filenames in NFD
    if nfdVariant != resolved, FileManager.default.fileExists(atPath: nfdVariant) { return nfdVariant }

    let curlyVariant = tryCurlyQuoteVariant(resolved)
    if curlyVariant != resolved, FileManager.default.fileExists(atPath: curlyVariant) { return curlyVariant }

    let nfdCurly = tryCurlyQuoteVariant(nfdVariant)
    if nfdCurly != resolved, FileManager.default.fileExists(atPath: nfdCurly) { return nfdCurly }

    return resolved
  }

  private static func normalizeUnicodeSpaces(_ s: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: unicodeSpacesPattern, options: []) else { return s }
    let range = NSRange(s.startIndex ..< s.endIndex, in: s)
    return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
  }

  private static func normalizeAtPrefix(_ s: String) -> String {
    if s.hasPrefix("@") { return String(s.dropFirst()) }
    return s
  }

  private static func tryMacOSScreenshotPath(_ s: String) -> String {
    // macOS screenshot names often contain a narrow no-break space before AM/PM.
    // If a user types a regular space, try swapping in U+202F.
    s.replacingOccurrences(of: " AM.", with: "\(narrowNoBreakSpace)AM.")
      .replacingOccurrences(of: " PM.", with: "\(narrowNoBreakSpace)PM.")
  }

  private static func tryCurlyQuoteVariant(_ s: String) -> String {
    // macOS screenshot names can contain U+2019; users often type ASCII apostrophe.
    s.replacingOccurrences(of: "'", with: "\u{2019}")
  }
}
