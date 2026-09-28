import Foundation
import JSONValue
import Testing

struct JSONValueCodingTests {
  // Key order is data here: tool-call arguments are replayed to a provider and
  // any reshuffle costs a prompt cache. Our own coders keep document order;
  // Foundation's do not — its encoder ignores the order a keyed container was
  // encoded in, and `allKeys` is not document order coming back. Anything whose
  // bytes must survive a round trip crosses Codable as a string. The day the
  // last expectation here fails is the day Foundation grew order preservation.
  @Test func `object key order survives our coders and not Foundation's`() throws {
    let text = #"{"command":"ls","max_output":30000,"timeout_seconds":30,"zeta":1,"alpha":2,"mu":3,"nu":4,"xi":5,"flag":true,"none":null,"ratio":0.5,"args":["a",1,false]}"#
    let source = try #require(JSONValue.parse(text))
    #expect(source.jsonString() == text)

    let ours = try JSONValueDecoder().decode(JSONValue.self, from: JSONValueEncoder().encode(source))
    #expect(ours.jsonString() == text)

    let foundation = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(source))
    #expect(foundation == source)
    #expect(foundation.jsonString(sortedKeys: true) == source.jsonString(sortedKeys: true))
    #expect(foundation.jsonString() != text)
  }

  @Test func `encodes codable values with json encoder style strategies`() throws {
    let encoder = JSONValueEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.dataEncodingStrategy = .base64
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "inf",
      negativeInfinity: "-inf",
      nan: "nan",
    )

    let value = try encoder.encode(StrategyPayload(
      userId: 42,
      createdAt: Date(timeIntervalSince1970: 1),
      avatarData: Data([1, 2, 3]),
      score: .infinity,
      childValues: [.init(displayName: "Ada Lovelace")],
    ))

    #expect(value == .object([
      "user_id": .number(42),
      "created_at": .string("1970-01-01T00:00:01Z"),
      "avatar_data": .string("AQID"),
      "score": .string("inf"),
      "child_values": .array([
        .object([
          "display_name": .string("Ada Lovelace"),
        ]),
      ]),
    ]))
  }

  @Test func `decodes codable values with json decoder style strategies`() throws {
    let decoder = JSONValueDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    decoder.dataDecodingStrategy = .base64
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf",
      negativeInfinity: "-inf",
      nan: "nan",
    )

    let payload = try decoder.decode(
      StrategyPayload.self,
      from: .object([
        "user_id": .number(42),
        "created_at": .string("1970-01-01T00:00:01Z"),
        "avatar_data": .string("AQID"),
        "score": .string("inf"),
        "child_values": .array([
          .object([
            "display_name": .string("Ada Lovelace"),
          ]),
        ]),
      ]),
    )

    #expect(payload.userId == 42)
    #expect(payload.createdAt == Date(timeIntervalSince1970: 1))
    #expect(payload.avatarData == Data([1, 2, 3]))
    #expect(payload.score == .infinity)
    #expect(payload.childValues == [.init(displayName: "Ada Lovelace")])
  }

  @Test func `iso8601 date strategy accepts explicit utc offsets`() throws {
    let decoder = JSONValueDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let zulu = try decoder.decode(Date.self, from: .string("1970-01-01T00:00:01Z"))
    #expect(zulu == Date(timeIntervalSince1970: 1))

    let offset = try decoder.decode(Date.self, from: .string("1970-01-01T02:00:01+02:00"))
    #expect(offset == Date(timeIntervalSince1970: 1))
  }

  @Test func `formatted date strategies round trip as strings`() throws {
    let formatter = formattedDateStrategyFormatter()
    let date = Date(timeIntervalSince1970: 1_711_972_496)

    let encoder = JSONValueEncoder()
    encoder.dateEncodingStrategy = .formatted(formatter)

    let encoded = try encoder.encode(FormattedDatePayload(createdAt: date))
    #expect(encoded == .object(["createdAt": .string("2024-04-01 11:54:56")]))

    let decoder = JSONValueDecoder()
    decoder.dateDecodingStrategy = .formatted(formatter)

    let decoded = try decoder.decode(FormattedDatePayload.self, from: encoded)
    #expect(decoded == FormattedDatePayload(createdAt: date))
  }

  @Test func `formatted date strategy never falls through to seconds strategy`() throws {
    let formatter = formattedDateStrategyFormatter()

    let encoder = JSONValueEncoder()
    encoder.dateEncodingStrategy = .formatted(formatter)

    let encoded = try encoder.encode(Date(timeIntervalSince1970: 1_711_972_496))
    #expect(encoded == .string("2024-04-01 11:54:56"))
    #expect(encoded != .number(1_711_972_496))

    let decoder = JSONValueDecoder()
    decoder.dateDecodingStrategy = .formatted(formatter)

    #expect(throws: (any Error).self) {
      _ = try decoder.decode(Date.self, from: .number(1_711_972_496))
    }
  }

  @Test func `supports custom strategies and user info`() throws {
    let encoder = JSONValueEncoder()
    encoder.userInfo[.decoration] = "!"
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode("ts:\(Int(date.timeIntervalSince1970))")
    }
    encoder.dataEncodingStrategy = .custom { data, encoder in
      var container = encoder.unkeyedContainer()
      for byte in data {
        try container.encode(Int(byte))
      }
    }

    let encoded = try encoder.encode(CustomPayload(
      createdAt: Date(timeIntervalSince1970: 10),
      blob: Data([4, 5, 6]),
      note: .init(message: "ready"),
    ))

    #expect(encoded == .object([
      "createdAt": JSONValue.string("ts:10"),
      "blob": JSONValue.array([.number(4), .number(5), .number(6)]),
      "note": JSONValue.string("ready!"),
    ]))

    let decoder = JSONValueDecoder()
    decoder.userInfo[.decoration] = "prefix:"
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      guard let seconds = Int(string.dropFirst(3)) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected ts:<seconds> date string.")
      }
      return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    decoder.dataDecodingStrategy = .custom { decoder in
      var container = try decoder.unkeyedContainer()
      var bytes: [UInt8] = []
      while !container.isAtEnd {
        try bytes.append(UInt8(container.decode(Int.self)))
      }
      return Data(bytes)
    }

    let decoded = try decoder.decode(CustomPayload.self, from: encoded)
    #expect(decoded == CustomPayload(
      createdAt: Date(timeIntervalSince1970: 10),
      blob: Data([4, 5, 6]),
      note: .init(message: "prefix:ready!"),
    ))
  }

  @Test func `super encoder and decoder round-trip through enum coding keys`() throws {
    let encoded = try JSONValueEncoder().encode(SubclassPayload(base: "root", extra: 7))
    #expect(encoded == .object([
      "extra": .integer(7),
      "super": .object(["base": .string("root")]),
    ]))

    let decoded = try JSONValueDecoder().decode(SubclassPayload.self, from: encoded)
    #expect(decoded.base == "root")
    #expect(decoded.extra == 7)
  }

  @Test func `encoding a UInt64 above Int.max throws instead of degrading through Double`() {
    let overflowing = UInt64(Int.max) + 1

    #expect(throws: EncodingError.self) {
      _ = try JSONValueEncoder().encode(overflowing)
    }
    #expect(throws: EncodingError.self) {
      _ = try JSONValueEncoder().encode([overflowing])
    }
    #expect(throws: EncodingError.self) {
      _ = try JSONValueEncoder().encode(UInt64Payload(id: overflowing))
    }
  }

  @Test func `encoding a UInt64 within Int range stays an integer`() throws {
    #expect(try JSONValueEncoder().encode(UInt64Payload(id: 42)) == .object(["id": .integer(42)]))
  }
}

