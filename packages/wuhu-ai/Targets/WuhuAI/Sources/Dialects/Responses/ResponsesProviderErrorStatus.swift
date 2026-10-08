import JSONValue

func responsesProviderErrorStatus(_ event: JSONValue, error: JSONValue) -> Int? {
  event.object?["status"]?.intValue
    ?? event.object?["status_code"]?.intValue
    ?? error.object?["status"]?.intValue
    ?? error.object?["status_code"]?.intValue
}
