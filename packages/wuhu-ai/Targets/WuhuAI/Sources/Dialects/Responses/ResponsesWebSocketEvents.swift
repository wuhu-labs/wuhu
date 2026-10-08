import Fetch
import FetchWebSocket
import HTTPTypes
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections

enum ResponsesRecovery: Error { case previousMissing, connectionExpired }

struct ResponsesWebSocketEvents {
  var responseID: String?
  var exposedOutput = false
  var continuable = true
  private var calls: [String: String] = [:]
  private var finishedCalls: Set<String> = []
  private var arguments: [String: String] = [:]
  private var finalArguments: [String: String] = [:]
  private var itemIDs: Set<String> = []
  private var kinds: [String: String] = [:]
  private var textByItem: [String: String] = [:]
  private var names: [String: String] = [:]
  private var finishedItems: Set<String> = []

  mutating func accept(_ value: JSONValue) throws -> (event: SSEEvent?, terminal: Bool) {
    guard var object = value.object, let type = object["type"]?.stringValue else {
      throw Self.invalid("Expected a Responses event object")
    }
    if type == "error" || type == "response.failed" {
      let error = object["error"] ?? object["response"]?.object?["error"] ?? value
      let code = error.object?["code"]?.stringValue ?? error.object?["type"]?.stringValue
      if !exposedOutput {
        if code == "previous_response_not_found" { throw ResponsesRecovery.previousMissing }
        if code == "websocket_connection_limit_reached" { throw ResponsesRecovery.connectionExpired }
      }
      let headers = object["headers"]?.object ?? error.object?["headers"]?.object ?? [:]
      throw Self.providerError(
        error,
        status: object["status"]?.intValue ?? object["status_code"]?.intValue ?? error.object?["status"]?.intValue ?? error.object?["status_code"]?.intValue,
        headers: RequestHeaders(values: Dictionary(uniqueKeysWithValues: headers.compactMap { key, value in value.stringValue.map { (key, $0) } })).fields,
      )
    }
    if type == "response.cancelled" { throw Self.invalid("Unsolicited response.cancelled") }
    guard type.hasPrefix("response.") else { return (nil, false) }
    if let id = object["response"]?.object?["id"]?.stringValue ?? object["response_id"]?.stringValue {
      if let responseID, responseID != id { throw Self.invalid("Response identity changed during inference") }
      responseID = id
    }
    switch type {
    case "response.output_item.added":
      exposedOutput = true
      guard let item = object["item"]?.object, let itemType = item["type"]?.stringValue else {
        throw Self.invalid("Missing output item")
      }
      guard let itemID = item["id"]?.stringValue, !itemID.isEmpty, itemIDs.insert(itemID).inserted else {
        throw Self.invalid("Invalid output item identity")
      }
      guard ["message", "function_call", "reasoning", "web_search_call"].contains(itemType) else {
        throw Self.invalid("Unsupported output item type")
      }
      kinds[itemID] = itemType
      if itemType == "function_call" {
        guard let id = item["id"]?.stringValue, let call = item["call_id"]?.stringValue,
              !id.isEmpty, !call.isEmpty, item["name"]?.stringValue != nil,
              calls[id] == nil, !calls.values.contains(call)
        else { throw Self.invalid("Invalid function call identity") }
        calls[id] = call
        names[id] = item["name"]?.stringValue
        arguments[id] = item["arguments"]?.stringValue ?? ""
      }
    case "response.output_text.delta", "response.refusal.delta":
      exposedOutput = true
      guard let id = object["item_id"]?.stringValue, kinds[id] == "message", !finishedItems.contains(id), let delta = object["delta"]?.stringValue else {
        throw Self.invalid("Text delta for an unknown or finished message")
      }
      textByItem[id, default: ""] += delta
      if type == "response.refusal.delta" { object["type"] = .string("response.output_text.delta") }
      return (SSEEvent(data: JSONValue.object(object).jsonString()), false)
    case "response.function_call_arguments.delta", "response.function_call_arguments.done":
      exposedOutput = true
      guard let id = object["item_id"]?.stringValue, calls[id] != nil, !finishedCalls.contains(id) else {
        throw Self.invalid("Arguments for an unknown or finished function call")
      }
      if type.hasSuffix(".delta") {
        guard let delta = object["delta"]?.stringValue else { throw Self.invalid("Missing argument delta") }
        arguments[id, default: ""] += delta
      } else {
        guard let text = object["arguments"]?.stringValue, ToolArguments(verbatim: text) != nil,
              arguments[id]?.isEmpty != false || arguments[id] == text
        else { throw Self.invalid("Invalid or inconsistent function call arguments") }
        finalArguments[id] = text
      }
    case "response.output_item.done":
      exposedOutput = true
      guard let item = object["item"]?.object else { throw Self.invalid("Missing completed output item") }
      guard let itemID = item["id"]?.stringValue, kinds[itemID] == item["type"]?.stringValue, finishedItems.insert(itemID).inserted else {
        throw Self.invalid("Unknown or duplicate completed output item")
      }
      if item["type"]?.stringValue == "message", let content = item["content"]?.array {
        let finalText = content.compactMap { part -> String? in
          switch part.object?["type"]?.stringValue {
          case "output_text": return part.object?["text"]?.stringValue
          case "refusal": return part.object?["refusal"]?.stringValue
          default: return nil
          }
        }.joined()
        guard finalText.hasPrefix(textByItem[itemID] ?? "") else { throw Self.invalid("Final text contradicts streamed text") }
      }
      if item["type"]?.stringValue == "function_call" {
        guard let id = item["id"]?.stringValue, calls[id] == item["call_id"]?.stringValue, names[id] == item["name"]?.stringValue,
              !finishedCalls.contains(id), let arguments = item["arguments"]?.stringValue,
              ToolArguments(verbatim: arguments) != nil,
              finalArguments[id] == nil || finalArguments[id] == arguments,
              self.arguments[id]?.isEmpty != false || self.arguments[id] == arguments
        else { throw Self.invalid("Invalid completed function call") }
        finishedCalls.insert(id)
      }
    case "response.completed", "response.incomplete":
      guard let id = responseID, !id.isEmpty, var response = object["response"]?.object,
            finishedCalls.count == calls.count, response["usage"]?.object != nil
      else { throw Self.invalid("Incomplete terminal response or unfinished function call") }
      if let output = response["output"]?.array {
        guard output.allSatisfy({ item in
          guard let id = item.object?["id"]?.stringValue else { return false }
          return finishedItems.contains(id)
        }) else { throw Self.invalid("Terminal output was not delivered by item events") }
      }
      if type == "response.incomplete" {
        continuable = false
        let reason = response["incomplete_details"]?.object?["reason"]?.stringValue
        if reason == "interrupted" { throw CancellationError() }
        guard reason == "max_output_tokens" || reason == "content_filter", response["usage"]?.object != nil else {
          throw Self.invalid("Unsupported incomplete response")
        }
        object["type"] = .string("response.completed")
        response["status"] = .string("incomplete")
        object["response"] = .object(response)
      } else if response["status"]?.stringValue != "completed" {
        throw Self.invalid("Invalid completed response status")
      }
      return (SSEEvent(data: JSONValue.object(object).jsonString()), true)
    default:
      if type.contains(".delta") || type.contains(".done") { exposedOutput = true }
    }
    return (SSEEvent(data: value.jsonString()), false)
  }

