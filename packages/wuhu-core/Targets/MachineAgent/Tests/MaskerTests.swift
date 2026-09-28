@testable import MachineAgent
import Testing

private func maskWhole(_ bytes: [UInt8], secrets: [String]) -> [UInt8] {
  var masker = SecretMasker(secrets: secrets)
  return masker.mask(bytes) + masker.flush()
}

private func maskChunked(_ chunks: [[UInt8]], secrets: [String]) -> [UInt8] {
  var masker = SecretMasker(secrets: secrets)
  var output: [UInt8] = []
  for chunk in chunks {
    output += masker.mask(chunk)
  }
  return output + masker.flush()
}

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Suite
struct MaskerTests {
  @Test func masksEverySingleSplitIdentically() {
    let secrets = ["hunter2", "ab"]
    let bytes = Array("xhunter2y ab and hunterhunter2ab tail hunte".utf8)
    let whole = maskWhole(bytes, secrets: secrets)
    let text = String(decoding: whole, as: UTF8.self)
    #expect(text == "x***y *** and hunter****** tail hunte")
    for split in 0 ... bytes.count {
      let chunked = maskChunked([Array(bytes[..<split]), Array(bytes[split...])], secrets: secrets)
      #expect(chunked == whole, "split at \(split)")
    }
  }

  @Test func masksEveryDoubleSplitIdentically() {
    let secrets = ["s3cr3t-long-value", "val"]
    let bytes = Array("s3cr3t-long-value|val|s3cr3t-long-valus3cr3t-long-value".utf8)
    let whole = maskWhole(bytes, secrets: secrets)
    #expect(String(decoding: whole, as: UTF8.self) == "***|***|s3cr3t-long-***u***")
    for first in 0 ... bytes.count {
      for second in first ... bytes.count {
        let chunks = [Array(bytes[..<first]), Array(bytes[first ..< second]), Array(bytes[second...])]
        #expect(maskChunked(chunks, secrets: secrets) == whole, "splits at \(first),\(second)")
      }
    }
  }

  @Test func secretStraddlingEveryBoundary() {
    let secret = "abcdefgh"
    for prefixLength in 0 ..< 8 {
      let bytes = Array("xy".utf8) + Array(secret.utf8) + Array("zw".utf8)
      let split = 2 + prefixLength
      let masked = maskChunked([Array(bytes[..<split]), Array(bytes[split...])], secrets: [secret])
      #expect(String(decoding: masked, as: UTF8.self) == "xy***zw", "prefix \(prefixLength)")
    }
  }

  @Test func overlappingSecretsPreferTheLongestMatch() {
    let masked = maskWhole(Array("aaaaaa".utf8), secrets: ["aaaa", "aa"])
    #expect(String(decoding: masked, as: UTF8.self) == "******")
  }

  @Test func secretAtStreamStartAndEnd() {
    let secrets = ["edge"]
    #expect(String(decoding: maskWhole(Array("edge-middle-edge".utf8), secrets: secrets), as: UTF8.self) == "***-middle-***")
    let chunked = maskChunked([Array("edge-middle-ed".utf8), Array("ge".utf8)], secrets: secrets)
    #expect(String(decoding: chunked, as: UTF8.self) == "***-middle-***")
  }

  @Test func flushReleasesAHeldPrefix() {
    var masker = SecretMasker(secrets: ["abcdef"])
    #expect(masker.mask(Array("xxabc".utf8)) == Array("xx".utf8))
    #expect(masker.flush() == Array("abc".utf8))
  }

  @Test func nonUTF8BytesPassThrough() {
    let bytes: [UInt8] = [0xFF, 0x00, 0xFE, 0x41]
    #expect(maskWhole(bytes, secrets: ["secret"]) == bytes)
  }

  @Test func emptySecretSetIsPassthrough() {
    var masker = SecretMasker(secrets: ["", ""])
    let bytes = Array("anything".utf8)
    #expect(masker.mask(bytes) == bytes)
    #expect(masker.flush() == [])
  }

  @Test func randomizedChunkingMatchesWholeStringMasking() {
    var rng = SplitMix64(seed: 20_260_704)
    let alphabet: [UInt8] = Array("abcXY01".utf8)
    for round in 0 ..< 200 {
      let secrets = (0 ..< Int.random(in: 1 ... 3, using: &rng)).map { _ in
        String(decoding: (0 ..< Int.random(in: 1 ... 6, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }, as: UTF8.self)
      }
      var plain: [UInt8] = []
      for _ in 0 ..< Int.random(in: 0 ... 12, using: &rng) {
        if Bool.random(using: &rng), let secret = secrets.randomElement(using: &rng) {
          plain += Array(secret.utf8)
        } else {
          plain += (0 ..< Int.random(in: 0 ... 5, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
        }
      }
      var chunks: [[UInt8]] = []
      var index = 0
      while index < plain.count {
        let end = min(index + Int.random(in: 1 ... 4, using: &rng), plain.count)
        chunks.append(Array(plain[index ..< end]))
        index = end
      }
      let whole = maskWhole(plain, secrets: secrets)
      let chunked = maskChunked(chunks, secrets: secrets)
      #expect(chunked == whole, "round \(round) secrets \(secrets) plain \(plain)")
    }
  }
}
