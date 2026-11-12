import Synchronization
import Testing
@testable import Wuwei

enum Chat: Socket {
  enum Incoming: Sendable {
    case say(String)
  }

  enum Outgoing: Sendable, Equatable {
    case history([String])
    case said(String)
  }
}

/// A chat room: every line said in it is kept, and every socket in it hears every line.
@Cell
struct Room {
  static let schema = ["CREATE TABLE line (text TEXT NOT NULL)"]

  func lines() -> [String] {
    db.rows("SELECT text FROM line ORDER BY rowid").map { $0[0].text! }
  }

  mutating func attached(_ socket: SocketHandle<Chat>) {
    socket.send(.history(lines()))
  }

  mutating func receive(_ frame: Chat.Incoming, from _: SocketHandle<Chat>) throws {
    guard case let .say(text) = frame else { return }
    try announce(text)
    if text == "boom" { throw Refused() }
  }

  mutating func closed(_ socket: SocketHandle<Chat>) throws {
    try db.execute("INSERT INTO line VALUES (?)", .text("\(socket.id) left"))
  }

  mutating func announce(_ text: String) throws {
    try db.execute("INSERT INTO line VALUES (?)", .text(text))
    ctx.dependency(Tripwire.self).trip()
    for socket in ctx.sockets(of: Chat.self) {
      socket.send(.said(text))
    }
  }

  mutating func kick(_ id: Int) {
    for socket in ctx.sockets(of: Chat.self) where socket.id == id {
      socket.send(.said("bye"))
      socket.close()
    }
  }
}

/// Opens with the last number its peer has.
enum Feed: Socket {
  typealias Opening = Int64
  typealias Outgoing = Int64
}

/// Publishes `1 ... count` to its sockets, a second apart, writing each number down before it goes out; a socket hears the numbers past the one it opened with.
@Job
struct Ticker {
  typealias Params = Int64
  typealias Message = Never
  static let schema = ["CREATE TABLE tick (n INTEGER NOT NULL)"]

  mutating func start() async throws -> Outcome {
    while Int64(ticks().count) < ctx.params {
      let n = Int64(ticks().count) + 1
      try db.execute("INSERT INTO tick VALUES (?)", .integer(n))
      for socket in ctx.sockets(of: Feed.self) where n > socket.opening {
        socket.send(n)
      }
      try await ctx.sleep(for: .seconds(1))
    }
    return .done
  }

  func ticks() -> [Int64] {
    db.rows("SELECT n FROM tick").map { $0[0].integer! }
  }
}

enum Wire: Socket {
  enum Incoming: Sendable {
    case hit(Int)
  }

  typealias Outgoing = Int
}

/// Writes every frame down before it answers it, and closes the socket on the first.
@Cell
struct ShortLived {
  static let schema = ["CREATE TABLE seen (n INTEGER NOT NULL)"]

  func seen() -> [Int] {
    db.rows("SELECT n FROM seen ORDER BY rowid").map { Int($0[0].integer!) }
  }

  mutating func receive(_ frame: Wire.Incoming, from socket: SocketHandle<Wire>) throws {
    guard case let .hit(n) = frame else { return }
    try db.execute("INSERT INTO seen VALUES (?)", .integer(Int64(n)))
    if n == 1 { socket.close() }
  }

  mutating func closed(_ socket: SocketHandle<Wire>) throws {
    try db.execute("INSERT INTO seen VALUES (-1)")
  }
}

/// Writes every frame it hears down, and closes its sockets on demand.
@Cell
struct Closer {
  static let schema = ["CREATE TABLE seen (n INTEGER NOT NULL)"]

  func seen() -> [Int] {
    db.rows("SELECT n FROM seen ORDER BY rowid").map { Int($0[0].integer!) }
  }

  mutating func receive(_ frame: Wire.Incoming, from socket: SocketHandle<Wire>) throws {
    guard case let .hit(n) = frame else { return }
    try db.execute("INSERT INTO seen VALUES (?)", .integer(Int64(n)))
  }

  mutating func close(_ id: Int) {
    for socket in ctx.sockets(of: Wire.self) where socket.id == id { socket.close() }
  }

  mutating func closed(_ socket: SocketHandle<Wire>) throws {
    try db.execute("INSERT INTO seen VALUES (-1)")
  }
}