  static func invalid(_ message: String) -> InferenceError {
    .transient(status: nil, body: "invalid_stream: \(message)")
  }

  static func providerError(_ value: JSONValue, status: Int?, headers: Headers) -> InferenceError {
    if let malformed = responsesMalformedMessage(value) { return malformed }
    let object = value.object
    let code = object?["code"]?.stringValue ?? object?["type"]?.stringValue ?? "unknown_error"
    let message = String((object?["message"]?.stringValue ?? code).prefix(8192))
    if let capacity = InferenceError.capacityError(code: code, message: message, status: status) { return capacity }
    if InferenceError.bodyIndicatesContextOverflow(code + " " + message) { return .contextTooLong }
    switch code {
    case "rate_limit_exceeded", "rate_limit_error", "insufficient_quota", "usage_limit_reached": return .rateLimited(retryAt: InferenceError.parseRetryAfter(headers))
    case "server_error", "internal_server_error", "overloaded_error", "temporarily_unavailable":
      return .transient(status: nil, body: message)
    case "invalid_api_key", "authentication_error", "unauthorized": return .invalidInput(status: 401, body: message)
    case "permission_denied", "forbidden": return .invalidInput(status: 403, body: message)
    case "previous_response_not_found", "websocket_connection_limit_reached": return .transient(status: status, body: message)
    case "invalid_stream_id", "websocket_stream_limit_reached", "invalid_request_error", "invalid_request", "invalid_value", "unsupported_parameter", "model_not_found":
      return .invalidInput(status: 400, body: message)
    default:
      if let status { return .classify(status: status, headers: headers, body: message) }
      return .other(status: nil, body: code + ": " + message)
    }
  }
}

func responsesWebSocketError(_ error: any Error) -> InferenceError {
  guard let socketError = error as? WebSocketError else {
    if let recovery = error as? ResponsesRecovery {
      return .transient(status: nil, body: recovery == .previousMissing ? "previous_response_not_found" : "websocket_connection_limit_reached")
    }
    return InferenceError.normalize(error)
  }
  switch socketError {
  case let .refused(status, headers, body): return .classify(status: status, headers: headers, body: String(decoding: body, as: UTF8.self))
  case .cancelled: return .cancelled
  case .connectTimeout: return .transport(.connectTimeout)
  case .connectionClosed: return .transport(.connectionClosed)
  case .io: return .transport(.io)
  case .tls(let message): return .invalidInput(status: 400, body: String(message.prefix(8192)))
  case .protocolViolation(let message): return ResponsesWebSocketEvents.invalid(String(message.prefix(8192)))
  case .multipleConsumers: return .invalidInput(status: 400, body: "Multiple WebSocket receive consumers")
  case .limitExceeded(.outboundMessage): return .requestTooLarge(limitBytes: responsesWebSocketByteLimit)
  case .limitExceeded: return ResponsesWebSocketEvents.invalid("WebSocket inbound payload limit exceeded")
  case .unimplemented, .invalidURL, .invalidConfiguration:
    return .invalidInput(status: 400, body: String(describing: socketError))
  }
}
