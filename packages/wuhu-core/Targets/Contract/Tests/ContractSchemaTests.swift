import Contract
import JSONValue
import Testing

@Contract
private struct Scalars {
  let name: String
  let count: Int
  let ratio: Double
  let active: Bool
}

@Contract
private struct Optionals {
  let nickname: String?
  let age: Int?
}

@Contract
private struct Arrays {
  let tags: [String]
  let scores: [Int]
}

@Contract
private struct Inner {
  let value: String
}

@Contract
private struct Outer {
  let label: String
  let inner: Inner
}

@Contract
private struct Composed {
  let items: [Inner]
  let maybeTags: [String]?
}

@Contract
private struct Keywords {
  let `default`: String
  let `class`: Int
}

@Contract
private struct Observed {
  var count: Int = 0 {
    didSet {}
  }

  var name: String = "" {
    willSet {}
    didSet {}
  }
}

@Contract
private struct Bounds {
  let lower, upper: Int
}

@Contract
private struct OptionalNested {
  let inner: Inner?
}

@Contract
private enum MutationEventSample {
  case write(path: String)
  case delete(path: String)
  case move(path: String, to: String)
}

@Contract
private enum Signal {
  case ping
  case put(path: String, ifMatch: String?)
}

@Contract
private enum EntryKindSample: String {
  case file
  case directory
}

@Contract
private struct WithOptionalEnum {
  let kind: EntryKindSample?
}

@Contract
private enum RawCode: String {
  case notFound = "not_found"
  case ok
}

@Contract
private struct WithAnyJSON: Codable, Equatable {
  let payload: JSONValue
  let rows: [JSONValue]
  let extra: JSONValue?
}

@Contract
private enum Command: Codable, Equatable {
  case ping
  case put(path: String, retries: Int?)
}