/// What a job heard on its sockets, which it may not write down itself.
final class Recorder: Sendable {
  private let heard = Mutex<[String]>([])

  func heard(_ event: String) {
    heard.withLock { $0.append(event) }
  }

  var events: [String] {
    heard.withLock { $0 }
  }
}

/// Says what it hears on its sockets to the recorder it was given; it never finishes.
@Job
struct Listener {
  typealias Params = Int64
  typealias Message = Never

  func attached(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("attached \(socket.id)")
  }

  func closed(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("closed \(socket.id)")
  }

  mutating func start() async throws -> Outcome {
    while true {
      try await ctx.sleep(for: .seconds(1))
    }
  }
}

/// Closes every socket of its own a second in; it never finishes.
@Job
struct Dropper {
  typealias Params = Int64
  typealias Message = Never

  func attached(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("attached \(socket.id)")
  }

  func closed(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("closed \(socket.id)")
  }

  mutating func start() async throws -> Outcome {
    while true {
      try await ctx.sleep(for: .seconds(1))
      for socket in ctx.sockets(of: Feed.self) {
        socket.close()
      }
    }
  }
}

/// Publishes nothing and finishes a second in.
@Job
struct Once {
  typealias Params = Int64
  typealias Message = Never

  func attached(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("attached \(socket.id)")
  }

  func closed(_ socket: SocketHandle<Feed>) {
    ctx.dependency(Recorder.self).heard("closed \(socket.id)")
  }

  mutating func start() async throws -> Outcome {
    try await ctx.sleep(for: .seconds(1))
    return .done
  }
}

/// The transport's side: what came out of the socket, and what the addressable's durable state was when it did.
final class Client<S: Socket>: Sendable where S.Outgoing: Equatable {
  enum Heard: Equatable {
    case frame(S.Outgoing)
    case closed
  }

  private let log = Mutex<[(heard: Heard, durable: [String])]>([])

  func hear(_ output: SocketOutput<S>, durable: [String]) {
    let heard: Heard = switch output {
    case let .frame(frame): .frame(frame)
    case .closed: .closed
    }
    log.withLock { $0.append((heard, durable)) }
  }

  var heard: [Heard] {
    log.withLock { $0.map(\.heard) }
  }

  var durable: [[String]] {
    log.withLock { $0.map(\.durable) }
  }
}

@Suite struct SocketTests {
  let world = World()
  let room = Room.ID("r")
  let tripwire = Tripwire()

  func node(_ id: String, in world: World? = nil) throws -> Node {
    var dependencies = Dependencies()
    dependencies.register(tripwire)
    return try (world ?? self.world).node(id, [.cell(Room.self), .job(Ticker.self)], dependencies: dependencies)
  }

