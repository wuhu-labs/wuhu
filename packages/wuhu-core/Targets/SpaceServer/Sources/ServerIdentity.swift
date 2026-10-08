import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import enum WuhuAI.InferenceError
import struct WuhuVFS.DiskVFSNode
import struct WuhuVFS.NodeTreeVFS
import struct WuhuVFS.VFSPath
import protocol WuhuVFS.VirtualFileSystem

struct ServerIdentity: Sendable {
  private let key: P256.Signing.PrivateKey
  let kid: String

  init(rawKey: Data) throws {
    key = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
    kid = Data(SHA256.hash(data: key.publicKey.x963Representation)).base64URL
  }

  static func loadOrCreate(from fs: any VirtualFileSystem) async throws -> Self {
    let path = try VFSPath(absoluteFilePath: "/identity.p256")
    if try await fs.status(at: path) != nil {
      return try Self(rawKey: await fs.readData(at: path))
    }
    let key = P256.Signing.PrivateKey()
    try await fs.createFile(at: path, data: key.rawRepresentation)
    return try Self(rawKey: key.rawRepresentation)
  }

  static func loadOrCreate(directory: URL) async throws -> Self {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent("identity.p256")
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.keyUnavailable }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    if FileManager.default.fileExists(atPath: file.path) {
      guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.keyUnavailable }
    }
    let identity = try await loadOrCreate(from: WuhuVFS.NodeTreeVFS(root: WuhuVFS.DiskVFSNode(path: directory.path, isMutable: true)))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return identity
  }

  var jwks: JSONValue {
    let point = key.publicKey.x963Representation
    return .object(["keys": .array([.object([
      "kty": .string("EC"), "crv": .string("P-256"), "alg": .string("ES256"),
      "use": .string("sig"), "kid": .string(kid),
      "x": .string(Data(point[1 ..< 33]).base64URL), "y": .string(Data(point[33 ..< 65]).base64URL),
    ])])])
  }

  func token(issuer: String?, audience: URL, space: String, group: String, session: String? = nil, now: Date, id: UUID) throws -> String {
    let issuer = try Self.issuer(issuer)
    guard var origin = URLComponents(url: audience, resolvingAgainstBaseURL: false),
          origin.scheme != nil, let host = origin.host, !host.isEmpty, origin.user == nil, origin.password == nil
    else { throw IdentityError.invalidAudience }
    origin.scheme = origin.scheme?.lowercased()
    origin.host = host.lowercased()
    if (origin.scheme == "https" && origin.port == 443) || (origin.scheme == "http" && origin.port == 80) { origin.port = nil }
    origin.path = ""
    origin.query = nil
    origin.fragment = nil
    guard let audience = origin.string else { throw IdentityError.invalidAudience }
    let issued = Int(now.timeIntervalSince1970)
    var claims: OrderedDictionary<String, JSONValue> = [
      "iss": .string(issuer), "aud": .string(audience), "iat": .integer(issued), "exp": .integer(issued + 300),
      "jti": .string(id.uuidString.lowercased()), "space": .string(space), "group": .string(group),
      "sub": .string(session.map { "\(group)/\($0)" } ?? group),
    ]
    if let session { claims["session"] = .string(session) }
    let header: JSONValue = .object(["alg": .string("ES256"), "typ": .string("JWT"), "kid": .string(kid)])
    let signingInput = Data(header.jsonString().utf8).base64URL + "." + Data(JSONValue.object(claims).jsonString().utf8).base64URL
    do {
      return try signingInput + "." + key.signature(for: Data(signingInput.utf8)).rawRepresentation.base64URL
    } catch { throw IdentityError.signingFailed }
  }

  func tokenForInference(issuer: String?, audience: URL, space: String, group: String, session: String, now: Date, id: UUID) throws(InferenceError) -> String {
    do {
      return try token(issuer: issuer, audience: audience, space: space, group: group, session: session, now: now, id: id)
    } catch IdentityError.invalidAudience {
      throw .invalidInput(status: 422, body: "OIDC token audience is invalid; check the provider baseURL.")
    } catch IdentityError.invalidIssuer {
      throw .invalidInput(status: 422, body: "OIDC token issuer is invalid; check HTTPS --origin.")
    } catch {
      throw InferenceError.normalize(error)
    }
  }

  static func issuer(_ origin: String?) throws -> String {
    guard let origin, let url = URLComponents(string: origin), url.scheme == "https",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
    else { throw IdentityError.invalidIssuer }
    return "https://\(host.lowercased())" + (url.port == nil || url.port == 443 ? "" : ":\(url.port!)")
  }
}

enum IdentityError: Error, Equatable, CustomStringConvertible {
  case invalidIssuer, invalidAudience, keyUnavailable, signingFailed

  var description: String {
    switch self {
    case .invalidIssuer: "OIDC requires a configured HTTPS --origin."
    case .invalidAudience: "OIDC provider baseURL must have a scheme and host, without user information."
    case .keyUnavailable: "The server identity key is unavailable."
    case .signingFailed: "The server could not sign an OIDC token."
    }
  }
}

private extension Data {
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
