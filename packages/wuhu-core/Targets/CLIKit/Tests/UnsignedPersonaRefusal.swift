import Fetch
import JSONValue

/// A server that seats nobody without a key answers an unsigned `POST /v1/persona` this way.
func unsignedPersonaRefusal() throws -> Response {
  try Response.json(["code": "unauthorized", "message": "a bearer assertion is required"] as JSONValue, status: .unauthorized)
}
