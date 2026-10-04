import Contract
import JSONValue

@Contract
public struct TranscriptionOutput: Codable, Equatable, Sendable {
  public let text: String
  public let provider: String
  public let model: String
  public let language: String?
  public let durationSeconds: Double?
  public let segments: [JSONValue]?
  public let words: [JSONValue]?
  public let confidence: Double?
  public let usage: JSONValue?
}

@Contract
public struct TranscriberInfo: Codable, Equatable, Sendable {
  public let available: Bool
  public let provider: String?
  public let model: String?
}
