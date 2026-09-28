#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import KeelObjectStore
import Testing

@Suite struct ObjectKeyTests {
  @Test func acceptsPlainRelativeKeys() throws {
    for raw in ["a", "wal/000001.wal", "logs/2026/07/20.log", "backups/db.sqlite"] {
      #expect(try ObjectKey(raw).raw == raw)
    }
  }

  @Test func rejectsUnsafeKeys() {
    for raw in ["", "/leading", "trailing/", "a//b", "a/../b", "..", ".", "a/./b", "with\u{0}nul"] {
      #expect(throws: ObjectStoreError.self) { try ObjectKey(raw) }
    }
  }
}

@Suite struct SigV4TimeTests {
  @Test func formatsUTCStamps() {
    #expect(SigV4Time.stamps(from: Date(timeIntervalSince1970: 0)).amzDate == "19700101T000000Z")
    #expect(SigV4Time.stamps(from: Date(timeIntervalSince1970: 0)).dateStamp == "19700101")
    #expect(SigV4Time.stamps(from: Date(timeIntervalSince1970: 1_000_000_000)).amzDate == "20010909T014640Z")
    #expect(SigV4Time.stamps(from: Date(timeIntervalSince1970: 1_369_353_600)).amzDate == "20130524T000000Z")
  }
}

@Suite struct S3ListParserTests {
  @Test func parsesContentsTruncationAndToken() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>bucket</Name>
      <Prefix>wal/</Prefix>
      <KeyCount>2</KeyCount>
      <MaxKeys>2</MaxKeys>
      <IsTruncated>true</IsTruncated>
      <NextContinuationToken>opaque-token-1</NextContinuationToken>
      <Contents>
        <Key>wal/a&amp;b.wal</Key>
        <LastModified>2026-07-20T00:00:00.000Z</LastModified>
        <ETag>&quot;abc&quot;</ETag>
        <Size>17</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
      <Contents>
        <Key>wal/c.wal</Key>
        <Size>4</Size>
      </Contents>
    </ListBucketResult>
    """
    let listing = try S3ListParser.parse(Data(xml.utf8))
    #expect(listing.entries.count == 2)
    #expect(listing.entries[0].key.raw == "wal/a&b.wal")
    #expect(listing.entries[0].size == 17)
    #expect(listing.entries[1].key.raw == "wal/c.wal")
    #expect(listing.entries[1].size == 4)
    #expect(listing.isTruncated)
    #expect(listing.continuationToken == "opaque-token-1")
  }

  @Test func dropsTokenWhenNotTruncated() throws {
    let xml = """
    <ListBucketResult>
      <IsTruncated>false</IsTruncated>
      <Contents><Key>only.txt</Key><Size>1</Size></Contents>
    </ListBucketResult>
    """
    let listing = try S3ListParser.parse(Data(xml.utf8))
    #expect(listing.entries.map { $0.key.raw } == ["only.txt"])
    #expect(listing.continuationToken == nil)
    #expect(!listing.isTruncated)
  }

  @Test func emptyListing() throws {
    let xml = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
    let listing = try S3ListParser.parse(Data(xml.utf8))
    #expect(listing.entries.isEmpty)
    #expect(listing.continuationToken == nil)
  }
}
