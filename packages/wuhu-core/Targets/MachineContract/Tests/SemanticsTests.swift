import JSONValue
import MachineContract
import Testing

@Suite
struct SemanticsTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  // Pins SPEC.md: bytes cross the wire base64-encoded, but every byte count —
  // cursors, window, maxOutput — is over decoded raw bytes. Five raw bytes are
  // eight base64 characters; a chars-counting producer fails here.
  @Test func cursorsCountDecodedBytesNotBase64Characters() throws {
    let chunk = Base64Data([104, 101, 108, 108, 111])
    let encoded = try encoder.encode(chunk)
    #expect(encoded == .string("aGVsbG8="))
    #expect(chunk.count == 5)
    if case let .string(text) = encoded {
      #expect(text.count == 8)
    }
    #expect(try decoder.decode(Base64Data.self, from: encoded) == chunk)
  }

  @Test func base64DecodeRejectsNonBase64Text() {
    #expect(throws: (any Error).self) {
      try decoder.decode(Base64Data.self, from: .string("not base64!"))
    }
  }

  @Test func idGrammarsMatchTheirSchemas() {
    #expect(MachineID.isValid("mc_a1b2c3d4"))
    #expect(!MachineID.isValid("mc_A1B2C3D4"))
    #expect(!MachineID.isValid("mc_a1b2c3"))
    #expect(!MachineID.isValid("ex_a1b2c3d4"))
    #expect(ExecID.isValid("ex_a1b2c3d4"))
    #expect(!ExecID.isValid("ex_a1b2c3d4e"))
  }

  // Pins SPEC.md: id decoding is total. Wire acceptance is not the shape gate —
  // isValid is, applied at minting and trust boundaries.
  @Test func idDecodingIsTotal() throws {
    let id = try decoder.decode(MachineID.self, from: .string("bogus"))
    #expect(id.rawValue == "bogus")
    #expect(!MachineID.isValid(id.rawValue))
    #expect(try encoder.encode(id) == .string("bogus"))
  }

  @Test func idsEncodeAsBareStrings() throws {
    #expect(try encoder.encode(MachineID(rawValue: "mc_a1b2c3d4")) == .string("mc_a1b2c3d4"))
    #expect(try encoder.encode(ExecID(rawValue: "ex_a1b2c3d4")) == .string("ex_a1b2c3d4"))
  }

  @Test func stringMapEncodesAsPlainObject() throws {
    let map: StringMap = ["PATH": "/usr/bin", "CI": "1"]
    let json = try encoder.encode(map)
    #expect(json == .object(["CI": "1", "PATH": "/usr/bin"]))
    #expect(try decoder.decode(StringMap.self, from: json) == map)
  }

  @Test func execDefaultWindowIsFourMiB() {
    #expect(ExecDefaults.window == 4_194_304)
  }
}
