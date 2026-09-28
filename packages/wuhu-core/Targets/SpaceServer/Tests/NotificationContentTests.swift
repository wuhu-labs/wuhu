import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct NotificationContentTests {
  @Test func sessionEventsAreTitledWithTheSessionAndSayWhatHappened() {
    let errored = NotificationContent(
      .sessionErrored,
      payload: #"{"sessionID":"s1","error":"rate limited"}"#,
      origin: .session("Fix the build"),
    )
    #expect(errored == NotificationContent(title: "Fix the build", subtitle: nil, body: "Stopped with an error: rate limited"))

    let failed = NotificationContent(
      .childFailed,
      payload: #"{"sessionID":"s2","parent":"s1","requestID":"r1","error":"killed"}"#,
      origin: .session("Worker"),
    )
    #expect(failed.body == "Failed with a request still open and sent no final report: killed")

    let deadline = NotificationContent(.requestDeadline, payload: #"{"sessionID":"s2"}"#, origin: .session("Worker"))
    #expect(deadline.body == "Passed its request deadline with no final report.")
  }

  @Test func aMessageIsTitledWithItsSenderAndTheBoxItWasPostedIn() {
    let content = NotificationContent(
      .conversationMessage,
      payload: #"{"sender":"s1","text":"PR is green"}"#,
      origin: .message(sender: "Reviewer", box: "Release train"),
    )
    #expect(content == NotificationContent(title: "Reviewer", subtitle: "Release train", body: "PR is green"))
    #expect(content.singleLineTitle == "Reviewer · Release train")
  }

  @Test func clippingCountsEncodedBytesAndStopsOnACharacterBoundary() {
    #expect(clipped("fits", toJSONBytes: 4) == "fits")
    #expect(clipped("abcdef", toJSONBytes: 5) == "ab…")
    #expect(clipped("\n\n\n\n", toJSONBytes: 7) == "\n\n…")
    #expect(clipped("🇨🇳🇨🇳", toJSONBytes: 12) == "🇨🇳…")
    #expect(clipped("\u{01}x", toJSONBytes: 6) == "…")
    let long = String(repeating: "é\"/", count: 1000)
    let title = clipped(long, toJSONBytes: NotificationContent.titleBytes)
    #expect(jsonBytes(title) <= NotificationContent.titleBytes)
    #expect(long.hasPrefix(title.dropLast()))
  }
}
