#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue

extension Executor {
  mutating func serverIdentity() async throws {
    let space = try wallet.pinnedSpace()
    let output: JSONValue = try await authenticated(space).api(.get, "/v1/identity")
    await runner.stdout(prettyJSON(output) + "\n")
  }

  mutating func serverIdentityIssuerFor(_ origin: String) async throws {
    let space = try wallet.pinnedSpace()
    var parts = URLComponents()
    parts.path = "/v1/identity/issuer-for"
    parts.queryItems = [URLQueryItem(name: "origin", value: origin)]
    let output: JSONValue = try await authenticated(space).api(.get, parts.string!)
    guard let issuer = output.object?["issuer"]?.stringValue else { throw UsageError(message: "identity: server returned no issuer") }
    await runner.stdout(issuer + "\n")
  }

  mutating func serverIdentityRegisterNew() async throws {
    let space = try wallet.pinnedSpace()
    let output: JSONValue = try await authenticated(space).api(.post, "/v1/identity/register-new")
    await runner.stdout(prettyJSON(output) + "\n")
  }

  mutating func serverIdentityRotate() async throws {
    let space = try wallet.pinnedSpace()
    let output: JSONValue = try await authenticated(space).api(.post, "/v1/identity/rotate")
    await runner.stdout(prettyJSON(output) + "\n")
  }

  mutating func serverIdentitySet(defaultIssuer: String?, audience: String?, issuer: String?) async throws {
    let space = try wallet.pinnedSpace()
    let body: JSONValue
    if let defaultIssuer { body = .object(["defaultIssuer": .string(defaultIssuer)]) }
    else { body = .object(["audience": .string(audience!), issuer == nil ? "remove" : "issuer": issuer.map(JSONValue.string) ?? .bool(true)]) }
    let output: JSONValue = try await authenticated(space).api(.put, "/v1/identity", body: body)
    await runner.stdout(prettyJSON(output) + "\n")
  }
}
