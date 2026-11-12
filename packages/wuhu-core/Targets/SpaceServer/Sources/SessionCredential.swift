#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import SessionDomain
import SpaceContract

struct SessionCredential: Decodable, Sendable {
  enum Purpose: String, Decodable { case session, exec }
  let iss: String
  let aud: String
  let space: String
  let group: GroupID
  let session: SessionID
  let credential: Purpose
  let machine: MachineID?
  let exec: ExecID?
  let iat: Int
  let exp: Int
}

extension IdentityController {
  func credential(session: SessionID, group: GroupID, exec: ExecClaims?, now: Date, lifetime: Int) async throws -> String {
    let space = try await space.identity().rawValue
    let issuer = "wuhu:space:" + space
    let signer = try await keys.load(state!.schedule.signer)
    return try signer.token(issuer: nil, audience: URL(string: issuer)!, space: space, group: group.rawValue, session: session.rawValue, now: now, id: nil, lifetime: lifetime, exec: exec, directoryIssuer: issuer, purpose: exec == nil ? "session" : "exec")
  }

  func credential(_ bearer: String) async throws -> SessionCredential? {
    struct Header: Decodable { let alg: String; let typ: String; let kid: String }
    let parts = bearer.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let headerData = decodeCredentialPart(parts[0]), let header = try? JSONDecoder().decode(Header.self, from: headerData),
          header.alg == "ES256", header.typ == "JWT", state!.schedule.keys.contains(header.kid),
          let payload = decodeCredentialPart(parts[1]), let claims = try? JSONDecoder().decode(SessionCredential.self, from: payload),
          let signature = decodeCredentialPart(parts[2])
    else { return nil }
    let key = try await keys.load(header.kid)
    guard key.verifies(Data((parts[0] + "." + parts[1]).utf8), signature: signature) else { return nil }
    let space = try await space.identity().rawValue
    let issuer = "wuhu:space:" + space
    guard claims.iss == issuer, claims.aud == issuer, claims.space == space else { return nil }
    return claims
  }
}

private func decodeCredentialPart(_ value: Substring) -> Data? {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
}

func isSessionBearer(_ bearer: String) -> Bool {
  bearer.hasPrefix(ExecTokens.prefix)
}