@Suite
struct ContractSchemaTests {
  @Test func scalarsSchema() {
    #expect(
      Scalars.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "name": .object(["type": .string("string")]),
          "count": .object(["type": .string("integer")]),
          "ratio": .object(["type": .string("number")]),
          "active": .object(["type": .string("boolean")]),
        ]),
        "required": .array([
          .string("name"), .string("count"), .string("ratio"), .string("active"),
        ]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func optionalsAreNullableAndNotRequired() {
    #expect(
      Optionals.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "nickname": .object(["type": .array([.string("string"), .string("null")])]),
          "age": .object(["type": .array([.string("integer"), .string("null")])]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func arraysCarryItemSchema() {
    #expect(
      Arrays.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "tags": .object([
            "type": .string("array"), "items": .object(["type": .string("string")]),
          ]),
          "scores": .object([
            "type": .string("array"), "items": .object(["type": .string("integer")]),
          ]),
        ]),
        "required": .array([.string("tags"), .string("scores")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func nestedReferencesInnerSchema() {
    #expect(
      Outer.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "label": .object(["type": .string("string")]),
          "inner": Inner.jsonSchema,
        ]),
        "required": .array([.string("label"), .string("inner")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func composedArrayOfNestedAndOptionalArray() {
    #expect(
      Composed.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "items": .object(["type": .string("array"), "items": Inner.jsonSchema]),
          "maybeTags": .object([
            "type": .array([.string("array"), .string("null")]),
            "items": .object(["type": .string("string")]),
          ]),
        ]),
        "required": .array([.string("items")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func backtickedNamesUseTheWireKey() {
    #expect(
      Keywords.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "default": .object(["type": .string("string")]),
          "class": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("default"), .string("class")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func observedStoredPropertiesAreIncluded() {
    #expect(
      Observed.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "count": .object(["type": .string("integer")]),
          "name": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("count"), .string("name")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func sharedTypeAnnotationCoversAllBindings() {
    #expect(
      Bounds.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "lower": .object(["type": .string("integer")]),
          "upper": .object(["type": .string("integer")]),
        ]),
        "required": .array([.string("lower"), .string("upper")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func optionalNestedIsAnyOfNullAndNotRequired() {
    #expect(
      OptionalNested.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "inner": .object(["anyOf": .array([Inner.jsonSchema, .object(["type": .string("null")])])]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func discriminatedUnionFlattensLabeledValuesBesideKind() {
    #expect(
      MutationEventSample.jsonSchema == .object([
        "oneOf": .array([
          .object([
            "type": .string("object"),
            "properties": .object([
              "kind": .object(["const": .string("write")]),
              "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("kind"), .string("path")]),
            "additionalProperties": .bool(false),
          ]),
          .object([
            "type": .string("object"),
            "properties": .object([
              "kind": .object(["const": .string("delete")]),
              "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("kind"), .string("path")]),
            "additionalProperties": .bool(false),
          ]),
          .object([
            "type": .string("object"),
            "properties": .object([
              "kind": .object(["const": .string("move")]),
              "path": .object(["type": .string("string")]),
              "to": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("kind"), .string("path"), .string("to")]),
            "additionalProperties": .bool(false),
          ]),
        ]),
      ]),
    )
  }

  @Test func unionValuelessCaseIsConstOnlyAndOptionalFieldIsNullable() {
    #expect(
      Signal.jsonSchema == .object([
        "oneOf": .array([
          .object([
            "type": .string("object"),
            "properties": .object([
              "kind": .object(["const": .string("ping")]),
            ]),
            "required": .array([.string("kind")]),
            "additionalProperties": .bool(false),
          ]),
          .object([
            "type": .string("object"),
            "properties": .object([
              "kind": .object(["const": .string("put")]),
              "path": .object(["type": .string("string")]),
              "ifMatch": .object(["type": .array([.string("string"), .string("null")])]),
            ]),
            "required": .array([.string("kind"), .string("path")]),
            "additionalProperties": .bool(false),
          ]),
        ]),
      ]),
    )
  }

  @Test func rawStringEnumIsStringWithEnumValues() {
    #expect(
      EntryKindSample.jsonSchema == .object([
        "type": .string("string"),
        "enum": .array([.string("file"), .string("directory")]),
      ]),
    )
  }

  @Test func optionalEnumTypedFieldIsAnyOfNull() {
    #expect(
      WithOptionalEnum.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "kind": .object(["anyOf": .array([EntryKindSample.jsonSchema, .object(["type": .string("null")])])]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func rawStringEnumUsesExplicitWireValues() {
    #expect(
      RawCode.jsonSchema == .object([
        "type": .string("string"),
        "enum": .array([.string("not_found"), .string("ok")]),
      ]),
    )
  }

  @Test func jsonValueLeafFieldsAreEmptySchema() {
    #expect(
      WithAnyJSON.jsonSchema == .object([
        "type": .string("object"),
        "properties": .object([
          "payload": .object([:]),
          "rows": .object(["type": .string("array"), "items": .object([:])]),
          "extra": .object([:]),
        ]),
        "required": .array([.string("payload"), .string("rows")]),
        "additionalProperties": .bool(false),
      ]),
    )
  }

  @Test func emittedUnionCodableIsInternallyTaggedAndRoundTrips() throws {
    let encoder = JSONValueEncoder()
    let decoder = JSONValueDecoder()
    #expect(try encoder.encode(Command.ping) == .object(["kind": "ping"]))
    #expect(try encoder.encode(Command.put(path: "a", retries: nil)) == .object(["kind": "put", "path": "a"]))
    #expect(try encoder.encode(Command.put(path: "a", retries: 3)) == .object(["kind": "put", "path": "a", "retries": 3]))
    for value: Command in [.ping, .put(path: "a", retries: nil), .put(path: "a", retries: 3)] {
      #expect(try decoder.decode(Command.self, from: encoder.encode(value)) == value)
    }
  }

  @Test func emittedUnionDecodeRejectsUnknownKind() {
    #expect(throws: (any Error).self) {
      try JSONValueDecoder().decode(Command.self, from: .object(["kind": "explode"]))
    }
  }
}
