#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Fetch.Request
import struct Fetch.RequestHeaders
import JSONValue
import enum MachineContract.SessionExecEnvironment

/// `wuhu id-token --audience <origin>`: inside a session's exec, trades the
/// exec's `WUHU_ID_TOKEN_REQUEST` capability at `WUHU_ID_TOKEN_URL` for a
/// short-lived OIDC token naming the session, machine and exec. Like `agent`,
/// it needs no wallet: the capability is the whole credential.
struct IDTokenVerb {
  let runner: CommandRunner

  func run(audience: String, json: Bool) async throws {
    let environment = runner.environment
    guard let endpoint = environment[SessionExecEnvironment.idTokenURL], !endpoint.isEmpty,
          let capability = environment[SessionExecEnvironment.idTokenRequest], !capability.isEmpty
    else {
      throw CLIError(message: "id-token: only a session's exec can mint one (\(SessionExecEnvironment.idTokenURL) and \(SessionExecEnvironment.idTokenRequest) are unset)")
    }
    guard var parts = URLComponents(string: endpoint), parts.scheme == "https" || parts.scheme == "http" else {
      throw CLIError(message: "id-token: \(SessionExecEnvironment.idTokenURL) is not an http(s) URL")
    }
    parts.queryItems = [URLQueryItem(name: "audience", value: audience)]
    guard let url = parts.url else { throw CLIError(message: "id-token: \(SessionExecEnvironment.idTokenURL) is not a URL") }
    var headers = RequestHeaders()
    headers.set("authorization", "Bearer \(capability)")
    let reply = try await runner.fetch(Request(url: url, headers: headers))
    var response = reply
    let body = try await response.data(upTo: 1 << 16)
    let value = JSONValue.parse(String(decoding: body, as: UTF8.self))?.object
    guard response.status.code == 200 else {
      let message = value?["message"]?.stringValue ?? "HTTP \(response.status.code)"
      throw CLIError(message: "id-token: \(message)")
    }
    guard let token = value?["token"]?.stringValue else { throw CLIError(message: "id-token: the server answered without a token") }
    if json {
      await runner.stdout(JSONValue.object(value ?? [:]).jsonString() + "\n")
    } else {
      await runner.stdout(token + "\n")
    }
  }
}