  func join(_ worker: Worker) throws -> (peer: Peer<Chat>, client: Client<Chat>) {
    let client = Client<Chat>()
    let room = room
    let peer = try #require(worker.attach(Chat.self, to: room) { output in
      client.hear(output, durable: worker.cell(room).lines())
    })
    return (peer, client)
  }

  @Test func aFrameIsACallWhoseRepliesWaitForItsWrites() throws {
    let a = try node("a")
    let (alice, aliceHears) = try join(a.worker)
    let (_, bobHears) = try join(a.worker)
    alice.send(.say("hi"))
    world.run(for: .seconds(2))
    #expect(aliceHears.heard == [.frame(.history([])), .frame(.said("hi"))])
    #expect(bobHears.heard == [.frame(.history([])), .frame(.said("hi"))])
    #expect(bobHears.durable.last == ["hi"])
  }

  @Test(arguments: 1 ... 20 as ClosedRange<UInt64>)
  func aSocketHearsNothingBeforeItsAttached(seed: UInt64) throws {
    let world = World(seed: seed)
    let a = try node("a", in: world)
    let client = Client<Chat>()
    _ = try #require(a.worker.attach(Chat.self, to: room) { client.hear($0, durable: []) })
    a.worker.send(room).announce("early")
    world.run(for: .seconds(2))
    #expect([[.frame(.history(["early"]))], [.frame(.history([])), .frame(.said("early"))]].contains(client.heard))
  }

  @Test(arguments: 1 ... 5 as ClosedRange<UInt64>)
  func framesFromOneSocketArriveInOrder(seed: UInt64) throws {
    let world = World(seed: seed)
    let a = try node("a", in: world)
    let peer = try #require(a.worker.attach(Chat.self, to: room) { _ in })
    let said = (0 ..< 20).map { "\($0)" }
    for text in said {
      peer.send(.say(text))
    }
    world.run(for: .seconds(2))
    #expect(a.worker.cell(room).lines() == said)
  }

  @Test(arguments: 1 ... 20 as ClosedRange<UInt64>)
  func aFrameThatMeetsAnEvictionReachesTheNextIncarnation(seed: UInt64) throws {
    let world = World(seed: seed)
    let a = try node("a", in: world)
    let (alice, hears) = try join(a.worker)
    a.process.at(world.simulation.now + .seconds(5)) { alice.send(.say("hi")) }
    world.run(for: .seconds(20))
    #expect(hears.heard == [.frame(.history([])), .frame(.said("hi"))])
    #expect(a.worker.cell(room).lines() == ["hi"])
    let b = try node("b", in: world)
    #expect(b.worker.attach(Chat.self, to: room) { _ in } != nil)
  }

  @Test func aFrameWhoseCallThrowsSendsNothing() throws {
    let a = try node("a")
    let (alice, hears) = try join(a.worker)
    alice.send(.say("boom"))
    alice.send(.say("ok"))
    world.run(for: .seconds(2))
    #expect(hears.heard == [.frame(.history([])), .frame(.said("ok"))])
    #expect(a.worker.cell(room).lines() == ["ok"])
  }

  @Test func membershipOutlivesTheIncarnation() throws {
    let a = try node("a")
    let (_, hears) = try join(a.worker)
    world.run(for: .seconds(20))
    try world.client().send(room).announce("news")
    world.run(for: .seconds(3))
    #expect(hears.heard == [.frame(.history([])), .frame(.said("news"))])
  }

  @Test func eitherSideCanClose() throws {
    let a = try node("a")
    let (alice, aliceHears) = try join(a.worker)
    let (bob, bobHears) = try join(a.worker)
    let (carol, carolHears) = try join(a.worker)
    world.run(for: .seconds(1))
    alice.close()
    a.worker.send(room).kick(2)
    world.run(for: .seconds(2))
    bob.send(.say("still here?"))
    carol.send(.say("hello"))
    world.run(for: .seconds(2))
    #expect(aliceHears.heard == [.frame(.history([]))])
    #expect(bobHears.heard == [.frame(.history([])), .frame(.said("bye")), .closed])
    #expect(carolHears.heard == [.frame(.history([])), .frame(.said("hello"))])
    #expect(a.worker.cell(room).lines() == ["1 left", "2 left", "hello"])
  }

  @Test func aFailedEpochDropsItsFramesAndClosesTheSocket() throws {
    let a = try node("a")
    let (_, hears) = try join(a.worker)
    world.run(for: .seconds(1))
    tripwire.arm { [world] in world.simulation.freeze(a.process) }
    try world.client().send(room).announce("news")
    world.run(for: .seconds(2))
    let b = try node("b")
    world.run(for: .seconds(20))
    world.simulation.thaw(a.process)
    world.run(for: .seconds(5))
    #expect(hears.heard == [.frame(.history([])), .closed])
    #expect(b.worker.cell(room).lines() == ["news"])
  }

  @Test func onlyTheWorkerHoldingTheCellTakesItsSockets() throws {
    let a = try node("a")
    _ = try join(a.worker)
    let b = try node("b")
    #expect(b.worker.attach(Chat.self, to: room) { _ in } == nil)
  }

  @Test func aJobPublishesWhatItWroteAndClosesWhenDone() throws {
    let a = try node("a")
    let ticker = Ticker.ID("t")
    try a.worker.create(ticker, params: 3)
    let client = Client<Feed>()
    _ = try #require(a.worker.attach(Feed.self, to: ticker, opening: 0) { output in
      client.hear(output, durable: a.worker.job(ticker).ticks().map(String.init))
    })
    world.run(for: .seconds(5))
    #expect(client.heard == [.frame(1), .frame(2), .frame(3), .closed])
    #expect(client.durable.prefix(3) == [["1"], ["1", "2"], ["1", "2", "3"]])
  }

  func recorded(_ recorder: Recorder, _ id: String, in world: World? = nil) throws -> Node {
    var dependencies = Dependencies()
    dependencies.register(recorder)
    return try (world ?? self.world).node(id, [.job(Listener.self), .job(Dropper.self), .job(Once.self)], dependencies: dependencies)
  }

  @Test(arguments: 1 ... 20 as ClosedRange<UInt64>)
  func aFrameQueuedBehindTheSocketsOwnCloseIsNotDelivered(seed: UInt64) throws {
    let world = World(seed: seed)
    let a = try world.node("a", [.cell(ShortLived.self)])
    let short = ShortLived.ID("s")
    let client = Client<Wire>()
    let peer = try #require(a.worker.attach(Wire.self, to: short) { client.hear($0, durable: []) })
    peer.send(.hit(1))
    peer.send(.hit(2))
    world.run(for: .seconds(2))
    #expect(a.worker.cell(short).seen() == [1, -1])
    #expect(client.heard == [.closed])
  }

  /// A frame handed to the host before another call closed the socket reaches nothing: eligibility is the attachment's, read on the lane.
  @Test func aFrameHandedToTheHostBeforeTheCloseIsNotDelivered() throws {
    let world = World()
    let a = try world.node("a", [.cell(Closer.self)])
    let closer = Closer.ID("c")
    _ = try #require(a.worker.attach(Wire.self, to: closer) { _ in })
    world.run(for: .seconds(1))
    let attachment = try #require(a.worker.attachments(at: closer.description).first)
    attachment.discardFrames()
    a.worker.task { await a.worker.deliver(.frame(Wire.Incoming.hit(9)), from: attachment) }
    world.run(for: .seconds(1))
    #expect(a.worker.cell(closer).seen() == [])
  }

  @Test func aJobHearsAClosedSocketOnceAfterItsAttached() throws {
    let recorder = Recorder()
    let a = try recorded(recorder, "a")
    let listener = Listener.ID("l")
    try a.worker.create(listener, params: 0)
    let peer = try #require(a.worker.attach(Feed.self, to: listener, opening: 0) { _ in })
    world.run(for: .seconds(2))
    #expect(recorder.events == ["attached 1"])
    peer.close()
    world.run(for: .seconds(5))
    #expect(recorder.events == ["attached 1", "closed 1"])
  }

  @Test func aJobHearsASocketItClosesItself() throws {
    let recorder = Recorder()
    let a = try recorded(recorder, "a")
    let dropper = Dropper.ID("d")
    try a.worker.create(dropper, params: 0)
    let client = Client<Feed>()
    _ = try #require(a.worker.attach(Feed.self, to: dropper, opening: 0) { client.hear($0, durable: []) })
    world.run(for: .seconds(5))
    #expect(recorder.events == ["attached 1", "closed 1"])
    #expect(client.heard == [.closed])
  }

  @Test func aJobHearsNoClosedWhenItIsDone() throws {
    let world = World()
    let recorder = Recorder()
    let a = try recorded(recorder, "a", in: world)
    let once = Once.ID("o")
    try a.worker.create(once, params: 0)
    let client = Client<Feed>()
    _ = try #require(a.worker.attach(Feed.self, to: once, opening: 0) { client.hear($0, durable: []) })
    world.run(for: .seconds(3))
    #expect(recorder.events == ["attached 1"])
    #expect(client.heard == [.closed])
  }

  @Test func aSocketClosedBetweenIncarnationsIsNotGreetedOrClosed() throws {
    let recorder = Recorder()
    let a = try recorded(recorder, "a")
    let listener = Listener.ID("l")
    try a.worker.create(listener, params: 0)
    let peer = try #require(a.worker.attach(Feed.self, to: listener, opening: 0) { _ in })
    world.run(for: .seconds(2))
    #expect(recorder.events == ["attached 1"])

    world.simulation.kill(a.process)
    peer.close()
    _ = try recorded(recorder, "b")
    world.run(for: .seconds(20))
    #expect(recorder.events == ["attached 1"])
  }

  @Test func aSocketCarriesWhatItOpenedWith() throws {
    let a = try node("a")
    let ticker = Ticker.ID("t")
    try a.worker.create(ticker, params: 3)
    let client = Client<Feed>()
    _ = try #require(a.worker.attach(Feed.self, to: ticker, opening: 2) { client.hear($0, durable: []) })
    world.run(for: .seconds(5))
    #expect(client.heard == [.frame(3), .closed])
  }
}
