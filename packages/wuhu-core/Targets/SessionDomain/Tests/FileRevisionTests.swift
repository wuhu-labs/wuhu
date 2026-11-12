#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing

@Suite struct FileRevisionTests {
  @Test func receiptsRoundTrip() throws {
    for value in [.machine("dev:inode:size:mtime:ctime"), .mtime(Date(timeIntervalSince1970: 100)), .journal(3)] as [FileRevision] {
      #expect(try JSONDecoder().decode(FileRevision.self, from: JSONEncoder().encode(value)) == value)
    }
  }
}
