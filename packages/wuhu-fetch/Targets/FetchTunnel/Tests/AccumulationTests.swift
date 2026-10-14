#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import FetchTunnel
import Testing

private extension TunnelState {
  func bodyAddress(_ id: UInt64) -> UInt {
    exchanges[id]!.body.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
  }
}

@Test func chunkAccumulationReusesReservedStorage() async throws {
  let transport = TunnelTransport(receive: { nil }, send: { _ in }, abort: {})
  let state = TunnelState(transport: transport, limits: .init(), handler: { _ in Response(status: .ok) })
  let head = Head(Request(url: .init(string: "https://example.test/")!, body: .empty), count: 1 << 20)
  _ = try await state.receive(Frame(kind: .request, id: 1, payload: JSONEncoder().encode(head)))
  let chunk = Frame(kind: .chunk, id: 1, payload: Bytes(repeating: 42, count: 16 << 10))
  _ = try await state.receive(chunk)
  let address = await state.bodyAddress(1)
  for _ in 1 ..< 64 {
    _ = try await state.receive(chunk)
    #expect(await state.bodyAddress(1) == address)
  }
  let work = try #require(await state.receive(Frame(kind: .end, id: 1)))
  #expect(try await work.request.body?.bytes() == Bytes(repeating: 42, count: 1 << 20))
  await state.close(.cancelled)
}
