import Foundation
import PiAI

public enum WuhuLLMCustomEntryTypes {
  public static let retry: String = "wuhu_llm_retry_v1"
  public static let giveUp: String = "wuhu_llm_give_up_v1"
}

public struct WuhuLLMRetryEvent: Sendable, Hashable, Codable {
  public var version: Int
  public var purpose: String?
  public var retryIndex: Int
  public var maxRetries: Int
  public var backoffSeconds: Double
  public var error: String

  public init(
    version: Int = 1,
    purpose: String?,
    retryIndex: Int,
    maxRetries: Int,
    backoffSeconds: Double,
    error: String,
  ) {
    self.version = version
    self.purpose = purpose
    self.retryIndex = retryIndex
    self.maxRetries = maxRetries
    self.backoffSeconds = backoffSeconds
    self.error = error
  }

  public func toJSONValue() -> JSONValue {
    var obj: [String: JSONValue] = [
      "version": .number(Double(version)),
      "retryIndex": .number(Double(retryIndex)),
      "maxRetries": .number(Double(maxRetries)),
      "backoffSeconds": .number(backoffSeconds),
      "error": .string(error),
    ]
    if let purpose {
      obj["purpose"] = .string(purpose)
    }
    return .object(obj)
  }
}

public struct WuhuLLMGiveUpEvent: Sendable, Hashable, Codable {
  public var version: Int
  public var purpose: String?
  public var maxRetries: Int
  public var error: String

  public init(
    version: Int = 1,
    purpose: String?,
    maxRetries: Int,
    error: String,
  ) {
    self.version = version
    self.purpose = purpose
    self.maxRetries = maxRetries
    self.error = error
  }

  public func toJSONValue() -> JSONValue {
    var obj: [String: JSONValue] = [
      "version": .number(Double(version)),
      "maxRetries": .number(Double(maxRetries)),
      "error": .string(error),
    ]
    if let purpose {
      obj["purpose"] = .string(purpose)
    }
    return .object(obj)
  }
}
