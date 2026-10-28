import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InMemoryTracing
import JSONValue
import ServerTelemetry
import SpaceCore
import Testing
import Tracing

// A timer's handler firing is its own trace under its session, naming the
// slot the woken turn will list; what the handler says stays out of it.
@Test(.deterministicDependencies) func aHandlerFiringIsARootSpanUnderItsSession() async throws {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/tick.js", Data("export default async ({ state, wake }) => { wake('secret wake'); return state }".utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "secret tick", "in_seconds": 1, "handler": "/tick.js"]))
        await time.advance(by: 2)
        try await untilAdvancing("the wake lands", time) { try await !handlerNotifications(space, session).isEmpty }
      }
      let notice = try #require(try await handlerNotifications(space, session).first)
      let firing = try #require(tracer.finishedSpans.first { $0.operationName == "handler.firing" })
      #expect(firing.parentSpanID == nil)
      #expect(firing.attributes.get("wuhu.session.id") == .string(session.rawValue))
      #expect(firing.attributes.get("wuhu.subscription.id") == .string(notice.subscriptionID.rawValue))
      #expect(firing.attributes.get("wuhu.firing.kind") == .string("timer"))
      #expect(firing.attributes.get("wuhu.firing.id") != nil)
      #expect(firing.attributes.get("wuhu.lag_ms") != nil)
      #expect(firing.attributes.get("wuhu.wakes") == .int64(1))
      #expect(firing.attributes.get("wuhu.outcome") == .string("ok"))
      for span in tracer.finishedSpans {
        span.attributes.forEach { key, value in #expect(!"\(value)".contains("secret"), "\(span.operationName) \(key)") }
      }
    }
  }
}
