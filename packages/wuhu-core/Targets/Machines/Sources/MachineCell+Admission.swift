import StructuredQueries
import WuweiQueries

@Selection private struct FileAdmissionChannels {
  @Column(as: [String: UInt64].JSONRepresentation.self) var offsets: [String: UInt64]
  @Column(as: [String: UInt64].JSONRepresentation.self) var inputOffsets: [String: UInt64]
}

extension MachineCell {
  var dispatchedFileStreams: Int {
    db.rows(MachineFileOperation.all.where { $0.dispatched }.select {
      FileAdmissionChannels.Columns(offsets: $0.offsets, inputOffsets: $0.inputOffsets)
    }).reduce(0) { $0 + fileStreamCount(inputs: $1.inputOffsets.count, outputs: $1.offsets.count) }
  }

  func fileStreamCount(inputs: Int, outputs: Int) -> Int {
    1 + outputs + (inputs == 0 ? 0 : 1)
  }
}
