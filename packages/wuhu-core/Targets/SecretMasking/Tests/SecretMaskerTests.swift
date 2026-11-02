import SecretMasking
import Testing

struct SecretMaskerTests {
  let masker = SecretMasker(secrets: ["fake-key\n"])

  @Test(arguments: [
    ("fake-key\n", "***"),
    ("Bearer fake-key rejected", "Bearer *** rejected"),
    (#"{"error":"bad header \"fake-key\n\""}"#, #"{"error":"bad header \"***\""}"#),
  ])
  func masksRawTrimmedAndJSONEscapedForms(input: String, expected: String) {
    #expect(masker.masked(input) == expected)
  }

  @Test func escapesQuotesBackslashesAndControlCharacters() {
    let masker = SecretMasker(secrets: ["a\"b\\c\u{1}d"])
    #expect(masker.masked(#"x a\"b\\c\u0001d y"#) == "x *** y")
  }

  @Test func slashesMayBeEscaped() {
    #expect(SecretMasker(secrets: ["fake/key"]).masked(#"fake/key fake\/key"#) == "*** ***")
  }

  @Test func unionAddsSecretsMidStream() {
    var streaming = SecretMasker(secrets: ["fake-one"])
    var output = streaming.mask(Array("fake-one fake-".utf8))
    streaming.formUnion(SecretMasker(secrets: ["fake-two"]))
    output += streaming.mask(Array("two".utf8)) + streaming.flush()
    #expect(String(decoding: output, as: UTF8.self) == "*** ***")
  }

  @Test func blankSecretsMaskNothing() {
    #expect(SecretMasker(secrets: ["", " \n", "\n"]).masked("a \n b\n") == "a \n b\n")
  }

  @Test func streamedFormsSplitAcrossChunksAreMasked() {
    let input = Array(#"fake-key\n | fake-key | fake-key"#.utf8) + [0x0A]
    var streaming = masker
    var output = input.flatMap { streaming.mask([$0]) }
    output += streaming.flush()
    #expect(String(decoding: output, as: UTF8.self) == "*** | *** | ***")
    #expect(output == masker.masked(input))
  }
}
