#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Testing

// Recorded from the SPA's actual minting code (wuhu-web app/lib/assertion.ts)
// running on WebCrypto in Deno: non-extractable keys, raw signatures, the
// browser's own base64 paths. These pin the cross-language wire contract —
// if the Swift side changes and these fail, the browser breaks too.
@Suite struct WebCryptoInteropTests {
  static let space = "sha256:" + String(repeating: "f", count: 64)
  static let fixtures: [(algorithm: String, label: String, assertion: String)] = [
    (
      algorithm: "ed25519",
      label: "ed25519:6WParhN3C+r085IWG6djxlTb2yNJfONRgQYyhDJGTkg=",
      assertion: "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJlZDI1NTE5OjZXUGFyaE4zQytyMDg1SVdHNmRqeGxUYjJ5TkpmT05SZ1FZeWhESkdUa2c9Iiwic3BhY2UiOiJzaGEyNTY6ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZiIsImV4cCI6NDEwMjQ0NDgwMH0.n8Hy3GpK_4MzUAu9N9Iukv1t9Sd0evYRElBcp0dorH9VrnG3cftogGVKrZLbkWizjAsyvqLhIUyniaRmi9jiDg",
    ),
    (
      algorithm: "p256",
      label: "p256:BAZfBJTxDCYEYgNmpOC7Gfp+GttJFWuTmA4FlHdYahmVyxnG8BM7PcD+OqYPmCLQLV03hIkm8x5vg99gclBZDjI=",
      assertion: "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiJwMjU2OkJBWmZCSlR4RENZRVlnTm1wT0M3R2ZwK0d0dEpGV3VUbUE0RmxIZFlhaG1WeXhuRzhCTTdQY0QrT3FZUG1DTFFMVjAzaElrbTh4NXZnOTlnY2xCWkRqST0iLCJzcGFjZSI6InNoYTI1NjpmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmIiwiZXhwIjo0MTAyNDQ0ODAwfQ.LiH0QQtEPvwkhzVRygX-UzVVGAjPIitFSSlXj8aecsEVtnehm96u-niU_ZpODdeJEDhTtqwO8A8xrhE4r2LLzw",
    ),
  ]

  @Test(arguments: fixtures.indices) func aWebCryptoMintedAssertionVerifies(index: Int) throws {
    let fixture = Self.fixtures[index]
    let parsed = try #require(SignedAssertion(rawValue: fixture.assertion))
    #expect(parsed.claims.key == fixture.label)
    #expect(parsed.claims.space == Self.space)
    #expect(parsed.claims.expiresAt == Date(timeIntervalSince1970: 4_102_444_800))
    #expect(parsed.hasValidSignature(publicKeyLabel: fixture.label))
    let other = Self.fixtures[(index + 1) % Self.fixtures.count]
    #expect(!parsed.hasValidSignature(publicKeyLabel: other.label))
  }
}
