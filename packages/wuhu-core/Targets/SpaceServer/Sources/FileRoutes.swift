#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import JSONValue
import Serve
import ServeRouting
import SpaceContract
import SpaceTools

// The byte lane for the same files the JSON tools serve as text. It lives under
// /v1 so the one API wall in SpaceServer.configuredHandler gates it exactly
// like POST /v1/tools/*: --public-read opens the content origin, never this.
let maximumFileRouteBytes = 64 << 20

// The files are the acting group's: `contextOf` resolves the request's principal.
func addFileRoutes(_ router: inout Router, contextOf: @escaping @Sendable (Request) async throws -> ToolContextVerdict) {
  router.get("/v1/f/*") { request, _ in
    guard let address = fileRouteAddress(request.url) else {
      return errorResponse(.badRequest, code: ErrorCode.invalidPath.rawValue, message: "malformed file path")
    }
    let context: SpaceToolContext
    switch try await contextOf(request) {
    case let .context(resolved): context = resolved
    case let .refused(response): return response
    }
    do {
      let file = try await context.readBytes(address)
      let contentType = mimeType(for: address)
      var headers = Headers()
      headers[.contentType] = contentType
      headers[.contentLength] = String(file.data.count)
      headers[.eTag] = quoted(file.token)
      return Response(status: .ok, headers: headers, body: .bytes(file.data, contentType: contentType))
    } catch let error as ToolRunError {
      return fileRouteFailure(error)
    }
  }
  router.put("/v1/f/*") { request, _ in
    guard let address = fileRouteAddress(request.url) else {
      return errorResponse(.badRequest, code: ErrorCode.invalidPath.rawValue, message: "malformed file path")
    }
    let data: Data
    do {
      data = try await request.body?.data(upTo: maximumFileRouteBytes) ?? Data()
    } catch {
      return errorResponse(
        .contentTooLarge,
        code: ErrorCode.invalidArgument.rawValue,
        message: "request body exceeds the \(maximumFileRouteBytes)-byte file route bound",
      )
    }
    let context: SpaceToolContext
    switch try await contextOf(request) {
    case let .context(resolved): context = resolved
    case let .refused(response): return response
    }
    do {
      let written = try await context.writeBytes(address, data, ifMatch: request.headers[.ifMatch].map(unquoted))
      return jsonResponse(.object([
        "rev": written.rev.map(JSONValue.integer) ?? .null,
        "token": .string(written.token),
      ]))
    } catch let error as ToolRunError {
      return fileRouteFailure(error)
    }
  }
}

enum ToolContextVerdict: Sendable {
  case context(SpaceToolContext)
  case refused(Response)
}

// `?group=<id>` names another group's file, like `wuhu://<id>.localspace/<path>`.
func fileRouteAddress(_ url: URL) -> String? {
  guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
  let rawPath = components.percentEncodedPath
  var segments: [String] = []
  for raw in rawPath.split(separator: "/", omittingEmptySubsequences: true).dropFirst(2) {
    guard let decoded = String(raw).removingPercentEncoding else { return nil }
    // A decoded slash (%2F) must not smuggle extra path structure past the
    // segment split.
    guard !decoded.contains("/") else { return nil }
    segments.append(decoded)
  }
  let path = "/" + segments.joined(separator: "/")
  guard let group = components.queryItems?.first(where: { $0.name == "group" })?.value else { return path }
  // The same parser as a `wuhu://<group>.localspace/` host, so the two
  // spellings accept the same groups.
  guard let named = try? GroupID.named(byHost: group + GroupID.hostSuffix) else { return nil }
  return named.address(path)
}

private func fileRouteFailure(_ error: ToolRunError) -> Response {
  switch error {
  case .undecodableInput:
    return jsonResponse(error.payload, status: .badRequest)
  case let .failed(code, _, _, _):
    let status: Status = switch code {
    case .notFound: .notFound
    case .conflict: .conflict
    case .invalidPath, .invalidArgument: .badRequest
    case .unauthorized: .unauthorized
    case .unsupported: .unsupportedMediaType
    case .unavailable: .serviceUnavailable
    case .internal: .internalServerError
    case .capabilityInvalidArgument, .unsupportedFeature: .badRequest
    case .providerAuth: .unauthorized
    case .providerRegion, .providerEntitlement: .forbidden
    case .providerRateLimited: .tooManyRequests
    case .providerNotConfigured, .providerUnavailable: .serviceUnavailable
    }
    return jsonResponse(error.payload, status: status)
  }
}

private func quoted(_ token: String) -> String {
  "\"\(token)\""
}

private func unquoted(_ header: String) -> String {
  guard header.count >= 2, header.hasPrefix("\""), header.hasSuffix("\"") else { return header }
  return String(header.dropFirst().dropLast())
}
