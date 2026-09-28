import Foundation

public enum TextEdit {
  public enum EditFailure: Error, Equatable, Sendable {
    case notFound
    case notUnique(count: Int)
    case noChange
  }

  public static func apply(content: String, old: String, new: String) -> Result<String, EditFailure> {
    let (bom, contentNoBom) = stripBom(content)
    let originalEnding = detectLineEnding(contentNoBom)

    let base = normalizeToLF(contentNoBom)
    let normalizedOld = normalizeToLF(old)
    let normalizedNew = normalizeToLF(new)

    // Fuzzy normalization is for FINDING only: the match span is mapped back to
    // the base content and the replacement spliced there, so bytes outside the
    // span are never rewritten. Uniqueness is counted in the same space the
    // match was found in — counting in a different space than the final span
    // produces false "not unique" rejections and wrong spans.
    let span: Range<String.Index>
    if let exact = base.range(of: normalizedOld) {
      let occurrences = base.components(separatedBy: normalizedOld).count - 1
      if occurrences > 1 { return .failure(.notUnique(count: occurrences)) }
      span = exact
    } else {
      let projection = fuzzyProjection(of: base)
      let fuzzyOld = normalizeForFuzzyMatch(normalizedOld)
      guard !fuzzyOld.isEmpty, let fuzzy = projection.text.range(of: fuzzyOld) else {
        return .failure(.notFound)
      }
      let occurrences = projection.text.components(separatedBy: fuzzyOld).count - 1
      if occurrences > 1 { return .failure(.notUnique(count: occurrences)) }
      span = projection.baseSpan(of: fuzzy)
    }

    let replaced = base.replacingCharacters(in: span, with: normalizedNew)
    guard base != replaced else { return .failure(.noChange) }

    return .success(bom + restoreLineEndings(replaced, ending: originalEnding))
  }
}

private struct FuzzyProjection {
  var text: String
  var sourceRanges: [Range<String.Index>]

  func baseSpan(of match: Range<String.Index>) -> Range<String.Index> {
    let lower = text.distance(from: text.startIndex, to: match.lowerBound)
    let upper = text.distance(from: text.startIndex, to: match.upperBound)
    return sourceRanges[lower].lowerBound ..< sourceRanges[upper - 1].upperBound
  }
}

// Mirrors normalizeForFuzzyMatch character by character, remembering where each
// projected character came from: line-end spaces/tabs are dropped, every other
// character is folded (smart quotes, dashes, unicode spaces).
private func fuzzyProjection(of base: String) -> FuzzyProjection {
  var text = ""
  var sourceRanges: [Range<String.Index>] = []
  var pendingLineEndWhitespace: [(Character, Range<String.Index>)] = []

  func emit(_ character: Character, from range: Range<String.Index>) {
    text.append(foldForFuzzyMatch(character))
    sourceRanges.append(range)
  }

  var index = base.startIndex
  while index < base.endIndex {
    let character = base[index]
    let range = index ..< base.index(after: index)
    switch character {
    case " ", "\t":
      pendingLineEndWhitespace.append((character, range))
    case "\n":
      pendingLineEndWhitespace.removeAll()
      emit(character, from: range)
    default:
      for (pending, pendingRange) in pendingLineEndWhitespace {
        emit(pending, from: pendingRange)
      }
      pendingLineEndWhitespace.removeAll()
      emit(character, from: range)
    }
    index = range.upperBound
  }
  return FuzzyProjection(text: text, sourceRanges: sourceRanges)
}

private func normalizeForFuzzyMatch(_ text: String) -> String {
  let stripped = text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { trimEnd(String($0)) }
    .joined(separator: "\n")
  return String(stripped.map(foldForFuzzyMatch))
}

private func foldForFuzzyMatch(_ character: Character) -> Character {
  switch character {
  case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": "'"
  case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": "\""
  case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": "-"
  case "\u{00A0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
       "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}": " "
  default: character
  }
}

private func stripBom(_ content: String) -> (bom: String, text: String) {
  if content.hasPrefix("\u{FEFF}") {
    return ("\u{FEFF}", String(content.dropFirst()))
  }
  return ("", content)
}

private func detectLineEnding(_ content: String) -> String {
  content.contains("\r\n") ? "\r\n" : "\n"
}

private func normalizeToLF(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func restoreLineEndings(_ text: String, ending: String) -> String {
  ending == "\r\n" ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
}

private func trimEnd(_ string: String) -> String {
  var end = string.endIndex
  while end > string.startIndex {
    let before = string.index(before: end)
    let character = string[before]
    if character == " " || character == "\t" {
      end = before
      continue
    }
    break
  }
  return String(string[..<end])
}
