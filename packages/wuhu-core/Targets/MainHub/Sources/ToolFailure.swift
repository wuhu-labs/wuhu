import JSONValue
import SpaceTools

public func renderedFailure(_ error: ToolRunError) -> String {
  guard case let .object(fields) = error.payload else { return "tool failed" }
  var text = ""
  if case let .string(code)? = fields["code"] { text += "\(code): " }
  if case let .string(message)? = fields["message"] { text += message }
  if case let .string(hint)? = fields["hint"] { text += " (\(hint))" }
  if case let .string(token)? = fields["token"] { text += " [current token: \(token)]" }
  return text
}
