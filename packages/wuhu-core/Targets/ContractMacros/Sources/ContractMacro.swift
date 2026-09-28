import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum ContractMacroError: Error, CustomStringConvertible {
  case notStructOrEnum
  case missingType(name: String)
  case tuplePattern(pattern: String)
  case attributedProperty(name: String)
  case unsupportedType(name: String, type: String)
  case unlabeledAssociatedValue(caseName: String)
  case discriminatorCollision(caseName: String, discriminator: String)
  case nonLiteralRawValue(caseName: String)
  case enumNeedsRawOrAssociated(name: String)
  case nonLiteralDiscriminator
  case discriminatorOutsideUnion

  var description: String {
    switch self {
    case .notStructOrEnum:
      return "@Contract can only be applied to a struct or enum"
    case let .missingType(name):
      return "@Contract requires an explicit type annotation on property '\(name)'"
    case let .tuplePattern(pattern):
      return "@Contract does not support tuple-pattern property '\(pattern)'; declare each property on its own binding"
    case let .attributedProperty(name):
      return "@Contract cannot derive a wire schema for property '\(name)' because it carries an attribute (e.g. a property wrapper), whose encoded form is not knowable from the declaration"
    case let .unsupportedType(name, type):
      var message =
        "@Contract does not support the type of '\(name)': \(type). Supported: String, Int, Double, Bool, JSONValue, their optionals and arrays, and nested @Contract types"
      if type == "Float" { message += " (use Double instead of Float)" }
      return message
    case let .unlabeledAssociatedValue(caseName):
      return "@Contract requires a label on every associated value; case '\(caseName)' has an unlabeled (or `_`-suppressed) one. Internally-tagged unions flatten associated values beside the discriminator by field name, so each needs a label — there is no _0 synthesis."
    case let .discriminatorCollision(caseName, discriminator):
      return "@Contract reserves the key '\(discriminator)' for the union discriminator; case '\(caseName)' has an associated value labeled '\(discriminator)', which would collide. Rename the associated value."
    case let .nonLiteralRawValue(caseName):
      return "@Contract needs a plain string-literal raw value to derive the wire value; case '\(caseName)' has a non-literal raw value"
    case let .enumNeedsRawOrAssociated(name):
      return "@Contract enum '\(name)' needs either a String raw type — spelled `String` or `Swift.String`, not through a typealias the macro cannot resolve — or at least one case with labeled associated values (a discriminated union)"
    case .nonLiteralDiscriminator:
      return "@Contract needs a plain string-literal discriminator"
    case .discriminatorOutsideUnion:
      return "@Contract takes a discriminator only on an enum with associated values (a discriminated union)"
    }
  }
}

indirect enum FieldSchema {
  case scalar(String)
  case array(FieldSchema)
  case nested(String)
  case anyJSON
}

private struct Field {
  let name: String
  let type: TypeSyntax
  var typeText: String { type.trimmedDescription }
}

