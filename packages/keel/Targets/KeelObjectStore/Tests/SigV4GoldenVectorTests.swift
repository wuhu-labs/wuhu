#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import KeelObjectStore
import Testing

private struct Vector {
  var method: String
  var canonicalURI: String
  var queryItems: [(name: String, value: String)]
  var headers: [SigV4.Header]
  var payloadHash: String
  var secretAccessKey: String
  var accessKeyID: String
  var amzDate: String
  var dateStamp: String
  var region: String
  var service: String

  func canonicalRequest() -> (request: String, signedHeaders: String) {
    SigV4.canonicalRequest(
      method: self.method,
      canonicalURI: self.canonicalURI,
      canonicalQuery: SigV4.canonicalQuery(self.queryItems),
      headers: self.headers,
      payloadHash: self.payloadHash,
    )
  }

  func signature() -> String {
    let (request, _) = self.canonicalRequest()
    let scope = SigV4.scope(dateStamp: self.dateStamp, region: self.region, service: self.service)
    let stringToSign = SigV4.stringToSign(amzDate: self.amzDate, scope: scope, canonicalRequest: request)
    let key = SigV4.signingKey(
      secretAccessKey: self.secretAccessKey,
      dateStamp: self.dateStamp,
      region: self.region,
      service: self.service,
    )
    return SigV4.signature(signingKey: key, stringToSign: stringToSign)
  }
}

@Suite struct SigV4GoldenVectorTests {
  // aws-sig-v4-test-suite: get-vanilla
  @Test func getVanilla() {
    let vector = Vector(
      method: "GET",
      canonicalURI: "/",
      queryItems: [],
      headers: [
        SigV4.Header(name: "host", value: "example.amazonaws.com"),
        SigV4.Header(name: "x-amz-date", value: "20150830T123600Z"),
      ],
      payloadHash: SigV4.emptyPayloadHash,
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      accessKeyID: "AKIDEXAMPLE",
      amzDate: "20150830T123600Z",
      dateStamp: "20150830",
      region: "us-east-1",
      service: "service",
    )

    let expectedCanonical = """
    GET
    /

    host:example.amazonaws.com
    x-amz-date:20150830T123600Z

    host;x-amz-date
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    """
    #expect(vector.canonicalRequest().request == expectedCanonical)
    #expect(vector.signature() == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  }

  // AWS S3 docs: "Example: GET Object" (virtual-host, empty payload, Range header).
  @Test func s3GetObject() {
    let vector = Vector(
      method: "GET",
      canonicalURI: SigV4.canonicalURI(path: "/test.txt", doubleEncode: false),
      queryItems: [],
      headers: [
        SigV4.Header(name: "host", value: "examplebucket.s3.amazonaws.com"),
        SigV4.Header(name: "range", value: "bytes=0-9"),
        SigV4.Header(name: "x-amz-content-sha256", value: SigV4.emptyPayloadHash),
        SigV4.Header(name: "x-amz-date", value: "20130524T000000Z"),
      ],
      payloadHash: SigV4.emptyPayloadHash,
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      accessKeyID: "AKIAIOSFODNN7EXAMPLE",
      amzDate: "20130524T000000Z",
      dateStamp: "20130524",
      region: "us-east-1",
      service: "s3",
    )

    let expectedCanonical = """
    GET
    /test.txt

    host:examplebucket.s3.amazonaws.com
    range:bytes=0-9
    x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    x-amz-date:20130524T000000Z

    host;range;x-amz-content-sha256;x-amz-date
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    """
    #expect(vector.canonicalRequest().request == expectedCanonical)
    #expect(vector.signature() == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
  }

  // AWS S3 docs: "Example: PUT Object" (single-encoded `$` in path, real payload
  // hash, `date` + `x-amz-*` in signed headers).
  @Test func s3PutObject() {
    let payloadHash = hexSHA256(Array("Welcome to Amazon S3.".utf8))
    let vector = Vector(
      method: "PUT",
      canonicalURI: SigV4.canonicalURI(path: "/test$file.text", doubleEncode: false),
      queryItems: [],
      headers: [
        SigV4.Header(name: "date", value: "Fri, 24 May 2013 00:00:00 GMT"),
        SigV4.Header(name: "host", value: "examplebucket.s3.amazonaws.com"),
        SigV4.Header(name: "x-amz-content-sha256", value: payloadHash),
        SigV4.Header(name: "x-amz-date", value: "20130524T000000Z"),
        SigV4.Header(name: "x-amz-storage-class", value: "REDUCED_REDUNDANCY"),
      ],
      payloadHash: payloadHash,
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      accessKeyID: "AKIAIOSFODNN7EXAMPLE",
      amzDate: "20130524T000000Z",
      dateStamp: "20130524",
      region: "us-east-1",
      service: "s3",
    )

    #expect(vector.canonicalURI == "/test%24file.text")
    let expectedCanonical = """
    PUT
    /test%24file.text

    date:Fri, 24 May 2013 00:00:00 GMT
    host:examplebucket.s3.amazonaws.com
    x-amz-content-sha256:\(payloadHash)
    x-amz-date:20130524T000000Z
    x-amz-storage-class:REDUCED_REDUNDANCY

    date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
    \(payloadHash)
    """
    #expect(vector.canonicalRequest().request == expectedCanonical)
    #expect(vector.signature() == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
  }

  @Test func uriEncodingRules() {
    #expect(SigV4.uriEncode("photos/2006/sample.jpg", encodeSlash: false) == "photos/2006/sample.jpg")
    #expect(SigV4.uriEncode("a b+c", encodeSlash: true) == "a%20b%2Bc")
    #expect(SigV4.uriEncode("key/with space", encodeSlash: false) == "key/with%20space")
    #expect(SigV4.uriEncode("key/with space", encodeSlash: true) == "key%2Fwith%20space")
    #expect(SigV4.uriEncode("~-._", encodeSlash: false) == "~-._")
  }

  @Test func querySortingAndHeaderTrimming() {
    #expect(
      SigV4.canonicalQuery([("Param2", "value2"), ("Param1", "value1")])
        == "Param1=value1&Param2=value2",
    )
    let (canonical, signed) = SigV4.canonicalHeaders([
      SigV4.Header(name: "X-Amz-Date", value: "20150830T123600Z"),
      SigV4.Header(name: "Host", value: "  example.amazonaws.com  "),
      SigV4.Header(name: "My-Header", value: "a   b   c"),
    ])
    #expect(signed == "host;my-header;x-amz-date")
    #expect(canonical == "host:example.amazonaws.com\nmy-header:a b c\nx-amz-date:20150830T123600Z\n")
  }

  @Test func unsignedPayloadIsSelfConsistent() {
    let (request, _) = SigV4.canonicalRequest(
      method: "PUT",
      canonicalURI: "/wal/000001.wal",
      canonicalQuery: "",
      headers: [
        SigV4.Header(name: "host", value: "bucket.example.com"),
        SigV4.Header(name: "x-amz-content-sha256", value: SigV4.unsignedPayload),
        SigV4.Header(name: "x-amz-date", value: "20150830T123600Z"),
      ],
      payloadHash: SigV4.unsignedPayload,
    )
    #expect(request.hasSuffix("\nUNSIGNED-PAYLOAD"))
  }
}
