import Fetch
import HTTPTypes
import JSONValue

/// The typed failure an `error` or `response.failed` event carries, over SSE and WebSocket alike.
func responsesFailure(_ event: JSONValue) -> InferenceError {
  let error = responsesEventError(event)
  let headers = event.object?["headers"]?.object ?? error.object?["headers"]?.object ?? [:]
  return responsesProviderError(
    error,
    status: responsesProviderErrorStatus(event, error: error),
    headers: RequestHeaders(values: Dictionary(uniqueKeysWithValues: headers.compactMap { key, value in value.stringValue.map { (key, $0) } })).fields,
  )
}

func responsesEventError(_ event: JSONValue) -> JSONValue {
  event.object?["error"] ?? event.object?["response"]?.object?["error"] ?? event
}

func responsesProviderError(_ value: JSONValue, status: Int?, headers: Headers) -> InferenceError {
  if let malformed = responsesMalformedMessage(value) { return malformed }
  let object = value.object
  let code = object?["code"]?.stringValue ?? object?["type"]?.stringValue ?? "unknown_error"
  let message = String((object?["message"]?.stringValue ?? code).prefix(8192))
  if let capacity = InferenceError.capacityError(code: code, message: message, status: status) { return capacity }
  if InferenceError.bodyIndicatesContextOverflow(code + " " + message) { return .contextTooLong }
  switch code {
  case "upstream_stream_cut": return .streamCut
  case "rate_limit_exceeded", "rate_limit_error", "insufficient_quota", "usage_limit_reached": return .rateLimited(retryAt: InferenceError.parseRetryAfter(headers))
  case "server_error", "internal_server_error", "overloaded_error", "temporarily_unavailable":
    return .upstreamUnavailable(code: code)
  case "upstream_unreachable": return .upstreamUnreachable
  case "invalid_api_key", "authentication_error", "unauthorized", "account_deactivated", "account_banned": return .authenticationRefused(code: code)
  case "permission_denied", "forbidden": return .invalidInput(status: 403, body: message)
  case "previous_response_not_found", "websocket_connection_limit_reached": return .transient(status: status, body: message)
  case "invalid_stream_id", "websocket_stream_limit_reached", "invalid_request_error", "invalid_request", "invalid_value", "unsupported_parameter", "model_not_found":
    return .invalidInput(status: 400, body: message)
  default:
    if let status { return .classify(status: status, headers: headers, body: message) }
    return .transient(status: nil, body: code + ": " + message)
  }
}

private func responsesProviderErrorStatus(_ event: JSONValue, error: JSONValue) -> Int? {
  event.object?["status"]?.intValue
    ?? event.object?["status_code"]?.intValue
    ?? error.object?["status"]?.intValue
    ?? error.object?["status_code"]?.intValue
}
