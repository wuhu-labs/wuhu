import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WuweiMacros
import XCTest

final class CellMacroTests: XCTestCase {
  private let macros: [String: any Macro.Type] = ["Cell": CellMacro.self, "Job": JobMacro.self]

  func testMutatingMethodsBecomeMessages() {
    assertMacroExpansion(
      """
      @Cell
      struct Account {
        func balance() -> Int64 { 0 }
        mutating func deposit(_ amount: Int64) throws {}
        mutating func rename(to name: String) {}
        private mutating func audit() {}
      }
      """,
      expandedSource: """
      struct Account {
        func balance() -> Int64 { 0 }
        mutating func deposit(_ amount: Int64) throws {}
        mutating func rename(to name: String) {}
        private mutating func audit() {}

        var _context: CellContext<Account>

        private var ctx: CellContext<Account> {
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

        private var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        private var id: ID {
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
      macros: macros,
      indentationWidth: .spaces(2),
    )
  }

  func testAMessageCannotAwait() {
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

        private var ctx: CellContext<Account> {
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

        private var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        private var id: ID {
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
      macros: macros,
      indentationWidth: .spaces(2),
    )
  }

  func testSocketHandlersAreDispatchedBySocketType() {
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

        private var ctx: CellContext<Room> {
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

        private var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        private var id: ID {
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
      macros: macros,
      indentationWidth: .spaces(2),
    )
  }

  func testASocketHandlerHasAFixedShape() {
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

        private var ctx: CellContext<Room> {
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

        private var db: Database {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        private var id: ID {
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
      macros: macros,
      indentationWidth: .spaces(2),
    )
  }

  func testAJobGetsItsContextAndState() {
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

        private var ctx: JobContext<Fetch> {
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

        private var db: JobDatabase {
          get {
            _context.db
          }
          set {
            _context.db = newValue
          }
        }

        private var id: ID {
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
      macros: macros,
      indentationWidth: .spaces(2),
    )
  }
}
