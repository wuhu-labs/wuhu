#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.CredentialResolver
import Fetch
import JSONValue
import LoopCore
import Serve
import ServeRouting
import SessionDomain
import class SessionTools.Scripts
import SpaceCore

// The plain-HTTP listener on 127.0.0.1 that Claude Code processes talk to:
// Wuhu's MCP tools and the two hooks, nothing else, and only with the token
// of a running activation.
func claudeCodeLoopbackHandler(
  space: Space,
  hub: MachineHub,
  credentials: CredentialResolver,
  version: String,
  host: ClaudeCodeHost,
  service: SessionService,
  scripts: Scripts?,
) -> Handler {
  var router = Router()
  addMcpRoutes(
    &router, space: space, hub: hub, credentials: credentials, version: version, recordsReceipts: true, scripts: scripts,
    control: sessionControl { service },
  ) { request, session in
    switch await host.holder(of: request, acting: session) {
    case .success: nil
    case let .failure(refusal): refusal.response(session)
    }
  }
  router.post("/v1/session/:id/claude-code/hook") { request, parameters in
    guard let session = sessionID(parameters) else { return unknownSession(parameters) }
    let holder: ClaudeCodeTokens.Holder
    switch await host.holder(of: request, acting: session) {
    case let .success(held): holder = held
    case let .failure(refusal): return refusal.response(session)
    }
    guard let body = JSONValue.parse(try await request.body?.text() ?? "") else {
      return errorResponse(.badRequest, code: "invalidArgument", message: "a hook body is a JSON object")
    }
    return jsonResponse(await service.claudeCodeHook(session, activation: holder.activation, body: body))
  }
  return router.handler
}

extension ClaudeCodeRefusal {
  func response(_ session: SessionID) -> Response {
    switch self {
    case .unauthorized:
      errorResponse(.unauthorized, code: "unauthorized", message: "a running Claude Code activation's token is required")
    case .foreignSession:
      errorResponse(.forbidden, code: "foreignSession", message: "this credential cannot act for session \(session.rawValue)")
    case .archived:
      errorResponse(.conflict, code: "archivedSession", message: "session \(session.rawValue) is archived and cannot act")
    }
  }
}