public struct ContractMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo _: [TypeSyntax],
    in _: some MacroExpansionContext,
  ) throws -> [DeclSyntax] {
    let discriminator = try discriminatorArgument(of: node)
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      guard discriminator == nil else { throw ContractMacroError.discriminatorOutsideUnion }
      return try structMembers(structDecl)
    }
    if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      return try enumMembers(enumDecl, discriminator: discriminator)
    }
    throw ContractMacroError.notStructOrEnum
  }

  private static func discriminatorArgument(of node: AttributeSyntax) throws -> String? {
    guard case let .argumentList(arguments) = node.arguments,
          let argument = arguments.first(where: { $0.label?.text == "discriminator" })
    else { return nil }
    guard let literal = stringLiteralValue(argument.expression) else {
      throw ContractMacroError.nonLiteralDiscriminator
    }
    return literal
  }

  private static func structMembers(_ structDecl: StructDeclSyntax) throws -> [DeclSyntax] {
    let fields = try storedProperties(of: structDecl)
    let (properties, required) = try fieldSchemas(of: fields)
    let object = objectSchemaExpr(properties: properties, required: required)
    let access = accessPrefix(of: structDecl.modifiers)
    return [
      DeclSyntax("\(raw: access)static var jsonSchema: JSONValue { \(raw: object) }"),
      DeclSyntax("\(raw: memberwiseInit(fields, access: access))"),
    ]
  }

  private static func memberwiseInit(_ fields: [Field], access: String) -> String {
    let parameters = fields.map { field in
      let name = escaped(field.name)
      let defaultValue = isOptional(field.type) ? " = nil" : ""
      return "\(name): \(field.typeText)\(defaultValue)"
    }
    let assignments = fields.map { "self.\(escaped($0.name)) = \(escaped($0.name))" }
    return """
    \(access)init(\(parameters.joined(separator: ", "))) {
    \(assignments.joined(separator: "\n"))
    }
    """
  }

  private static func enumMembers(_ enumDecl: EnumDeclSyntax, discriminator: String?) throws -> [DeclSyntax] {
    let cases = enumCases(of: enumDecl)
    let access = accessPrefix(of: enumDecl.modifiers)
    if cases.contains(where: { !$0.parameters.isEmpty }) {
      let key = discriminator ?? "kind"
      let schema = try discriminatedUnionExpr(cases, discriminator: key)
      let coding = discriminatedUnionCoding(cases, typeName: enumDecl.name.text, access: access, discriminator: key)
      return [
        DeclSyntax("\(raw: access)static var jsonSchema: JSONValue { \(raw: schema) }"),
        DeclSyntax("\(raw: coding.encode)"),
        DeclSyntax("\(raw: coding.decode)"),
      ]
    }
    guard discriminator == nil else { throw ContractMacroError.discriminatorOutsideUnion }
    guard hasStringRawType(enumDecl) else {
      throw ContractMacroError.enumNeedsRawOrAssociated(name: enumDecl.name.text)
    }
    return [DeclSyntax("\(raw: access)static var jsonSchema: JSONValue { \(raw: try stringEnumExpr(cases)) }")]
  }

  private static func accessPrefix(of modifiers: DeclModifierListSyntax) -> String {
    for modifier in modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.public), .keyword(.open): return "public "
      case .keyword(.package): return "package "
      default: continue
      }
    }
    return ""
  }

  // MARK: - Struct properties

  private static func storedProperties(of structDecl: StructDeclSyntax) throws -> [Field] {
    var result: [Field] = []
    for member in structDecl.memberBlock.members {
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
      if varDecl.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) {
        continue
      }
      result.append(contentsOf: try storedBindings(of: varDecl))
    }
    return result
  }

  // `let lower, upper: Int` shares one trailing annotation across both bindings,
  // and SwiftSyntax attaches it only to the last binding, so carry it backward.
  private static func storedBindings(of varDecl: VariableDeclSyntax) throws -> [Field] {
    var fields: [Field] = []
    var trailingType: TypeSyntax?
    for binding in varDecl.bindings.reversed() {
      if let annotated = binding.typeAnnotation?.type {
        trailingType = annotated
      }
      if let accessorBlock = binding.accessorBlock, isComputed(accessorBlock) {
        continue
      }
      guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        throw ContractMacroError.tuplePattern(pattern: binding.pattern.trimmedDescription)
      }
      let name = wireName(identifierPattern.identifier)
      if !varDecl.attributes.isEmpty {
        throw ContractMacroError.attributedProperty(name: name)
      }
      guard let type = trailingType else {
        throw ContractMacroError.missingType(name: name)
      }
      fields.append(Field(name: name, type: type))
    }
    return fields.reversed()
  }

  // willSet/didSet observers keep a property stored; only a getter — or any
  // get/set, read/modify, or addressor accessor — makes it computed and absent
  // from the encoded wire form.
  private static func isComputed(_ accessorBlock: AccessorBlockSyntax) -> Bool {
    switch accessorBlock.accessors {
    case .getter:
      return true
    case let .accessors(list):
      return !list.allSatisfy { accessor in
        let kind = accessor.accessorSpecifier.tokenKind
        return kind == .keyword(.willSet) || kind == .keyword(.didSet)
      }
    }
  }

  // MARK: - Enum cases

  private struct Case {
    let name: String
    let parameters: [Field]
    let rawValue: ExprSyntax?
  }

  private static func enumCases(of enumDecl: EnumDeclSyntax) -> [Case] {
    var result: [Case] = []
    for member in enumDecl.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      for element in caseDecl.elements {
        let name = wireName(element.name)
        let parameters = (element.parameterClause?.parameters).map(caseParameters) ?? []
        result.append(Case(name: name, parameters: parameters, rawValue: element.rawValue?.value))
      }
    }
    return result
  }

  // A `_`-suppressed label is unlabeled on the wire; map it to the empty name so
  // the discriminated-union path rejects it exactly like a missing label.
  private static func caseParameters(_ list: EnumCaseParameterListSyntax) -> [Field] {
    list.map { parameter in
      let label: String
      if let first = parameter.firstName, first.tokenKind != .wildcard {
        label = wireName(first)
      } else {
        label = ""
      }
      return Field(name: label, type: parameter.type)
    }
  }

  private static func hasStringRawType(_ enumDecl: EnumDeclSyntax) -> Bool {
    guard let first = enumDecl.inheritanceClause?.inheritedTypes.first?.type else { return false }
    if first.as(IdentifierTypeSyntax.self)?.name.text == "String" { return true }
    return first.as(MemberTypeSyntax.self)?.name.text == "String"
  }

  private static func discriminatedUnionExpr(_ cases: [Case], discriminator: String) throws -> String {
    var branches: [String] = []
    for enumCase in cases {
      for parameter in enumCase.parameters {
        if parameter.name.isEmpty {
          throw ContractMacroError.unlabeledAssociatedValue(caseName: enumCase.name)
        }
        if parameter.name == discriminator {
          throw ContractMacroError.discriminatorCollision(caseName: enumCase.name, discriminator: discriminator)
        }
      }
      let discriminatorEntry = #""\#(discriminator)": .object(["const": .string("\#(enumCase.name)")])"#
      let (fieldEntries, required) = try fieldSchemas(of: enumCase.parameters)
      let properties = ([discriminatorEntry] + fieldEntries).joined(separator: ", ")
      let requiredNames = ([discriminator] + required).map { #".string("\#($0)")"# }.joined(separator: ", ")
      branches.append(
        #".object(["type": .string("object"), "properties": .object([\#(properties)]), "required": .array([\#(requiredNames)]), "additionalProperties": .bool(false)])"#,
      )
    }
    return #".object(["oneOf": .array([\#(branches.joined(separator: ", "))])])"#
  }

  private static func stringEnumExpr(_ cases: [Case]) throws -> String {
    var values: [String] = []
    for enumCase in cases {
      guard let rawValue = enumCase.rawValue else {
        values.append(enumCase.name)
        continue
      }
      guard let literal = stringLiteralValue(rawValue) else {
        throw ContractMacroError.nonLiteralRawValue(caseName: enumCase.name)
      }
      values.append(literal)
    }
    let entries = values.map { #".string("\#($0)")"# }.joined(separator: ", ")
    return #".object(["type": .string("string"), "enum": .array([\#(entries)])])"#
  }

  // MARK: - Emitted internally-tagged Codable

  // The macro derives the discriminated-union schema AND the matching Codable
  // from one source, so the two cannot drift: a synthesized (externally tagged)
  // Codable would silently contradict the schema, which the design forbids.
  private static func discriminatedUnionCoding(
    _ cases: [Case],
    typeName: String,
    access: String,
    discriminator: String,
  ) -> (encode: String, decode: String) {
    var keys = [discriminator]
    for enumCase in cases {
      for parameter in enumCase.parameters where !keys.contains(parameter.name) {
        keys.append(parameter.name)
      }
    }
    let codingKeys = "enum CodingKeys: String, CodingKey { case \(keys.map(escaped).joined(separator: ", ")) }"
    let discriminatorKey = escaped(discriminator)

    var encodeCases: [String] = []
    var decodeCases: [String] = []
    for enumCase in cases {
      let binders = enumCase.parameters.map { escaped($0.name) }
      let pattern = binders.isEmpty ? "" : "(\(binders.joined(separator: ", ")))"
      let leadingLet = binders.isEmpty ? "" : "let "
      var encodeBody = ["try container.encode(\"\(enumCase.name)\", forKey: .\(discriminatorKey))"]
      for parameter in enumCase.parameters {
        let key = escaped(parameter.name)
        let verb = isOptional(parameter.type) ? "encodeIfPresent" : "encode"
        encodeBody.append("try container.\(verb)(\(key), forKey: .\(key))")
      }
      encodeCases.append("case \(leadingLet).\(escaped(enumCase.name))\(pattern):\n" + encodeBody.joined(separator: "\n"))

      let decoded = enumCase.parameters.map { parameter -> String in
        let key = escaped(parameter.name)
        if let wrapped = optionalWrappedType(parameter.type) {
          return "\(key): try container.decodeIfPresent(\(wrapped).self, forKey: .\(key))"
        }
        return "\(key): try container.decode(\(parameter.typeText).self, forKey: .\(key))"
      }
      let payload = decoded.isEmpty ? "" : "(\(decoded.joined(separator: ", ")))"
      decodeCases.append("case \"\(enumCase.name)\":\nself = .\(escaped(enumCase.name))\(payload)")
    }

    let encode = """
    \(access)func encode(to encoder: any Encoder) throws {
    \(codingKeys)
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    \(encodeCases.joined(separator: "\n"))
    }
    }
    """
    let decode = """
    \(access)init(from decoder: any Decoder) throws {
    \(codingKeys)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .\(discriminatorKey))
    switch kind {
    \(decodeCases.joined(separator: "\n"))
    default:
    throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unknown \(typeName) \(discriminator): \\(kind)"))
    }
    }
    """
    return (encode, decode)
  }

  // MARK: - Shared type analysis

  private static func fieldSchemas(of fields: [Field]) throws -> (entries: [String], required: [String]) {
    var entries: [String] = []
    var required: [String] = []
    for field in fields {
      let (schema, optional) = try analyze(field)
      if optional {
        entries.append("\"\(field.name)\": \(nullableSchemaExpr(schema))")
      } else {
        entries.append("\"\(field.name)\": \(schemaExpr(schema))")
        required.append(field.name)
      }
    }
    return (entries, required)
  }

  private static func objectSchemaExpr(properties: [String], required: [String]) -> String {
    let propertiesExpr = properties.isEmpty
      ? ".object([:])"
      : ".object([\(properties.joined(separator: ", "))])"
    let requiredExpr = ".array([\(required.map { ".string(\"\($0)\")" }.joined(separator: ", "))])"
    return #".object(["type": .string("object"), "properties": \#(propertiesExpr), "required": \#(requiredExpr), "additionalProperties": .bool(false)])"#
  }

  private static func analyze(_ field: Field) throws -> (FieldSchema, Bool) {
    if let optional = field.type.as(OptionalTypeSyntax.self) {
      return (try parse(optional.wrappedType, named: field.name), true)
    }
    return (try parse(field.type, named: field.name), false)
  }

  private static func parse(_ type: TypeSyntax, named name: String) throws -> FieldSchema {
    if let array = type.as(ArrayTypeSyntax.self) {
      return .array(try parse(array.element, named: name))
    }
    guard let ident = type.as(IdentifierTypeSyntax.self), ident.genericArgumentClause == nil else {
      throw ContractMacroError.unsupportedType(name: name, type: type.trimmedDescription)
    }
    switch ident.name.text {
    case "String": return .scalar("string")
    case "Int": return .scalar("integer")
    case "Double": return .scalar("number")
    case "Bool": return .scalar("boolean")
    case "JSONValue": return .anyJSON
    case let leaf where deniedLeafTypes.contains(leaf):
      throw ContractMacroError.unsupportedType(name: name, type: leaf)
    default:
      return .nested(ident.name.text)
    }
  }

  private static let deniedLeafTypes: Set<String> = [
    "UUID", "Date", "Data", "URL", "Decimal", "Float",
    "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
  ]

  private static func schemaExpr(_ schema: FieldSchema) -> String {
    switch schema {
    case let .scalar(keyword):
      #".object(["type": .string("\#(keyword)")])"#
    case let .array(element):
      #".object(["type": .string("array"), "items": \#(schemaExpr(element))])"#
    case let .nested(name):
      "\(name).jsonSchema"
    case .anyJSON:
      ".object([:])"
    }
  }

  private static func nullableSchemaExpr(_ schema: FieldSchema) -> String {
    switch schema {
    case let .scalar(keyword):
      #".object(["type": .array([.string("\#(keyword)"), .string("null")])])"#
    case let .array(element):
      #".object(["type": .array([.string("array"), .string("null")]), "items": \#(schemaExpr(element))])"#
    case let .nested(name):
      #".object(["anyOf": .array([\#(name).jsonSchema, .object(["type": .string("null")])])])"#
    case .anyJSON:
      // The empty schema already admits null; optionality only drops it from required.
      ".object([:])"
    }
  }

  // MARK: - Syntax helpers

  private static func isOptional(_ type: TypeSyntax) -> Bool {
    type.is(OptionalTypeSyntax.self)
  }

  private static func optionalWrappedType(_ type: TypeSyntax) -> String? {
    type.as(OptionalTypeSyntax.self)?.wrappedType.trimmedDescription
  }

  private static func stringLiteralValue(_ expr: ExprSyntax) -> String? {
    guard let literal = expr.as(StringLiteralExprSyntax.self),
          literal.segments.count == 1,
          let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else { return nil }
    return segment.content.text
  }

  private static func wireName(_ token: TokenSyntax) -> String {
    Identifier(token)?.name ?? token.text
  }

  private static func escaped(_ name: String) -> String {
    swiftKeywords.contains(name) ? "`\(name)`" : name
  }

  private static let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
    "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "throw",
    "throws", "where", "while", "as", "Any", "catch", "false", "is", "nil", "self",
    "Self", "super", "true", "try", "Type", "Protocol", "_",
  ]
}
