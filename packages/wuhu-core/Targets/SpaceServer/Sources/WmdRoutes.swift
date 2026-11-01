import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import HTTPTypes
import JSONValue
import Serve
import ServeRouting
import enum SpaceContract.ErrorCode
import enum SpaceContract.GroupHeader
import enum SpaceContract.WmdChannel
import enum SpaceContract.WmdClientControl
import enum SpaceContract.WmdErrorCode
import enum SpaceContract.WmdServerControl
import SpaceCore
import SpaceTools

/// `GET /v1/wmd/<path>`: the live channel of a `.wmd` document. The wall lets
/// the upgrade through bare; the `hello` frame carries the credential and must
/// come within `wmdHelloDeadline`, and a person key's socket ends with the key.
func addWmdRoutes(
  _ router: inout Router, space: Space, keyStreams: KeyStreams, dev: Bool,
  contextOf: @escaping @Sendable (Request) async throws -> ToolContextVerdict,
) {
  @Dependency(\.date) var dateGen
  @Dependency(\.continuousClock) var continuousClock
  let clock = continuousClock
  router.webSocket(WmdChannel.routePrefix + "/*") { request, _ in
    .webSocket { socket in
      let (frames, sink) = AsyncStream.makeStream(of: WmdInbound.self, bufferingPolicy: .bufferingNewest(wmdInboundLimit))
      var inbound = socket.inbound.makeAsyncIterator()
      let hello = await withTaskGroup(of: Void.self) { deadline in
        deadline.addTask {
          guard (try? await clock.sleep(for: wmdHelloDeadline)) != nil else { return }
          socket.close()
        }
        defer { deadline.cancelAll() }
        return await inbound.next()
      }
      guard let first = hello else { return }
      let (outbound, key) = await wmdOpen(
        first, upgrade: request, space: space, now: dateGen.now, dev: dev, contextOf: contextOf, frames: frames,
      )
      let relay = { [inbound] in
        var inbound = inbound
        await withDiscardingTaskGroup { group in
          group.addTask {
            for await message in outbound {
              try? await socket.send(wmdMessage(message))
            }
            socket.close()
          }
          while let message = await inbound.next() {
            let result = switch message {
            case let .binary(bytes): sink.yield(.binary(bytes))
            case let .text(text): sink.yield(.text(text))
            }
            // A client outrunning its node has lost frames: it reconnects and syncs anew.
            if case .dropped = result { socket.close() }
          }
          sink.finish()
        }
      }
      guard let key else { return await relay() }
      await keyStreams.holding(key, space: space, end: socket.close) { await relay() }
    }
  }
}

/// The channel, and the person key it lives under.
private func wmdOpen(
  _ first: WebSocketMessage, upgrade: Request, space: Space, now: Date, dev: Bool,
  contextOf: @Sendable (Request) async throws -> ToolContextVerdict, frames: AsyncStream<WmdInbound>,
) async -> (AsyncStream<WmdOutbound>, KeyRecord?) {
  guard case let .text(text) = first, let json = JSONValue.parse(text),
        case let .hello(authorization, group, peer, create)? = try? JSONValueDecoder().decode(WmdClientControl.self, from: json)
  else { return (wmdRefusal(.unauthorized, "the first frame is a hello"), nil) }
  var request = upgrade
  request.headers[.authorization] = authorization
  request.headers[GroupHeader.name] = group
  let context: SpaceToolContext
  let key: KeyRecord?
  do {
    switch try await contextOf(request) {
    case let .context(resolved): context = resolved
    case .refused: return (wmdRefusal(.unauthorized, "the hello's assertion is not accepted"), nil)
    }
    if !dev, case let .verified(credential) = try await bearerVerdict(request: request, space: space, now: now) {
      key = credential.key
    } else {
      key = nil
    }
  } catch {
    return (wmdRefusal(.internal, "\(error)"), nil)
  }
  if case .anonymous = context.principal.actor, !dev {
    return (wmdRefusal(.unauthorized, "this space admits enrolled devices only"), nil)
  }
  guard let address = fileRouteAddress(upgrade.url) else { return (wmdRefusal(.notFound, "malformed file path"), nil) }
  let target: WmdTarget
  do { target = try await context.wmdTarget(address) } catch {
    let (code, message) = wmdTargetRefusal(error, address: address)
    return (wmdRefusal(code, message), nil)
  }
  let channel = await context.space.wmdChannel(
    target.group, target.path, peer: peer, name: target.name, access: target.access, create: create ?? false, frames: frames,
    reauthorize: {
      // A group the principal no longer reads answers notFound, like a path that never was.
      do { return try await context.wmdTarget(address).access } catch {
        switch wmdTargetRefusal(error, address: address).code {
        case .forbidden, .notFound: return nil
        default: return target.access
        }
      }
    },
  )
  return (channel, key)
}

let wmdHelloDeadline = Duration.seconds(10)
private let wmdInboundLimit = 256

private func wmdTargetRefusal(_ error: any Error, address: String) -> (code: WmdErrorCode, message: String) {
  switch error {
  case let ToolRunError.failed(code, message, _, _):
    (code == .unauthorized ? .forbidden : code == .notFound || code == .invalidPath ? .notFound : .internal, message)
  case SpaceError.notFound: (.notFound, "\(address) does not exist")
  case SpaceError.groupForbidden, SpaceError.personalGroupPrivate: (.forbidden, "\(address) is not readable from here")
  default: (.internal, "\(error)")
  }
}

private func wmdRefusal(_ code: WmdErrorCode, _ message: String) -> AsyncStream<WmdOutbound> {
  AsyncStream { continuation in
    continuation.yield(.control(.error(code: code, message: message)))
    continuation.finish()
  }
}

private func wmdMessage(_ outbound: WmdOutbound) -> WebSocketMessage {
  switch outbound {
  case let .frame(frame):
    return .binary(frame.bytes)
  case let .control(control):
    // Encoding a closed enum of strings and integers cannot fail.
    return .text(try! JSONValueEncoder().encode(control).jsonString())
  }
}
