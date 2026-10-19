import JSONValue
import SpaceTools

/// A budget or protocol failure stays a plain error; a space failure becomes
/// the payload the core turns into a SpaceError.
public func spaceAnswer(_ body: () async throws -> JSONValue) async -> JSONValue {
  do {
    return .object(["ok": try await body()])
  } catch let error as ScriptError {
    return .object(["error": ToolRunError.failed(code: .invalidArgument, message: error.description, hint: nil).payload])
  } catch {
    return .object(["error": Wire.failure(error).payload])
  }
}
