import MachineChannel

actor Relay {
  private var a: (any FrameTransport)?
  private var b: (any FrameTransport)?
  private var aGeneration: Int = 0
  private var bGeneration: Int = 0

  func runA(_ transport: some FrameTransport) async {
    aGeneration += 1
    let generation = aGeneration
    a = transport
    for await frame in transport.inbound {
      guard let destination = b else { continue }
      try? await destination.send(frame)
    }
    if generation == aGeneration { a = nil }
  }

  func runB(_ transport: some FrameTransport) async {
    bGeneration += 1
    let generation = bGeneration
    b = transport
    for await frame in transport.inbound {
      guard let destination = a else { continue }
      try? await destination.send(frame)
    }
    if generation == bGeneration { b = nil }
  }
}