private struct UInt64Payload: Codable, Equatable {
  var id: UInt64
}

private class BasePayload: Codable {
  var base: String

  init(base: String) {
    self.base = base
  }
}

private final class SubclassPayload: BasePayload {
  var extra: Int

  enum CodingKeys: String, CodingKey {
    case extra
  }

  init(base: String, extra: Int) {
    self.extra = extra
    super.init(base: base)
  }

  required init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    extra = try container.decode(Int.self, forKey: .extra)
    try super.init(from: container.superDecoder())
  }

  override func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(extra, forKey: .extra)
    try super.encode(to: container.superEncoder())
  }
}

private struct StrategyPayload: Codable, Equatable {
  var userId: Int
  var createdAt: Date
  var avatarData: Data
  var score: Double
  var childValues: [Child]

  struct Child: Codable, Equatable {
    var displayName: String
  }
}

private struct FormattedDatePayload: Codable, Equatable {
  var createdAt: Date
}

private struct CustomPayload: Codable, Equatable {
  var createdAt: Date
  var blob: Data
  var note: DecoratedMessage
}

private struct DecoratedMessage: Codable, Equatable {
  var message: String

  init(message: String) {
    self.message = message
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    let suffix = (encoder.userInfo[.decoration] as? String) ?? ""
    try container.encode(message + suffix)
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let prefix = (decoder.userInfo[.decoration] as? String) ?? ""
    message = try prefix + (container.decode(String.self))
  }
}

private func formattedDateStrategyFormatter() -> DateFormatter {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return formatter
}

private extension CodingUserInfoKey {
  static let decoration = CodingUserInfoKey(rawValue: "decoration")!
}
