import MachineContract

public enum InboundRequest: Sendable, Equatable {
  case vfs(VFSRequest)
  case search(SearchRequest)
  case vaultSet(VaultSet)
  case vaultRemove(VaultRemove)
  case vaultList(VaultList)
}

public enum OutboundResponse: Sendable, Equatable {
  case vfs(VFSResponse)
  case search(SearchResponse)
  case vaultSet(VaultOutcome)
  case vaultRemove(VaultOutcome)
  case vaultList(VaultOutcome)
}

extension ChannelEndpoint {
  public func vfs(_ op: VFSOp) async throws -> VFSResult {
    try await roundTrip(.vfsRequest, VFSResponse.self) { VFSRequest(id: $0, op: op) }.result
  }

  public func search(_ query: SearchQuery) async throws -> SearchResult {
    try await roundTrip(.searchRequest, SearchResponse.self) { SearchRequest(id: $0, query: query) }.result
  }

  public func vaultSet(name: String, value: String) async throws -> VaultOutcome {
    try await roundTrip(.vaultSet, VaultOutcome.self) { VaultSet(id: $0, name: name, value: value) }
  }

  public func vaultRemove(name: String) async throws -> VaultOutcome {
    try await roundTrip(.vaultRemove, VaultOutcome.self) { VaultRemove(id: $0, name: name) }
  }

  public func vaultList() async throws -> VaultOutcome {
    try await roundTrip(.vaultList, VaultOutcome.self) { VaultList(id: $0) }
  }

  public func respond(_ response: OutboundResponse) {
    let frame: Frame = switch response {
    case let .vfs(payload): Frame(streamID: 0, opcode: .vfsResponse, payload: payload)
    case let .search(payload): Frame(streamID: 0, opcode: .searchResponse, payload: payload)
    case let .vaultSet(outcome): Frame(streamID: 0, opcode: .vaultSet, payload: outcome)
    case let .vaultRemove(outcome): Frame(streamID: 0, opcode: .vaultRemove, payload: outcome)
    case let .vaultList(outcome): Frame(streamID: 0, opcode: .vaultList, payload: outcome)
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
