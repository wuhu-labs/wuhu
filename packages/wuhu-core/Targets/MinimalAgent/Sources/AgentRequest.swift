#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum Credentials.ProviderCredential
import struct InferenceKit.ModelsDocument

public struct AgentError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Code: String, Sendable {
    case isolation
    case invalidRequest
    case transcript
    case inference
    case noComplete
    case turnBudgetExhausted
  }

  public var code: Code
  public var message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { "\(code.rawValue): \(message)" }
}

/// Where the run's transcript goes: a new JSONL file, or an existing one it continues and keeps appending to.
public enum AgentLog: Equatable, Sendable {
  case new(String)
  case resume(String)
}

struct AgentRequest: Decodable {
  var model: String
  var effort: String?
  var provider: ModelsDocument.Provider
  var credential: Credential
  var system: String
  var task: String
  var maxTurns: Int
  var bashTimeoutSeconds: Int

  enum Credential: Decodable {
    case apiKey(String)
    case chatGPT(accessToken: String, accountID: String)

    private enum CodingKeys: String, CodingKey { case apiKey, chatGPT }
    private struct Login: Decodable {
      var accessToken: String
      var accountID: String
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try (container.decodeIfPresent(String.self, forKey: .apiKey), container.decodeIfPresent(Login.self, forKey: .chatGPT)) {
      case let (key?, nil): self = .apiKey(key)
      case let (nil, login?): self = .chatGPT(accessToken: login.accessToken, accountID: login.accountID)
      default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "credential takes exactly one of apiKey or chatGPT"))
      }
    }

    var provider: ProviderCredential {
      switch self {
      case let .apiKey(key): .apiKey(key)
      case let .chatGPT(token, account): .chatGPT(accessToken: token, accountID: account)
      }
    }

    var secrets: [String] {
      switch self {
      case let .apiKey(key): [key]
      case let .chatGPT(token, account): [token, account]
      }
    }
  }

  static func decode(_ text: String) throws(AgentError) -> Self {
    let request: Self
    do { request = try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
    catch { throw AgentError(.invalidRequest, "stdin is not an agent request: \(error)") }
    guard request.maxTurns > 0 else { throw AgentError(.invalidRequest, "maxTurns must be positive") }
    guard request.bashTimeoutSeconds > 0 else { throw AgentError(.invalidRequest, "bashTimeoutSeconds must be positive") }
    return request
  }
}
