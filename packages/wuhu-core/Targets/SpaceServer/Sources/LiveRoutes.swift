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
import enum SpaceContract.LiveChannel
import enum SpaceContract.LiveClientControl
import enum SpaceContract.LiveErrorCode
import enum SpaceContract.LiveServerControl
import SpaceCore
import SpaceTools

/// `GET /v1/live/<path>`: the live channel of a `.wmd` or `.canvas` document. The wall lets
/// the upgrade through bare; the `hello` frame carries the credential and must
/// come within `liveHelloDeadline`, and a person key's socket ends with the key.
func addLiveRoutes(
  _ router: inout Router, space: Space, keyStreams: KeyStreams, dev: Bool,
  contextOf: @escaping @Sendable (Request) async throws -> ToolContextVerdict,
) {
  @Dependency(\.date) var dateGen
  @Dependency(\.continuousClock) var continuousClock
  let clock = continuousClock
  for prefix in liveRoutePrefixes {
    let legacy = prefix == legacyLiveRoutePrefix
    router.webSocket(prefix + "/*") { request, _ in
      .webSocket { socket in
        let (frames, sink) = AsyncStream.makeStream(of: LiveInbound.self, bufferingPolicy: .bufferingNewest(liveInboundLimit))
        var inbound = socket.inbound.makeAsyncIterator()
        let hello = await withTaskGroup(of: Void.self) { deadline in
          deadline.addTask {
            guard (try? await clock.sleep(for: liveHelloDeadline)) != nil else { return }
            socket.close()
          }
          defer { deadline.cancelAll() }
          return await inbound.next()
        }
        guard let first = hello else { return }
        let (outbound, key) = await liveOpen(
          first, upgrade: request, space: space, now: dateGen.now, dev: dev, contextOf: contextOf, frames: frames,
        )
        let relay = { [inbound] in
          var inbound = inbound
          await withDiscardingTaskGroup { group in
            group.addTask {
              for await message in outbound {
                try? await socket.send(liveMessage(message, legacy: legacy))
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
}

/// The channel, and the person key it lives under.
private func liveOpen(
  _ first: WebSocketMessage, upgrade: Request, space: Space, now: Date, dev: Bool,
  contextOf: @Sendable (Request) async throws -> ToolContextVerdict, frames: AsyncStream<LiveInbound>,
) async -> (AsyncStream<LiveOutbound>, KeyRecord?) {
  guard case let .text(text) = first, let json = JSONValue.parse(text),
        case let .hello(authorization, group, peer, create)? = try? JSONValueDecoder().decode(LiveClientControl.self, from: json)
  else { return (liveRefusal(.unauthorized, "the first frame is a hello"), nil) }
  var request = upgrade
  request.headers[.authorization] = authorization
  request.headers[GroupHeader.name] = group
  let context: SpaceToolContext
  let key: KeyRecord?
  do {
    switch try await contextOf(request) {
    case let .context(resolved): context = resolved
    case .refused: return (liveRefusal(.unauthorized, "the hello's assertion is not accepted"), nil)
    }
    if !dev, case let .verified(credential) = try await bearerVerdict(request: request, space: space, now: now) {
      key = credential.key
    } else {
      key = nil
    }
  } catch {
    return (liveRefusal(.internal, "\(error)"), nil)
  }
  if case .anonymous = context.principal.actor, !dev {
    return (liveRefusal(.unauthorized, "this space admits enrolled devices only"), nil)
  }
  guard let address = fileRouteAddress(upgrade.url) else { return (liveRefusal(.notFound, "malformed file path"), nil) }
  let target: LiveTarget
  do { target = try await context.liveTarget(address) } catch {
    let (code, message) = liveTargetRefusal(error, address: address)
    return (liveRefusal(code, message), nil)
  }
  let channel = await context.space.liveChannel(
    target.group, target.path, peer: peer, name: target.name, access: target.access, create: create ?? false, frames: frames,
    reauthorize: {
      // A group the principal no longer reads answers notFound, like a path that never was.
      do { return try await context.liveTarget(address).access } catch {
        switch liveTargetRefusal(error, address: address).code {
        case .forbidden, .notFound: return nil
        default: return target.access
        }
      }
    },
  )
  return (channel, key)
}

let liveHelloDeadline = Duration.seconds(10)
/// The channel's name in clients built before `.canvas`; they decode `notLive` as `notWmd`.
let legacyLiveRoutePrefix = "/v1/wmd"
let liveRoutePrefixes = [LiveChannel.routePrefix, legacyLiveRoutePrefix]
private let liveInboundLimit = 256

private func liveTargetRefusal(_ error: any Error, address: String) -> (code: LiveErrorCode, message: String) {
  switch error {
  case let ToolRunError.failed(code, message, _, _):
    (code == .unauthorized ? .forbidden : code == .notFound || code == .invalidPath ? .notFound : .internal, message)
  case SpaceError.notFound: (.notFound, "\(address) does not exist")
  case SpaceError.groupForbidden: (.forbidden, "\(address) is not readable from here")
  default: (.internal, "\(error)")
  }
}

private func liveRefusal(_ code: LiveErrorCode, _ message: String) -> AsyncStream<LiveOutbound> {
  AsyncStream { continuation in
    continuation.yield(.control(.error(code: code, message: message)))
    continuation.finish()
  }
}

private func liveMessage(_ outbound: LiveOutbound, legacy: Bool) -> WebSocketMessage {
  switch outbound {
  case let .frame(frame):
    return .binary(frame.bytes)
  case let .control(control):
    // Encoding a closed enum of strings and integers cannot fail.
    var json = try! JSONValueEncoder().encode(control)
    if legacy, case .error(code: .notLive, _) = control, case var .object(fields) = json {
      fields["code"] = .string("notWmd")
      json = .object(fields)
    }
    return .text(json.jsonString())
  }
}
