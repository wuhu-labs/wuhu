import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Cell`: every mutating method that is not private and returns nothing is a message, except `wake`, `lost` and `around`. It becomes a case of `Message`, a branch of `receive` and a method of `Sender`, which posts that case. A method taking a `SocketHandle` is a socket handler instead, dispatched by a generated `_socket`.
public struct CellMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of _: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo _: [TypeSyntax],
    in context: some MacroExpansionContext,
  ) throws -> [DeclSyntax] {
    guard let cell = declaration.as(StructDeclSyntax.self) else { throw Refusal("@Cell applies to a struct") }
    let access = cell.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
    var messages: [Message] = []
    var handlers: [SocketHandler] = []
    for member in cell.memberBlock.members {
      guard let method = member.decl.as(FunctionDeclSyntax.self) else { continue }
      if let handler = SocketHandler(method) {
        if let refusal = handler.refusal(method) {
          context.diagnose(Diagnostic(node: method.name, message: refusal))
        } else {
          handlers.append(handler)
        }
        continue
      }
      guard Message.isMessage(method) else { continue }
      if let refusal = Message.refusal(method) {
        context.diagnose(Diagnostic(node: method.name, message: refusal))
      } else if messages.contains(where: { $0.name == method.name.text }) {
        context.diagnose(Diagnostic(node: method.name, message: Refusal("a cell's messages need distinct names; '\(method.name.text)' is overloaded")))
      } else {
        messages.append(Message(method))
      }
    }
    var members = contextMembers(of: cell, kind: "Cell", access: access)
    members.append(
      messages.isEmpty
        ? "\(raw: access)typealias Message = Never"
        : "\(raw: access)enum Message: Codable, Sendable {\(raw: block(messages.map { "case \($0.caseDeclaration)" }))}",
    )
    members.append("""
    \(raw: access)mutating func receive(_ message: Message) throws {
      switch message {\(raw: block(messages.map { "case \($0.pattern): \($0.call)" }))}
    }
    """)
    let senders = messages.map { "\n  \(access)func \($0.name)(\($0.parameters)) { outbox.post(\($0.value)) }" }
    members.append("\(raw: access)struct Sender {\n  let outbox: Outbox<Message>\(raw: senders.joined())\n}")
    members.append("\(raw: access)static func sender(_ outbox: Outbox<Message>) -> Sender { Sender(outbox: outbox) }")
    if !handlers.isEmpty { members.append(SocketHandler.dispatch(handlers, access: access)) }
    return members
  }

  public static func expansion(
    of _: AttributeSyntax,
    attachedTo _: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in _: some MacroExpansionContext,
  ) throws -> [ExtensionDeclSyntax] {
    try conformance(of: type, to: protocols)
  }
}

/// `@Job`: the context, its private `ctx`, `kind`, a private `state` when the job declares a `State`, and `_attached` and `_closed` dispatching to its `attached(_:)` and `closed(_:)` methods, one per socket type.
public struct JobMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of _: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo _: [TypeSyntax],
    in context: some MacroExpansionContext,
  ) throws -> [DeclSyntax] {
    guard let job = declaration.as(StructDeclSyntax.self) else { throw Refusal("@Job applies to a struct") }
    let access = job.modifiers.contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
    let declaresState = job.memberBlock.members.contains { member in
      let decl = member.decl
      let name = decl.as(TypeAliasDeclSyntax.self)?.name ?? decl.as(StructDeclSyntax.self)?.name ?? decl.as(ClassDeclSyntax.self)?.name ?? decl.as(EnumDeclSyntax.self)?.name
      return name?.text == "State"
    }
    var members = contextMembers(of: job, kind: "Job", access: access)
    if declaresState {
      members.append("private var state: State { get { _context.state } nonmutating set { _context.state = newValue } }")
    }
    var handlers: [SocketHandler] = []
    for member in job.memberBlock.members {
      guard let method = member.decl.as(FunctionDeclSyntax.self), let handler = SocketHandler(method) else { continue }
      if let refusal = handler.jobRefusal(method) {
        context.diagnose(Diagnostic(node: method.name, message: refusal))
      } else {
        handlers.append(handler)
      }
    }
    for (name, dispatch) in [("attached", "_attached"), ("closed", "_closed")] {
      let branches = handlers.filter { $0.name == name }.map { "if let socket = event.socket(\($0.socket).self) { \($0.call) }" }
      guard !branches.isEmpty else { continue }
      members.append("\(raw: access)func \(raw: dispatch)(_ event: SocketEvent) {\n  \(raw: branches.joined(separator: " else "))\n}")
    }
    return members
  }

  public static func expansion(
    of _: AttributeSyntax,
    attachedTo _: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in _: some MacroExpansionContext,
  ) throws -> [ExtensionDeclSyntax] {
    try conformance(of: type, to: protocols)
  }
}

/// The stored context the protocol needs; the `ctx`, `db` and `id` the type's own code uses; and `kind` unless the type declares it.
private func contextMembers(of type: StructDeclSyntax, kind: String, access: String) -> [DeclSyntax] {
  let name = type.name.text
  let declaresKind = type.memberBlock.members.contains { member in
    member.decl.as(VariableDeclSyntax.self)?.bindings.contains { $0.pattern.trimmedDescription == "kind" } ?? false
  }
  var members: [DeclSyntax] = [
    "\(raw: access)var _context: \(raw: kind)Context<\(raw: name)>",
    "var ctx: \(raw: kind)Context<\(raw: name)> { get { _context } set { _context = newValue } }",
    "\(raw: access)init(_context: \(raw: kind)Context<\(raw: name)>) { self._context = _context }",
    "var db: \(raw: kind == "Job" ? "JobDatabase" : "Database") { get { _context.db } set { _context.db = newValue } }",
    "var id: ID { _context.id }",
  ]
  if !declaresKind { members.append("\(raw: access)static let kind = \(literal: name)") }
  return members
}

/// Every protocol the attribute names that the type lacks, `Addressable` included although `Cell` and `Job` imply it: Swift 6.4 drops a conformance implied by a macro's extension when another file asks for it (swiftlang/swift#87872).
private func conformance(of type: some TypeSyntaxProtocol, to protocols: [TypeSyntax]) throws -> [ExtensionDeclSyntax] {
  guard !protocols.isEmpty else { return [] }
  return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: protocols.map { "Wuwei.\($0.trimmedDescription)" }.joined(separator: ", ")) {}")]
}

/// Lines inside braces, or nothing when there are none.
private func block(_ lines: [String]) -> String {
  lines.isEmpty ? "" : "\n" + lines.map { "  \($0)\n" }.joined()
}

private struct Message {
  let name: String
  let labels: [String?]
  let types: [String]
  let throwing: Bool

  static func isMessage(_ method: FunctionDeclSyntax) -> Bool {
    let modifiers = method.modifiers.map(\.name.tokenKind)
    if method.name.text == "wake", method.signature.parameterClause.parameters.isEmpty { return false }
    if method.name.text == "lost", method.signature.parameterClause.parameters.count == 1 { return false }
    if method.name.text == "around", method.signature.parameterClause.parameters.count == 1 { return false }
    if method.signature.returnClause != nil { return false }
    return modifiers.contains(.keyword(.mutating)) && !modifiers.contains(.keyword(.private)) && !modifiers.contains(.keyword(.fileprivate))
  }

  static func refusal(_ method: FunctionDeclSyntax) -> Refusal? {
    if method.signature.effectSpecifiers?.asyncSpecifier != nil { return Refusal("a cell never awaits: '\(method.name.text)' is async; effects belong to a job") }
    if method.genericParameterClause != nil { return Refusal("a message cannot be generic: '\(method.name.text)'") }
    for parameter in method.signature.parameterClause.parameters {
      if parameter.ellipsis != nil || parameter.type.is(AttributedTypeSyntax.self) {
        return Refusal("a message's parameters are plain Codable values: '\(method.name.text)'")
      }
    }
    return nil
  }

  init(_ method: FunctionDeclSyntax) {
    name = method.name.text
    let parameters = method.signature.parameterClause.parameters
    labels = parameters.map { $0.firstName.tokenKind == .wildcard ? nil : $0.firstName.text }
    types = parameters.map(\.type.trimmedDescription)
    throwing = method.signature.effectSpecifiers?.throwsClause != nil
  }

  private var values: [String] {
    types.indices.map { "_\($0)" }
  }

  var caseDeclaration: String {
    types.isEmpty ? name : "\(name)(\(zip(labels, types).map { label, type in label.map { "\($0): \(type)" } ?? type }.joined(separator: ", ")))"
  }

  var pattern: String {
    types.isEmpty ? ".\(name)" : "let .\(name)(\(values.joined(separator: ", ")))"
  }

  var call: String {
    "\(throwing ? "try " : "")self.\(name)(\(arguments))"
  }

  var parameters: String {
    zip(labels, zip(values, types)).map { label, value in "\(label ?? "_") \(value.0): \(value.1)" }.joined(separator: ", ")
  }

  var value: String {
    types.isEmpty ? ".\(name)" : ".\(name)(\(arguments))"
  }

  private var arguments: String {
    zip(labels, values).map { label, value in label.map { "\($0): \(value)" } ?? value }.joined(separator: ", ")
  }
}

/// `attached(_:)`, `receive(_:from:)` or `closed(_:)` for one socket type.
private struct SocketHandler {
  let name: String
  let socket: String
  let call: String

  /// `nil` unless the method takes a `SocketHandle`.
  init?(_ method: FunctionDeclSyntax) {
    let parameters = Array(method.signature.parameterClause.parameters)
    guard let handle = parameters.lazy.compactMap({ Self.socketType($0.type) }).first else { return nil }
    name = method.name.text
    socket = handle
    let values = parameters.count == 2 ? ["frame as! \(parameters[0].type.trimmedDescription)", "socket"] : ["socket"]
    let arguments = zip(parameters, values).map { parameter, value in parameter.firstName.tokenKind == .wildcard ? value : "\(parameter.firstName.text): \(value)" }
    let throwing = method.signature.effectSpecifiers?.throwsClause != nil
    call = "\(throwing ? "try " : "")self.\(name)(\(arguments.joined(separator: ", ")))"
  }

  private static func socketType(_ type: TypeSyntax) -> String? {
    guard let type = type.as(IdentifierTypeSyntax.self), type.name.text == "SocketHandle", let argument = type.genericArgumentClause?.arguments.first else { return nil }
    return argument.argument.trimmedDescription
  }

  func refusal(_ method: FunctionDeclSyntax) -> Refusal? {
    let parameters = Array(method.signature.parameterClause.parameters)
    let shapes = ["attached": 1, "receive": 2, "closed": 1]
    guard let count = shapes[name] else { return Refusal("a socket handler is attached(_:), receive(_:from:) or closed(_:), not '\(name)'") }
    if parameters.count != count || Self.socketType(parameters.last!.type) == nil || (count == 2 && Self.socketType(parameters[0].type) != nil) {
      return Refusal(count == 2 ? "receive takes a frame and then its SocketHandle" : "\(name) takes only its SocketHandle")
    }
    if !method.modifiers.contains(where: { $0.name.tokenKind == .keyword(.mutating) }) { return Refusal("a socket handler is mutating: '\(name)'") }
    if method.signature.effectSpecifiers?.asyncSpecifier != nil { return Refusal("a cell never awaits: '\(name)' is async") }
    if method.signature.returnClause != nil { return Refusal("a socket handler returns nothing: '\(name)'") }
    return nil
  }

  /// A job's sockets only hear it publish, so its handlers greet a socket as it attaches and say goodbye as it closes, and they may not write or mutate: they run beside `start`.
  func jobRefusal(_ method: FunctionDeclSyntax) -> Refusal? {
    if !["attached", "closed"].contains(name) || method.signature.parameterClause.parameters.count != 1 { return Refusal("a job's socket handlers are attached(_:) and closed(_:), not '\(name)'") }
    if method.modifiers.contains(where: { $0.name.tokenKind == .keyword(.mutating) }) { return Refusal("a job's \(name)(_:) is not mutating: it runs beside start") }
    if method.signature.effectSpecifiers?.asyncSpecifier != nil || method.signature.effectSpecifiers?.throwsClause != nil { return Refusal("a job's \(name)(_:) neither awaits nor throws") }
    if method.signature.returnClause != nil { return Refusal("a socket handler returns nothing: '\(name)'") }
    return nil
  }

  /// One branch per socket type, in the order the types first appear.
  static func dispatch(_ handlers: [SocketHandler], access: String) -> DeclSyntax {
    var sockets: [String] = []
    for handler in handlers where !sockets.contains(handler.socket) {
      sockets.append(handler.socket)
    }
    let branches = sockets.map { socket in
      let mine = handlers.filter { $0.socket == socket }
      let attached = mine.first { $0.name == "attached" }?.call ?? "break"
      let closed = mine.first { $0.name == "closed" }?.call ?? "break"
      let frame = mine.first { $0.name == "receive" }.map { "case let .frame(frame): \($0.call)" } ?? "case .frame: event.unhandled()"
      return """
      if let socket = event.socket(\(socket).self) {
        switch event.kind {
        case .attached: \(attached)
        \(frame)
        case .closed: \(closed)
        }
      }
      """
    }
    return """
    \(raw: access)mutating func _socket(_ event: SocketEvent) throws {
      \(raw: branches.joined(separator: " else ").replacing("\n", with: "\n  ")) else {
        event.unhandled()
      }
    }
    """
  }
}

private struct Refusal: Error, DiagnosticMessage, CustomStringConvertible {
  let message: String
  var description: String { message }
  var diagnosticID: MessageID { MessageID(domain: "WuweiMacros", id: "cell") }
  var severity: DiagnosticSeverity { .error }

  init(_ message: String) {
    self.message = message
  }
}
