import Contract
import JSONValue

@Contract
public struct TranscriptionOutput: Codable, Equatable, Sendable {
  public let text: String
  public let provider: String
  public let model: String
  public let language: String?
  public let durationSeconds: Double?
}

@Contract
public struct TranscriberInfo: Codable, Equatable, Sendable {
  public let available: Bool
  public let provider: String?
  public let model: String?
}
