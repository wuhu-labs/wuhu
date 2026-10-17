import MachineChannel
import Serve
import SpaceServer
import Testing

@Test func closingExecTransportEndsBothSocketDirections() async {
  let (server, client) = WebSocket.pair()
  let transport = WebSocketTransport(client)
  transport.close()
  for await _ in transport.inbound { Issue.record("A closed transport delivered a frame") }
  for await _ in server.inbound { Issue.record("A closed socket delivered a message") }
}

@Test(.timeLimit(.minutes(1))) func transportEOFFinishesBeforeItsBlockedPeerAndDoesNotCancelIt() async {
  let (server, client) = WebSocket.pair()
  let transport = WebSocketTransport(client)
  let (release, continuation) = AsyncStream<Void>.makeStream()
  let peer = Task {
    for await _ in server.inbound {}
    for await _ in release {}
    return Task.isCancelled
  }
  transport.close()
  for await _ in transport.inbound { Issue.record("A closed transport delivered a frame") }
  #expect(!peer.isCancelled)
  continuation.finish()
  #expect(await peer.value == false)
}
