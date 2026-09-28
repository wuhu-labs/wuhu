import Contract
import JSONValue

@Contract
public enum MutationEvent: Codable, Equatable, Sendable {
  case write(path: String, rev: Int, entry: EntryKind)
  case delete(path: String, rev: Int)
  case move(path: String, to: String, rev: Int, entry: EntryKind)
}
