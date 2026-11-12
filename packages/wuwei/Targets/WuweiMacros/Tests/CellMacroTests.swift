import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
import WuweiMacros

struct CellMacroTests {
  private let macros: [String: any Macro.Type] = ["Cell": CellMacro.self, "Job": JobMacro.self]

  @Test func testMutatingMethodsBecomeMessagesButWakeAndAround() {
    assertMacroExpansion(
      """
      @Cell
      struct Account {
        func balance() -> Int64 { 0 }
        mutating func deposit(_ amount: Int64) throws {}
        mutating func rename(to name: String) {}
        mutating func withdraw(_ amount: Int64) throws -> Int64 { amount }
        private mutating func audit() {}
        mutating func wake() throws {}
        mutating func around(_ call: (inout Account) throws -> Void) throws { try call(&self) }
      }
      """,
      expandedSource: """
      struct Account {
        func balance() -> Int64 { 0 }
        mutating func deposit(_ amount: Int64) throws {}
        mutating func rename(to name: String) {}
        mutating func withdraw(_ amount: Int64) throws -> Int64 { amount }
        private mutating func audit() {}
        mutating func wake() throws {}
        mutating func around(_ call: (inout Account) throws -> Void) throws { try call(&self) }

        var _context: CellContext<Account>

        var ctx: CellContext<Account> {
          get {
            _context
          }
          set {
            _context = newValue
          }
        }

        init(_context: CellContext<Account>) {
          self._context = _context
        }

        var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        var id: ID {
          _context.id
        }

        static let kind = "Account"

        enum Message: Codable, Sendable {
          case deposit(Int64)
          case rename(to: String)
        }

        mutating func receive(_ message: Message) throws {
          switch message {
          case let .deposit(_0):
            try self.deposit(_0)
          case let .rename(_0):
            self.rename(to: _0)
          }
        }

        struct Sender {
          let outbox: Outbox<Message>
          func deposit(_ _0: Int64) {
            outbox.post(.deposit(_0))
          }
          func rename(to _0: String) {
            outbox.post(.rename(to: _0))
          }
        }

        static func sender(_ outbox: Outbox<Message>) -> Sender {
          Sender(outbox: outbox)
        }
      }
      """,
      macroSpecs: macros.mapValues { MacroSpec(type: $0) },
      indentationWidth: .spaces(2),
      failureHandler: recordFailure,
    )
  }

  @Test func testAMessageCannotAwait() {
    assertMacroExpansion(
      """
      @Cell
      struct Account {
        mutating func charge() async {}
      }
      """,
      expandedSource: """
      struct Account {
        mutating func charge() async {}

        var _context: CellContext<Account>

        var ctx: CellContext<Account> {
          get {
            _context
          }
          set {
            _context = newValue
          }
        }

        init(_context: CellContext<Account>) {
          self._context = _context
        }

        var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        var id: ID {
          _context.id
        }

        static let kind = "Account"

        typealias Message = Never

        mutating func receive(_ message: Message) throws {
          switch message {
          }
        }

        struct Sender {
          let outbox: Outbox<Message>
        }

        static func sender(_ outbox: Outbox<Message>) -> Sender {
          Sender(outbox: outbox)
        }
      }
      """,
      diagnostics: [DiagnosticSpec(message: "a cell never awaits: 'charge' is async; effects belong to a job", line: 3, column: 17)],
      macroSpecs: macros.mapValues { MacroSpec(type: $0) },
      indentationWidth: .spaces(2),
      failureHandler: recordFailure,
    )
  }

