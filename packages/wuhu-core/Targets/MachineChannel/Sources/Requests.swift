import MachineContract

public enum InboundRequest: Sendable, Equatable {
  case vfs(VFSRequest)
}

public enum OutboundResponse: Sendable, Equatable {
  case vfs(VFSResponse)
}

extension ChannelEndpoint {
  public func vfs(_ op: VFSOp) async throws -> VFSResult {
    try await roundTrip(.vfsRequest, VFSResponse.self) { VFSRequest(id: $0, op: op) }.result
  }

  public func respond(_ response: OutboundResponse) {
    let frame: Frame = switch response {
    case let .vfs(payload): Frame(streamID: 0, opcode: .vfsResponse, payload: payload)
    }
    outbound?.yield(frame)
  }

  private func roundTrip<Request: Encodable, Response: Decodable>(
    _ opcode: Opcode,
    _ responseType: Response.Type,
    _ request: (Int) -> Request,
  ) async throws -> Response {
    guard let outbound else { throw ChannelError.severed }
    let id = nextRequestID
    nextRequestID += 1
    let (frames, continuation) = AsyncThrowingStream<Frame, any Error>.makeStream()
    pendingRequests[id] = continuation
    outbound.yield(Frame(streamID: 0, opcode: opcode, payload: request(id)))
    do {
      for try await frame in frames {
        return try frame.payload(Response.self)
      }
      throw ChannelError.severed
    } catch {
      pendingRequests[id] = nil
      throw error
    }
  }
}
