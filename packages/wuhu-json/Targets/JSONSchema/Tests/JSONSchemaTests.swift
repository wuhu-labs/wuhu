import JSONSchema
import JSONValue
import Testing

@Suite struct JSONSchemaTests {
  private func schema(_ text: String) throws -> JSONSchema {
    try JSONSchema(#require(JSONValue.parse(text)))
  }

  private func violations(_ schemaText: String, _ instance: String) throws -> [String] {
    try schema(schemaText).violations(of: #require(JSONValue.parse(instance)))
  }

  @Test func anObjectSchemaChecksTypesRequiredAndExtraProperties() throws {
    let verdict = #"""
    {"type": "object", "title": "Verdict",
     "properties": {"verdict": {"enum": ["approve", "block"]}, "findings": {"type": "array", "items": {"type": "string"}, "maxItems": 2}},
     "required": ["verdict"], "additionalProperties": false}
    """#
    #expect(try violations(verdict, #"{"verdict": "approve", "findings": ["a"]}"#).isEmpty)
    #expect(try violations(verdict, #"{"findings": ["a", 2, "c"], "extra": 1}"#) == [
      "$.findings[1] is integer, not string",
      "$.findings has 3 items, wants at most 2",
      "$.verdict is required",
      "$.extra is not an allowed property",
    ])
    #expect(try violations(verdict, #""approve""#) == ["$ is string, not object"])
  }

  @Test func numbersBoundsAndIntegersFollowJSONNotSwift() throws {
    #expect(try violations(#"{"type": "integer", "minimum": 1}"#, "2.0").isEmpty)
    #expect(try violations(#"{"type": "integer", "minimum": 1}"#, "0.5") == ["$ is number, not integer", "$ is 0.5, wants at least 1.0"])
    #expect(try violations(#"{"type": ["number", "null"], "exclusiveMaximum": 3}"#, "null").isEmpty)
    #expect(try violations(#"{"exclusiveMaximum": 3}"#, "3") == ["$ is 3.0, wants less than 3.0"])
    #expect(try violations(#"{"type": "string", "minLength": 2}"#, #""é""#) == ["$ has 1 characters, wants at least 2"])
  }

  @Test func lengthsCountCodePointsNotGraphemes() throws {
    #expect(try violations(#"{"minLength": 2, "maxLength": 2}"#, #""e\u0301""#).isEmpty)
    #expect(try violations(#"{"maxLength": 1}"#, "\"🇯🇵\"") == ["$ has 2 characters, wants at most 1"])
  }

  @Test func combinatorsCountMatchingBranches() throws {
    let either = #"{"oneOf": [{"type": "integer"}, {"type": "number"}]}"#
    #expect(try violations(either, "1.5").isEmpty)
    #expect(try violations(either, "1") == ["$ matches 2 of oneOf, wants exactly 1"])
    #expect(try violations(#"{"anyOf": [{"const": 1}, {"const": "one"}]}"#, "2") == ["$ matches none of anyOf"])
    #expect(try violations(#"{"not": {"type": "null"}}"#, "null") == ["$ matches a schema under not"])
    #expect(try violations(#"{"allOf": [true, {"additionalProperties": {"type": "boolean"}}]}"#, #"{"a": 1}"#) == ["$.a is integer, not boolean"])
    #expect(try violations("false", "{}") == ["$ is not allowed"])
  }

  @Test func aSchemaIsRefusedForWhatItCannotEnforce() {
    func refusal(_ text: String) -> String? {
      do throws(JSONSchemaError) { _ = try JSONSchema(JSONValue.parse(text)!); return nil } catch { return error.description }
    }
    #expect(refusal(#"{"properties": {"name": {"pattern": "^a"}}}"#) == "#/properties/name: pattern is not a supported keyword")
    #expect(refusal(#"{"type": "float"}"#) == "#: type is one of null, boolean, integer, number, string, array, object or an array of them")
    #expect(refusal("[]") == "# is not a schema: a schema is an object or a boolean")
  }
}