  @Test func testSocketHandlersAreDispatchedBySocketType() {
    assertMacroExpansion(
      """
      @Cell
      struct Room {
        mutating func attached(_ socket: SocketHandle<Chat>) {}
        mutating func receive(_ frame: Chat.Incoming, from socket: SocketHandle<Chat>) throws {}
        mutating func closed(_ socket: SocketHandle<Feed>) {}
      }
      """,
      expandedSource: """
      struct Room {
        mutating func attached(_ socket: SocketHandle<Chat>) {}
        mutating func receive(_ frame: Chat.Incoming, from socket: SocketHandle<Chat>) throws {}
        mutating func closed(_ socket: SocketHandle<Feed>) {}

        var _context: CellContext<Room>

        var ctx: CellContext<Room> {
          get {
            _context
          }
          set {
            _context = newValue
          }
        }

        init(_context: CellContext<Room>) {
          self._context = _context
        }

        var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        var id: ID {
          _context.id
        }

        static let kind = "Room"

        typealias Message = Never

        mutating func receive(_ message: Message) throws {
          switch message {
          }
        }

        struct Sender {
          let outbox: Outbox<Message>
        }

        static func sender(_ outbox: Outbox<Message>) -> Sender {
          Sender(outbox: outbox)
        }

        mutating func _socket(_ event: SocketEvent) throws {
          if let socket = event.socket(Chat.self) {
            switch event.kind {
            case .attached:
              self.attached(socket)
            case let .frame(frame):
              try self.receive(frame as! Chat.Incoming, from: socket)
            case .closed:
              break
            }
          } else if let socket = event.socket(Feed.self) {
            switch event.kind {
            case .attached:
              break
            case .frame:
              event.unhandled()
            case .closed:
              self.closed(socket)
            }
          } else {
            event.unhandled()
          }
        }
      }
      """,
      macroSpecs: macros.mapValues { MacroSpec(type: $0) },
      indentationWidth: .spaces(2),
      failureHandler: recordFailure,
    )
  }

  @Test func testASocketHandlerHasAFixedShape() {
    assertMacroExpansion(
      """
      @Cell
      struct Room {
        mutating func joined(_ socket: SocketHandle<Chat>) {}
      }
      """,
      expandedSource: """
      struct Room {
        mutating func joined(_ socket: SocketHandle<Chat>) {}

        var _context: CellContext<Room>

        var ctx: CellContext<Room> {
          get {
            _context
          }
          set {
            _context = newValue
          }
        }

        init(_context: CellContext<Room>) {
          self._context = _context
        }

        var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        var id: ID {
          _context.id
        }

        static let kind = "Room"

        typealias Message = Never

        mutating func receive(_ message: Message) throws {
          switch message {
          }
        }

        struct Sender {
          let outbox: Outbox<Message>
        }

        static func sender(_ outbox: Outbox<Message>) -> Sender {
          Sender(outbox: outbox)
        }
      }
      """,
      diagnostics: [DiagnosticSpec(message: "a socket handler is attached(_:), receive(_:from:) or closed(_:), not 'joined'", line: 3, column: 17)],
      macroSpecs: macros.mapValues { MacroSpec(type: $0) },
      indentationWidth: .spaces(2),
      failureHandler: recordFailure,
    )
  }

  @Test func testAJobGetsItsContextAndState() {
    assertMacroExpansion(
      """
      @Job
      public struct Fetch {
        public static let kind = "Fetch.v2"
        public struct State {}
      }
      """,
      expandedSource: """
      public struct Fetch {
        public static let kind = "Fetch.v2"
        public struct State {}

        public var _context: JobContext<Fetch>

        var ctx: JobContext<Fetch> {
          get {
            _context
          }
          set {
            _context = newValue
          }
        }

        public init(_context: JobContext<Fetch>) {
          self._context = _context
        }

        var db: JobDatabase {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        var id: ID {
          _context.id
        }

        private var state: State {
          get {
            _context.state
          }
          nonmutating set {
            _context.state = newValue
          }
        }
      }
      """,
      macroSpecs: macros.mapValues { MacroSpec(type: $0) },
      indentationWidth: .spaces(2),
      failureHandler: recordFailure,
    )
  }

  private func recordFailure(_ failure: TestFailureSpec) {
    Issue.record("\(failure.message)", sourceLocation: .init(fileID: failure.location.fileID, filePath: failure.location.filePath, line: failure.location.line, column: failure.location.column))
  }
}
