import JSONValue
import Testing

@Suite struct ParseTests {
  @Test func utf8BytesParseLikeText() {
    let text = #"{"b":[1,2.5,"éé"],"a":null}"#
    #expect(JSONValue.parse(utf8: Array(text.utf8)[...]) == JSONValue.parse(text))
    #expect(JSONValue.parse(utf8: Array(text.utf8))?.jsonString() == #"{"b":[1,2.5,"éé"],"a":null}"#)
    #expect(JSONValue.parse(utf8: Array("{\"a\":".utf8)) == nil)
  }

  @Test func parseBool() {
    let v = JSONValue.parse(#"{"flag": true}"#)!
    guard case let .object(obj) = v,
          case let .bool(b) = obj["flag"]!
    else {
      #expect(Bool(false), "flag should be bool, got \(v)")
      return
    }
    #expect(b == true)
  }

  @Test func prettyIndentsNestedContainersAndKeepsKeyOrder() {
    let v = JSONValue.parse(#"{"b":{"deep":[1,"two"]},"a":{},"c":[]}"#)!
    #expect(v.jsonString(pretty: true) == """
    {
      "b": {
        "deep": [
          1,
          "two"
        ]
      },
      "a": {},
      "c": []
    }
    """)
  }

  @Test func prettyRoundTripsBackToTheSameValue() {
    let v = JSONValue.parse(#"{"a":[{"b":null},true,1.5],"c":"x\ny"}"#)!
    #expect(JSONValue.parse(v.jsonString(pretty: true)) == v)
  }

  @Test func jsonStringSortedKeysOption() {
    let v = JSONValue.parse(#"{"b":2,"a":1}"#)!
    #expect(v.jsonString(sortedKeys: true) == #"{"a":1,"b":2}"#)
  }
}

extension ParseTests {
  @Test func intValueFromInteger() {
    let v = JSONValue.parse(#"{"n": 42}"#)!
    guard case let .object(obj) = v else { return }
    #expect(obj["n"]?.intValue == 42)
  }

  @Test func intValueFromWholeNumber() {
    #expect(JSONValue.number(42).intValue == 42)
  }

  @Test func intValueFromFractional() {
    let v = JSONValue.parse(#"{"n": 3.14}"#)!
    guard case let .object(obj) = v else { return }
    #expect(obj["n"]?.intValue == nil)
  }

  @Test func doubleValueFromInteger() {
    #expect(JSONValue.integer(7).doubleValue == 7.0)
  }

  @Test func intValueFromBool() {
    #expect(JSONValue.bool(true).intValue == nil)
  }

  @Test func intValueFromString() {
    #expect(JSONValue.string("42").intValue == nil)
  }
}

extension ParseTests {
  @Test func integerAndWholeNumberCompareAndHashEqual() {
    let integer = JSONValue.integer(5)
    let number = JSONValue.number(5)
    #expect(integer == number)
    #expect(number == integer)
    #expect(integer.hashValue == number.hashValue)
    #expect(Set([integer, number]).count == 1)
  }

  @Test func objectEqualityIsKeyOrderInsensitive() {
    let a = JSONValue.parse(#"{"b":2,"a":1}"#)!
    let b = JSONValue.parse(#"{"a":1,"b":2}"#)!
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }

  @Test func fractionalNumberNotEqualToNearbyInteger() {
    #expect(JSONValue.number(1.5) != JSONValue.integer(1))
  }
}

extension ParseTests {
  private func nestedArrays(depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
  }

  @Test func parsesUpToDepthLimit() {
    #expect(JSONValue.parse(nestedArrays(depth: 511)) != nil)
    #expect(JSONValue.parse(nestedArrays(depth: 512)) != nil)
  }

  @Test func rejectsBeyondDepthLimit() {
    #expect(JSONValue.parse(nestedArrays(depth: 513)) == nil)
  }

  @Test func survivesPathologicalNestingWithoutCrashing() {
    #expect(JSONValue.parse(String(repeating: "[", count: 100_000)) == nil)
  }

  @Test func rejectsLeadingZeros() {
    #expect(JSONValue.parse("0123") == nil)
    #expect(JSONValue.parse("007") == nil)
    #expect(JSONValue.parse("-01") == nil)
    #expect(JSONValue.parse(#"{"n":0123}"#) == nil)
  }

  @Test func acceptsLoneZeroAndZeroLedFractions() {
    #expect(JSONValue.parse("0") == .integer(0))
    #expect(JSONValue.parse("-0") == .integer(0))
    #expect(JSONValue.parse("0.5") == .number(0.5))
    #expect(JSONValue.parse("0e1") == .number(0))
    #expect(JSONValue.parse("10") == .integer(10))
  }

  @Test func rejectsNonFiniteNumbers() {
    #expect(JSONValue.parse("1e999") == nil)
    #expect(JSONValue.parse("-1e999") == nil)
    #expect(JSONValue.parse(#"{"budget":1e999}"#) == nil)
  }

  @Test func rejectsTrailingGarbage() {
    #expect(JSONValue.parse("{} x") == nil)
    #expect(JSONValue.parse("[1,2] extra") == nil)
    #expect(JSONValue.parse("1 2") == nil)
    #expect(JSONValue.parse("truefalse") == nil)
  }

  @Test func duplicateKeysAreLastWinsAtOriginalPosition() {
    let v = JSONValue.parse(#"{"a":1,"a":2}"#)!
    #expect(v == .object(["a": .integer(2)]))

    let positional = JSONValue.parse(#"{"a":1,"b":2,"a":3}"#)!
    #expect(positional.jsonString() == #"{"a":3,"b":2}"#)
  }
}

extension ParseTests {
  @Test func crossCaseEqualityIsTransitiveAroundTwoToTheFiftyThree() {
    let integerAbove = JSONValue.integer(9_007_199_254_740_993) // 2^53 + 1
    let numberAt = JSONValue.number(9_007_199_254_740_992.0) // 2^53
    let integerAt = JSONValue.integer(9_007_199_254_740_992) // 2^53

    #expect(numberAt == integerAt)
    #expect(integerAbove != numberAt)
    #expect(integerAbove != integerAt)
  }

  @Test func equalValuesHashEqualAcrossNumericCases() {
    let samples: [JSONValue] = [
      .integer(0), .number(0),
      .integer(5), .number(5), .number(5.5),
      .integer(-7), .number(-7),
      .integer(9_007_199_254_740_992), .number(9_007_199_254_740_992.0),
      .integer(9_007_199_254_740_993),
      .number(1e30),
    ]
    for x in samples {
      for y in samples where x == y {
        #expect(x.hashValue == y.hashValue, "\(x) == \(y) but hashes differ")
      }
    }
  }
}

extension ParseTests {
  @Test func literalsBuildExpectedCases() {
    let value: JSONValue = [
      "name": "wuhu",
      "count": 3,
      "ratio": 0.5,
      "enabled": true,
      "tags": ["a", "b"],
    ]
    #expect(value == .object([
      "name": .string("wuhu"),
      "count": .integer(3),
      "ratio": .number(0.5),
      "enabled": .bool(true),
      "tags": .array([.string("a"), .string("b")]),
    ]))
  }
}
