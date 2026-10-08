#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import OrderedCollections
import WuhuAI

struct OIDCAnthropicEndpoint: AnthropicMessagesEndpoint {
  let model: String
  let baseURL: URL
  let token: String
  let deepSeek: Bool

  var providerID: String { deepSeek ? "deepseek" : "anthropic" }
  var acceptsUnsignedThinking: Bool { deepSeek }

  func modifyBody(_ body: inout OrderedDictionary<String, JSONValue>, options: RequestOptions) {
    if deepSeek {
      DeepSeekAnthropicEndpoint(model: model, baseURL: baseURL, apiKey: "").modifyBody(&body, options: options)
    } else {
      AnthropicEndpoint(model: model, baseURL: baseURL, apiKey: "", promptCache: .oneHour).modifyBody(&body, options: options)
    }
  }

  func modifyHeaders(_ headers: inout RequestHeaders, options: RequestOptions) {
    headers.setSensitive("authorization", "Bearer \(token)")
    headers.set("anthropic-version", "2023-06-01")
  }
}
