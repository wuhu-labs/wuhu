import Dependencies

public struct ServerTrustProbe: Sendable {
  public var validateSystem: @Sendable (_ host: String, _ port: Int) async throws -> Void
  public var observeLeaf: @Sendable (_ host: String, _ port: Int) async throws -> String

  public init(
    validateSystem: @escaping @Sendable (_ host: String, _ port: Int) async throws -> Void,
    observeLeaf: @escaping @Sendable (_ host: String, _ port: Int) async throws -> String,
  ) {
    self.validateSystem = validateSystem
    self.observeLeaf = observeLeaf
  }
}

extension ServerTrustProbe: TestDependencyKey {
  public static var testValue: ServerTrustProbe {
    ServerTrustProbe(
      validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
      observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
    )
  }
}

struct UnimplementedProbe: Error, CustomStringConvertible {
  let endpoint: String
  var description: String { "ServerTrustProbe.\(self.endpoint) is unimplemented" }
}
