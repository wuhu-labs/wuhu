import struct SessionDomain.Transcript
import enum SpaceCore.SessionCommand
import Testing
@testable import WorkerOwner

@Test func commandSnapshotRoundTrip() throws {
  let command = SessionCommand.compact(instructions: "keep decisions")
  #expect(try CommandSnapshot(command).command() == command)
}

@Test func transcriptSnapshotPreservesNonPersistedSubscriptionSets() throws {
  let transcript = Transcript(registeredSubscriptions: [.init(rawValue: "plain")], handlerSubscriptions: [.init(rawValue: "handler")])
  let snapshot = try ownerDecode(TranscriptSnapshot.self, ownerEncode(TranscriptSnapshot(transcript)))
  #expect(snapshot.value == transcript)
}
