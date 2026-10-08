import JSONValue

func responsesMalformedMessage(_ error: JSONValue) -> InferenceError? {
  let object = error.object
  guard object?["code"]?.stringValue == "malformed_model_message"
    || object?["type"]?.stringValue == "malformed_model_message"
  else { return nil }
  return .malformedModelMessage(
    message: String((object?["message"]?.stringValue ?? "malformed_model_message").prefix(8192)),
    reason: object?["reason"]?.stringValue.map { String($0.prefix(8192)) },
  )
}
