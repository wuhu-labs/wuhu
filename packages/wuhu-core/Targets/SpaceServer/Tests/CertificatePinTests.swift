import Crypto
import Fetch
import Foundation
import struct MachineContract.MachineAddOutput
import struct MachineContract.MachineRotateOutput
import enum PinnedTLS.PinnedTLS
import Scratch
import ServeNIO
import ServeTLS
import struct SpaceContract.AccountPayload
import struct SpaceContract.EnrollMintOutput
import struct SpaceContract.ShareLoginChallengeOutput
import struct SpaceContract.ShareLoginOutput
import SpaceCore
import SpaceServer
import Testing

// Everything serve hands out for a client to enroll with carries a
// fingerprint exactly when serve runs the certificate it generated.
@Suite struct CertificatePinTests {
  @Test func theGeneratedCertificateIsHandedOutEverywhere() async throws {
    let base = try scratchURL("certificate-pin")
    defer { try? FileManager.default.removeItem(at: base) }
    let handedOut = try await serveAndCollect(folder: base.appendingPathComponent("store"))
    let generated = try TLSIdentity.fingerprint(certificatePEM: String(
      contentsOf: base.appendingPathComponent("store/tls/cert.pem"), encoding: .utf8,
    ))
    #expect(handedOut.served == generated)
    #expect(handedOut.all == Array(repeating: generated, count: 6))
  }

  @Test func aProvidedCertificateIsNeverHandedOut() async throws {
    let base = try scratchURL("certificate-pin")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    // Self-signed, yet passed through --cert: clients must trust it themselves.
    let own = try TLSIdentity.selfSigned(hosts: ["space.test"])
    let certificate = base.appendingPathComponent("own.pem")
    let privateKey = base.appendingPathComponent("own.key")
    try own.certificatePEM.write(to: certificate, atomically: true, encoding: .utf8)
    try own.privateKeyPEM.write(to: privateKey, atomically: true, encoding: .utf8)
    let handedOut = try await serveAndCollect(
      folder: base.appendingPathComponent("store"), certificate: certificate, privateKey: privateKey,
    )
    #expect(handedOut.served == (try own.fingerprint()))
    #expect(handedOut.all == Array(repeating: nil, count: 6))
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("store/tls").path))
  }

  @Test func aGroupCertificateNeedsItsOwnCertificateBeside() async throws {
    let base = try scratchURL("certificate-pin")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let group = try TLSIdentity.selfSigned(hosts: ["*.space.test"])
    let certificate = base.appendingPathComponent("group.pem")
    let privateKey = base.appendingPathComponent("group.key")
    try group.certificatePEM.write(to: certificate, atomically: true, encoding: .utf8)
    try group.privateKeyPEM.write(to: privateKey, atomically: true, encoding: .utf8)
    await #expect(throws: GroupTLSError.noCertificate) {
      try await SpaceServer.serve(
        folder: base.appendingPathComponent("store"), port: 0, origin: URL(string: "https://space.test:5530"), webPort: nil,
        dev: true, groupCertificate: certificate, groupPrivateKey: privateKey,
      )
    }
    #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("store/tls").path))
  }
}

private struct HandedOut {
  var served: String
  /// enroll mint, share-login, machine add, machine rotate, the deployment
  /// record's pin and the offline invite, in that order.
  var all: [String?]
}

private func serveAndCollect(folder: URL, certificate: URL? = nil, privateKey: URL? = nil) async throws -> HandedOut {
  let (binds, bindsContinuation) = AsyncStream<Int?>.makeStream()
  let hooks = ServeNIOHooks(
    onDidBind: { bindsContinuation.yield($0.port) },
    onStartupFailure: { _ in bindsContinuation.finish() },
  )
  let server = Task {
    try await SpaceServer.serve(
      folder: folder, port: 0, origin: URL(string: "https://space.test:5530"), webPort: nil, dev: true,
      certificate: certificate, privateKey: privateKey, hooks: hooks,
    )
  }
  var iterator = binds.makeAsyncIterator()
  let port = try #require(await iterator.next() ?? nil)
  let served = try PinnedTLS.fingerprint(certificateDERBase64: try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port))
  let client = PinnedClient(port: port, pin: served)

  let account: AccountPayload = try await client.post("/v1/accounts", #"{"name":"alice"}"#)
  let mint: EnrollMintOutput = try await client.post(
    "/v1/enroll", #"{"account":"\#(account.id)","capabilities":["device"]}"#,
  )
  let key = Curve25519.Signing.PrivateKey()
  let pubkey = "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString()
  let _: JSONIgnored = try await client.post("/v1/enroll/consume", #"{"token":"\#(mint.token)","pubkey":"\#(pubkey)"}"#)
  let challenge: ShareLoginChallengeOutput = try await client.get("/v1/enroll/share-login/challenge")
  let signature = try key.signature(for: Data("wuhu-share-login:\(challenge.challenge)".utf8)).base64EncodedString()
  let shareLogin: ShareLoginOutput = try await client.post(
    "/v1/enroll/share-login",
    #"{"pubkey":"\#(pubkey)","challenge":"\#(challenge.challenge)","signature":"\#(signature)"}"#,
  )
  let added: MachineAddOutput = try await client.post("/v1/machine", #"{"name":"box"}"#)
  let rotated: MachineRotateOutput = try await client.post("/v1/machine/\(added.id.rawValue)/rotate", nil)
  server.cancel()
  try await server.value

  let recorded = try await Space.open(file: folder.appendingPathComponent("space.sqlite")).deployment()
  let (link, _) = try await UserRecovery.invite(folder: folder, account: account.id, server: nil, ttl: nil)
  let offline = link.split(separator: "&").first { $0.hasPrefix("fp=") }.map { String($0.dropFirst(3)).trimmingCharacters(in: .newlines) }
  return HandedOut(
    served: served,
    all: [mint.fingerprint, shareLogin.fingerprint, added.fingerprint, rotated.fingerprint, recorded?.pin, offline],
  )
}

private struct JSONIgnored: Decodable {}

private struct PinnedClient {
  let port: Int
  let pin: String

  func get<T: Decodable>(_ path: String) async throws -> T {
    try await self.send(Request(url: self.url(path)))
  }

  func post<T: Decodable>(_ path: String, _ body: String?) async throws -> T {
    try await self.send(Request(
      url: self.url(path),
      method: .post,
      body: body.map { .bytes(Data($0.utf8), contentType: "application/json") },
    ))
  }

  private func url(_ path: String) -> URL {
    URL(string: "https://127.0.0.1:\(self.port)\(path)")!
  }

  private func send<T: Decodable>(_ request: Request) async throws -> T {
    let response = try await PinnedTLS.fetch(request, pinnedFingerprint: self.pin)
    let data = try await response.body.data()
    try #require(response.status == .ok, "\(request.url.path): \(response.status) \(String(decoding: data, as: UTF8.self))")
    return try JSONDecoder().decode(T.self, from: data)
  }
}
