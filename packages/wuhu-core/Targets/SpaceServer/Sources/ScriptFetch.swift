#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import NIOCore
import SessionDomain
import struct SessionTools.ScriptIdentityUnavailable
import SpaceCore

struct ScriptFetch: Sendable {
  let mint: @Sendable (URL, String, String, String, Date, UUID) async throws -> String

  init(identity: ServerIdentity, issuer: String?, hop: @escaping @Sendable (Request, NIODeadline) async throws -> Response = Self.liveHop) {
    mint = { audience, space, group, session, now, id in
      try identity.token(issuer: issuer, audience: audience, space: space, group: group, session: session, now: now, id: id, lifetime: 60)
    }
    self.hop = hop
  }

  init(controller: IdentityController, hop: @escaping @Sendable (Request, NIODeadline) async throws -> Response = Self.liveHop) {
    mint = { audience, space, group, session, now, id in
      try await controller.token(audience: audience, space: space, group: group, session: session, now: now, id: id, lifetime: 60)
    }
    self.hop = hop
  }

  static let liveHop: @Sendable (Request, NIODeadline) async throws -> Response = {
    try await pinnedPageFetch($0, deadline: $1, stripCookies: false, timeoutError: FetchError.transportFailure(kind: .deadlineExceeded))
  }

  var hop: @Sendable (Request, NIODeadline) async throws -> Response

  func response(_ request: Request, session: SessionID, space: Space, protect: @Sendable (String) -> Void) async throws -> Response {
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock
    let origin: String
    let token: String
    do {
      guard let named = fetchOrigin(request.url) else { throw IdentityError.invalidAudience }
      origin = named
      let record = try await space.sessions.record(session)
      token = try await mint(request.url, space.identity().rawValue, record.group.rawValue, session.rawValue, date.now, uuid())
    } catch let error as IdentityError where error.directoryCode != nil {
      throw ScriptIdentityUnavailable(message: error.description, code: error.directoryCode!)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ScriptIdentityUnavailable(message: "the server could not mint the fetch identity token: \(error)")
    }
    protect(token)
    let deadline = NIODeadline.now() + .seconds(60)
    let remaining = scriptFetchRemaining(clock)
    let timeout = FetchError.transportFailure(kind: .deadlineExceeded)
    var body = try await request.body?.bytes()
    var target = request
    for count in 0 ... 20 {
      guard remaining() > .zero, .now() < deadline else { throw timeout }
      target.body = body.map { .bytes($0) }
      target.headers[.authorization] = fetchOrigin(target.url) == origin ? "Bearer " + token : nil
      let outgoing = target
      let hop = hop
      let response = try await fetchWithinDeadline(deadline, timeoutError: timeout, remaining: remaining) {
        try await hop(outgoing, deadline)
      }
      guard [301, 302, 303, 307, 308].contains(response.status.code), let location = response.headers[.location] else {
        return response
      }
      guard count < 20, let url = URL(string: location, relativeTo: target.url)?.absoluteURL, fetchOrigin(url) != nil else {
        throw ScriptFetchError.invalidRedirect
      }
      target.url = url
      if (response.status.code == 303 && target.method != .head) || ([301, 302].contains(response.status.code) && target.method == .post) {
        target.method = .get
        body = nil
        target.headers[.contentType] = nil
        target.headers[.contentLength] = nil
      }
    }
    preconditionFailure()
  }
}

private enum ScriptFetchError: Error {
  case invalidRedirect
}

private func scriptFetchRemaining<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
  let expires = clock.now.advanced(by: .seconds(60))
  return { clock.now.duration(to: expires) }
}
