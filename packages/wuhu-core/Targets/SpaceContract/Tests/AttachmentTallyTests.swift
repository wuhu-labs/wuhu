import enum SpaceContract.AttachmentLimits
import enum SpaceContract.AttachmentRefusal
import struct SpaceContract.AttachmentTally
import Testing

struct AttachmentTallyTests {
  @Test func `a file at the size limit is admitted and one byte more is refused`() throws {
    var tally = AttachmentTally()
    try tally.open("full")
    try tally.add(AttachmentLimits.maxFileBytes, to: "full")
    #expect(throws: AttachmentRefusal.fileTooLarge(name: "full")) { try tally.add(1, to: "full") }
  }

  @Test func `a total over the limit is refused at the file that breaks it`() throws {
    var tally = AttachmentTally()
    for index in 0 ..< AttachmentLimits.maxTotalBytes / AttachmentLimits.maxFileBytes {
      try tally.admit("full\(index)", size: AttachmentLimits.maxFileBytes)
    }
    #expect(throws: AttachmentRefusal.totalTooLarge(name: "extra")) { try tally.admit("extra", size: 1) }
  }
}
